// Burnbot.app: a native Mac shell around the Burnbot tracker.
//
// It starts the tracker (a small Node server bundled in the app), then shows
// two windows of its own: the dashboard, and the robot. The robot goes
// fullscreen on a second screen whenever one is attached, and sits in a normal
// window when there is only one screen.
//
// Launch with `--snapshot <folder>` to write PNGs of both windows a few seconds
// after start, for checking that they render.

import Cocoa
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
    // O_APPEND, because the tracker writes to the same file from another process.
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

// MARK: - Finding the tracker

enum Probe { case burnbot, somethingElse, nothing }

/// What, if anything, answers on a local port.
func probe(_ port: Int) -> Probe {
    var request = URLRequest(url: URL(string: "http://localhost:\(port)/api/state")!)
    request.timeoutInterval = 2
    request.cachePolicy = .reloadIgnoringLocalCacheData
    let done = DispatchSemaphore(value: 0)
    var result = Probe.nothing
    URLSession.shared.dataTask(with: request) { data, response, error in
        if let http = response as? HTTPURLResponse {
            let head = String(decoding: (data ?? Data()).prefix(300), as: UTF8.self)
            result = http.statusCode == 200 && head.contains("\"scan\"") ? .burnbot : .somethingElse
        } else if let error = error as NSError?, error.code == NSURLErrorTimedOut {
            result = .somethingElse
        }
        done.signal()
    }.resume()
    done.wait()
    return result
}

/// Node is not on a GUI app's PATH, so look where it usually lives, then ask the login shell.
func findNode() -> String? {
    let home = NSHomeDirectory()
    var candidates: [String] = []
    if let override = ProcessInfo.processInfo.environment["BURNBOT_NODE"] { candidates.append(override) }
    if let saved = Bundle.main.url(forResource: "node-path", withExtension: nil),
       let text = try? String(contentsOf: saved, encoding: .utf8) {
        candidates.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    candidates += ["\(home)/.local/node/bin/node", "/opt/homebrew/bin/node", "/usr/local/bin/node", "\(home)/.volta/bin/node"]
    if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return found }

    let shell = Process()
    shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
    shell.arguments = ["-lic", "command -v node"]
    let pipe = Pipe()
    shell.standardOutput = pipe
    shell.standardError = FileHandle.nullDevice
    guard (try? shell.run()) != nil else { return nil }
    shell.waitUntilExit()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return output.split(separator: "\n").map(String.init).last(where: { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) })
}

extension NSScreen {
    var isBuiltIn: Bool {
        guard let id = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
        return CGDisplayIsBuiltin(id) != 0
    }
}

