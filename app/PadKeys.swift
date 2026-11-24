// The desk pad's keys: a board with keys under its screen (the Claude Pad, desk/burnbot_pad).
//
// Approve and Deny answer Claude Code's permission prompt. ask.sh (ClaudeHooks) is a hook Claude
// Code waits for: while Burnbot keeps "pad-alive" fresh it copies the request into asks/ and waits
// for answers/<same name>; with no answer it says nothing and Claude asks you as usual.
//
// Talk holds the Mac's dictation down: Wispr Flow's push-to-talk (fn held) when it is running, or
// macOS Dictation's own shortcut pressed twice to start and twice to stop.

import AppKit
import ApplicationServices

/// A permission prompt waiting for the pad.
struct PadAsk: Equatable {
    let id: String                          // the file's name in asks/, and its answer's in answers/
    let session: String
    let project: String
    let tool: String
    let detail: String
    let ms: Double                          // when it came

    static func == (a: PadAsk, b: PadAsk) -> Bool { a.id == b.id }
}

/// The files between ask.sh and the app. Used on the engine's queue.
final class PadAsks {
    static let waitSeconds = 45             // how long ask.sh waits for a key before Claude asks you as usual
    private let asks: String
    private let answers: String
    private let alive: String
    private var answered: Set<String> = []  // answered, not yet picked up by ask.sh
    private(set) var beating = false

    init(dataFolder: String) {
        asks = dataFolder + "/asks"
        answers = dataFolder + "/answers"
        alive = dataFolder + "/pad-alive"
    }

    /// Says a pad with keys is plugged in and Burnbot is answering for it. Call every second while it is.
    func beat() {
        let manager = FileManager.default
        if !manager.fileExists(atPath: alive) { manager.createFile(atPath: alive, contents: nil) }
        try? manager.setAttributes([.modificationDate: Date()], ofItemAtPath: alive)
        if !beating { try? manager.createDirectory(atPath: answers, withIntermediateDirectories: true) }
        beating = true
    }

    /// The pad went, or Burnbot is closing: ask.sh stops waiting and Claude asks as usual.
    func stop() {
        guard beating else { return }
        beating = false
        try? FileManager.default.removeItem(atPath: alive)
    }

    /// The newest prompt still waiting, or nil.
    func pending(now: Double) -> PadAsk? {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: asks) else { return nil }
        var newest: PadAsk?
        var live: Set<String> = []
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let id = String(name.dropLast(5))
            let path = asks + "/" + name
            let ms = ((try? manager.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()).timeIntervalSince1970 * 1000
            // ask.sh removes its file when it ends; one left behind (the script was killed) is old news.
            if now - ms > Double(PadAsks.waitSeconds + 20) * 1000 {
                try? manager.removeItem(atPath: path)
                continue
            }
            live.insert(id)
            guard !answered.contains(id), let event = HookEvent.read(path, ms: ms, limit: 96) else { continue }
            if newest == nil || ms > newest!.ms {
                newest = PadAsk(id: id, session: event.session, project: event.project, tool: event.tool, detail: event.detail, ms: ms)
            }
        }
        answered.formIntersection(live)
        return newest
    }

    /// Approve (true) or Deny (false), for ask.sh to hand to Claude Code.
    func answer(_ ask: PadAsk, allow: Bool) {
        let decision: [String: Any] = allow ? ["behavior": "allow"] : ["behavior": "deny", "message": "Denied from the desk pad."]
        let reply: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        guard let data = try? JSONSerialization.data(withJSONObject: reply) else { return }
        put(ask, data)
    }

    /// No answer from the pad: ask.sh ends at once and Claude asks you as usual.
    func letGo(_ ask: PadAsk) { put(ask, Data()) }

    private func put(_ ask: PadAsk, _ data: Data) {
        try? FileManager.default.createDirectory(atPath: answers, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: answers + "/" + ask.id + ".json"), options: .atomic)
        answered.insert(ask.id)
    }
}

