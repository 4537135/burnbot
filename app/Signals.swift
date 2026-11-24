// What Claude Code tells Burnbot through its hooks, and where you are.
//
// Hooks: Burnbot adds three entries to ~/.claude/settings.json (PermissionRequest,
// Stop, SessionEnd). Each runs hook.sh, which copies what Claude Code sends into a
// folder (inbox/) and does nothing else. It prints nothing, so Claude's own
// behaviour does not change, and it runs in the background ("async"). The app
// reads each file once and deletes it. While the app is closed the folder is
// gone, so the hook writes nothing.
//
// Where you are: which app is in front, and how long since you last touched
// the keyboard or mouse. Neither needs a permission prompt.

import Cocoa

// MARK: - Hook inbox

struct HookEvent {
    let event: String                       // PermissionRequest, Stop, SessionEnd
    let session: String
    let agent: String                       // set when a subagent asked
    let project: String
    let tool: String                        // PermissionRequest: which tool
    let detail: String                      // PermissionRequest: the command, file or address, shortened
    let reason: String                      // SessionEnd: why it ended
    let ms: Double                          // when it came
}

extension HookEvent {
    /// What one hook call sent (the JSON Claude Code gives a hook), or nil when it is not one.
    /// `limit`: how long the detail may be.
    static func read(_ path: String, ms: Double, limit: Int = 48) -> HookEvent? {
        guard let data = FileManager.default.contents(atPath: path),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let event = raw["hook_event_name"] as? String, let session = raw["session_id"] as? String else { return nil }
        let cwd = raw["cwd"] as? String ?? ""
        var project = (cwd as NSString).lastPathComponent
        if let range = cwd.range(of: "/.claude/worktrees/") { project = (String(cwd[..<range.lowerBound]) as NSString).lastPathComponent }
        let tool = raw["tool_name"] as? String ?? ""
        let input = raw["tool_input"] as? [String: Any] ?? [:]
        var detail = ""
        if let command = input["command"] as? String {
            detail = command
        } else if let path = (input["file_path"] ?? input["notebook_path"] ?? input["path"]) as? String {
            detail = (path as NSString).lastPathComponent
        } else if let address = input["url"] as? String {
            detail = URL(string: address)?.host ?? address
        }
        return HookEvent(event: event, session: session, agent: raw["agent_id"] as? String ?? "", project: project, tool: tool,
                         detail: shortened(detail, limit), reason: raw["reason"] as? String ?? "", ms: ms)
    }
}

/// One line, at most `limit` characters, for a card.
func shortened(_ text: String, _ limit: Int = 60) -> String {
    let flat = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    return flat.count <= limit ? flat : String(flat.prefix(limit - 1)) + "…"
}

final class HookInbox {
    let folder: String

    init(dataFolder: String) { folder = dataFolder + "/inbox" }

    /// Makes the folder the hook writes to. Anything already in it is old news and is dropped.
    func open() {
        let manager = FileManager.default
        try? manager.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for name in (try? manager.contentsOfDirectory(atPath: folder)) ?? [] { try? manager.removeItem(atPath: folder + "/" + name) }
    }

    /// Removes the folder, so the hook stops writing while the app is closed.
    func close() { try? FileManager.default.removeItem(atPath: folder) }

    /// Reads, deletes and returns what came since the last call, oldest first.
    func drain() -> [HookEvent] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: folder) else { return [] }
        var found: [(ms: Double, path: String)] = []
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let path = folder + "/" + name
            let modified = (try? manager.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()
            found.append((modified.timeIntervalSince1970 * 1000, path))
        }
        var events: [HookEvent] = []
        for entry in found.sorted(by: { $0.ms < $1.ms }) {
            defer { try? manager.removeItem(atPath: entry.path) }
            if let event = HookEvent.read(entry.path, ms: entry.ms) { events.append(event) }
        }
        return events
    }

    /// The same, from a file of hook events with their times (fixtures): one JSON object per line, with "at".
    static func scripted(_ path: String) -> [HookEvent] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var events: [HookEvent] = []
        for line in text.split(separator: "\n") {
            guard let raw = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let at = (raw["at"] as? String).flatMap(milliseconds) else { continue }
            let input = raw["tool_input"] as? [String: Any] ?? [:]
            let detail = (input["command"] as? String) ?? ((input["file_path"] as? String).map { ($0 as NSString).lastPathComponent }) ?? ""
            events.append(HookEvent(event: raw["hook_event_name"] as? String ?? "", session: raw["session_id"] as? String ?? "",
                                    agent: raw["agent_id"] as? String ?? "", project: ((raw["cwd"] as? String ?? "") as NSString).lastPathComponent,
                                    tool: raw["tool_name"] as? String ?? "", detail: shortened(detail, 48), reason: raw["reason"] as? String ?? "", ms: at))
        }
        return events
    }
}

// MARK: - Installing the hooks

enum HookError: LocalizedError {
    case unreadable(String)
    var errorDescription: String? {
        switch self {
        case .unreadable(let path): return "\(path) could not be read as JSON, so it was left alone"
        }
    }
}

