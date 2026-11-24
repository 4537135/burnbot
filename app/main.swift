// Burnbot.app: tracks Claude Code token burn on this Mac, turns it into a
// level calibrated to you, and shows it on two windows of its own (the
// dashboard and the robot) and, if one is plugged in, a desk screen.
//
// Everything runs inside the app, and nothing is sent anywhere unless you switch
// on AI session summaries (Summaries.swift). The screens are the pages in public/;
// the tracker is Tracker.swift and Metrics.swift; what the robot notices and how it
// reacts is Signals.swift and Moments.swift.
//
// Options, for testing and for working on the screens:
//   --pages <folder>      serve the screens from a folder instead of the app (edit, then ⌘R)
//   --root <folder>       read session logs from here instead of ~/.claude/projects
//   --data <folder>       keep history here instead of Application Support
//   --fresh               behave like a first launch: no saved history, show the welcome
//   --background          start without taking the focus (pair with `open -g`)
//   --snapshot <folder>   write a picture of each window a few seconds after start
//   --dump-state <file>   print what the tracker sees as JSON and quit (add --now <ms>)
//   --dump-timeline <fixture folder>   replay a recorded session and print what the robot
//                         noticed, decided and showed (tools/check-moments.sh)
//   --demo                play every moment once the robot is up (Robot > Play Every Moment)

import Cocoa
import ServiceManagement
import WebKit

// MARK: - Logging (~/Library/Logs/Burnbot.log)

let logURL: URL = {
    let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("Burnbot.log")
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    if size == 0 || size > 1_000_000 { FileManager.default.createFile(atPath: url.path, contents: nil) }
    return url
}()

func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    let fd = open(logURL.path, O_WRONLY | O_APPEND)
    guard fd >= 0 else { return }
    _ = line.withCString { write(fd, $0, strlen($0)) }
    close(fd)
}

func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let fresh = CommandLine.arguments.contains("--fresh")
let logsRoot = argument("--root") ?? NSHomeDirectory() + "/.claude/projects"
let dataFolder: String = {
    if let chosen = argument("--data") { return chosen }
    if fresh { return NSTemporaryDirectory() + "burnbot-fresh-\(ProcessInfo.processInfo.processIdentifier)" }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Burnbot").path
}()
let pagesFolder = argument("--pages").map { URL(fileURLWithPath: $0) } ?? Bundle.main.resourceURL!.appendingPathComponent("public")
/// The session Play Every Moment replays: in the app, or next to the pages when working on them.
let demoFolder: String = {
    let packed = Bundle.main.resourceURL!.appendingPathComponent("demo").path
    if argument("--pages") == nil, FileManager.default.fileExists(atPath: packed) { return packed }
    return pagesFolder.deletingLastPathComponent().appendingPathComponent("tools/fixtures/demo").path
}()

// MARK: - Headless: what does the tracker see?

if let fixture = argument("--dump-timeline") {
    print(replayTimeline(fixture, voice: Voice(file: pagesFolder.appendingPathComponent("voice.json"))), terminator: "")
    exit(0)
}

if let out = argument("--dump-state") {
    let tracker = Tracker(root: logsRoot, storePath: "/nonexistent/store.json")
    tracker.scanAll()
    let now = argument("--now").flatMap(Double.init) ?? Date().timeIntervalSince1970 * 1000
    var state = analyze(files: Array(tracker.files.values), lastCallMs: tracker.lastCallMs, lastPromptMs: tracker.lastPromptMs, now: now)
    state["older"] = olderHistory(files: Array(tracker.files.values), now: now)
    try? JSONSerialization.data(withJSONObject: state).write(to: URL(fileURLWithPath: out))
    exit(0)
}

// MARK: - The engine: tracker + desk screen, off the main thread

