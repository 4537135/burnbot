// Reads Claude Code's session logs (~/.claude/projects/**/*.jsonl) and folds
// them into per-minute buckets. Each log is tailed from where the last read
// stopped, so a running session shows up within a couple of seconds.
//
// Everything is counted in tokens, never money.

import Foundation

/// Layout of a minute bucket.
enum F {
    static let input = 0          // uncached input tokens
    static let output = 1         // output tokens (includes thinking)
    static let cacheWrite = 2
    static let cacheRead = 3
    static let thinking = 4
    static let calls = 5          // API responses
    static let tools = 6          // tool calls Claude made
    static let prompts = 7        // messages the person sent
    static let chars = 8          // characters the person typed
    static let pasted = 9         // characters the person pasted
    static let lines = 10         // lines Claude wrote through Edit/Write
    static let family = 11        // all tokens by model family: +0 fable, +1 opus, +2 sonnet, +3 haiku, +4 other
    // You at work without typing a prompt: answering Claude's questions, approving or turning down
    // a plan, a permission click, stopping Claude. The wait before an answer counts too (you were reading).
    static let hands = 16
    // Wins, for the daily goal: a green after a fight with red runs, a commit, a pull request, a plan you approved.
    static let greens = 17
    static let commits = 18       // a log that shipped a commit: once a day, however many it made
    static let prs = 19
    static let plans = 20
    static let count = 21
}

/// What a store row looked like before Burnbot 1.2.
private let oldCount = 16

let modelFamilies = ["fable", "opus", "sonnet", "haiku", "other"]

/// Every token a response touched: read, cached and written.
func totalTokens(_ v: [Double]) -> Double { v[F.input] + v[F.output] + v[F.cacheWrite] + v[F.cacheRead] }

/// One session log and what it has contributed so far.
final class LogFile {
    let path: String
    let side: Bool                          // a subagent's log
    var offset = 0                          // bytes already read
    var modified = 0.0                      // seconds since 1970
    var project = ""
    var gone = false                        // Claude Code deleted it; its history is kept
    var minutes: [Int: [Double]] = [:]      // minute -> bucket
    var seen: [String: [Double]] = [:]      // response id -> [minute, input, output, cacheWrite, cacheRead, thinking]
    // What the robot needs to know about the session, besides tokens.
    var session = ""                        // Claude Code's session id; a subagent's log carries its parent's
    var title = ""                          // what Claude Code named the session
    var renamed = false                     // you named it yourself, so Claude Code's own name does not replace it
    var branch = ""
    var edited: Set<String> = []            // files written to
    var lastPrompt = 0.0                    // ms of the last prompt you typed here
    var runs: [String: PendingRun] = [:]   // Bash runs still waiting for their result
    var asks: [String: (tool: String, ms: Double)] = [:]   // questions and plans still waiting for your answer
    var ledger = RunLedger()                // red runs on the way to a green
    var shippedDay = -1                     // the day this log last counted a commit as a win
    let agent: String                       // a subagent's id, "" for the main log

    init(path: String) {
        self.path = path
        side = path.contains("/subagents/")
        // <session>.jsonl, or <session>/subagents/agent-<id>.jsonl
        let url = URL(fileURLWithPath: path)
        session = side ? url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent : url.deletingPathExtension().lastPathComponent
        let name = url.deletingPathExtension().lastPathComponent
        agent = side ? (name.hasPrefix("agent-") ? String(name.dropFirst(6)) : name) : ""
    }
}

/// How a Bash run ended, as the log tells it.
struct RunResult {
    let error: Bool                         // Claude Code marked the result as an error
    let exit: Int?                          // from "Exit code N", when it says
    let denied: Bool                        // never ran: permission refused
    let interrupted: Bool
    let output: String                      // the last 2 KB of what it printed
}

/// A Bash run waiting for its result. History only keeps the ones that can be wins.
struct PendingRun {
    let command: String
    let ms: Double
    let family: Family?
    let core: String
    let git: String?
}

/// How you answered Claude without typing a prompt.
enum Decision: String { case answer, approve, reject, permission, interrupt }

/// One session as a whole (Tracker.session).
struct SessionInfo {
    let id: String
    var project = "", title = "", branch = ""
    var edited: Set<String> = []
    var lastPrompt = 0.0                    // ms
    var activeMinutes = 0                   // minutes with a prompt or a response
    var firstMinute = 0, lastMinute = 0     // minutes since 1970
}