final class ClaudeHooks {
    static let events = ["PermissionRequest", "Stop", "SessionEnd"]
    static let marker = "# burnbot"         // ends each command Burnbot adds, so it can find them again
    let settingsPath: String
    let script: String
    let askScript: String                   // waits for the desk pad's Approve or Deny (see PadAsks)

    init(dataFolder: String, settingsPath: String) {
        self.settingsPath = settingsPath
        script = dataFolder + "/hook.sh"
        askScript = dataFolder + "/ask.sh"
    }

    private var command: String { "\"\(script)\" \(ClaudeHooks.marker)" }
    private var askCommand: String { "\"\(askScript)\" \(ClaudeHooks.marker)" }

    /// The script the hooks run. Written at every launch so it is always this version's.
    func writeScript() {
        let body = """
        #!/bin/sh
        # Burnbot: copies what Claude Code reports into the Burnbot app's inbox.
        # Prints nothing and always succeeds, so Claude Code carries on as before.
        d="$(dirname "$0")/inbox"
        if [ ! -d "$d" ]; then cat >/dev/null; exit 0; fi
        t="$d/.$$.tmp"
        cat > "$t" && mv "$t" "$d/$(date +%s).$$.json"
        find "$d" -name '*.json' -mmin +10 -delete 2>/dev/null
        exit 0

        """
        try? FileManager.default.createDirectory(atPath: (script as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: script, contents: Data(body.utf8), attributes: [.posixPermissions: 0o755])
        // Claude Code waits for this one. Without a desk pad that Burnbot keeps alive it is gone at
        // once, saying nothing, and Claude asks you as usual; so it is when nobody presses a key.
        let ask = """
        #!/bin/sh
        # Burnbot: lets the desk pad's keys answer Claude Code's permission prompt.
        # Prints nothing, so Claude asks you as usual, unless Burnbot is running with the pad plugged in.
        # Then the pad shows what Claude wants to do, and this waits up to \(PadAsks.waitSeconds) seconds for Approve or Deny.
        d="$(dirname "$0")"
        a="$d/pad-alive"
        alive() { [ -f "$a" ] && [ $(( $(date +%s) - $(stat -f %m "$a" 2>/dev/null || echo 0) )) -le 5 ]; }
        input="$(cat)"
        alive || exit 0
        printf '%s' "$input" | grep -q -E '"tool_name" *: *"(AskUserQuestion|ExitPlanMode)"' && exit 0
        mkdir -p "$d/asks" "$d/answers" || exit 0
        id="$(date +%s).$$"
        trap 'rm -f "$d/asks/$id.json" "$d/answers/$id.json"' EXIT
        trap 'exit 0' INT TERM HUP
        printf '%s' "$input" > "$d/asks/.$id.tmp" && mv "$d/asks/.$id.tmp" "$d/asks/$id.json" || exit 0
        n=0
        while [ $n -lt \(PadAsks.waitSeconds * 5) ]; do
          if [ -f "$d/answers/$id.json" ]; then cat "$d/answers/$id.json"; exit 0; fi
          alive || exit 0
          sleep 0.2
          n=$((n + 1))
        done
        exit 0

        """
        FileManager.default.createFile(atPath: askScript, contents: Data(ask.utf8), attributes: [.posixPermissions: 0o755])
    }

    /// The hooks were added by a Burnbot from before the desk pad's keys: add them again, with ask.sh.
    var lacksAsk: Bool {
        guard installed, let settings = try? readSettings().settings, let hooks = settings["hooks"] as? [String: Any] else { return false }
        return !((hooks["PermissionRequest"] as? [[String: Any]]) ?? []).contains {
            (($0["hooks"] as? [Any]) ?? []).contains { ($0 as? [String: Any])?["command"] as? String == askCommand }
        }
    }

    private func readSettings() throws -> (settings: [String: Any], original: Data?) {
        guard let data = FileManager.default.contents(atPath: settingsPath) else { return ([:], nil) }
        if data.isEmpty { return ([:], data) }
        guard let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw HookError.unreadable(settingsPath) }
        return (settings, data)
    }

    private static func isOurs(_ handler: Any) -> Bool {
        ((handler as? [String: Any])?["command"] as? String)?.hasSuffix(marker) == true
    }

    /// The settings with Burnbot's entries taken out, everything else untouched.
    private static func without(_ settings: [String: Any]) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            var kept: [[String: Any]] = []
            for var group in groups {
                guard let handlers = group["hooks"] as? [Any] else { kept.append(group); continue }
                let rest = handlers.filter { !isOurs($0) }
                if rest.count == handlers.count { kept.append(group); continue }
                if rest.isEmpty { continue }
                group["hooks"] = rest
                kept.append(group)
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        return settings
    }

