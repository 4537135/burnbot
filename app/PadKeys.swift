// The desk pad's keys: a board with keys under its screen (the Claude Pad, desk/burnbot_pad).
//
// Approve and Deny answer Claude Code's permission prompt. ask.sh (ClaudeHooks) is a hook Claude
// Code waits for: while Burnbot keeps "pad-alive" fresh it copies the request into asks/ and waits
// for answers/<same name>; with no answer it says nothing and Claude asks you as usual.
//
// The pad offers Approve only for a request it can show whole: the full command (or a file inside
// the project, or the full address), every letter of it one the pad draws, in four rows of 25. It
// shows capitals only and runs of spaces as one. Anything else is handed back at once, so Claude
// asks on the Mac with everything in view.

import Foundation

/// A permission prompt waiting for the pad.
struct PadAsk: Equatable {
    let id: String                          // the file's name in asks/, and its answer's in answers/
    let session: String
    let project: String
    let tool: String
    let shown: String                       // what the pad shows: "BASH: NPM TEST"
    let whole: Bool                         // `shown` is all of the request, so it may be approved on the pad
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
        if !beating {
            // Only you can read what Claude asks, or answer it.
            for folder in [asks, answers] {
                try? manager.createDirectory(atPath: folder, withIntermediateDirectories: true)
                try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder)
            }
        }
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
            guard !answered.contains(id), let event = HookEvent.read(path, ms: ms),
                  let data = manager.contents(atPath: path),
                  let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if newest == nil || ms > newest!.ms {
                let (shown, whole) = padRequest(raw)
                newest = PadAsk(id: id, session: event.session, project: event.project, tool: event.tool, shown: shown, whole: whole, ms: ms)
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

/// The letters the pad draws, besides a to z (shown as capitals) and the space.
let padLetters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.,!%/:+&'\"()?=_*#;<>@$|[]~`^{}\\")

/// Whether `text` fits a card on the pad: words of at most `cols` letters, in at most `rows` rows,
/// wrapped as pad.h's wrap() does.
func padFits(_ text: String, cols: Int = 25, rows: Int = 4) -> Bool {
    var full = 0, length = 0                    // rows filled; letters in the row being filled
    for word in text.split(separator: " ") {
        if word.count > cols { return false }
        if length > 0 && length + 1 + word.count > cols { full += 1; length = 0 }
        length += (length > 0 ? 1 : 0) + word.count
    }
    return full < rows
}

/// What a permission prompt (the JSON Claude Code gives the hook) asks, as the pad shows it, and
/// whether that is all of it: the command; a file by its place in the project (one outside the
/// project is never whole); an address in full; a tool with other input never whole.
func padRequest(_ raw: [String: Any]) -> (shown: String, whole: Bool) {
    let tool = raw["tool_name"] as? String ?? "?"
    let input = raw["tool_input"] as? [String: Any] ?? [:]
    let cwd = raw["cwd"] as? String ?? ""
    var what = ""
    var whole = true
    if let command = input["command"] as? String {
        what = command
        if command.contains("\n") || command.contains("\r") { whole = false }   // lines would read as one
    } else if let path = (input["file_path"] ?? input["notebook_path"] ?? input["path"]) as? String {
        if !cwd.isEmpty, path.hasPrefix(cwd + "/") {
            what = String(path.dropFirst(cwd.count + 1))
        } else {
            what = path
            whole = false
        }
    } else if let address = input["url"] as? String {
        what = address
    } else if !input.isEmpty {
        whole = false
    }
    let text = what.isEmpty ? tool : tool + ": " + what
    var shown = ""
    for c in text {
        let drawn: Character = c == "\t" ? " " : c
        if drawn != " " && !padLetters.contains(drawn) && !(drawn >= "a" && drawn <= "z") { whole = false }
        shown.append(drawn)
    }
    shown = shown.uppercased()
    if !padFits(shown) { whole = false }
    return (shown, whole)
}

/// What the pad's labels say now, left to right, and what it shows for a prompt (the B line's
/// ky=, pr= and pp=). Its letters: capitals, digits and the marks the board draws; no "|", which
/// ends a field.
func padLine(ask: PadAsk?, card: Card?, pages: Bool = false) -> String {
    if let ask, ask.whole {
        // Sent whole (pad.h shows it whole, as padFits checked); a "|" goes as 0x7F, since "|" ends a field.
        let what = ask.shown.split(separator: " ").joined(separator: " ").replacingOccurrences(of: "|", with: "\u{7F}")
        return "|ky=DENY,,SHOW,APPROVE|pr=" + what + "|pp=" + padText(ask.project, 18)
    }
    // A pad with pages needs no labels: keys 1 and 4 step through its pages, 3 goes to the session.
    if pages { return "" }
    return "|ky=" + (card == nil ? "" : "CLOSE") + ",,SHOW,"
}