/// Something that just happened in a session, seen in a live log (never during the first read of history).
enum LogSignal {
    case line(session: String, agent: String, assistant: Bool, ms: Double)   // Claude or you did something; agent "" = main log
    case prompt(session: String, ms: Double, text: String)  // you typed a prompt (what you typed, cut to 500)
    case ask(session: String, tool: String, ms: Double)     // Claude asked you a question or showed a plan
    case decision(session: String, kind: Decision, ms: Double)
    case edit(session: String, ms: Double)                  // Claude changed a file (progress, as far as loops go)
    case run(session: String, id: String, command: String, ms: Double)
    case result(session: String, id: String, command: String, outcome: RunResult, ms: Double)
}

private func bytes(_ text: String) -> UnsafeRawBufferPointer {
    let copy = UnsafeMutableRawBufferPointer.allocate(byteCount: text.utf8.count, alignment: 1)
    copy.copyBytes(from: Array(text.utf8))
    return UnsafeRawBufferPointer(copy)
}
private let needleAssistant = bytes("\"type\":\"assistant\"")
private let needleUser = bytes("\"type\":\"user\"")
private let needleToolResult = bytes("\"tool_use_id\"")
private let needleTitle = bytes("-title\"")           // "ai-title" and "custom-title" lines
private let needleYours = bytes("\"source\":\"user")    // a permission you granted yourself
private let exitCode = try! NSRegularExpression(pattern: "^(?:Error: )?Exit code (-?[0-9]+)")

private func has(_ needle: UnsafeRawBufferPointer, _ line: UnsafeRawPointer, _ length: Int) -> Bool {
    memmem(line, length, needle.baseAddress, needle.count) != nil
}

private let writeTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]
/// Tools that wait for you to answer.
private let askTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]
/// A wait this long or shorter before an answer was you reading; a longer one, you were away
/// and only its last minutes count.
private let readingWait = 20

/// "[Request interrupted by user]": you stopped Claude.
func isInterrupt(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[Request interrupted by user")
}

// Wrappers the harness injects into user turns. None of it was typed by the person.
private let injected = try! NSRegularExpression(
    pattern: "<(system-reminder|artifact-view-context|artifact-content-authored-by-others|local-command-stdout|local-command-stderr|"
        + "local-command-caveat|bash-stdout|bash-stderr|task-notification|fork-boilerplate|command-message|command-args|"
        + "user-prompt-submit-hook)\\b[^>]*>[\\s\\S]*?</\\1>")
private let pastedBlock = try! NSRegularExpression(pattern: "<pasted_content\\b[^>]*>([\\s\\S]*?)</pasted_content[^>]*>")
private let keptTags = try! NSRegularExpression(pattern: "</?(bash-input|command-name)>")

/// Splits a user turn into what was typed and what was pasted (lengths as JavaScript counts them).
/// The raw text of a prompt you sent, or nil when a "user" line is something else
/// (a tool result, a subagent's brief, a command's output, a compacted summary).
func promptText(_ object: [String: Any]) -> String? {
    for flag in ["isSidechain", "isMeta", "isCompactSummary", "isVisibleInTranscriptOnly"] where (object[flag] as? Bool) == true { return nil }
    if object["toolUseResult"] != nil { return nil }
    var kind = (object["origin"] as? [String: Any])?["kind"] as? String ?? ""
    if kind.isEmpty { kind = object["turnOrigin"] as? String ?? "" }
    if !kind.isEmpty, kind != "human" { return nil }
    let content = (object["message"] as? [String: Any])?["content"]
    if let whole = content as? String { return whole }
    guard let blocks = content as? [[String: Any]] else { return nil }
    var text = ""
    for block in blocks {
        let type = block["type"] as? String
        if type == "tool_result" { return nil }
        if type == "text" { text += (block["text"] as? String ?? "") + "\n" }
    }
    return text
}

/// What you typed, with pasted blocks, injected context and wrapper tags taken out.
func typedOnly(_ text: String) -> String {
    var rest = pastedBlock.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: " [pasted] ")
    rest = injected.stringByReplacingMatches(in: rest, range: NSRange(location: 0, length: (rest as NSString).length), withTemplate: "")
    rest = keptTags.stringByReplacingMatches(in: rest, range: NSRange(location: 0, length: (rest as NSString).length), withTemplate: "")
    return rest.trimmingCharacters(in: .whitespacesAndNewlines)
}

func measurePrompt(_ text: String) -> (typed: Int, pasted: Int) {
    let whole = NSRange(location: 0, length: (text as NSString).length)
    var pasted = 0
    for match in pastedBlock.matches(in: text, range: whole) { pasted += match.range(at: 1).length }
    var rest = pastedBlock.stringByReplacingMatches(in: text, range: whole, withTemplate: "")
    rest = injected.stringByReplacingMatches(in: rest, range: NSRange(location: 0, length: (rest as NSString).length), withTemplate: "")
    rest = keptTags.stringByReplacingMatches(in: rest, range: NSRange(location: 0, length: (rest as NSString).length), withTemplate: "")
    return (rest.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count, pasted)
}

