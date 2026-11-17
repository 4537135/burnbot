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
    private var aiSummaries = false         // you switch these on yourself
    private let desk = DeskScreen()
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
    /// Called on the main thread with the days before the 30-day window, when they have been worked out.
    var onOlder: ((String) -> Void)?
    private var olderDay = -1

    init(root: String, storePath: String) {
        tracker = Tracker(root: root, storePath: storePath)
        desk.log = { log($0) }
        moments.voice = Voice(file: pagesFolder.appendingPathComponent("voice.json"))
        moments.isWork = { [attention] in attention.isWork($0) }
        moments.sessionInfo = { [tracker] id, now, since in tracker.session(id, now: now, since: since) }
        moments.trace = { log("moment " + $0) }
        summaries.log = { log($0) }
        moments.lastSession = { [memory] now in memory.last(now: now) }
        moments.onSessionDone = { [weak self] recap in self?.remember(recap) }
    }

    /// A session ended: keep its recap, and if you switched AI summaries on, ask your claude for one.
    private func remember(_ recap: SessionRecap) {
        memory.add(recap)
        guard intelligence, aiSummaries else { return }
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
    func setOptions(intelligence: Bool, aiSummaries: Bool) {
        queue.async {
            self.intelligence = intelligence
            self.aiSummaries = aiSummaries
            self.encode()
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

    private func step() {
        tick += 1
        let changed = tick % 2 == 0 ? tracker.poll() : false
        let now = Date().timeIntervalSince1970 * 1000
        let signals = tracker.takeSignals()
        if signals.contains(where: { if case .prompt = $0 { return true } else { return false } }) { attention.learn() }
        let place = attention.now
        let moved = moments.tick(signals: signals, hooks: inbox.drain(), front: place.front, idle: place.idle,
                                 level: state?["state"] as? String ?? "", now: now)
        if changed || state == nil || Int(now / 60000) != analyzedMinute || now - analyzedAt >= 10_000 {
            refresh()
        } else if moved || tick % 2 == 0 {
            encode()                    // the desk screen may have come or gone
        }
        if !demo.isEmpty { encode() }           // the demo moves on its own clock
        if moved || tick % 2 == 0 || !demo.isEmpty { deliver() }
        if let state {
            let speaks = desk.speaks
            desk.send(deskLine(state, names: names, expr: speaks ? shown.expr : ""), moment: speaks ? deskMoment(shown.card) : nil)
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
        guard let data = try? JSONSerialization.data(withJSONObject: older), let text = String(data: data, encoding: .utf8) else { return }
        log(String(format: "Older history: %d days before the last 30, in %.2fs", (older["days"] as? [Any])?.count ?? 0, Date().timeIntervalSince(began)))
        DispatchQueue.main.async { self.onOlder?(text) }
    }

    private func refresh() {
        let now = Date().timeIntervalSince1970 * 1000
        state = analyze(files: Array(tracker.files.values), lastCallMs: tracker.lastCallMs, lastPromptMs: tracker.lastPromptMs, now: now)
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

    func dismissMoment(_ id: String) {
        queue.async {
            let now = Date().timeIntervalSince1970 * 1000
            if let shown = self.demoOutput(now), shown.card?.id == id {
                // Clicking a bubble in the demo skips ahead to whatever comes after it.
                let elapsed = now - self.demoStart
                if let next = self.demo.first(where: { $0.at > elapsed && $0.output.card?.id != id }) {
                    self.demoStart = now - next.at
                }
                self.encode()
                self.deliver()
                return
            }
            self.moments.dismiss(id, now: now)
            self.encode()
            self.deliver()
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            tracker.save()
            desk.shutDown()
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
    private var robotPanel: NSPanel?                // the small robot, floating over everything
    private var robotStage: NSWindow?               // the robot filling a whole screen
    private var robotView: WKWebView?
    private var robotShown: Bool { robotPanel?.isVisible == true || robotStage?.isVisible == true }
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
    private var aiSummaries = !fresh && UserDefaults.standard.bool(forKey: "aiSummaries")
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
        engine.setOptions(intelligence: intelligence, aiSummaries: aiSummaries)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Which app you are in decides whether the robot speaks up or just pulls a face.
        let workspace = NSWorkspace.shared
        engine.attention.setFront(workspace.frontmostApplication?.bundleIdentifier ?? "")
        workspace.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.engine.attention.setFront(app?.bundleIdentifier ?? "")
        }
        engine.onState = { [weak self] json in self?.push(json) }
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
            "aiSummaries": aiSummaries,
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

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(pages, forURLScheme: Pages.scheme)
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

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        listening.removeAll { $0 === webView }      // the page is reloading; it will ask again
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log("Loaded \(webView.url?.absoluteString ?? "?")")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log("Could not load \(webView.url?.absoluteString ?? "page"): \(error.localizedDescription)")
    }

    /// Links that would open a new tab: the level preview goes to the robot window, web links to the browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if url.scheme == Pages.scheme, url.path == "/display" {
            followSecondScreen = false
            if !robotShown { showRobot(on: dashboard?.screen ?? NSScreen.screens[0], fullscreen: false) }
            robotView?.load(URLRequest(url: url))
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
        case "aiSummaries":
            // On the welcome the box is the consent: its words say what is sent.
            setAISummaries(body["on"] as? Bool ?? false)
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
        case "moment":
            // A speech bubble was clicked: it goes, and if it was asking for you, so do you.
            guard let id = body["id"] as? String else { return }
            if body["action"] as? String == "focus" { bringBackWork() }
            engine.dismissMoment(id)
        default:
            break
        }
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

    private func setAISummaries(_ on: Bool) {
        aiSummaries = on
        if !fresh { UserDefaults.standard.set(on, forKey: "aiSummaries") }
        engine.setOptions(intelligence: intelligence, aiSummaries: on)
        log("AI session summaries \(on ? "on" : "off")")
        refreshMeta()
    }

    @objc func toggleAISummaries() {
        if aiSummaries { return setAISummaries(false) }
        // Switching it on from the menu: say what leaves the Mac first.
        let alert = NSAlert()
        alert.messageText = "Send session summaries to Claude?"
        alert.informativeText = """
        When a session ends, Burnbot asks Claude for a short summary of it, through the claude command \
        you already use, on your own plan. It sends the session's name, your prompts (shortened), the names \
        of files edited and how test and build runs turned out. Never the contents of your files.

        At most 20 a day. Without it, the robot still sums up each session from what is on this Mac.
        """
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { setAISummaries(true) }
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

    /// A small 16:9 window in the bottom-right corner of a screen.
    private func cornerFrame(on screen: NSScreen) -> NSRect {
        let area = screen.visibleFrame
        let width = min(560, (area.width * 0.4).rounded())
        let height = (width * 9 / 16).rounded()
        return NSRect(x: area.maxX - width - 24, y: area.minY + 24, width: width, height: height)
    }

    private func robotWebView() -> WKWebView {
        if let view = robotView { return view }
        let view = makeWebView()
        view.load(URLRequest(url: URL(string: Pages.home + "display")!))
        robotView = view
        return view
    }

    /// On top, the small robot floats over everything: every desktop, and other
    /// apps' fullscreen windows too, the way a second screen would always be in view.
    private func applyWindowMode() {
        guard let panel = robotPanel else { return }
        panel.level = keepOnTop ? .floating : .normal
        panel.isFloatingPanel = keepOnTop
        panel.collectionBehavior = keepOnTop ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
    }

    /// The small robot. A panel that does not take the focus, which is what
    /// lets it stay visible over another app's fullscreen window.
    private func showRobotPanel(on screen: NSScreen?) {
        if stageIsFull {
            afterExitFullScreen = { [weak self] in self?.showRobotPanel(on: screen) }
            robotStage?.toggleFullScreen(nil)
            return
        }
        robotStage?.orderOut(nil)
        if robotPanel == nil {
            let home = screen ?? NSScreen.screens[0]
            let panel = NSPanel(contentRect: cornerFrame(on: home), styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Burnbot Robot"
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.backgroundColor = .black
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.minSize = NSSize(width: 360, height: 202)
            panel.delegate = self
            // Remember where the person puts it.
            if fresh || !panel.setFrameUsingName("BurnbotRobot") { panel.setFrame(cornerFrame(on: home), display: false) }
            if !fresh { panel.setFrameAutosaveName("BurnbotRobot") }
            robotPanel = panel
        }
        guard let panel = robotPanel else { return }
        if let screen, panel.screen != screen { panel.setFrame(cornerFrame(on: screen), display: true) }
        if panel.contentView !== robotView { panel.contentView = robotWebView() }
        applyWindowMode()
        // Regardless: the robot should come into view even when another app has the focus.
        // (macOS also stops animating a window that is completely covered.)
        panel.orderFrontRegardless()
        log("Robot shown in a window on \(panel.screen?.localizedName ?? "?")")
        updateAwake()
    }

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
        robotPanel?.orderOut(nil)
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
        if fullscreen { showRobotStage(on: screen) } else { showRobotPanel(on: screen) }
    }

    @objc func toggleRobotFullScreen() {
        followSecondScreen = false
        if stageIsFull {
            robotStage?.toggleFullScreen(nil)       // back to the small robot, see windowDidExitFullScreen
        } else {
            showRobotStage(on: robotPanel?.screen ?? dashboard?.screen ?? NSScreen.screens[0])
        }
    }

    /// View > Full Screen: the robot needs its own path, the dashboard uses the standard one.
    @objc func toggleFullScreenOfFrontWindow() {
        if NSApp.keyWindow === dashboard { dashboard?.toggleFullScreen(nil) } else { toggleRobotFullScreen() }
    }

    @objc func showRobotLive() {
        if robotView?.url?.query != nil { robotView?.load(URLRequest(url: URL(string: Pages.home + "display")!)) }
        if robotShown {
            (stageIsFull ? robotStage : robotPanel)?.orderFrontRegardless()
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
        showRobotPanel(on: robotShown ? nil : dashboard?.screen)
    }

    @objc func previewLevels() {
        if !robotShown { robotToWindow() }
        robotView?.load(URLRequest(url: URL(string: Pages.home + "display?demo=cycle")!))
    }

    /// A recorded session through the robot's real reactions, about a minute long, on the
    /// robot window and the desk screen; then back to your own.
    @objc func playMoments() {
        if !robotShown { robotToWindow() }
        if robotView?.url?.query != nil { robotView?.load(URLRequest(url: URL(string: Pages.home + "display")!)) }
        engine.playDemo(demoFolder)
    }

    @objc func hideRobot() {
        followSecondScreen = false
        robotPanel?.orderOut(nil)
        if stageIsFull {
            afterExitFullScreen = { [weak self] in self?.robotStage?.orderOut(nil) }
            robotStage?.toggleFullScreen(nil)
        } else {
            robotStage?.orderOut(nil)
        }
        updateAwake()
    }

    @objc func reload() {
        (NSApp.keyWindow === dashboard ? dashboardView : robotView)?.reload()
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
            showRobotPanel(on: NSScreen.screens[0])
        }
    }

    func windowDidEnterFullScreen(_ notification: Notification) { updateAwake() }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard (notification.object as? NSWindow) === robotStage else { return }
        updateAwake()
        if let work = afterExitFullScreen {
            afterExitFullScreen = nil
            work()
        } else {
            showRobotPanel(on: nil)                 // left fullscreen by hand: back to the small robot
        }
    }

    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        if closing === robotPanel || closing === robotStage { followSecondScreen = false }
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
            item("Robot in a Window", #selector(robotToWindow), "4", mine: true),
            item("Keep Robot on Top", #selector(toggleKeepOnTop), "t", mine: true),
            item("Hide Robot", #selector(hideRobot), mine: true),
            .separator(),
            item("Preview Every Level", #selector(previewLevels), mine: true),
            item("Play Every Moment", #selector(playMoments), mine: true),
            .separator(),
            item("Claude Code Alerts", #selector(toggleClaudeAlerts), mine: true),
            item("AI Session Summaries…", #selector(toggleAISummaries), mine: true),
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
        if menuItem.action == #selector(toggleKeepOnTop) { menuItem.state = keepOnTop ? .on : .off }
        if menuItem.action == #selector(toggleOpenAtLogin) { menuItem.state = openAtLogin ? .on : .off }
        if menuItem.action == #selector(toggleClaudeAlerts) { menuItem.state = hooks.installed ? .on : .off }
        if menuItem.action == #selector(toggleAISummaries) {
            menuItem.state = aiSummaries ? .on : .off
            menuItem.title = aiSummaries ? "AI Session Summaries" : "AI Session Summaries…"
        }
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

    /// The robot's reactions (display?demo=moments), at the robot window's size and at a big one,
    /// then back to the live robot.
    private func snapshotMoments(in directory: URL) {
        guard let view = robotView, let window = view.window else { return }
        let original = window.frame
        let big = NSSize(width: 1120, height: 630)
        var steps = (0..<5).map { (name: "robot-moment-\($0)", size: original.size, n: $0) }
            + (0..<5).map { (name: "robot-moment-big-\($0)", size: big, n: $0) }
        func next() {
            guard !steps.isEmpty else {
                window.setFrame(original, display: true)
                view.load(URLRequest(url: URL(string: Pages.home + "display")!))
                return
            }
            let step = steps.removeFirst()
            if window.frame.size != step.size, !window.styleMask.contains(.fullScreen) {
                window.setFrame(NSRect(origin: original.origin, size: step.size), display: true)
            }
            view.load(URLRequest(url: URL(string: Pages.home + "display?demo=moments&n=\(step.n)")!))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.capture(view, as: step.name, in: directory) { next() } }
        }
        next()
    }

    /// Writes pictures of the windows, and what the pages say, so a build can be checked without looking at the screen.
    /// As a first launch it also presses Start on the welcome and checks that it goes away for good.
    private func snapshot(to folder: String) {
        let directory = URL(fileURLWithPath: folder)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let frames = [dashboard, robotPanel, robotStage].compactMap { $0 }.filter { $0.isVisible }.map {
            "\($0.title) \(Int($0.frame.width))x\(Int($0.frame.height)) on \($0.screen?.localizedName ?? "no screen") inView=\($0.occlusionState.contains(.visible)) level=\($0.level.rawValue)"
        }
        log("Windows: \(frames.joined(separator: "; "))")
        capture(robotView, as: "robot", in: directory) { self.snapshotMoments(in: directory) }

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