    var installed: Bool {
        guard let settings = try? readSettings().settings, let hooks = settings["hooks"] as? [String: Any] else { return false }
        return ClaudeHooks.events.allSatisfy { event in
            ((hooks[event] as? [[String: Any]]) ?? []).contains { (($0["hooks"] as? [Any]) ?? []).contains(where: ClaudeHooks.isOurs) }
        }
    }

    private func write(_ settings: [String: Any], replacing original: Data?) throws {
        if let original { try original.write(to: URL(fileURLWithPath: settingsPath + ".burnbot-backup")) }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(atPath: (settingsPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try (data + Data("\n".utf8)).write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
    }

    /// Adds Burnbot's hooks (replacing any it added before): hook.sh on three events, and ask.sh for the pad. Other hooks and settings are kept.
    func install() throws {
        writeScript()
        let (settings, original) = try readSettings()
        var merged = ClaudeHooks.without(settings)
        var hooks = merged["hooks"] as? [String: Any] ?? [:]
        for event in ClaudeHooks.events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(["hooks": [["type": "command", "command": command, "async": true, "timeout": 10]]])
            // Not async: Claude Code waits for the pad's answer (ask.sh is gone at once without one).
            if event == "PermissionRequest" {
                groups.append(["hooks": [["type": "command", "command": askCommand, "timeout": PadAsks.waitSeconds + 15]]])
            }
            hooks[event] = groups
        }
        merged["hooks"] = hooks
        try write(merged, replacing: original)
        log("Claude Code hooks added to \(settingsPath)")
    }

    /// Takes Burnbot's hooks out again.
    func remove() throws {
        let (settings, original) = try readSettings()
        guard original != nil else { return }
        let cleaned = ClaudeHooks.without(settings)
        guard !NSDictionary(dictionary: cleaned).isEqual(to: settings) else { return }
        try write(cleaned, replacing: original)
        log("Claude Code hooks removed from \(settingsPath)")
    }
}

// MARK: - Where you are

/// Which app is in front and how long since you touched the Mac. Safe from any thread.
final class Attention {
    // Terminals, editors and IDEs: where a person working with Claude Code usually is.
    private static let seeds: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
        "io.alacritty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper", "org.tabby", "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders", "com.vscodium", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf",
        "dev.zed.Zed", "dev.zed.Zed-Preview", "com.apple.dt.Xcode", "com.sublimetext.4", "com.panic.Nova",
        "com.anthropic.claudefordesktop",
    ]
    private let lock = NSLock()
    private var front = ""
    private var lastWork = ""
    private var learned: [String: Int]
    private var breaks: [Double]            // seconds: stretches in other apps that ended with you prompting again
    private let remember: Bool
    /// Set to replace the real thing (fixtures): (bundle id in front, seconds since input).
    var scripted: (() -> (String, Double))?

    init(remember: Bool) {
        self.remember = remember
        learned = remember ? (UserDefaults.standard.dictionary(forKey: "workApps") as? [String: Int] ?? [:]) : [:]
        breaks = remember ? (UserDefaults.standard.array(forKey: "breaks") as? [Double] ?? []) : []
    }

    /// One more of your breaks, in ms (the last 100 are kept).
    func addBreak(_ ms: Double) {
        lock.lock()
        defer { lock.unlock() }
        breaks = Array((breaks + [ms / 1000]).suffix(100))
        if remember { UserDefaults.standard.set(breaks, forKey: "breaks") }
    }

    /// How long you usually step away to another app mid-session, in ms: 5 min until 20 breaks
    /// are known, then the 75th percentile of them, kept between 3 and 20 min.
    var usualBreak: Double {
        lock.lock()
        defer { lock.unlock() }
        guard breaks.count >= 20 else { return 5 * 60_000 }
        let sorted = breaks.sorted()
        let p75 = sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * 0.75).rounded()))]
        return min(20 * 60, max(3 * 60, p75)) * 1000
    }

    private func known(_ id: String) -> Bool {
        Attention.seeds.contains(id) || id.hasPrefix("com.jetbrains.") || (learned[id] ?? 0) >= 2
    }

    func isWork(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return known(id)
    }

    /// The app in front changed (main thread).
    func setFront(_ id: String) {
        lock.lock()
        front = id
        if known(id) { lastWork = id }
        lock.unlock()
    }

    /// You just sent a prompt: whatever is in front is somewhere you work.
    func learn() {
        lock.lock()
        defer { lock.unlock() }
        let id = scripted?().0 ?? front
        guard !id.isEmpty, id != Bundle.main.bundleIdentifier, !Attention.seeds.contains(id) else { return }
        learned[id, default: 0] += 1
        if remember { UserDefaults.standard.set(learned, forKey: "workApps") }
    }

    /// The work app you were in last, to bring forward.
    var workApp: String {
        lock.lock()
        defer { lock.unlock() }
        return lastWork
    }

    /// (app in front, seconds since you last typed, clicked or moved the mouse)
    var now: (front: String, idle: Double) {
        if let scripted { return scripted() }
        lock.lock()
        let id = front
        lock.unlock()
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        return (id, idle)
    }
}