// MARK: - The app

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private var server: Process?
    private var port = 4747
    private var failure = "The tracker did not start."
    private var dashboard: NSWindow?
    private var dashboardView: WKWebView?
    private var robot: NSWindow?
    private var robotView: WKWebView?
    /// Keep the robot fullscreen on a second screen whenever one is attached.
    private var followSecondScreen = true
    /// In a window, float the robot above everything so it is always in view.
    private var keepOnTop = UserDefaults.standard.object(forKey: "keepRobotOnTop") as? Bool ?? true
    private var afterExitFullScreen: (() -> Void)?
    private var awake: NSObjectProtocol?

    private var base: String { "http://localhost:\(port)" }

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        log("Burnbot \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "") starting")
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = self.startServer()
            DispatchQueue.main.async { ok ? self.openWindows() : self.reportFailure() }
        }
    }

    /// Reuses a tracker that is already running, otherwise starts the bundled one.
    private func startServer() -> Bool {
        for candidate in 4747...4756 {
            switch probe(candidate) {
            case .burnbot:
                port = candidate
                log("Using the tracker already running on port \(candidate)")
                return true
            case .somethingElse:
                continue
            case .nothing:
                guard launchServer(on: candidate) else { return false }
                port = candidate
                for _ in 0..<80 {
                    if probe(candidate) == .burnbot { return true }
                    if server?.isRunning == false { break }
                    Thread.sleep(forTimeInterval: 0.25)
                }
                failure = "The tracker started but did not answer. See ~/Library/Logs/Burnbot.log."
                return false
            }
        }
        failure = "Ports 4747 to 4756 are all in use by other programs."
        return false
    }

    private func launchServer(on port: Int) -> Bool {
        guard let node = findNode() else {
            failure = "Burnbot needs Node.js 20 or newer. Install it from nodejs.org and open Burnbot again."
            return false
        }
        guard let code = Bundle.main.resourceURL?.appendingPathComponent("server") else { return false }
        let data = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Burnbot")
        try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [code.appendingPathComponent("server.mjs").path, "--port", "\(port)", "--parent", "\(ProcessInfo.processInfo.processIdentifier)"]
        process.currentDirectoryURL = code
        var environment = ProcessInfo.processInfo.environment
        environment["BURNBOT_DATA"] = data.path
        process.environment = environment
        let fd = open(logURL.path, O_WRONLY | O_APPEND)
        if fd >= 0 {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            process.standardOutput = handle
            process.standardError = handle
        }
        do {
            try process.run()
        } catch {
            failure = "Could not start the tracker: \(error.localizedDescription)"
            return false
        }
        server = process
        log("Started the tracker with \(node) on port \(port)")
        return true
    }

    private func reportFailure() {
        log("Failed: \(failure)")
        let alert = NSAlert()
        alert.messageText = "Burnbot could not start"
        alert.informativeText = failure
        alert.runModal()
        NSApp.terminate(nil)
    }

    private func openWindows() {
        showDashboard()
        let second = secondScreen()
        showRobot(on: second ?? NSScreen.screens[0], fullscreen: second != nil)
        NSApp.activate(ignoringOtherApps: true)
        if let folder = argument("--snapshot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) { self.snapshot(to: folder) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.terminate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showDashboard() }
        return true
    }

    // MARK: Web views

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "burnbot")
        // Page errors are otherwise invisible in an app; send them to the log.
        let report = """
        window.addEventListener('error', (e) => webkit.messageHandlers.burnbot.postMessage({ type: 'error', text: e.message + ' at ' + (e.filename || '') + ':' + e.lineno }));
        window.addEventListener('unhandledrejection', (e) => webkit.messageHandlers.burnbot.postMessage({ type: 'error', text: 'unhandled: ' + ((e.reason && e.reason.message) || e.reason) }));
        """
        configuration.userContentController.addUserScript(WKUserScript(source: report, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.underPageBackgroundColor = .black
        return view
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log("Loaded \(webView.url?.absoluteString ?? "?")")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log("Could not load \(webView.url?.absoluteString ?? "page"): \(error.localizedDescription)")
        // The tracker may still be starting, or was restarted: try again shortly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak webView] in
            guard let self, let webView else { return }
            let path = webView === self.robotView ? "/display" : "/"
            webView.load(URLRequest(url: URL(string: self.base + path)!))
        }
    }

    /// Links that would open a new tab: the level preview goes to the robot window, anything else to the browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if url.host == "localhost", url.path == "/display" {
            followSecondScreen = false
            if robot == nil || robot?.isVisible == false { showRobot(on: dashboard?.screen ?? NSScreen.screens[0], fullscreen: false) }
            robotView?.load(URLRequest(url: url))
            robot?.makeKeyAndOrderFront(nil)
        } else {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "error":
            log("Page error: \(body["text"] ?? "")")
        case "toggleFullscreen":
            toggleRobotFullScreen()
        case "robot":
            let screens = NSScreen.screens
            let index = body["index"] as? Int ?? 0
            let fullscreen = body["fullscreen"] as? Bool ?? false
            let screen = fullscreen && index < screens.count ? screens[index] : (dashboard?.screen ?? screens[0])
            followSecondScreen = false
            showRobot(on: screen, fullscreen: fullscreen)
        case "hideRobot":
            hideRobot()
        default:
            break
        }
    }

    // MARK: Windows

    @objc func showDashboard() {
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
            view.load(URLRequest(url: URL(string: base + "/")!))
            dashboard = window
            dashboardView = view
        }
        dashboard?.makeKeyAndOrderFront(nil)
    }

    /// The screen the robot should take over by itself: never the primary one.
    private func secondScreen() -> NSScreen? {
        let others = Array(NSScreen.screens.dropFirst())
        return others.first(where: { !$0.isBuiltIn }) ?? others.first
    }

    /// A small 16:9 window in the bottom-right corner of a screen.
    private func cornerFrame(on screen: NSScreen) -> NSRect {
        let area = screen.visibleFrame
        let width = min(560, (area.width * 0.4).rounded())
        let height = (width * 9 / 16).rounded()
        return NSRect(x: area.maxX - width - 24, y: area.minY + 24, width: width, height: height)
    }

    /// In a window the robot floats over everything, on every desktop and over
    /// other apps' fullscreen, the way a second screen would always be in view.
    private func applyWindowMode() {
        guard let window = robot, !window.styleMask.contains(.fullScreen) else { return }
        window.level = keepOnTop ? .floating : .normal
        window.collectionBehavior = keepOnTop ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.fullScreenPrimary]
    }

    private func enterFullScreen(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        window.level = .normal
        window.collectionBehavior = [.fullScreenPrimary]
        window.toggleFullScreen(nil)
    }

    private func showRobot(on screen: NSScreen, fullscreen: Bool) {
        if robot == nil {
            let view = makeWebView()
            let window = NSWindow(contentRect: cornerFrame(on: screen), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Burnbot Robot"
            window.appearance = NSAppearance(named: .darkAqua)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.backgroundColor = .black
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 360, height: 202)
            window.contentView = view
            window.delegate = self
            // Remember where the person puts it.
            if !window.setFrameUsingName("BurnbotRobot") { window.setFrame(cornerFrame(on: screen), display: false) }
            window.setFrameAutosaveName("BurnbotRobot")
            view.load(URLRequest(url: URL(string: base + "/display")!))
            robot = window
            robotView = view
        }
        guard let window = robot else { return }
        let isFull = window.styleMask.contains(.fullScreen)
        if isFull && fullscreen && window.screen == screen {
            window.orderFrontRegardless()
            return
        }
        let place = { [weak self] in
            guard let self, let window = self.robot else { return }
            if window.screen != screen { window.setFrame(self.cornerFrame(on: screen), display: true) }
            self.applyWindowMode()
            // Regardless: the robot should come into view even when another app has the focus.
            window.orderFrontRegardless()
            log("Robot shown on \(screen.localizedName)\(fullscreen ? ", going fullscreen" : " in a window")")
            guard fullscreen else { return }
            // The window has to be on screen before it can go fullscreen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.enterFullScreen(window) }
        }
        if isFull {
            afterExitFullScreen = place
            window.toggleFullScreen(nil)
        } else {
            place()
        }
    }

    @objc func toggleRobotFullScreen() {
        guard let window = robot else { return }
        followSecondScreen = false
        if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) } else { enterFullScreen(window) }
    }

    /// View > Full Screen: the robot needs its own path, the dashboard uses the standard one.
    @objc func toggleFullScreenOfFrontWindow() {
        if NSApp.keyWindow === dashboard { dashboard?.toggleFullScreen(nil) } else { toggleRobotFullScreen() }
    }

    @objc func toggleKeepOnTop() {
        keepOnTop.toggle()
        UserDefaults.standard.set(keepOnTop, forKey: "keepRobotOnTop")
        applyWindowMode()
    }

    @objc func showRobotLive() {
        if robotView?.url?.query != nil { robotView?.load(URLRequest(url: URL(string: base + "/display")!)) }
        if let window = robot, window.isVisible {
            window.orderFrontRegardless()
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
        showRobot(on: dashboard?.screen ?? NSScreen.screens[0], fullscreen: false)
    }

    @objc func previewLevels() {
        if robot == nil || robot?.isVisible == false { robotToWindow() }
        robotView?.load(URLRequest(url: URL(string: base + "/display?demo=cycle")!))
        robot?.makeKeyAndOrderFront(nil)
    }

    @objc func hideRobot() {
        followSecondScreen = false
        guard let window = robot else { return }
        if window.styleMask.contains(.fullScreen) {
            afterExitFullScreen = { window.orderOut(nil) }
            window.toggleFullScreen(nil)
        } else {
            window.orderOut(nil)
        }
        updateAwake()
    }

    @objc func reload() {
        (NSApp.keyWindow === robot ? robotView : dashboardView)?.reload()
    }

    /// A screen was plugged in or removed.
    @objc func screensChanged() {
        guard followSecondScreen, let window = robot, window.isVisible else { return }
        let isFull = window.styleMask.contains(.fullScreen)
        if let second = secondScreen() {
            if !(isFull && window.screen == second) {
                log("Second screen attached: \(second.localizedName)")
                showRobot(on: second, fullscreen: true)
            }
        } else if isFull {
            // Its screen is gone: do not sit fullscreen over the only screen left.
            log("Second screen removed")
            showRobot(on: NSScreen.screens[0], fullscreen: false)
        }
    }

    func windowDidEnterFullScreen(_ notification: Notification) { updateAwake() }

    func windowDidExitFullScreen(_ notification: Notification) {
        applyWindowMode()
        updateAwake()
        let work = afterExitFullScreen
        afterExitFullScreen = nil
        work?()
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === robot { followSecondScreen = false }
        DispatchQueue.main.async { self.updateAwake() }
    }

    /// While the robot owns a whole screen, keep that screen from going to sleep.
    private func updateAwake() {
        let owning = robot.map { $0.isVisible && $0.styleMask.contains(.fullScreen) } ?? false
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
            item("Robot in a Window", #selector(robotToWindow), "4", mine: true),
            item("Keep Robot on Top", #selector(toggleKeepOnTop), "t", mine: true),
            item("Hide Robot", #selector(hideRobot), mine: true),
            .separator(),
            item("Preview Every Level", #selector(previewLevels), mine: true),
        ])
        add("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        NSApp.mainMenu = bar
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(robotToSecondScreen) { return secondScreen() != nil }
        if menuItem.action == #selector(hideRobot) { return robot?.isVisible == true }
        if menuItem.action == #selector(toggleKeepOnTop) { menuItem.state = keepOnTop ? .on : .off }
        return true
    }

    // MARK: Self-check

    /// Writes a picture of each window, and what the pages say, so a build can be checked without looking at the screen.
    private func snapshot(to folder: String) {
        let directory = URL(fileURLWithPath: folder)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, view) in [("dashboard", dashboardView), ("robot", robotView)] {
            guard let view else { continue }
            view.takeSnapshot(with: nil) { image, error in
                guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else {
                    log("Snapshot of \(name) failed: \(error?.localizedDescription ?? "no image")")
                    return
                }
                try? png.write(to: directory.appendingPathComponent("\(name).png"))
                log("Snapshot of \(name): \(Int(image.size.width)) x \(Int(image.size.height))")
            }
            view.evaluateJavaScript("document.title + ' | ' + document.body.innerText.replace(/\\s+/g, ' ').slice(0, 260)") { value, _ in
                log("Text in \(name): \(value ?? "nothing")")
            }
        }
        let frames = [dashboard, robot].compactMap { $0 }.map {
            "\($0.title) \(Int($0.frame.width))x\(Int($0.frame.height)) on \($0.screen?.localizedName ?? "no screen") inView=\($0.occlusionState.contains(.visible)) level=\($0.level.rawValue)"
        }
        log("Windows: \(frames.joined(separator: "; "))")
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
