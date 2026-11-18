// The desktop robot: Burnbot standing on your desktop with nothing around it.
//
// It is a borderless, see-through panel a little bigger than the robot, so the screen its head
// turns into, a speech bubble or its panel have room beside it. Only the robot and those catch
// the mouse; everywhere else a click goes through to whatever is underneath.
//
// The page (public/companion.html) draws everything and says where its clickable parts are
// ('hit'). This side moves the window, follows the pointer (a panel that never takes the focus
// gets no mouse-moved events of its own, so the page could not tell you are pointing at it while
// you work in another app), lets you drag the robot, and turns clicks on and off.
//
// A quick two-finger flick over the robot sends it to one of eight spots around its screen: the
// way your fingers went picks the spot (left: the middle of the left edge, up and right: the
// top-right corner), wherever it stands. An ordinary scroll over it does nothing.

import Cocoa
import WebKit

/// A web view that takes the first click, even while Burnbot is in the background.
final class FirstClickWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class Companion: NSObject {
    /// Robot pixels to points: Small, Medium, Large.
    static let scales = [2, 3, 4]
    static let sizeNames = ["Small", "Medium", "Large"]
    /// Hover screens: 1 the head grows into a big screen with the rate, 2 it widens into a strip
    /// with the eyes at one end, 3 a smaller head with a thin frame. Drawn in public/companion.js.
    static let styleNames = ["Big", "Wide", "Compact"]
    /// The window, in robot pixels: room for the head grown into a screen, and a bubble or the panel beside it.
    static let room = NSSize(width: 210, height: 150)
    /// The robot's feet from the window's near side, and from its bottom when things open upward.
    static let feetIn = NSPoint(x: 52, y: 10)
    /// Room above the feet for the tallest the robot gets (its head as a screen, flames on top).
    static let headroom: CGFloat = 82
    /// The robot at rest, in robot pixels: arms to arms, and feet to antenna (robotBox in companion.js).
    static let body = NSSize(width: 40, height: 53)
    /// The gap, in robot pixels, it keeps from the edge of the screen you can see.
    static let margin: CGFloat = 4

    let panel: NSPanel
    let view: WKWebView
    private(set) var size: Int                       // index into scales
    private(set) var style: Int                      // how the head turns into a screen, 1 to 3 (see styleNames)
    private var feet: NSPoint                        // where the robot stands, on screen
    private var openRight = true, openDown = false   // which way its bubble and panel open: toward the screen's middle
    private var hits: [NSRect] = []                  // the parts that catch the mouse, in page coordinates
    private var robot: NSRect = .zero                // the robot itself: drag it, right-click it
    private var timer: Timer?
    private var monitors: [Any] = []
    private var outside: Any?
    private var pointer: NSPoint?
    private var drag: (start: NSPoint, feet: NSPoint, moving: Bool)?
    private var swipe: (at: TimeInterval, dx: CGFloat, dy: CGFloat)?   // a two-finger swipe begun over the robot
    private var swallowing = false                                      // the rest of that swipe, its glide included
    private var slide: (from: NSPoint, to: NSPoint, at: TimeInterval)?
    private var slider: Timer?
    private let remember: Bool

    /// The right-click menu.
    var menu: (() -> NSMenu)?

    var isVisible: Bool { panel.isVisible }
    var scale: CGFloat { CGFloat(Self.scales[size]) }

    init(view: WKWebView, remember: Bool) {
        self.view = view
        self.remember = remember
        let defaults = UserDefaults.standard
        size = remember ? min(max(defaults.object(forKey: "robotSize") as? Int ?? 1, 0), 2) : 1
        style = remember ? min(max(defaults.object(forKey: "hoverStyle") as? Int ?? 1, 1), 3) : 1
        feet = .zero
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "Burnbot Robot"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        view.setValue(false, forKey: "drawsBackground")
        view.underPageBackgroundColor = .clear
        panel.contentView = view
        if remember, let saved = defaults.string(forKey: "robotFeet") {
            let parts = saved.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 { feet = NSPoint(x: parts[0], y: parts[1]) }
        }
    }

    // MARK: Showing

    /// Shows the robot where you left it, or in the bottom-right corner of `screen` the first time.
    func show(on screen: NSScreen?, onTop: Bool) {
        if feet == .zero || NSScreen.screens.allSatisfy({ !$0.frame.contains(feet) }) {
            let area = (screen ?? NSScreen.screens[0]).visibleFrame
            feet = NSPoint(x: area.maxX - 70 * scale, y: area.minY + 14 * scale)
        }
        setOnTop(onTop)
        settle()
        panel.orderFrontRegardless()
        start()
    }