func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }

private func lineCount(_ value: Any?) -> Double {
    guard let text = value as? String, !text.isEmpty else { return 0 }
    var n = 1.0
    for unit in text.utf8 where unit == 10 { n += 1 }
    return n
}

/// "2026-11-13T15:59:20.123Z" -> milliseconds since 1970. Claude Code always writes UTC.
func milliseconds(_ stamp: String) -> Double? {
    let u = Array(stamp.utf8)
    guard u.count >= 20, u[u.count - 1] == 90 else {
        return ISO8601DateFormatter().date(from: stamp).map { $0.timeIntervalSince1970 * 1000 }
    }
    func digits(_ at: Int, _ length: Int) -> Int? {
        var value = 0
        for k in at..<(at + length) {
            let d = Int(u[k]) - 48
            guard d >= 0, d <= 9 else { return nil }
            value = value * 10 + d
        }
        return value
    }
    guard let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
          let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2) else { return nil }
    var fraction = 0.0
    if u[19] == 46 {
        var scale = 0.1
        var k = 20
        while k < u.count, u[k] >= 48, u[k] <= 57 {
            fraction += Double(u[k] - 48) * scale
            scale /= 10
            k += 1
        }
    }
    // days since 1970 from a civil date
    let y = month <= 2 ? year - 1 : year
    let era = (y >= 0 ? y : y - 399) / 400
    let yearOfEra = y - era * 400
    let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    let days = era * 146097 + dayOfEra - 719468
    return (Double(days * 86400 + hour * 3600 + minute * 60 + second) + fraction) * 1000
}

private func projectName(_ cwd: String) -> String {
    // Worktrees live under <repo>/.claude/worktrees/<name>; report the repo.
    var dir = cwd
    if let range = cwd.range(of: "/.claude/worktrees/") { dir = String(cwd[..<range.lowerBound]) }
    let trimmed = dir.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    let name = (trimmed as NSString).lastPathComponent
    return name.isEmpty ? dir : name
}

final class Tracker {
    let root: String
    let storePath: String
    private(set) var files: [String: LogFile] = [:]
    private(set) var lastCallMs = 0.0
    private(set) var lastPromptMs = 0.0
    private var signals: [LogSignal] = []
    private var dirty = false
    private var lastWalk = 0.0
    private let lock = NSLock()
    private var progress: (phase: String, done: Int, total: Int) = ("starting", 0, 0)

    /// How far the first read of the logs has got. phase: "starting", "scanning", then "live". Safe from any thread.
    var scan: (phase: String, done: Int, total: Int) {
        get { lock.lock(); defer { lock.unlock() }; return progress }
        set { lock.lock(); progress = newValue; lock.unlock() }
    }

    init(root: String, storePath: String) {
        self.root = root
        self.storePath = storePath
    }

    var foundLogs: Bool { !files.isEmpty }

