// What Burnbot remembers about your sessions, and the optional AI summary of each.
//
// Memory: Application Support/Burnbot/sessions.json keeps the last 50 sessions, the local recap
// of each (title, time, files edited, wins, commits). It feeds "Last time: ..." on the robot.
//
// AI summaries are off until you switch them on. Then, when a session ends, Burnbot runs your
// own `claude` once: `claude -p` with no tools, no settings (so no hooks, and no other Claude
// setup runs), no saved session (so it leaves no log and does not count in your totals), a small
// model, a spending cap, and a JSON schema the answer has to match. It sends the session's title,
// project and branch, the prompts you typed (cut short), file names and what came of the runs:
// never file contents. At most 20 a day; 60 s at most each; anything that does not fit the schema
// is thrown away and the local recap stands.

import Foundation

final class Memory {
    private let path: String
    private(set) var sessions: [[String: Any]] = []
    private var runs: [String: Int] = [:]         // "yyyy-MM-dd" -> AI summaries run that day
    let keep = 50

    init(dataFolder: String) {
        path = dataFolder + "/sessions.json"
        if let data = FileManager.default.contents(atPath: path),
           let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            sessions = raw["sessions"] as? [[String: Any]] ?? []
            runs = raw["summaryRuns"] as? [String: Int] ?? [:]
        }
    }

    func add(_ recap: SessionRecap) {
        // A session can be recapped more than once (you came back to it): one entry each time,
        // so "last time" is always the latest stretch.
        sessions.append([
            "id": recap.id, "project": recap.project, "title": recap.title, "branch": recap.branch,
            "start": recap.start, "end": recap.end, "minutes": recap.minutes, "edited": recap.edited,
            "wins": recap.wins, "commits": recap.commits, "pr": recap.pr, "red": recap.red,
        ])
        sessions = Array(sessions.suffix(keep))
        save()
    }

    func attach(id: String, end: Double, done: [String], next: String) {
        guard let index = sessions.lastIndex(where: { $0["id"] as? String == id && number($0["end"]) == end }) else { return }
        sessions[index]["summary"] = ["done": done, "next": next]
        save()
    }

    /// The last session, for "Last time: ..." when nothing is going on. Only for the next 18 hours.
    func last(now: Double) -> (title: String, next: String, red: [String])? {
        guard let entry = sessions.last, now - number(entry["end"]) < 18 * 3_600_000 else { return nil }
        let title = (entry["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? entry["project"] as? String ?? ""
        guard !title.isEmpty else { return nil }
        let next = (entry["summary"] as? [String: Any])?["next"] as? String ?? ""
        return (title, next, entry["red"] as? [String] ?? [])
    }

    /// Takes one of today's summary runs, or says there are none left.
    func takeRun(now: Double, limit: Int) -> Bool {
        let day = Memory.day(now)
        guard runs[day, default: 0] < limit else { return false }
        runs = [day: runs[day, default: 0] + 1]     // only today's count is worth keeping
        save()
        return true
    }

    private static func day(_ ms: Double) -> String {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd"
        return format.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    private func save() {
        let whole: [String: Any] = ["version": 1, "sessions": sessions, "summaryRuns": runs]
        guard let data = try? JSONSerialization.data(withJSONObject: whole, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

/// Runs `claude -p` for a session summary. Everything here happens off the engine's queue;
/// `done` is called back on the queue given.
final class Summaries {
    let perDay = 20
    let timeout = 60.0
    let budget = "0.10"         // the CLI's own extra calls cost about $0.04 a summary
    let model = "haiku"
    var log: (String) -> Void = { _ in }

    private var found: (path: String, flags: Set<String>)??     // looked up once: nil inside = not installed
    private let work = DispatchQueue(label: "burnbot.summaries", qos: .utility)

    static let schema = """
    {"type":"object","properties":{"done":{"type":"array","items":{"type":"string","maxLength":80},"maxItems":3},"next":{"type":"string","maxLength":80}},"required":["done","next"],"additionalProperties":false}
    """

    /// What is sent: the session as you would describe it to a colleague, never file contents.
    static func prompt(_ recap: SessionRecap, prompts: [String]) -> String {
        var lines = ["Session: \"\(recap.title.isEmpty ? recap.project : recap.title)\" in project \(recap.project)"
                     + (recap.branch.isEmpty ? "" : " (branch \(recap.branch))") + ", \(recap.minutes) min hands-on."]
        if !prompts.isEmpty { lines.append("What I typed:"); lines += prompts.map { "- \($0)" } }
        if !recap.edited.isEmpty { lines.append("Files edited: " + recap.edited.prefix(15).joined(separator: ", ")) }
        var results = recap.wins
        if recap.commits > 0 { results.append("\(recap.commits) commit\(recap.commits == 1 ? "" : "s")") }
        if recap.pr { results.append("opened a pull request") }
        if !results.isEmpty { lines.append("Results: " + results.joined(separator: "; ")) }
        lines.append("Summarise this coding session for the person who did it: up to 3 short things that got done, "
                     + "and the one next step it points to. Plain words, no more than 8 words each. "
                     + "Only what the notes above support; if the next step is unclear, say what to check.")
        return lines.joined(separator: "\n")
    }

    func run(_ recap: SessionRecap, prompts: [String], then queue: DispatchQueue,
             done: @escaping (_ done: [String], _ next: String) -> Void) {
        let text = Summaries.prompt(recap, prompts: prompts)
        work.async {
            let started = Date()
            guard let output = self.ask(text, schema: Summaries.schema, timeout: self.timeout, what: "AI summary") else { return }
            guard let parsed = Summaries.parse(output) else {
                self.log("AI summary did not match the schema; keeping the local recap")
                return
            }
            self.log(String(format: "AI summary in %.1f s", Date().timeIntervalSince(started)))
            queue.async { done(parsed.done, parsed.next) }
        }
    }

    static let loopSchema = """
    {"type":"object","properties":{"loop":{"type":"boolean"},"why":{"type":"string","maxLength":60}},"required":["loop","why"],"additionalProperties":false}
    """

    static func loopPrompt(_ prompts: [String]) -> String {
        (["My last prompts to a coding agent, oldest first:"] + prompts.map { "- \(shortened($0, 300))" }
         + ["Between them the agent changed no files and no test or build got further. "
            + "Am I going round in circles (the same ask again and again, getting nowhere), "
            + "or is this real iteration (each prompt narrows, adds something new, or changes direction)? "
            + "loop: true only for going round. why: a few plain words."]).joined(separator: "\n")
    }

    /// Going round or real iteration? `answer` gets true, false, or nil when there is no usable answer.
    func judgeLoop(_ prompts: [String], then queue: DispatchQueue, answer: @escaping (Bool?) -> Void) {
        let text = Summaries.loopPrompt(prompts)
        work.async {
            let started = Date()
            var verdict: Bool?
            if let output = self.ask(text, schema: Summaries.loopSchema, timeout: 30, what: "AI loop check"),
               let raw = (try? JSONSerialization.jsonObject(with: output)) as? [String: Any], raw["is_error"] as? Bool != true,
               let structured = raw["structured_output"] as? [String: Any], let loop = structured["loop"] as? Bool {
                verdict = loop
                self.log(String(format: "AI loop check in %.1f s: %@ (%@)", Date().timeIntervalSince(started),
                                loop ? "a loop" : "real iteration", shortened(structured["why"] as? String ?? "", 60)))
            } else {
                self.log("AI loop check gave no usable answer")
            }
            queue.async { answer(verdict) }
        }
    }

    /// One `claude -p` with a JSON schema, on the work queue. nil (and a log line) when it cannot run.
    private func ask(_ text: String, schema: String, timeout: Double, what: String) -> Data? {
        guard let claude = locate() else {
            log("\(what) skipped: no claude command found")
            return nil
        }
        let (path, flags) = (claude.path, claude.flags)
        guard flags.contains("--json-schema"), flags.contains("--no-session-persistence") else {
            log("\(what) skipped: this claude (\(path)) has no --json-schema / --no-session-persistence; update Claude Code")
            return nil
        }
        var args = ["-p", "--no-session-persistence", "--model", model, "--output-format", "json", "--json-schema", schema]
        // Only flags this claude knows: an unknown one fails the whole run.
        if flags.contains("--bare") { args.append("--bare") }
        else if flags.contains("--setting-sources") { args += ["--setting-sources", ""] }
        if flags.contains("--tools") { args += ["--tools", ""] }
        if flags.contains("--max-budget-usd") { args += ["--max-budget-usd", budget] }
        return execute(path, args, input: text, timeout: timeout, what: what)
    }

    /// The answer, if it is what was asked for: up to 3 short strings and a next step.
    static func parse(_ output: Data) -> (done: [String], next: String)? {
        guard let raw = (try? JSONSerialization.jsonObject(with: output)) as? [String: Any],
              raw["is_error"] as? Bool != true,
              let structured = raw["structured_output"] as? [String: Any],
              let done = structured["done"] as? [String], let next = structured["next"] as? String else { return nil }
        let clean = { (text: String) in shortened(text.trimmingCharacters(in: .whitespacesAndNewlines), 80) }
        let items = done.map(clean).filter { !$0.isEmpty }.prefix(3)
        return (Array(items), clean(next))
    }

    private func execute(_ path: String, _ args: [String], input: String, timeout: Double, what: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        // An empty folder of its own, so no project's CLAUDE.md or settings come along.
        let folder = NSTemporaryDirectory() + "burnbot-summary"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ((path as NSString).deletingLastPathComponent) + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        // claude finds its login in the keychain under your user name.
        if environment["USER"] == nil { environment["USER"] = NSUserName() }
        if environment["LOGNAME"] == nil { environment["LOGNAME"] = NSUserName() }
        if environment["HOME"] == nil { environment["HOME"] = NSHomeDirectory() }
        if environment["TMPDIR"] == nil { environment["TMPDIR"] = NSTemporaryDirectory() }
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        var output = Data(), errors = Data()
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global(qos: .utility).async { output = stdout.fileHandleForReading.readDataToEndOfFile(); reading.leave() }
        reading.enter()
        DispatchQueue.global(qos: .utility).async { errors = stderr.fileHandleForReading.readDataToEndOfFile(); reading.leave() }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }     // before run: a quick exit is not missed
        do { try process.run() } catch {
            log("\(what) could not start \(path): \(error.localizedDescription)")
            return nil
        }
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try? stdin.fileHandleForWriting.close()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 3)
            log("\(what) took over \(Int(timeout)) s and was stopped")
            return nil
        }
        reading.wait()
        guard process.terminationStatus == 0 else {
            let reason = String(decoding: errors.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            log("\(what) failed (exit \(process.terminationStatus)): \(reason)")
            return nil
        }
        return output
    }

    /// Where `claude` is, and which flags it has. A Mac app does not get your shell's PATH,
    /// so ask your login shell first, then try the usual places.
    private func locate() -> (path: String, flags: Set<String>)? {
        if let known = found { return known }
        var candidates: [String] = []
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if let answer = capture(shell, ["-lic", "command -v claude"], seconds: 10) {
            candidates += answer.split(separator: "\n").map(String.init).filter { $0.hasPrefix("/") }.reversed()
        }
        let home = NSHomeDirectory()
        candidates += [home + "/.claude/local/claude", home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            let help = capture(path, ["--help"], seconds: 20) ?? ""
            guard help.contains("--print") || help.contains("-p,") else { continue }
            let flags = Set(["--bare", "--json-schema", "--no-session-persistence", "--tools", "--max-budget-usd", "--setting-sources"]
                .filter { help.range(of: $0 + "\\b", options: .regularExpression) != nil })
            log("Found claude at \(path): \(flags.sorted().joined(separator: " "))")
            found = .some((path, flags))
            return (path, flags)
        }
        found = .some(nil)
        return nil
    }

    private func capture(_ path: String, _ args: [String], seconds: Double) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        var data = Data()
        let reading = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async { data = out.fileHandleForReading.readDataToEndOfFile(); reading.signal() }
        guard (try? process.run()) != nil else { return nil }
        if reading.wait(timeout: .now() + seconds) == .timedOut { process.terminate(); return nil }
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