    /// Called when the robot leaves the desktop. A hidden page stops running, so it can no longer
    /// say that you have stopped pointing at it or reading its panel: whatever it held back must go.
    var onHide: (() -> Void)?

    func hide() {
        panel.orderOut(nil)
        stop()
        say("window.burnbotHidden && window.burnbotHidden()")
        onHide?()
    }

    func setOnTop(_ on: Bool) {
        panel.level = on ? .floating : .normal
        panel.collectionBehavior = on ? [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle] : [.ignoresCycle]
    }

    func setSize(_ index: Int) {
        size = min(max(index, 0), 2)
        if remember { UserDefaults.standard.set(size, forKey: "robotSize") }
        settle()
    }

    func setStyle(_ n: Int) {
        style = min(max(n, 1), 3)
        if remember { UserDefaults.standard.set(style, forKey: "hoverStyle") }
        tellPlace()
    }

    /// Keeps the robot on its screen, picks the way things open, and moves the window there.
    func settle() {
        let area = visibleArea()
        let s = scale, edge = Self.margin * s
        feet.x = min(max(feet.x, area.minX + edge + Self.body.width / 2 * s), area.maxX - edge - Self.body.width / 2 * s)
        feet.y = min(max(feet.y, area.minY + edge), area.maxY - edge - Self.body.height * s)
        openRight = feet.x < area.midX
        openDown = feet.y > area.midY
        panel.setFrame(frame(), display: true)
        if remember { UserDefaults.standard.set("\(Int(feet.x)),\(Int(feet.y))", forKey: "robotFeet") }
        tellPlace()
    }