    /// The prompts you typed in a session (its main log only) between two times, oldest first,
    /// each cut to `each` characters, the last `limit` of them. Read from disk: only used for
    /// AI summaries, which you switch on yourself.
    func prompts(session id: String, from: Double, to: Double, limit: Int = 12, each: Int = 200) -> [String] {
        var found: [(ms: Double, text: String)] = []
        for file in files.values where file.session == id && !file.side {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: file.path), options: .alwaysMapped) else { continue }
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                var start = 0
                while start < raw.count, let newline = memchr(base + start, 10, raw.count - start) {
                    let end = base.distance(to: UnsafeRawPointer(newline))
                    let line = base + start, length = end - start
                    if length > 20, has(needleUser, line, length), !has(needleToolResult, line, length) {
                        let slice = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: line), count: length, deallocator: .none)
                        if let object = (try? JSONSerialization.jsonObject(with: slice)) as? [String: Any],
                           let stamp = object["timestamp"] as? String, let ms = milliseconds(stamp), ms >= from, ms <= to,
                           let text = promptText(object) {
                            let typed = shortened(typedOnly(text), each)
                            if !typed.isEmpty { found.append((ms, typed)) }
                        }
                    }
                    start = end + 1
                }
            }
        }
        return found.sorted { $0.ms < $1.ms }.suffix(limit).map { $0.text }
    }

    /// When Claude started waiting for your answer to a question or a plan (the oldest one still
    /// open), or 0. Questions older than `within` are taken as forgotten.
    func pendingAsk(now: Double, within: Double = 20 * 60_000) -> Double {
        var oldest = 0.0
        for file in files.values where !file.gone {
            for ask in file.asks.values where now - ask.ms < within && ask.ms <= now {
                if oldest == 0 || ask.ms < oldest { oldest = ask.ms }
            }
        }
        return oldest
    }

    /// What happened in live logs since the last call.
    func takeSignals() -> [LogSignal] {
        defer { signals = [] }
        return signals
    }

    /// One session as a whole, its main log and its subagents' together, over the last `hours`
    /// (and after minute `since`, when given).
    func session(_ id: String, now: Double, hours: Double = 12, since: Int = 0) -> SessionInfo? {
        let cutoff = max(since + 1, Int((now - hours * 3_600_000) / 60000))
        var info = SessionInfo(id: id)
        var active = Set<Int>()
        var found = false
        for file in files.values where file.session == id {
            found = true
            if !file.side || info.project.isEmpty {
                if !file.project.isEmpty { info.project = file.project }
                if !file.title.isEmpty { info.title = file.title }
                if !file.branch.isEmpty { info.branch = file.branch }
            }
            info.edited.formUnion(file.edited)
            info.lastPrompt = max(info.lastPrompt, file.lastPrompt)
            for (minute, bucket) in file.minutes where minute >= cutoff && bucket[F.calls] + bucket[F.prompts] > 0 { active.insert(minute) }
        }
        guard found else { return nil }
        info.activeMinutes = active.count
        info.firstMinute = active.min() ?? 0
        info.lastMinute = active.max() ?? 0
        return info
    }

    /// Where a session was started: Claude Code's entry point ("claude-vscode", "cli", ...) and the
    /// folder it was opened in, a worktree reported as its repo. Read from the head of its main log
    /// only when asked (a click on Go to it), so a log restored from the store needs no new field.
    func origin(_ id: String) -> (entry: String, cwd: String)? {
        guard !id.isEmpty,
              let file = files.values.filter({ $0.session == id && !$0.side && !$0.gone }).max(by: { $0.modified < $1.modified }),
              let handle = FileHandle(forReadingAtPath: file.path) else { return nil }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 1 << 20)
        for line in head.split(separator: 10) where line.count > 20 {
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  var cwd = object["cwd"] as? String, !cwd.isEmpty else { continue }
            if let range = cwd.range(of: "/.claude/worktrees/") { cwd = String(cwd[..<range.lowerBound]) }
            return (object["entrypoint"] as? String ?? "", cwd)
        }
        return nil
    }

    // MARK: Parsing

    private func bump(_ file: LogFile, _ minute: Int, _ field: Int, _ value: Double) {
        if value == 0 { return }
        file.minutes[minute, default: [Double](repeating: 0, count: F.count)][field] += value
    }

    private func assistant(_ file: LogFile, _ object: [String: Any], _ ms: Double, live: Bool) -> Double {
        guard let message = object["message"] as? [String: Any], let usage = message["usage"] as? [String: Any] else { return 0 }
        let model = message["model"] as? String ?? ""
        if model == "<synthetic>" { return 0 }
        let minute = Int((ms / 60000).rounded(.down))

        // Claude Code writes one line per content block, so block stats are per line...
        var tools = 0.0
        var lines = 0.0
        if let content = message["content"] as? [[String: Any]] {
            for block in content where block["type"] as? String == "tool_use" {
                tools += 1
                let name = block["name"] as? String ?? ""
                let input = block["input"] as? [String: Any] ?? [:]
                if askTools.contains(name), let id = block["id"] as? String {
                    file.asks[id] = (name, ms)
                    if live { signals.append(.ask(session: file.session, tool: name, ms: ms)) }
                }
                if name == "Bash", input["run_in_background"] as? Bool != true,
                   let id = block["id"] as? String, let command = input["command"] as? String {
                    let kind = classify(command)
                    let git = gitAction(command)
                    // Live, every run is news for the robot; in history only the ones that can be wins matter.
                    if live || kind != nil || git != nil {
                        file.runs[id] = PendingRun(command: command, ms: ms, family: kind?.family, core: kind?.core ?? "", git: git)
                    }
                    if live { signals.append(.run(session: file.session, id: id, command: command, ms: ms)) }
                }
                guard writeTools.contains(name) else { continue }
                if live { signals.append(.edit(session: file.session, ms: ms)) }
                if let target = (input["file_path"] ?? input["notebook_path"]) as? String, file.edited.count < 500 { file.edited.insert(target) }
                lines += lineCount(input["new_string"] ?? input["content"] ?? input["new_source"])
                if let edits = input["edits"] as? [[String: Any]] { for edit in edits { lines += lineCount(edit["new_string"]) } }
            }
        }
        bump(file, minute, F.tools, tools)
        bump(file, minute, F.lines, lines)

        // ...but every line of one response repeats that response's usage. Count
        // each response once, and top it up if a later line reports more.
        let id = [message["id"], object["requestId"], object["uuid"]].compactMap { $0 as? String }.first { !$0.isEmpty } ?? ""
        var now = [
            Double(minute), number(usage["input_tokens"]), number(usage["output_tokens"]),
            number(usage["cache_creation_input_tokens"]), number(usage["cache_read_input_tokens"]),
            number((usage["output_tokens_details"] as? [String: Any])?["thinking_tokens"]),
        ]
        let before = file.seen[id]
        if let before, now[2] <= before[2], now[1] + now[2] + now[3] + now[4] <= before[1] + before[2] + before[3] + before[4] { return 0 }

        let at = before.map { Int($0[0]) } ?? minute
        func delta(_ i: Int) -> Double { now[i] - (before?[i] ?? 0) }
        bump(file, at, F.input, delta(1))
        bump(file, at, F.output, delta(2))
        bump(file, at, F.cacheWrite, delta(3))
        bump(file, at, F.cacheRead, delta(4))
        bump(file, at, F.thinking, delta(5))
        let lower = model.lowercased()
        let family = lower.contains("fable") || lower.contains("mythos") ? 0 : lower.contains("opus") ? 1 : lower.contains("sonnet") ? 2 : lower.contains("haiku") ? 3 : 4
        bump(file, at, F.family + family, delta(1) + delta(2) + delta(3) + delta(4))
        if before == nil { bump(file, at, F.calls, 1) }
        now[0] = Double(at)
        file.seen[id] = now
        return ms
    }

    /// A prompt you sent. Returns its time, or 0 when the line is something else. Stopping Claude
    /// is you at work too, but not a prompt.
    private func user(_ file: LogFile, _ object: [String: Any], _ ms: Double, live: Bool) -> Double {
        guard let text = promptText(object) else { return 0 }
        let minute = Int((ms / 60000).rounded(.down))
        if isInterrupt(text) {
            bump(file, minute, F.hands, 1)
            if live { signals.append(.decision(session: file.session, kind: .interrupt, ms: ms)) }
            return 0
        }
        let measured = measurePrompt(text)
        if measured.typed == 0, measured.pasted == 0 { return 0 }
        bump(file, minute, F.prompts, 1)
        bump(file, minute, F.chars, Double(measured.typed))
        bump(file, minute, F.pasted, Double(measured.pasted))
        if live { signals.append(.prompt(session: file.session, ms: ms, text: String(typedOnly(text).prefix(500)))) }
        return ms
    }

    /// Your answers that are not prompts: to a question, to a plan, to a permission prompt.
    /// The minutes you spent reading before answering count as hands-on.
    private func decisions(_ file: LogFile, _ object: [String: Any], _ ms: Double, live: Bool) {
        guard let blocks = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return }
        let minute = Int((ms / 60000).rounded(.down))
        var answered = false
        for block in blocks where block["type"] as? String == "tool_result" {
            guard let id = block["tool_use_id"] as? String, let ask = file.asks.removeValue(forKey: id) else { continue }
            var text = block["content"] as? String ?? ""
            if let parts = block["content"] as? [[String: Any]] { text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n") }
            let result = object["toolUseResult"] as? [String: Any]
            var kind: Decision
            var typed = 0
            if text.hasPrefix("The user doesn't want to proceed") || text.hasPrefix("User rejected tool use") {
                kind = .reject
                // Turning a plan down with a note: the note is typed.
                if let said = text.range(of: "the user said:") { typed = text[said.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).utf16.count }
            } else if ask.tool == "ExitPlanMode", result?["plan"] != nil || text.hasPrefix("User has approved your plan") {
                kind = .approve
            } else if ask.tool == "AskUserQuestion", let answers = result?["answers"] as? [String: Any] {
                kind = .answer
                // An answer that is none of the offered options was typed ("Other").
                var offered = Set<String>()
                for question in result?["questions"] as? [[String: Any]] ?? [] {
                    for option in question["options"] as? [[String: Any]] ?? [] { if let label = option["label"] as? String { offered.insert(label) } }
                }
                for case let answer as String in answers.values {
                    for part in answer.components(separatedBy: ", ") where !offered.contains(part) { typed += part.utf16.count }
                }
            } else {
                continue                    // it failed or was cut off: not you
            }
            answered = true
            let asked = Int((ask.ms / 60000).rounded(.down))
            let from = minute - asked <= readingWait ? asked : minute - 2
            for m in min(minute, max(from, minute - readingWait))...minute { bump(file, m, F.hands, 1) }
            if typed > 0 { bump(file, minute, F.chars, Double(typed)) }
            if kind == .approve { bump(file, minute, F.plans, 1) }
            if live { signals.append(.decision(session: file.session, kind: kind, ms: ms)) }
        }
        // A permission prompt you answered yourself (not a rule, not the classifier).
        if !answered, let decision = object["permissionDecision"] as? [String: Any],
           (decision["source"] as? String ?? "").hasPrefix("user") {
            bump(file, minute, F.hands, 1)
            if live { signals.append(.decision(session: file.session, kind: .permission, ms: ms)) }
        }
    }

    /// The results of Bash runs this log is waiting for.
    private func results(_ file: LogFile, _ object: [String: Any], _ ms: Double, live: Bool) {
        guard let blocks = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return }
        for block in blocks where block["type"] as? String == "tool_result" {
            guard let id = block["tool_use_id"] as? String, let run = file.runs.removeValue(forKey: id) else { continue }
            var text = ""
            if let whole = block["content"] as? String { text = whole }
            else if let parts = block["content"] as? [[String: Any]] { text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n") }
            var output = text
            var interrupted = false
            if let result = object["toolUseResult"] as? [String: Any] {
                output = [result["stdout"] as? String ?? "", result["stderr"] as? String ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
                interrupted = result["interrupted"] as? Bool ?? false
            }
            let head = String(text.prefix(40))
            let code = exitCode.firstMatch(in: head, range: NSRange(location: 0, length: (head as NSString).length))
                .flatMap { Int((head as NSString).substring(with: $0.range(at: 1))) }
            let denied = object["toolDenialKind"] != nil || head.hasPrefix("Permission ") || head.hasPrefix("The user doesn't want")
            let outcome = RunResult(error: block["is_error"] as? Bool ?? false, exit: code, denied: denied, interrupted: interrupted,
                                    output: String(output.suffix(2000)))
            // Wins, counted the same way the robot cheers them.
            if run.family != nil || run.git != nil {
                let minute = Int((ms / 60000).rounded(.down))
                let result = verdict(run.command, outcome)
                if let git = run.git, result != .fail, !outcome.error, !outcome.denied {
                    // Claude commits often and in small steps: a session that ships counts once a day.
                    if git != "commit" { bump(file, minute, F.prs, 1) }
                    else if minute / 1440 != file.shippedDay { file.shippedDay = minute / 1440; bump(file, minute, F.commits, 1) }
                }
                if let family = run.family, case .green = file.ledger.record(family, core: run.core, verdict: result, ms: ms) {
                    bump(file, minute, F.greens, 1)
                }
            }
            if live { signals.append(.result(session: file.session, id: id, command: run.command, outcome: outcome, ms: ms)) }
        }
    }

    /// Reads whatever was appended to a log since the last look. Touches only that log, so logs can be read in parallel.
    /// Returns the newest response and prompt times it saw.
    /// `live`: this is news, not history, so it also becomes signals for the robot.
    @discardableResult
    private func read(_ file: LogFile, size: Int, modified: Double, live: Bool = false) -> (changed: Bool, call: Double, prompt: Double) {
        if size < file.offset {                         // truncated or replaced: start over
            file.minutes = [:]
            file.seen = [:]
            file.runs = [:]
            file.asks = [:]
            file.ledger = RunLedger()
            file.shippedDay = -1
            file.offset = 0
        }
        file.modified = modified
        file.gone = false
        guard size > file.offset,
              let data = try? Data(contentsOf: URL(fileURLWithPath: file.path), options: .alwaysMapped), data.count > file.offset else {
            return (false, 0, 0)
        }
        var call = 0.0
        var prompt = 0.0
        let from = file.offset
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let total = raw.count
            var start = from
            while start < total, let newline = memchr(base + start, 10, total - start) {
                let end = base.distance(to: UnsafeRawPointer(newline))
                let length = end - start
                if length > 20 {
                    let line = base + start
                    // Cheap byte-level filter first: most lines are tool output and bookkeeping.
                    // Tool output is only opened when a run or a question is waiting for it, or when
                    // it carries a permission you gave.
                    let isAssistant = has(needleAssistant, line, length)
                    let isUser = !isAssistant && has(needleUser, line, length)
                    let isResult = isUser && has(needleToolResult, line, length)
                    let isTitle = !isAssistant && !isUser && length < 4000 && has(needleTitle, line, length)
                    let wanted = isResult && (!file.runs.isEmpty || !file.asks.isEmpty || has(needleYours, line, length))
                    if isAssistant || (isUser && (!isResult || wanted)) || isTitle {
                        let slice = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: line), count: length, deallocator: .none)
                        let object = (try? JSONSerialization.jsonObject(with: slice)) as? [String: Any] ?? [:]
                        if let id = object["sessionId"] as? String, !id.isEmpty { file.session = id }
                        if isTitle {
                            if let named = object["customTitle"] as? String, !named.isEmpty {
                                file.title = named
                                file.renamed = true
                            } else if let named = object["aiTitle"] as? String, !named.isEmpty, !file.renamed {
                                file.title = named
                            }
                        } else if let stamp = object["timestamp"] as? String, let ms = milliseconds(stamp) {
                            if file.project.isEmpty, let cwd = object["cwd"] as? String { file.project = projectName(cwd) }
                            if let branch = object["gitBranch"] as? String, !branch.isEmpty { file.branch = branch }
                            switch object["type"] as? String {
                            case "assistant":
                                call = max(call, assistant(file, object, ms, live: live))
                            case "user" where isResult:
                                results(file, object, ms, live: live)
                                decisions(file, object, ms, live: live)
                            case "user":
                                let typed = user(file, object, ms, live: live)
                                prompt = max(prompt, typed)
                                if typed > 0 { file.lastPrompt = max(file.lastPrompt, typed) }
                            default: break
                            }
                            if live { signals.append(.line(session: file.session, agent: file.agent, assistant: isAssistant, ms: ms)) }
                        }
                    }
                }
                start = end + 1
            }
            // A trailing partial line is still being written; pick it up next time.
            file.offset = start
        }
        // A log that has been quiet for two weeks will not repeat a response id.
        if Date().timeIntervalSince1970 - modified > 14 * 86400 { file.seen = [:] }
        return (file.offset != from, call, prompt)
    }

    // MARK: Discovery

    private func walk() -> [(path: String, size: Int, modified: Double)] {
        var found: [(String, Int, Double)] = []
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys) else { return [] }
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            found.append((url.path, values.fileSize ?? 0, values.contentModificationDate?.timeIntervalSince1970 ?? 0))
        }
        return found
    }

    private func note(_ result: (changed: Bool, call: Double, prompt: Double)) {
        if result.call > lastCallMs { lastCallMs = result.call }
        if result.prompt > lastPromptMs { lastPromptMs = result.prompt }
        if result.changed { dirty = true }
    }

    /// First pass over everything on disk. `progress` is called now and then, and once more after the
    /// logs from the last day are in, so today can be shown while the rest is still being read.
    func scanAll(progress: (() -> Void)? = nil) {
        let found = walk().sorted { $0.modified > $1.modified }
        var done = 0
        scan = ("scanning", 0, found.count)
        var onDisk = Set<String>()
        var pending: [(file: LogFile, size: Int, modified: Double)] = []
        for entry in found {
            onDisk.insert(entry.path)
            let file = files[entry.path] ?? LogFile(path: entry.path)
            files[entry.path] = file
            if entry.size != file.offset || file.gone { pending.append((file, entry.size, entry.modified)) } else { file.modified = entry.modified }
        }
        done = found.count - pending.count
        scan = ("scanning", done, found.count)

        // Today first, one at a time, so the screens have something right away.
        let recent = Date().timeIntervalSince1970 - 86400
        let first = pending.filter { $0.modified >= recent }
        for entry in first {
            note(read(entry.file, size: entry.size, modified: entry.modified))
            done += 1
        }
        scan = ("scanning", done, found.count)
        progress?()

        // Then the history, on every core. Each log only touches itself.
        let rest = pending.filter { $0.modified < recent }
        var results = [(changed: Bool, call: Double, prompt: Double)](repeating: (false, 0, 0), count: rest.count)
        results.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: rest.count) { i in
                buffer[i] = self.read(rest[i].file, size: rest[i].size, modified: rest[i].modified)
                self.lock.lock()
                self.progress.done += 1
                self.lock.unlock()
            }
        }
        for result in results { note(result) }

        // Logs Claude Code has since deleted stay in history.
        for file in files.values where !onDisk.contains(file.path) { file.gone = true }
        lastWalk = Date().timeIntervalSince1970
        scan = ("live", found.count, found.count)
    }

    /// Cheap periodic check: tail recently active logs, rediscover now and then. Returns whether anything changed.
    /// What it reads is news, so it also becomes signals (see takeSignals).
    @discardableResult
    func poll(walkNow: Bool = false) -> Bool {
        guard scan.phase == "live" else { return false }
        let now = Date().timeIntervalSince1970
        var changed = false
        if walkNow || now - lastWalk > 20 {
            lastWalk = now
            for entry in walk() {
                let file = files[entry.path] ?? LogFile(path: entry.path)
                files[entry.path] = file
                if entry.size != file.offset || file.gone {
                    let result = read(file, size: entry.size, modified: entry.modified, live: true)
                    note(result)
                    changed = changed || result.changed
                }
            }
        } else {
            for file in files.values where !file.gone && now - file.modified < 6 * 3600 {
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                      let size = (attributes[.size] as? NSNumber)?.intValue else {
                    file.gone = true
                    continue
                }
                if size != file.offset {
                    let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? now
                    let result = read(file, size: size, modified: modified, live: true)
                    note(result)
                    changed = changed || result.changed
                }
            }
        }
        return changed
    }

    // MARK: Persistence

    /// Restores history from the last run, so start-up does not re-read every log and deleted logs are not forgotten.
    @discardableResult
    func load() -> Bool {
        guard let data = FileManager.default.contents(atPath: storePath),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = raw["version"] as? Int, (4...6).contains(version), (raw["root"] as? String) == root,
              let saved = raw["files"] as? [[String: Any]] else { return false }
        // Before version 6 (Burnbot 1.2) answers, plans and wins were not counted. Every log still on
        // disk is read again from the start, once, to count them; deleted logs keep what they had.
        for entry in saved {
            guard let path = entry["p"] as? String else { continue }
            let file = LogFile(path: path)
            file.offset = (entry["o"] as? NSNumber)?.intValue ?? 0
            file.modified = number(entry["t"]) / 1000
            file.project = entry["j"] as? String ?? ""
            if let session = entry["s"] as? String, !session.isEmpty { file.session = session }
            file.title = entry["n"] as? String ?? ""
            file.renamed = entry["r"] as? Bool ?? false
            file.branch = entry["b"] as? String ?? ""
            file.edited = Set(entry["e"] as? [String] ?? [])
            file.lastPrompt = number(entry["lp"])
            if version < 6, FileManager.default.fileExists(atPath: path) {
                file.offset = 0
                files[path] = file
                continue
            }
            for row in entry["m"] as? [[NSNumber]] ?? [] where row.count == F.count + 1 || row.count == oldCount + 1 {
                file.minutes[row[0].intValue] = row.dropFirst().map { $0.doubleValue } + [Double](repeating: 0, count: F.count + 1 - row.count)
            }
            for row in entry["a"] as? [[Any]] ?? [] where row.count == 3 {
                if let id = row[0] as? String, let tool = row[1] as? String { file.asks[id] = (tool, number(row[2])) }
            }
            if let day = entry["sd"] as? Int { file.shippedDay = day }
            for row in entry["i"] as? [[Any]] ?? [] {
                guard let id = row.first as? String else { continue }
                file.seen[id] = row.dropFirst().map { number($0) }
            }
            files[path] = file
        }
        lastCallMs = number(raw["lastCallMs"])
        lastPromptMs = number(raw["lastPromptMs"])
        return true
    }

    func save(force: Bool = false) {
        guard dirty || force else { return }
        var saved: [[String: Any]] = []
        for file in files.values where !file.minutes.isEmpty || file.offset > 0 {
            var entry: [String: Any] = [
                "p": file.path, "o": file.offset, "t": file.modified * 1000, "j": file.project,
                "m": file.minutes.map { [Double($0.key)] + $0.value },
            ]
            if !file.seen.isEmpty { entry["i"] = file.seen.map { [$0.key as Any] + $0.value.map { $0 as Any } } }
            entry["s"] = file.session
            if !file.title.isEmpty { entry["n"] = file.title }
            if file.renamed { entry["r"] = true }
            if !file.branch.isEmpty { entry["b"] = file.branch }
            if file.lastPrompt > 0 { entry["lp"] = file.lastPrompt }
            if !file.asks.isEmpty { entry["a"] = file.asks.map { [$0.key, $0.value.tool, $0.value.ms] as [Any] } }
            if file.shippedDay >= 0 { entry["sd"] = file.shippedDay }
            // Which files a session touched only matters while it might still be recapped.
            if !file.edited.isEmpty, Date().timeIntervalSince1970 - file.modified < 2 * 86400 { entry["e"] = Array(file.edited) }
            saved.append(entry)
        }
        let body: [String: Any] = [
            "version": 6, "root": root, "savedAt": Date().timeIntervalSince1970 * 1000,
            "lastCallMs": lastCallMs, "lastPromptMs": lastPromptMs, "files": saved,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        try? FileManager.default.createDirectory(atPath: (storePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard (try? data.write(to: URL(fileURLWithPath: storePath), options: .atomic)) != nil else { return }
        dirty = false
    }
}