/// What the pad's labels say now, left to right, and what it shows for a prompt (the B line's
/// ky=, pr= and pp=). Its letters: capitals, digits and the marks the board draws; no "|", which
/// ends a field.
func padLine(ask: PadAsk?, card: Card?) -> String {
    func clean(_ text: String, _ limit: Int) -> String {
        let letters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -.,!%/:+&\"()?=_*#;<>@$[]~")
        var out = ""
        for c in text.uppercased() {
            let mapped: Character = c == "|" ? "/" : c == "'" || c == "`" ? "\"" : c == "{" ? "(" : c == "}" ? ")" : c
            let next: Character = letters.contains(mapped) ? mapped : " "
            if next == " " && out.last == " " { continue }
            out.append(next)
        }
        return String(out.trimmingCharacters(in: .whitespaces).prefix(limit))
    }
    if let ask {
        let what = ask.detail.isEmpty ? ask.tool : ask.tool + ": " + ask.detail
        return "|ky=DENY,TALK,SHOW,APPROVE|pr=" + clean(what, 96) + "|pp=" + clean(ask.project, 18)
    }
    return "|ky=" + (card == nil ? "" : "CLOSE") + ",TALK,SHOW,"
}

// MARK: - Talk

/// Starts and stops the Mac's dictation as if you pressed its shortcut. Main thread.
enum Dictation {
    /// Burnbot may press keys for you (System Settings > Privacy & Security > Accessibility).
    /// `ask`: show the system's request when it may not.
    static func allowed(ask: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: ask] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Wispr Flow is running: its push-to-talk is fn held down.
    static var wispr: Bool {
        NSWorkspace.shared.runningApplications.contains { ($0.bundleIdentifier ?? "").lowercased().contains("wispr") }
    }

    private static var holding = false      // fn is down for Wispr Flow
    private static var started = false      // macOS Dictation was started

    /// The key down: start listening.
    static func start() {
        guard allowed(ask: true) else { return log("Talk: Burnbot is not allowed to press keys yet (Accessibility)") }
        if wispr {
            modifier(keyCode: 63, flag: .maskSecondaryFn, down: true)
            holding = true
            log("Talk: holding fn for Wispr Flow")
        } else {
            let (code, flag) = shortcut()
            tapTwice(keyCode: code, flag: flag)
            started = true
            log("Talk: Dictation on")
        }
    }

    /// The key up: stop, and the words land where the cursor is.
    static func stop() {
        if holding {
            modifier(keyCode: 63, flag: .maskSecondaryFn, down: false)
            holding = false
        } else if started {
            let (code, flag) = shortcut()
            tapTwice(keyCode: code, flag: flag)
            started = false
            log("Talk: Dictation off")
        }
    }

    /// macOS Dictation's shortcut, a modifier pressed twice (System Settings > Keyboard > Dictation):
    /// fn when the fn (Globe) key is set to start dictation, else the one it names; Control if it says none.
    private static func shortcut() -> (CGKeyCode, CGEventFlags) {
        if UserDefaults(suiteName: "com.apple.HIToolbox")?.integer(forKey: "AppleFnUsageType") == 3 { return (63, .maskSecondaryFn) }
        let hotkeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys")
        let value = (hotkeys?["164"] as? [String: Any])?["value"] as? [String: Any]
        let mask = ((value?["parameters"] as? [NSNumber])?.first?.uint64Value) ?? CGEventFlags.maskControl.rawValue
        switch mask {
        case CGEventFlags.maskCommand.rawValue: return (55, .maskCommand)
        case CGEventFlags.maskAlternate.rawValue: return (58, .maskAlternate)
        case CGEventFlags.maskShift.rawValue: return (56, .maskShift)
        case CGEventFlags.maskSecondaryFn.rawValue: return (63, .maskSecondaryFn)
        default: return (59, .maskControl)
        }
    }

    private static func tapTwice(keyCode: CGKeyCode, flag: CGEventFlags) {
        for _ in 0..<2 {
            modifier(keyCode: keyCode, flag: flag, down: true)
            usleep(30_000)
            modifier(keyCode: keyCode, flag: flag, down: false)
            usleep(70_000)
        }
    }

    private static func modifier(keyCode: CGKeyCode, flag: CGEventFlags, down: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return }
        event.type = .flagsChanged
        event.flags = down ? flag : []
        event.post(tap: .cghidEventTap)
    }
}