    /// The part of the robot's screen you can see (of the nearest screen, if its feet are off every one).
    private func visibleArea() -> NSRect {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(feet) })
            ?? NSScreen.screens.min(by: { distance($0.frame, feet) < distance($1.frame, feet) }) ?? NSScreen.screens[0]
        return screen.visibleFrame
    }

    /// Its head grown into a screen is wider and taller than the robot at rest: near an edge the
    /// robot steps in just far enough to keep it all on screen, and back as it shrinks. Its spot stays.
    private func keepInside() {
        guard drag == nil, slide == nil, !robot.isEmpty else { return }
        let f = frame(), area = visibleArea(), edge = Self.margin * scale
        let box = NSRect(x: f.minX + robot.minX, y: f.maxY - robot.maxY, width: robot.width, height: robot.height)
        let dx = max(0, area.minX + edge - box.minX) - max(0, box.maxX - (area.maxX - edge))
        let dy = max(0, area.minY + edge - box.minY) - max(0, box.maxY - (area.maxY - edge))
        let origin = NSPoint(x: f.minX + dx, y: f.minY + dy)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }

    private func distance(_ rect: NSRect, _ p: NSPoint) -> CGFloat {
        hypot(max(rect.minX - p.x, 0, p.x - rect.maxX), max(rect.minY - p.y, 0, p.y - rect.maxY))
    }

    /// The window around the robot's feet.
    private func frame() -> NSRect {
        let s = scale
        let w = Self.room.width * s, h = Self.room.height * s
        let x = openRight ? feet.x - Self.feetIn.x * s : feet.x - (w - Self.feetIn.x * s)
        let y = openDown ? feet.y + Self.headroom * s - h : feet.y - Self.feetIn.y * s
        return NSRect(x: x.rounded(), y: y.rounded(), width: w, height: h)
    }

    /// Where the robot stands in the page, which way things open, and the part of the window that is on screen.
    func tellPlace() {
        let f = frame()
        let s = scale
        let x = openRight ? Self.feetIn.x * s : f.width - Self.feetIn.x * s
        let y = openDown ? Self.headroom * s : f.height - Self.feetIn.y * s
        let area = (panel.screen ?? NSScreen.screens[0]).visibleFrame.intersection(f)
        let shown = area.isEmpty ? NSRect(origin: .zero, size: f.size)
            : NSRect(x: area.minX - f.minX, y: f.maxY - area.maxY, width: area.width, height: area.height)
        let place: [String: Any] = [
            "scale": Int(s), "style": style, "x": Int(x), "y": Int(y), "right": openRight, "down": openDown,
            "shown": [Int(shown.minX), Int(shown.minY), Int(shown.width), Int(shown.height)],
        ]
        say("window.burnbotPlace && window.burnbotPlace(\(json(place)))")
    }

    /// The page says where its clickable parts are: [[x, y, w, h], …] and the robot's own box.
    func setHits(_ rects: [[Double]], robot box: [Double]) {
        hits = rects.filter { $0.count == 4 }.map { NSRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
        if box.count == 4 { robot = NSRect(x: box[0], y: box[1], width: box[2], height: box[3]) }
        keepInside()
        follow()
    }

    /// While the panel is open, a click anywhere else closes it.
    func watchOutside(_ on: Bool) {
        if on, outside == nil {
            outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.say("window.burnbotOutside && window.burnbotOutside()")
            }
        } else if !on, let monitor = outside {
            NSEvent.removeMonitor(monitor)
            outside = nil
        }
    }

    // MARK: The pointer

    private func start() {
        guard timer == nil else { return }
        let tick = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.follow() }
        RunLoop.main.add(tick, forMode: .common)
        timer = tick
        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .scrollWheel]) { [weak self] event in
            self?.handle(event) ?? event
        }
        if let local { monitors.append(local) }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        if slide != nil { finishSlide() }
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        watchOutside(false)
        if pointer != nil {
            pointer = nil
            say("window.burnbotPointer && window.burnbotPointer(null)")
        }
    }

    /// The pointer, in page coordinates.
    private func local(_ p: NSPoint) -> NSPoint {
        let f = panel.frame
        return NSPoint(x: p.x - f.minX, y: f.maxY - p.y)
    }

    /// Thirty times a second: tell the page where the pointer is, and catch clicks only over its clickable parts.
    private func follow() {
        guard panel.isVisible else { return }
        let mouse = NSEvent.mouseLocation
        let inside = panel.frame.contains(mouse)
        let p = local(mouse)
        if drag?.moving != true {
            let over = inside && hits.contains { $0.contains(p) }
            if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
        }
        let now: NSPoint? = inside ? NSPoint(x: p.x.rounded(), y: p.y.rounded()) : nil
        if now != pointer {
            pointer = now
            say(now.map { "window.burnbotPointer && window.burnbotPointer(\(Int($0.x)), \(Int($0.y)))" } ?? "window.burnbotPointer && window.burnbotPointer(null)")
        }
    }

    /// Drag the robot by itself; right-click it for its menu. Anything else goes to the page.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.window === panel else {
            // A click in another of Burnbot's own windows is a click outside, too.
            if outside != nil, event.type == .leftMouseDown || event.type == .rightMouseDown {
                say("window.burnbotOutside && window.burnbotOutside()")
            }
            return event
        }
        let mouse = NSEvent.mouseLocation
        switch event.type {
        case .leftMouseDown:
            if robot.contains(local(mouse)) { drag = (mouse, feet, false) }
            return event
        case .leftMouseDragged:
            guard var moving = drag else { return event }
            if !moving.moving {
                guard hypot(mouse.x - moving.start.x, mouse.y - moving.start.y) >= 3 else { return event }
                moving.moving = true
                drag = moving
                say("window.burnbotDrag && window.burnbotDrag(true)")
            }
            feet = NSPoint(x: moving.feet.x + mouse.x - moving.start.x, y: moving.feet.y + mouse.y - moving.start.y)
            panel.setFrameOrigin(frame().origin)
            return nil
        case .leftMouseUp:
            guard let moved = drag else { return event }
            drag = nil
            if moved.moving {
                settle()
                say("window.burnbotDrag && window.burnbotDrag(false)")
            }
            return event
        case .rightMouseDown:
            guard robot.contains(local(mouse)), let menu = menu?() else { return event }
            NSMenu.popUpContextMenu(menu, with: event, for: view)
            return nil
        case .scrollWheel:
            return scrolled(event, over: robot.contains(local(mouse))) ? nil : event
        default:
            return event
        }
    }

    // MARK: Flicking it to a spot

    /// A flick: a short, quick two-finger swipe in one clear direction.
    static let flickDistance: CGFloat = 60      // points the fingers travel, at least
    static let flickTime: TimeInterval = 0.35   // from the fingers moving to them lifting, at most
    static let slideTime: TimeInterval = 0.2

    /// Follows a two-finger swipe that began over the robot, and flicks it when the fingers lift.
    /// True when the event is the robot's (the page should not scroll).
    private func scrolled(_ event: NSEvent, over: Bool) -> Bool {
        // A wheel mouse has no fingers to lift: it never flicks.
        guard event.hasPreciseScrollingDeltas else { return false }
        if event.momentumPhase != [] {
            let ours = swallowing
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { swallowing = false }
            return ours
        }
        switch event.phase {
        case .mayBegin:
            // Fingers down again: whatever was gliding before is over.
            swallowing = false
            return false
        case .began:
            guard over, drag == nil else { swallowing = false; return false }
            swipe = (event.timestamp, 0, 0)
            swallowing = true
            add(event)
            return true
        case .changed:
            add(event)
            return swallowing
        case .ended:
            add(event)
            if let done = swipe { flick(done, ended: event.timestamp) }
            swipe = nil
            return swallowing
        case .cancelled:
            swipe = nil
            return swallowing
        default:
            return swallowing
        }
    }

    /// Adds up how far the fingers went, on screen: right and up are positive. With natural scrolling
    /// (the Mac's default) the page follows the fingers; without it, the page goes the other way.
    private func add(_ event: NSEvent) {
        guard var going = swipe else { return }
        let follows: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        going.dx += follows * event.scrollingDeltaX
        going.dy -= follows * event.scrollingDeltaY
        swipe = going
    }

    private func flick(_ done: (at: TimeInterval, dx: CGFloat, dy: CGFloat), ended: TimeInterval) {
        let (dx, dy) = (done.dx, done.dy)
        let ms = Int((ended - done.at) * 1000)
        let far = hypot(dx, dy), across = min(abs(dx), abs(dy)), along = max(abs(dx), abs(dy))
        var line = "Flick: dx \(Int(dx)) dy \(Int(dy)) in \(ms)ms → "
        defer { log(line) }
        guard far >= Self.flickDistance else { line += "ignored (too short)"; return }
        guard ended - done.at <= Self.flickTime else { line += "ignored (too slow)"; return }
        // Eight ways: straight along an axis, or a diagonal when neither axis is under half the other.
        let diagonal = across >= along / 2
        let way = (col: abs(dx) >= abs(dy) || diagonal ? (dx < 0 ? -1 : 1) : 0,
                   row: abs(dy) > abs(dx) || diagonal ? (dy < 0 ? -1 : 1) : 0)
        // One spot on from the one it is at, that way; along the other axis it stays put. At an edge it
        // stays on it: flicked right at the top right, it is still at the top right.
        let at = cell()
        var col = min(max(at.col + way.col, -1), 1), row = min(max(at.row + way.row, -1), 1)
        // The middle of the screen is no spot: it carries on through to the far side.
        if col == 0, row == 0 { (col, row) = (way.col, way.row) }
        let (to, name) = spot(col: col, row: row)
        line += name
        glide(to: to)
    }

    /// The spot it is at, or nearest to: which third of its screen it stands in, across and up.
    /// While it slides, the spot it is sliding to.
    private func cell() -> (col: Int, row: Int) {
        let area = visibleArea(), at = slide?.to ?? feet
        func third(_ v: CGFloat, _ low: CGFloat, _ span: CGFloat) -> Int { v < low + span / 3 ? -1 : v > low + span * 2 / 3 ? 1 : 0 }
        return (third(at.x, area.minX, area.width), third(at.y + Self.body.height * scale / 2, area.minY, area.height))
    }

    /// One of the eight spots on the robot's screen, as where its feet go: the robot at rest a
    /// margin in from the edges of the part of the screen you can see (where a drag can take it).
    private func spot(col: Int, row: Int) -> (NSPoint, String) {
        let area = visibleArea()
        let s = scale, edge = Self.margin * s, w = Self.body.width * s, h = Self.body.height * s
        let x = [area.minX + edge + w / 2, area.midX, area.maxX - edge - w / 2][col + 1]
        let y = [area.minY + edge, area.midY - h / 2, area.maxY - edge - h][row + 1]
        let name = (row == 0 ? "middle" : row > 0 ? "top" : "bottom") + "-" + (col == 0 ? "middle" : col > 0 ? "right" : "left")
        return (NSPoint(x: x.rounded(), y: y.rounded()), name)
    }

    /// Slides the robot there, quickly and slowing as it lands; with Reduce Motion it is just there.
    /// A new flick on the way sends it on from wherever it has got to.
    private func glide(to: NSPoint) {
        if slide == nil { say("window.burnbotDrag && window.burnbotDrag(true)") }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            feet = to
            return finishSlide()
        }
        slide = (feet, to, ProcessInfo.processInfo.systemUptime)
        guard slider == nil else { return }
        let tick = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(tick, forMode: .common)
        slider = tick
    }

    private func step() {
        guard let going = slide else { return finishSlide() }
        let t = min((ProcessInfo.processInfo.systemUptime - going.at) / Self.slideTime, 1)
        let eased = 1 - pow(1 - t, 3)
        feet = NSPoint(x: going.from.x + (going.to.x - going.from.x) * eased, y: going.from.y + (going.to.y - going.from.y) * eased)
        panel.setFrameOrigin(frame().origin)
        if t >= 1 { finishSlide() }
    }

    private func finishSlide() {
        slider?.invalidate()
        slider = nil
        if let going = slide { feet = going.to }
        slide = nil
        settle()
        say("window.burnbotDrag && window.burnbotDrag(false)")
    }

    private func say(_ script: String) {
        view.evaluateJavaScript(script, completionHandler: nil)
    }

    private func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