final class Engine {
    let tracker: Tracker
    let attention = Attention(remember: !fresh)
    private let moments = Moments()
    private let inbox = HookInbox(dataFolder: dataFolder)
    private let memory = Memory(dataFolder: dataFolder)
    private let summaries = Summaries()
    // Set from the main thread through setOptions.
    private var intelligence = true         // the pricing switch: the robot's reactions, Now line and summaries
    private var aiOn = true                 // AI recaps and loop judging through your own claude
    private var dailyGoal = 0               // wins a day you set; 0 = worked out from your days
    private var olderDays: [[String: Any]] = []     // the days before the live window, for the streak
    private let desk = DeskScreen()
    private let asks = PadAsks(dataFolder: dataFolder)
    private var asking: PadAsk?              // the permission prompt the pad shows, while ask.sh waits
    private let queue = DispatchQueue(label: "burnbot.engine", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var state: [String: Any]?
    private var json = ""
    private var analyzedAt = 0.0
    private var analyzedMinute = 0
    private var tick = 0
    private var meta: [String: Any] = [:]
    /// What each state is called on screen. The pages own the names and send them over.
    private var names = ["asleep": "Asleep", "idle": "Chilling", "warming": "Warming up", "cruising": "Cooking",
                         "locked": "Locked in", "overdrive": "On fire", "autopilot": "Autopilot"]
    /// Called on the main thread with the state as JSON, about every two seconds.
    var onState: ((String) -> Void)?
    /// A knock on the desk screen closed a bubble that was asking for you, with its session (main thread).
    var onFocus: ((String) -> Void)?
    /// The pad's Talk key went down (true) or up, with the session to talk to ("" for none) (main thread).
    var onTalk: ((String, Bool) -> Void)?
    /// Whether the desk screen can feel knocks, and its knock setting, when that changes (main thread).
    var onDeskKnocks: ((Bool, Int) -> Void)?
    private var knockDismiss = false        // a knock closes the bubble; off until you have tried it on your desk
    private var testKnockUntil = 0.0        // Test Knock: until then every knock felt is shown, nothing closes
    private var knockFeltAt = 0.0
    private var reportedKnocks: (Bool, Int)?
    /// Called on the main thread with the days before the 30-day window, when they have been worked out.
    var onOlder: ((String) -> Void)?
    private var olderDay = -1

    init(root: String, storePath: String) {
        tracker = Tracker(root: root, storePath: storePath)
        desk.log = { log($0) }
        desk.onKnock = { [weak self] in self?.knocked() }
        desk.onKey = { [weak self] key, down in self?.pressed(key, down: down) }
        moments.voice = Voice(file: pagesFolder.appendingPathComponent("voice.json"))
        moments.isWork = { [attention] in attention.isWork($0) }
        moments.sessionInfo = { [tracker] id, now, since in tracker.session(id, now: now, since: since) }
        moments.trace = { log("moment " + $0) }
        summaries.log = { log($0) }
        moments.lastSession = { [memory] now in memory.last(now: now) }
        moments.onSessionDone = { [weak self] recap in self?.remember(recap) }
        moments.usualBreak = { [attention] in attention.usualBreak }
        moments.onBreak = { [attention] in attention.addBreak($0) }
        applyAI()
    }

    /// With AI on, your claude tells a loop from real iteration; with it off, the rule decides alone.
    private func applyAI() {
        moments.judgeLoop = intelligence && aiOn ? { [weak self] prompts, answer in self?.judge(prompts, answer) ?? answer(nil) } : nil
    }

    /// Going round or real iteration: your claude decides when AI is on. If it fails or gives no
    /// answer, the robot keeps quiet; once today's AI runs are used up, the rule decides.
    private func judge(_ prompts: [String], _ answer: @escaping (Bool?) -> Void) {
        guard memory.takeRun(now: Date().timeIntervalSince1970 * 1000, limit: summaries.perDay) else {
            // Out of AI runs for today: the rule already says it is a loop, so it stands.
            log("AI loop check skipped: \(summaries.perDay) AI runs already today; the rule decides")
            return answer(true)
        }
        summaries.judgeLoop(prompts, then: queue, answer: answer)
    }

    /// A session ended: keep its recap, and with AI on, ask your claude for a summary of it.
    private func remember(_ recap: SessionRecap) {
        memory.add(recap)
        guard intelligence, aiOn else { return }
        guard memory.takeRun(now: Date().timeIntervalSince1970 * 1000, limit: summaries.perDay) else {
            log("AI summary skipped: \(summaries.perDay) already today")
            return
        }
        let prompts = tracker.prompts(session: recap.id, from: recap.start, to: recap.end + 60_000)
        summaries.run(recap, prompts: prompts, then: queue) { [memory] done, next in
            memory.attach(id: recap.id, end: recap.end, done: done, next: next)
            log("AI summary kept: \(done.joined(separator: " / ")) · next: \(next)")
        }
    }

    /// Settings from the menu and the welcome screen.
    /// You are pointing at the desktop robot or reading its panel: bubbles that can wait, wait.
    func setBusy(_ on: Bool) {
        queue.async {
            guard self.moments.busy != on else { return }
            self.moments.busy = on
            log("moment you are \(on ? "reading the robot: bubbles wait" : "done reading the robot")")
        }
    }

    func setOptions(intelligence: Bool, aiOn: Bool, dailyGoal: Int) {
        queue.async {
            self.intelligence = intelligence
            self.aiOn = aiOn
            self.applyAI()
            let goalChanged = dailyGoal != self.dailyGoal
            self.dailyGoal = dailyGoal
            if goalChanged, self.state != nil { self.refresh() } else { self.encode() }
            self.deliver()
        }
    }

    func start() {
        queue.async {
            self.inbox.open()
            let restored = self.tracker.load()
            let began = Date()
            // Publish once as soon as today's logs are in, then again when all of history is.
            self.tracker.scanAll { self.refresh(); self.deliver() }
            self.refresh()
            self.deliver()
            log(String(format: "Read %d session logs in %.1fs%@", self.tracker.files.count, Date().timeIntervalSince(began),
                       restored ? " (history restored)" : ""))
            self.tracker.save()
            self.refreshOlder()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { self.step() }
            timer.resume()
            self.timer = timer
        }
    }

    /// The stretch with Claude so far and your usual long one, in minutes, from the last analysis.
    private func stretch(_ state: [String: Any]?) -> (minutes: Int, long: Int)? {
        guard let live = state?["live"] as? [String: Any], let baseline = state?["baseline"] as? [String: Any],
              let minutes = (live["stretchMin"] as? NSNumber)?.intValue, let long = (baseline["longStretch"] as? NSNumber)?.intValue
        else { return nil }
        return (minutes, long)
    }

    private func step() {
        tick += 1
        let changed = tick % 2 == 0 ? tracker.poll() : false
        let now = Date().timeIntervalSince1970 * 1000
        let signals = tracker.takeSignals()
        if signals.contains(where: { if case .prompt = $0 { return true } else { return false } }) { attention.learn() }
        let place = attention.now
        let moved = moments.tick(signals: signals, hooks: inbox.drain(), front: place.front, idle: place.idle,
                                 level: (state?["live"] as? [String: Any])?["state"] as? String ?? "", goal: GoalState(state?["goal"], now: now),
                                 stretch: stretch(state), now: now)
        if changed || state == nil || Int(now / 60000) != analyzedMinute || now - analyzedAt >= 10_000 {
            refresh()
        } else if moved || tick % 2 == 0 {
            encode()                    // the desk screen may have come or gone
        }
        if !demo.isEmpty { encode() }           // the demo moves on its own clock
        if moved || tick % 2 == 0 || !demo.isEmpty { deliver() }
        if let state {
            let speaks = desk.speaks
            let felt = now - knockFeltAt < 1500
            let moment = !speaks ? nil
                : now < testKnockUntil ? (felt ? "M|k=b|h=1|t=KNOCK!|a=FELT THAT ONE." : "M|k=m|h=1|t=TEST KNOCK|a=KNOCK TWICE ON|b=THE CASE.")
                : deskMoment(shown.card)
            let expr = !speaks ? "" : now < testKnockUntil ? (felt ? "happy" : "") : shown.expr
            var keys = ""
            if desk.hasKeys {
                asks.beat()
                asking = asks.pending(now: now)
                // A request the pad cannot show in full is never approved there: Claude asks on the Mac.
                if let ask = asking, !ask.whole {
                    asks.letGo(ask)
                    asking = nil
                    log("Pad: \(ask.tool) is asked on the Mac, since the pad cannot show all of it")
                }
                // Typing in your terminal or editor: you are there, so the prompt is answered there.
                if let ask = asking, now - ask.ms > 2000, attention.isWork(place.front),
                   CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < 1.5 {
                    asks.letGo(ask)
                    asking = nil
                    log("Pad: you are typing, so \(ask.tool) is asked on the Mac")
                }
                keys = padLine(ask: asking, card: shown.card)
            } else if asks.beating {
                asks.stop()
                asking = nil
            }
            desk.send(deskLine(state, names: names, expr: expr) + keys, moment: moment)
        }
        let knocks = (desk.knocks, desk.sensitivity)
        if reportedKnocks == nil || reportedKnocks! != knocks {
            reportedKnocks = knocks
            DispatchQueue.main.async { self.onDeskKnocks?(knocks.0, knocks.1) }
        }
        if tick % 300 == 0 { tracker.save() }
        if tick % 60 == 0 { refreshOlder() }
    }

    /// Days older than the live window never change, so they are only worked out again when the day does.
    private func refreshOlder() {
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        guard day != olderDay else { return }
        olderDay = day
        let began = Date()
        let older = olderHistory(files: Array(tracker.files.values), now: Date().timeIntervalSince1970 * 1000)
        olderDays = older["days"] as? [[String: Any]] ?? []
        if state != nil { refresh() }           // the streak can reach back into them
        guard let data = try? JSONSerialization.data(withJSONObject: older), let text = String(data: data, encoding: .utf8) else { return }
        log(String(format: "Older history: %d days before the last 30, in %.2fs", (older["days"] as? [Any])?.count ?? 0, Date().timeIntervalSince(began)))
        DispatchQueue.main.async { self.onOlder?(text) }
    }

    private func refresh() {
        let now = Date().timeIntervalSince1970 * 1000
        // A question or plan waiting on you while you are at the Mac: you are reading it, which is work.
        let askedAt = attention.now.idle < 120 ? tracker.pendingAsk(now: now) : 0
        state = analyze(files: Array(tracker.files.values), lastCallMs: tracker.lastCallMs, lastPromptMs: tracker.lastPromptMs,
                        now: now, askedAt: askedAt, goal: dailyGoal, before: olderDays)
        analyzedAt = now
        analyzedMinute = Int(now / 60000)
        encode()
    }

    private func encode() {
        guard var whole = state else { return }
        let progress = tracker.scan
        whole["scan"] = ["phase": progress.phase, "done": progress.done, "total": progress.total]
        var extra = meta
        extra["source"] = (tracker.root as NSString).abbreviatingWithTildeInPath
        extra["foundLogs"] = tracker.foundLogs
        extra["desk"] = desk.status
        whole["meta"] = extra
        // The robot's reactions come with Burnbot's paid tier; the levels never do.
        // Play Every Moment shows them either way: it is how you see what they are.
        if let played = demoOutput(Date().timeIntervalSince1970 * 1000) {
            shown = played
            whole["demo"] = true
        } else {
            shown = intelligence ? moments.output : MomentsOutput()
        }
        if whole["demo"] != nil || intelligence { for (key, value) in shown.json { whole[key] = value } }
        let now = Date().timeIntervalSince1970 * 1000
        if now < testKnockUntil { whole["knockTest"] = ["felt": now - knockFeltAt < 1500, "left": Int((testKnockUntil - now) / 1000)] }
        if let data = try? JSONSerialization.data(withJSONObject: whole), let text = String(data: data, encoding: .utf8) { json = text }
    }

    private func deliver() {
        let text = json
        guard !text.isEmpty else { return }
        DispatchQueue.main.async { self.onState?(text) }
    }

    /// Things only the main thread knows (screens, preferences), for the pages.
    func setMeta(_ value: [String: Any]) {
        queue.async {
            self.meta = value
            self.encode()
            self.deliver()
        }
    }

    func setNames(_ value: [String: String]) { queue.async { self.names = value } }
    func flipDesk() { queue.async { self.desk.flip() } }

    /// You closed or clicked a speech bubble.
    // ---------- Play Every Moment ----------
    // A recorded session (tools/fixtures/demo) goes through the same tracker, detectors and
    // decisions as your own, then plays back with the quiet stretches cut short.
    private var demo: [(at: Double, output: MomentsOutput)] = []    // at: ms after demoStart
    private var demoStart = 0.0
    private var shown = MomentsOutput()     // what the robot shows now: the demo, your own, or nothing

    func playDemo(_ folder: String) {
        let voice = moments.voice
        DispatchQueue.global(qos: .userInitiated).async {
            var frames: [(Double, MomentsOutput)] = []
            _ = replayTimeline(folder, voice: voice) { now, output in frames.append((now, output)) }
            let schedule = squeeze(frames)
            log("Play Every Moment: \(frames.count) s of a session in \(Int((schedule.last?.at ?? 0) / 1000)) s")
            self.queue.async {
                self.demo = schedule
                self.demoStart = 0              // starts once there is a robot to show it on
                self.encode()
                self.deliver()
            }
        }
    }

    /// What the demo shows now, or nil when none is playing (and it is forgotten once over).
    private func demoOutput(_ now: Double) -> MomentsOutput? {
        guard !demo.isEmpty else { return nil }
        if demoStart == 0 { demoStart = now }
        let elapsed = now - demoStart
        guard let last = demo.last, elapsed < last.at + 1500 else {
            demo = []
            log("Play Every Moment: over")
            return nil
        }
        return demo.last(where: { $0.at <= elapsed })?.output ?? MomentsOutput()
    }

    /// Where a session was started (see Tracker.origin), answered on the main thread.
    func origin(of session: String, _ done: @escaping ((entry: String, cwd: String)?) -> Void) {
        queue.async {
            let found = self.tracker.origin(session)
            DispatchQueue.main.async { done(found) }
        }
    }

    func dismissMoment(_ id: String) {
        queue.async {
            self.close(id, now: Date().timeIntervalSince1970 * 1000)
            self.encode()
            self.deliver()
        }
    }

    private func close(_ id: String, now: Double) {
        if let shown = demoOutput(now), shown.card?.id == id {
            // Closing a bubble in the demo skips ahead to whatever comes after it.
            let elapsed = now - demoStart
            if let next = demo.first(where: { $0.at > elapsed && $0.output.card?.id != id }) { demoStart = now - next.at }
            return
        }
        moments.dismiss(id, now: now)
    }

    /// Two taps on the desk screen's case. In Test Knock it only shows that it felt it; otherwise, with
    /// Knock to Dismiss on, it does what a click on the bubble does.
    private func knocked() {
        let now = Date().timeIntervalSince1970 * 1000
        if now < testKnockUntil {
            knockFeltAt = now
            log("Test Knock: felt one")
        } else if knockDismiss, let card = shown.card {
            log("Knock closed \"\(card.title)\"")
            if card.action == "focus", demoOutput(now) == nil { DispatchQueue.main.async { self.onFocus?(card.session) } }
            close(card.id, now: now)
        } else {
            return
        }
        encode()
        deliver()
    }

    /// A key on the desk pad. While Claude waits for a yes: Deny, Talk, Show, Approve. Otherwise the first
    /// closes the bubble, Talk and Show go to the session the robot is talking about, and the last does nothing.
    private func pressed(_ key: Int, down: Bool) {
        let now = Date().timeIntervalSince1970 * 1000
        let ask = asking, card = shown.card
        let session = ask?.session ?? card?.session ?? ""
        switch (key, down) {
        case (1, true):
            if let ask {
                asks.answer(ask, allow: false)
                log("Pad: denied \(ask.tool)")
                settle(ask, now: now)
            } else if let card {
                log("Pad closed \"\(card.title)\"")
                close(card.id, now: now)
            } else {
                return
            }
        case (4, true):
            guard let ask else { return }
            asks.answer(ask, allow: true)
            log("Pad: approved \(ask.tool)")
            settle(ask, now: now)
        case (3, true):
            DispatchQueue.main.async { self.onFocus?(session) }
            return
        case (2, _):
            DispatchQueue.main.async { self.onTalk?(session, down) }
            return
        default:
            return
        }
        encode()
        deliver()
    }

    /// An answer from the pad: the prompt is gone, and so is the bubble asking about it.
    private func settle(_ ask: PadAsk, now: Double) {
        asking = nil
        if let card = shown.card, card.kind == "waiting", card.session == ask.session { close(card.id, now: now) }
    }

    func setKnock(dismiss: Bool) { queue.async { self.knockDismiss = dismiss } }
    func setKnockSensitivity(_ level: Int) { queue.async { self.desk.setSensitivity(level) } }
    func testKnock() {
        queue.async {
            self.testKnockUntil = Date().timeIntervalSince1970 * 1000 + 30_000
            self.knockFeltAt = 0
            log("Test Knock: 30 s")
            self.encode()
            self.deliver()
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            tracker.save()
            desk.shutDown()
            asks.stop()
            inbox.close()
        }
    }
}

extension NSScreen {
    var isBuiltIn: Bool {
        guard let id = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
        return CGDisplayIsBuiltin(id) != 0
    }
}

// MARK: - The app

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private let engine = Engine(root: logsRoot, storePath: dataFolder + "/store.json")
    private let pages = Pages(folder: pagesFolder)
    private var dashboard: NSWindow?
    private var dashboardView: WKWebView?
    private var companion: Companion?               // the robot standing on your desktop
    private var robotStage: NSWindow?               // the robot's whole scene, filling a screen
    private var robotView: WKWebView?               // the scene (display.html)
    private var robotShown: Bool { companion?.isVisible == true || robotStage?.isVisible == true }
    /// The page that shows the robot right now: the desktop robot's, or the scene's.
    private var shownRobotView: WKWebView? { robotStage?.isVisible == true ? robotView : companion?.view }
    private var stageIsFull: Bool { robotStage?.styleMask.contains(.fullScreen) == true }
    private var listening: [WKWebView] = []         // pages that have asked for state
    private var latest = ""
    private var latestOlder = ""
    /// Keep the robot fullscreen on a second screen whenever one is attached.
    private var followSecondScreen = true
    /// In a window, float the robot above everything so it is always in view.
    private var keepOnTop = fresh ? true : UserDefaults.standard.object(forKey: "keepRobotOnTop") as? Bool ?? true
    // 1 = saw the 1.0 welcome, 2 = saw the one that asks about Claude Code alerts and AI summaries.
    private var welcomed = fresh ? 0 : max(UserDefaults.standard.integer(forKey: "welcomeSeen"), UserDefaults.standard.bool(forKey: "welcomed") ? 1 : 0)
    // AI recaps and loop judging: you opt in on the welcome. Someone who already answered the welcome
    // and never touched the setting keeps it on, as they were told (the 1.1 opt-in key is not carried over).
    private var aiOn = fresh ? false : UserDefaults.standard.object(forKey: "aiOn") as? Bool ?? (UserDefaults.standard.integer(forKey: "welcomeSeen") >= 2)
    private var dailyGoal = fresh ? 0 : UserDefaults.standard.integer(forKey: "dailyGoal")
    // The pricing switch: the robot's reactions, its Now line and summaries. On; the levels are never behind it.
    private let intelligence = fresh || UserDefaults.standard.object(forKey: "intelligence") as? Bool ?? true
    // Claude Code's settings. A first-launch test run works on a throwaway copy, never on yours.
    private let hooks = ClaudeHooks(dataFolder: dataFolder,
                                    settingsPath: fresh ? dataFolder + "/claude-settings.json" : NSHomeDirectory() + "/.claude/settings.json")
    private var afterExitFullScreen: (() -> Void)?
    private var awake: NSObjectProtocol?

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        log("Burnbot \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "") starting\(fresh ? " (as a first launch)" : "")")
        // The hooks run this script; it is rewritten each launch so it is always this version's.
        // Whether the hooks are in Claude Code's settings is up to you (the welcome, or the Robot menu).
        hooks.writeScript()
        if hooks.lacksAsk {
            // Added by a Burnbot from before the desk pad's keys: add them again, with the pad's.
            do { try hooks.install() } catch { log("Could not add the desk pad's hook: \(error.localizedDescription)") }
        }
        engine.setOptions(intelligence: intelligence, aiOn: aiOn, dailyGoal: dailyGoal)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Which app you are in decides whether the robot speaks up or just pulls a face.
        let workspace = NSWorkspace.shared
        engine.attention.setFront(workspace.frontmostApplication?.bundleIdentifier ?? "")
        workspace.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.engine.attention.setFront(app?.bundleIdentifier ?? "")
        }
        engine.onState = { [weak self] json in self?.push(json) }
        engine.onFocus = { [weak self] session in self?.goTo(session: session) }
        engine.onTalk = { [weak self] session, down in self?.talk(session: session, down: down) }
        engine.onDeskKnocks = { [weak self] can, level in
            self?.deskKnocks = can
            self?.deskSensitivity = level
        }
        engine.setKnock(dismiss: knockDismiss)
        engine.onOlder = { [weak self] json in
            guard let self else { return }
            self.latestOlder = json
            for view in self.listening { view.evaluateJavaScript("window.burnbotOlder && window.burnbotOlder(\(json))") }
        }
        refreshMeta()
        engine.start()
        let second = secondScreen()
        if CommandLine.arguments.contains("--background") {
            ensureDashboard()
            dashboard?.orderBack(nil)
            showRobot(on: second ?? NSScreen.screens[0], fullscreen: second != nil)
        } else {
            showDashboard()
            showRobot(on: second ?? NSScreen.screens[0], fullscreen: second != nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        if let folder = argument("--snapshot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) { self.snapshot(to: folder) }
        }
        if CommandLine.arguments.contains("--demo") { playMoments() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showDashboard() }
        return true
    }

    // MARK: Talking to the pages

    private var openAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    /// What the pages need to know that only the app knows.
    private func refreshMeta() {
        let screens = NSScreen.screens.enumerated().map { index, screen in
            ["index": index, "name": screen.localizedName, "width": screen.frame.width, "height": screen.frame.height, "primary": index == 0] as [String: Any]
        }
        engine.setMeta([
            "firstRun": welcomed < 2,
            "claudeAlerts": hooks.installed,
            "aiOn": aiOn,
            "dailyGoal": dailyGoal,
            "intelligence": intelligence,
            "openAtLogin": openAtLogin,
            "keepOnTop": keepOnTop,
            "screens": screens,
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
        ])
    }

    private func push(_ json: String) {
        latest = json
        for view in listening { view.evaluateJavaScript("window.burnbotReceive && window.burnbotReceive(\(json))") }
    }

    private func makeWebView(firstClick: Bool = false) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(pages, forURLScheme: Pages.scheme)
        configuration.userContentController.add(self, name: "burnbot")
        // Page errors are otherwise invisible in an app; send them to the log.
        let report = """
        window.addEventListener('error', (e) => webkit.messageHandlers.burnbot.postMessage({ type: 'error', text: e.message + ' at ' + (e.filename || '') + ':' + e.lineno }));
        window.addEventListener('unhandledrejection', (e) => webkit.messageHandlers.burnbot.postMessage({ type: 'error', text: 'unhandled: ' + ((e.reason && e.reason.message) || e.reason) }));
        """
        configuration.userContentController.addUserScript(WKUserScript(source: report, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = firstClick ? FirstClickWebView(frame: .zero, configuration: configuration) : WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.underPageBackgroundColor = .black
        return view
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        listening.removeAll { $0 === webView }      // the page is reloading; it will ask again
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log("Loaded \(webView.url?.absoluteString ?? "?")")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log("Could not load \(webView.url?.absoluteString ?? "page"): \(error.localizedDescription)")
    }

    /// Links that would open a new tab: the level preview goes to the robot, web links to the browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if url.scheme == Pages.scheme, url.path == "/display" {
            followSecondScreen = false
            previewLevels()
        } else if url.scheme == "https" {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            guard let view = message.webView else { return }
            if !listening.contains(where: { $0 === view }) { listening.append(view) }
            if !latestOlder.isEmpty { view.evaluateJavaScript("window.burnbotOlder && window.burnbotOlder(\(latestOlder))") }
            if !latest.isEmpty { view.evaluateJavaScript("window.burnbotReceive && window.burnbotReceive(\(latest))") }
        case "levels":
            if let names = body["names"] as? [String: String] { engine.setNames(names) }
        case "error":
            log("Page error: \(body["text"] ?? "")")
        case "welcomed":
            welcomed = 2
            if !fresh { UserDefaults.standard.set(2, forKey: "welcomeSeen") }
            refreshMeta()
        case "claudeAlerts":
            setClaudeAlerts(body["on"] as? Bool ?? false)
        case "aiOn":
            // It sends your session details to Claude: a missing or garbled answer changes nothing.
            guard let on = body["on"] as? Bool else { return }
            setAI(on)
        case "dailyGoal":
            setDailyGoal(body["n"] as? Int ?? 0)
        case "openAtLogin":
            setOpenAtLogin(body["on"] as? Bool ?? false)
        case "keepOnTop":
            setKeepOnTop(body["on"] as? Bool ?? true)
        case "toggleFullscreen":
            toggleRobotFullScreen()
        case "robot":
            let screens = NSScreen.screens
            let index = body["index"] as? Int ?? 0
            let fullscreen = body["fullscreen"] as? Bool ?? false
            followSecondScreen = false
            showRobot(on: fullscreen && index < screens.count ? screens[index] : (dashboard?.screen ?? screens[0]), fullscreen: fullscreen)
        case "hideRobot":
            hideRobot()
        case "flipDesk":
            engine.flipDesk()
        case "hit":
            let rects = (body["rects"] as? [[Any]] ?? []).map { $0.compactMap { ($0 as? NSNumber)?.doubleValue } }
            let robot = (body["robot"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
            companion?.setHits(rects, robot: robot)
        case "where":
            // The desktop robot's page is ready to hear where the robot stands (it asks once it has loaded:
            // telling it sooner, before its script has run, would be lost).
            companion?.tellPlace()
        case "busy":
            // You are reading the robot's face or its panel: a bubble that is not urgent waits.
            engine.setBusy(body["on"] as? Bool ?? false)
        case "panel":
            companion?.watchOutside(body["open"] as? Bool ?? false)
        case "dashboard":
            showDashboard()
        case "focus":
            goTo(session: body["session"] as? String ?? "")
        case "moment":
            // A speech bubble was clicked: it goes, and if it was asking for you, so do you.
            guard let id = body["id"] as? String else { return }
            if body["action"] as? String == "focus" { goTo(session: body["session"] as? String ?? "") }
            engine.dismissMoment(id)
        default:
            break
        }
    }

    // ---------- the knock ----------
    private var knockDismiss = !fresh && UserDefaults.standard.bool(forKey: "knockDismiss")
    private var deskKnocks = false
    private var deskSensitivity = 1

    @objc func toggleKnockDismiss() {
        knockDismiss.toggle()
        if !fresh { UserDefaults.standard.set(knockDismiss, forKey: "knockDismiss") }
        engine.setKnock(dismiss: knockDismiss)
        log("Knock to Dismiss \(knockDismiss ? "on" : "off")")
    }

    @objc func pickKnockSensitivity(_ sender: NSMenuItem) {
        deskSensitivity = sender.tag
        engine.setKnockSensitivity(sender.tag)
    }

    /// 30 seconds in which every knock the desk feels shows on the desk and in the robot window,
    /// so you can find a sensitivity that catches your knocks and not your typing.
    @objc func testKnock() {
        if !robotShown { showRobotLive() }
        engine.testKnock()
    }

    /// Go to it: takes you to the session a bubble or the panel is about. A session in the VS Code
    /// extension (or a fork of it) gets its own window and its own Claude tab: opening the folder makes
    /// the editor raise that window, which also moves you to its Space when it is full screen (a plain
    /// activate leaves you where you are when "switch to a Space with open windows" is off). Then
    /// the extension's link reveals the session's tab. Anything else brings back your work app.
    private func goTo(session: String) {
        guard !session.isEmpty else { return bringBackWork() }
        engine.origin(of: session) { [weak self] found in
            guard let self else { return }
            guard let found, found.entry == "claude-vscode", let editor = Self.editor(prefer: self.engine.attention.workApp),
                  let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.id) else { return self.bringBackWork() }
            let folder = URL(fileURLWithPath: found.cwd, isDirectory: true)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            log("Go to it: \(session.prefix(8)) in \(editor.id) at \((found.cwd as NSString).abbreviatingWithTildeInPath)")
            NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: configuration) { _, error in
                if let error { log("Could not open \(found.cwd) in \(editor.id): \(error.localizedDescription)") }
                var link = URLComponents()
                link.scheme = editor.scheme
                link.host = "anthropic.claude-code"
                link.path = "/open"
                link.queryItems = [URLQueryItem(name: "session", value: session)]
                guard let url = link.url else { return }
                DispatchQueue.main.async {
                    NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { _, error in
                        if let error { log("Could not open the session's tab: \(error.localizedDescription)") }
                    }
                }
            }
        }
    }

    /// The pad's Talk key: down brings the session forward and starts dictation, up stops it, so
    /// what you said lands in its prompt. Both wait a moment, so the window is in front first.
    private func talk(session: String, down: Bool) {
        if down { goTo(session: session) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { down ? Dictation.start() : Dictation.stop() }
    }

    /// Editors that run the Claude Code VS Code extension, with the link scheme each one answers.
    private static let editors = [("com.microsoft.VSCode", "vscode"), ("com.microsoft.VSCodeInsiders", "vscode-insiders"),
                                  ("com.todesktop.230313mzl4w4u92", "cursor"), ("com.exafunction.windsurf", "windsurf"),
                                  ("com.vscodium", "vscodium")]

    /// The editor to go to: the work app you were last in, if it is one, or else the first one running.
    private static func editor(prefer workApp: String) -> (id: String, scheme: String)? {
        if let hit = editors.first(where: { $0.0 == workApp }) { return hit }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return editors.first(where: { running.contains($0.0) })
    }

    /// Brings forward the terminal or editor you were last working in. Through Launch Services,
    /// because the robot's panel never makes Burnbot the active app, so a plain activate is refused.
    private func bringBackWork() {
        let id = engine.attention.workApp
        guard !id.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error { log("Could not bring \(id) forward: \(error.localizedDescription)") }
        }
    }

    // MARK: Preferences

    private func setClaudeAlerts(_ on: Bool) {
        guard on != hooks.installed else { return }
        do {
            if on { try hooks.install() } else { try hooks.remove() }
        } catch {
            log("Claude Code alerts: \(error)")
            let alert = NSAlert()
            alert.messageText = on ? "Burnbot could not add its hooks" : "Burnbot could not remove its hooks"
            alert.informativeText = "\(error)\n\nClaude Code's settings file was left as it was."
            alert.runModal()
        }
        refreshMeta()
    }

    @objc func toggleClaudeAlerts() { setClaudeAlerts(!hooks.installed) }

    private func setAI(_ on: Bool) {
        aiOn = on
        if !fresh { UserDefaults.standard.set(on, forKey: "aiOn") }
        engine.setOptions(intelligence: intelligence, aiOn: on, dailyGoal: dailyGoal)
        log("AI recaps and loop checks \(on ? "on" : "off")")
        refreshMeta()
    }

    @objc func toggleAI() { setAI(!aiOn) }

    /// Wins a day to aim for; 0 goes back to working it out from your own days.
    private func setDailyGoal(_ n: Int) {
        dailyGoal = max(0, min(20, n))
        if !fresh { UserDefaults.standard.set(dailyGoal, forKey: "dailyGoal") }
        engine.setOptions(intelligence: intelligence, aiOn: aiOn, dailyGoal: dailyGoal)
        refreshMeta()
    }

    private func setOpenAtLogin(_ on: Bool) {
        guard on != openAtLogin else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log("Open at login could not be changed: \(error.localizedDescription)")
        }
        refreshMeta()
    }

    @objc func toggleOpenAtLogin() { setOpenAtLogin(!openAtLogin) }

    private func setKeepOnTop(_ on: Bool) {
        keepOnTop = on
        if !fresh { UserDefaults.standard.set(on, forKey: "keepRobotOnTop") }
        applyWindowMode()
        refreshMeta()
    }

    @objc func toggleKeepOnTop() { setKeepOnTop(!keepOnTop) }

    @objc func showWelcome() {
        showDashboard()
        dashboardView?.evaluateJavaScript("window.burnbotWelcome && window.burnbotWelcome()")
    }

    @objc func openHelp() {
        NSWorkspace.shared.open(URL(string: "https://github.com/megamind-rgb/burnbot#readme")!)
    }

    // MARK: Windows

    private func ensureDashboard() {
        if dashboard == nil {
            let view = makeWebView()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Burnbot"
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(calibratedWhite: 0.05, alpha: 1)
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 480, height: 420)
            window.contentView = view
            window.center()
            window.setFrameAutosaveName("BurnbotDashboard")
            view.load(URLRequest(url: URL(string: Pages.home)!))
            dashboard = window
            dashboardView = view
        }
    }

    @objc func showDashboard() {
        ensureDashboard()
        dashboard?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The screen the robot should take over by itself: never the primary one.
    private func secondScreen() -> NSScreen? {
        let others = Array(NSScreen.screens.dropFirst())
        return others.first(where: { !$0.isBuiltIn }) ?? others.first
    }

    private func robotWebView() -> WKWebView {
        if let view = robotView { return view }
        // It sits on another screen while you work elsewhere: Go to it has to work on the first click.
        let view = makeWebView(firstClick: true)
        view.load(URLRequest(url: URL(string: Pages.home + "display")!))
        robotView = view
        return view
    }

    /// On top, the desktop robot floats over everything: every desktop, and other
    /// apps' fullscreen windows too, the way a second screen would always be in view.
    private func applyWindowMode() {
        companion?.setOnTop(keepOnTop)
    }

    private func ensureCompanion() -> Companion {
        if let companion { return companion }
        let view = makeWebView(firstClick: true)
        let made = Companion(view: view, remember: !fresh)
        made.menu = { [weak self] in self?.companionMenu() ?? NSMenu() }
        made.onHide = { [weak self] in self?.engine.setBusy(false) }
        view.load(URLRequest(url: URL(string: Pages.home + "companion")!))
        companion = made
        return made
    }

    /// The robot on your desktop: no window around it, only the robot. It never takes the focus,
    /// which is what lets it stay in view over another app's fullscreen window.
    private func showCompanion(on screen: NSScreen?) {
        if stageIsFull {
            afterExitFullScreen = { [weak self] in self?.showCompanion(on: screen) }
            robotStage?.toggleFullScreen(nil)
            return
        }
        robotStage?.orderOut(nil)
        let robot = ensureCompanion()
        // Regardless: the robot should come into view even when another app has the focus.
        robot.show(on: screen ?? dashboard?.screen, onTop: keepOnTop)
        log("Robot shown on the desktop on \(robot.panel.screen?.localizedName ?? "?")")
        updateAwake()
    }

    /// Right-click the robot.
    private func companionMenu() -> NSMenu {
        let menu = NSMenu()
        func entry(_ title: String, _ action: Selector, tag: Int = 0, on: Bool = false) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.state = on ? .on : .off
            return item
        }
        menu.addItem(entry("Open Dashboard", #selector(showDashboard)))
        menu.addItem(.separator())
        menu.addItem(sizeMenuItem())
        menu.addItem(styleMenuItem())
        menu.addItem(entry("Keep on Top", #selector(toggleKeepOnTop), on: keepOnTop))
        if secondScreen() != nil { menu.addItem(entry("Robot on the Second Screen", #selector(robotToSecondScreen))) }
        menu.addItem(.separator())
        menu.addItem(entry("Hide Robot", #selector(hideRobot)))
        return menu
    }

    private func sizeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Robot Size", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        for (index, name) in Companion.sizeNames.enumerated() {
            let entry = NSMenuItem(title: name, action: #selector(pickRobotSize(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = index
            menu.addItem(entry)
        }
        item.submenu = menu
        return item
    }

    /// How the robot's head turns into a screen when you point at it: yours to pick.
    private func styleMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Hover Screen", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        for (index, name) in Companion.styleNames.enumerated() {
            let entry = NSMenuItem(title: name, action: #selector(pickHoverStyle(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = index + 1
            menu.addItem(entry)
        }
        item.submenu = menu
        return item
    }

    @objc func pickRobotSize(_ sender: NSMenuItem) { ensureCompanion().setSize(sender.tag) }
    @objc func pickHoverStyle(_ sender: NSMenuItem) { ensureCompanion().setStyle(sender.tag) }

    /// The robot filling a whole screen, as a normal fullscreen window.
    private func showRobotStage(on screen: NSScreen) {
        if stageIsFull {
            if robotStage?.screen == screen { return }
            afterExitFullScreen = { [weak self] in self?.showRobotStage(on: screen) }
            robotStage?.toggleFullScreen(nil)
            return
        }
        if robotStage == nil {
            let window = NSWindow(contentRect: screen.visibleFrame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Burnbot Robot"
            window.appearance = NSAppearance(named: .darkAqua)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.backgroundColor = .black
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.fullScreenPrimary]
            window.delegate = self
            robotStage = window
        }
        guard let window = robotStage else { return }
        companion?.hide()
        if window.contentView !== robotView { window.contentView = robotWebView() }
        window.setFrame(screen.visibleFrame, display: true)
        window.orderFrontRegardless()
        log("Robot going fullscreen on \(screen.localizedName)")
        // The window has to be on screen before it can go fullscreen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        }
    }

    private func showRobot(on screen: NSScreen, fullscreen: Bool) {
        if fullscreen { showRobotStage(on: screen) } else { showCompanion(on: screen) }
    }

    @objc func toggleRobotFullScreen() {
        followSecondScreen = false
        if stageIsFull {
            robotStage?.toggleFullScreen(nil)       // back to the small robot, see windowDidExitFullScreen
        } else {
            showRobotStage(on: companion?.panel.screen ?? dashboard?.screen ?? NSScreen.screens[0])
        }
    }

    /// View > Full Screen: the robot needs its own path, the dashboard uses the standard one.
    @objc func toggleFullScreenOfFrontWindow() {
        if NSApp.keyWindow === dashboard { dashboard?.toggleFullScreen(nil) } else { toggleRobotFullScreen() }
    }

    @objc func showRobotLive() {
        backToLive()
        if robotShown {
            if stageIsFull { robotStage?.orderFrontRegardless() } else { companion?.panel.orderFrontRegardless() }
        } else {
            let second = secondScreen()
            followSecondScreen = true
            showRobot(on: second ?? dashboard?.screen ?? NSScreen.screens[0], fullscreen: second != nil)
        }
    }

    @objc func robotToSecondScreen() {
        guard let screen = secondScreen() else { return }
        followSecondScreen = true
        showRobot(on: screen, fullscreen: true)
    }

    @objc func robotToWindow() {
        followSecondScreen = false
        showCompanion(on: robotShown ? nil : dashboard?.screen)
    }

    /// The pages showing the robot back on your own data, after a preview.
    private func backToLive() {
        if robotView?.url?.query != nil { robotView?.load(URLRequest(url: URL(string: Pages.home + "display")!)) }
        if let view = companion?.view, view.url?.query != nil { view.load(URLRequest(url: URL(string: Pages.home + "companion")!)) }
    }

    @objc func previewLevels() {
        if !robotShown { robotToWindow() }
        let page = robotStage?.isVisible == true ? "display" : "companion"
        shownRobotView?.load(URLRequest(url: URL(string: Pages.home + page + "?demo=cycle")!))
    }

    /// A recorded session through the robot's real reactions, about a minute long, on the
    /// robot and the desk screen; then back to your own.
    @objc func playMoments() {
        if !robotShown { robotToWindow() }
        backToLive()
        engine.playDemo(demoFolder)
    }

    @objc func hideRobot() {
        followSecondScreen = false
        companion?.hide()
        if stageIsFull {
            afterExitFullScreen = { [weak self] in self?.robotStage?.orderOut(nil) }
            robotStage?.toggleFullScreen(nil)
        } else {
            robotStage?.orderOut(nil)
        }
        updateAwake()
    }

    @objc func reload() {
        if NSApp.keyWindow === dashboard { dashboardView?.reload() } else { shownRobotView?.reload() }
    }

    /// A screen was plugged in or removed.
    @objc func screensChanged() {
        refreshMeta()
        guard followSecondScreen, robotShown else { return }
        if let second = secondScreen() {
            if !(stageIsFull && robotStage?.screen == second) {
                log("Second screen attached: \(second.localizedName)")
                showRobot(on: second, fullscreen: true)
            }
        } else if stageIsFull {
            // Its screen is gone: do not sit fullscreen over the only screen left.
            log("Second screen removed")
            showCompanion(on: NSScreen.screens[0])
        }
        companion?.settle()                         // keep the desktop robot on a screen that is still there
    }

    func windowDidEnterFullScreen(_ notification: Notification) { updateAwake() }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard (notification.object as? NSWindow) === robotStage else { return }
        updateAwake()
        if let work = afterExitFullScreen {
            afterExitFullScreen = nil
            work()
        } else {
            showCompanion(on: nil)                  // left fullscreen by hand: back to the desktop robot
        }
    }

    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        if closing === robotStage { followSecondScreen = false }
        DispatchQueue.main.async { self.updateAwake() }
    }

    /// While the robot owns a whole screen, keep that screen from going to sleep.
    private func updateAwake() {
        let owning = robotStage?.isVisible == true && stageIsFull
        if owning, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled], reason: "Burnbot robot on its own screen")
        } else if !owning, let token = awake {
            ProcessInfo.processInfo.endActivity(token)
            awake = nil
        }
    }

    // MARK: Menu

    private func buildMenu() {
        let bar = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) {
            let holder = NSMenuItem()
            let menu = NSMenu(title: title)
            items.forEach { menu.addItem($0) }
            holder.submenu = menu
            bar.addItem(holder)
        }
        func item(_ title: String, _ action: Selector, _ key: String = "", mine: Bool = false, modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.keyEquivalentModifierMask = modifiers
            if mine { entry.target = self }
            return entry
        }
        add("Burnbot", [
            item("About Burnbot", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            item("Welcome to Burnbot…", #selector(showWelcome), mine: true),
            .separator(),
            item("Open at Login", #selector(toggleOpenAtLogin), mine: true),
            .separator(),
            item("Hide Burnbot", #selector(NSApplication.hide(_:)), "h"),
            item("Quit Burnbot", #selector(NSApplication.terminate(_:)), "q"),
        ])
        add("Edit", [
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        add("View", [
            item("Reload", #selector(reload), "r", mine: true),
            item("Full Screen", #selector(toggleFullScreenOfFrontWindow), "f", mine: true, modifiers: [.command, .control]),
        ])
        add("Robot", [
            item("Show Dashboard", #selector(showDashboard), "1", mine: true),
            item("Show Robot", #selector(showRobotLive), "2", mine: true),
            .separator(),
            item("Robot on the Second Screen", #selector(robotToSecondScreen), "3", mine: true),
            item("Robot on the Desktop", #selector(robotToWindow), "4", mine: true),
            sizeMenuItem(),
            styleMenuItem(),
            item("Keep Robot on Top", #selector(toggleKeepOnTop), "t", mine: true),
            item("Hide Robot", #selector(hideRobot), mine: true),
            .separator(),
            item("Preview Every Level", #selector(previewLevels), mine: true),
            item("Play Every Moment", #selector(playMoments), mine: true),
            .separator(),
            item("Claude Code Alerts", #selector(toggleClaudeAlerts), mine: true),
            item("AI Recaps and Loop Checks", #selector(toggleAI), mine: true),
            .separator(),
            item("Knock to Dismiss", #selector(toggleKnockDismiss), mine: true),
            {
                let holder = NSMenuItem(title: "Knock Sensitivity", action: nil, keyEquivalent: "")
                let menu = NSMenu(title: "Knock Sensitivity")
                for (tag, name) in ["Light", "Medium", "Firm"].enumerated() {
                    let entry = item(name, #selector(pickKnockSensitivity(_:)), mine: true)
                    entry.tag = tag
                    menu.addItem(entry)
                }
                holder.submenu = menu
                return holder
            }(),
            item("Test Knock", #selector(testKnock), mine: true),
        ])
        add("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        add("Help", [item("Burnbot Help", #selector(openHelp), "?", mine: true)])
        NSApp.mainMenu = bar
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(robotToSecondScreen) { return secondScreen() != nil }
        if menuItem.action == #selector(hideRobot) { return robotShown }
        if menuItem.action == #selector(pickRobotSize(_:)) { menuItem.state = menuItem.tag == (companion?.size ?? 1) ? .on : .off }
        if menuItem.action == #selector(pickHoverStyle(_:)) { menuItem.state = menuItem.tag == (companion?.style ?? 1) ? .on : .off }
        if menuItem.action == #selector(toggleKeepOnTop) { menuItem.state = keepOnTop ? .on : .off }
        if menuItem.action == #selector(toggleOpenAtLogin) { menuItem.state = openAtLogin ? .on : .off }
        if menuItem.action == #selector(toggleClaudeAlerts) { menuItem.state = hooks.installed ? .on : .off }
        if menuItem.action == #selector(toggleAI) { menuItem.state = aiOn ? .on : .off }
        // The knock needs a desk screen with the motion sensor, on program 3 or later.
        if menuItem.action == #selector(toggleKnockDismiss) { menuItem.state = knockDismiss ? .on : .off; return deskKnocks }
        if menuItem.action == #selector(pickKnockSensitivity(_:)) { menuItem.state = menuItem.tag == deskSensitivity ? .on : .off; return deskKnocks }
        if menuItem.action == #selector(testKnock) { return deskKnocks }
        return true
    }

    // MARK: Self-check

    /// Takes a picture of one page. The scene is moved on by hand first, because
    /// macOS does not animate a window that is covered by other windows.
    private func capture(_ view: WKWebView?, as name: String, in directory: URL, then: (() -> Void)? = nil) {
        guard let view else {
            then?()
            return
        }
        let settle = """
        (() => { const b = window.burnbot || {}; const s = b.scene || b.mini;
          if (b.fit) b.fit();
          if (s) { let t = performance.now(); for (let i = 0; i < 200; i++) { t += 33; s.frame(t); } }
          return document.title + ' | ' + document.body.innerText.replace(/\\s+/g, ' ').slice(0, 200); })()
        """
        view.evaluateJavaScript(settle) { value, _ in
            log("Text in \(name): \(value ?? "nothing")")
            view.takeSnapshot(with: nil) { image, error in
                if let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                   let png = bitmap.representation(using: .png, properties: [:]) {
                    try? png.write(to: directory.appendingPathComponent("\(name).png"))
                    log("Snapshot of \(name): \(Int(image.size.width)) x \(Int(image.size.height))")
                } else {
                    log("Snapshot of \(name) failed: \(error?.localizedDescription ?? "no image")")
                }
                then?()
            }
        }
    }

    /// The robot's reactions (?demo=moments): the desktop robot's, with its head as a screen and its
    /// panel open, and the scene's too while it is on a screen; then back to the live robot.
    private func snapshotMoments(in directory: URL) {
        var steps: [(name: String, view: WKWebView, page: String)] = []
        if let view = companion?.view, companion?.isVisible == true {
            steps += (0..<12).map { ("robot-moment-\($0)", view, "companion?demo=moments&n=\($0)") }
            steps += [("robot-hover", view, "companion?demo=cruising&hover=1"),
                      ("robot-panel", view, "companion?demo=moments&n=2&panel=1")]
        }
        if let view = robotView, robotStage?.isVisible == true {
            steps += (0..<12).map { ("robot-moment-big-\($0)", view, "display?demo=moments&n=\($0)") }
        }
        func next() {
            guard !steps.isEmpty else { return backToLive() }
            let step = steps.removeFirst()
            step.view.load(URLRequest(url: URL(string: Pages.home + step.page)!))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.capture(step.view, as: step.name, in: directory) { next() } }
        }
        next()
    }

    /// Writes pictures of the windows, and what the pages say, so a build can be checked without looking at the screen.
    /// As a first launch it also presses Start on the welcome and checks that it goes away for good.
    private func snapshot(to folder: String) {
        let directory = URL(fileURLWithPath: folder)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let frames = [dashboard, companion?.panel, robotStage].compactMap { $0 }.filter { $0.isVisible }.map {
            "\($0.title) \(Int($0.frame.width))x\(Int($0.frame.height)) on \($0.screen?.localizedName ?? "no screen") inView=\($0.occlusionState.contains(.visible)) level=\($0.level.rawValue)"
        }
        log("Windows: \(frames.joined(separator: "; "))")
        capture(shownRobotView, as: "robot", in: directory) { self.snapshotMoments(in: directory) }

        // Today from the top and further down, then History the same way.
        var shots: [(name: String, script: String)] = [
            ("dashboard", "window.scrollTo(0, 0)"),
            ("dashboard-2", "window.scrollTo(0, 620)"),
            ("dashboard-3", "window.scrollTo(0, document.body.scrollHeight)"),
            ("history", "window.burnbot.show('history'); window.scrollTo(0, 0)"),
            ("history-2", "window.scrollTo(0, 700)"),
            ("history-3", "document.querySelectorAll('details.fold').forEach((d) => (d.open = true)); window.scrollTo(0, document.body.scrollHeight)"),
        ]
        func next() {
            guard !shots.isEmpty else {
                // leave the dashboard the way a person would find it
                self.dashboardView?.evaluateJavaScript("document.querySelectorAll('details.fold').forEach((d) => (d.open = false)); window.burnbot.show('today')")
                return
            }
            let shot = shots.removeFirst()
            self.dashboardView?.evaluateJavaScript(shot.script) { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.capture(self.dashboardView, as: shot.name, in: directory) { next() } }
            }
        }
        let rest = { next() }
        guard fresh else { return rest() }
        capture(dashboardView, as: "welcome", in: directory) {
            self.dashboardView?.evaluateJavaScript("document.getElementById('welcome').hidden ? 'not shown' : (document.getElementById('welcomeGo').click(), 'shown, Start pressed')") { value, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.dashboardView?.evaluateJavaScript("document.getElementById('welcome').hidden") { hidden, _ in
                        log("Welcome: \(value ?? "?"); hidden afterwards=\(hidden ?? "?"); remembered=\(self.welcomed)")
                        rest()
                    }
                }
            }
        }
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
