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
    static let count = 16
}

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

    init(path: String) {
        self.path = path
        side = path.contains("/subagents/")
    }
}

private func bytes(_ text: String) -> UnsafeRawBufferPointer {
    let copy = UnsafeMutableRawBufferPointer.allocate(byteCount: text.utf8.count, alignment: 1)
    copy.copyBytes(from: Array(text.utf8))
    return UnsafeRawBufferPointer(copy)
}
private let needleAssistant = bytes("\"type\":\"assistant\"")
private let needleUser = bytes("\"type\":\"user\"")
private let needleToolResult = bytes("\"tool_use_id\"")

private func has(_ needle: UnsafeRawBufferPointer, _ line: UnsafeRawPointer, _ length: Int) -> Bool {
    memmem(line, length, needle.baseAddress, needle.count) != nil
}

private let writeTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

// Wrappers the harness injects into user turns. None of it was typed by the person.
private let injected = try! NSRegularExpression(
    pattern: "<(system-reminder|artifact-view-context|artifact-content-authored-by-others|local-command-stdout|local-command-stderr|"
        + "local-command-caveat|bash-stdout|bash-stderr|task-notification|fork-boilerplate|command-message|command-args|"
        + "user-prompt-submit-hook)\\b[^>]*>[\\s\\S]*?</\\1>")
private let pastedBlock = try! NSRegularExpression(pattern: "<pasted_content\\b[^>]*>([\\s\\S]*?)</pasted_content[^>]*>")
private let keptTags = try! NSRegularExpression(pattern: "</?(bash-input|command-name)>")

/// Splits a user turn into what was typed and what was pasted (lengths as JavaScript counts them).
func measurePrompt(_ text: String) -> (typed: Int, pasted: Int) {
    let whole = NSRange(location: 0, length: (text as NSString).length)
    var pasted = 0
    for match in pastedBlock.matches(in: text, range: whole) { pasted += match.range(at: 1).length }
    var rest = pastedBlock.stringByReplacingMatches(in: text, range: whole, withTemplate: "")
    rest = injected.stringByReplacingMatches(in: rest, range: NSRange(location: 0, length: (rest as NSString).length), withTemplate: "")
    rest = keptTags.stringByReplacingMatches(in: rest, range: NSRange(location: 0, length: (rest as NSString).length), withTemplate: "")
    return (rest.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count, pasted)
}

private func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }

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

    // MARK: Parsing

    private func bump(_ file: LogFile, _ minute: Int, _ field: Int, _ value: Double) {
        if value == 0 { return }
        file.minutes[minute, default: [Double](repeating: 0, count: F.count)][field] += value
    }

    private func assistant(_ file: LogFile, _ object: [String: Any], _ ms: Double) -> Double {
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
                guard let name = block["name"] as? String, writeTools.contains(name), let input = block["input"] as? [String: Any] else { continue }
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

    private func user(_ file: LogFile, _ object: [String: Any], _ ms: Double) -> Double {
        for flag in ["isSidechain", "isMeta", "isCompactSummary", "isVisibleInTranscriptOnly"] where (object[flag] as? Bool) == true { return 0 }
        if object["toolUseResult"] != nil { return 0 }
        var kind = (object["origin"] as? [String: Any])?["kind"] as? String ?? ""
        if kind.isEmpty { kind = object["turnOrigin"] as? String ?? "" }
        if !kind.isEmpty, kind != "human" { return 0 }
        let content = (object["message"] as? [String: Any])?["content"]
        var text = ""
        if let whole = content as? String {
            text = whole
        } else if let blocks = content as? [[String: Any]] {
            for block in blocks {
                let type = block["type"] as? String
                if type == "tool_result" { return 0 }
                if type == "text" { text += (block["text"] as? String ?? "") + "\n" }
            }
        } else {
            return 0
        }
        let measured = measurePrompt(text)
        if measured.typed == 0, measured.pasted == 0 { return 0 }
        let minute = Int((ms / 60000).rounded(.down))
        bump(file, minute, F.prompts, 1)
        bump(file, minute, F.chars, Double(measured.typed))
        bump(file, minute, F.pasted, Double(measured.pasted))
        return ms
    }

    /// Reads whatever was appended to a log since the last look. Touches only that log, so logs can be read in parallel.
    /// Returns the newest response and prompt times it saw.
    @discardableResult
    private func read(_ file: LogFile, size: Int, modified: Double) -> (changed: Bool, call: Double, prompt: Double) {
        if size < file.offset {                         // truncated or replaced: start over
            file.minutes = [:]
            file.seen = [:]
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
                    let isAssistant = has(needleAssistant, line, length)
                    if isAssistant || (has(needleUser, line, length) && !has(needleToolResult, line, length)) {
                        let slice = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: line), count: length, deallocator: .none)
                        if let object = (try? JSONSerialization.jsonObject(with: slice)) as? [String: Any],
                           let stamp = object["timestamp"] as? String, let ms = milliseconds(stamp) {
                            if file.project.isEmpty, let cwd = object["cwd"] as? String { file.project = projectName(cwd) }
                            switch object["type"] as? String {
                            case "assistant": call = max(call, assistant(file, object, ms))
                            case "user": prompt = max(prompt, user(file, object, ms))
                            default: break
                            }
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
    @discardableResult
    func poll() -> Bool {
        guard scan.phase == "live" else { return false }
        let now = Date().timeIntervalSince1970
        var changed = false
        if now - lastWalk > 20 {
            lastWalk = now
            for entry in walk() {
                let file = files[entry.path] ?? LogFile(path: entry.path)
                files[entry.path] = file
                if entry.size != file.offset || file.gone {
                    let result = read(file, size: entry.size, modified: entry.modified)
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
                    let result = read(file, size: size, modified: modified)
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
              (raw["version"] as? Int) == 4, (raw["root"] as? String) == root,
              let saved = raw["files"] as? [[String: Any]] else { return false }
        for entry in saved {
            guard let path = entry["p"] as? String else { continue }
            let file = LogFile(path: path)
            file.offset = (entry["o"] as? NSNumber)?.intValue ?? 0
            file.modified = number(entry["t"]) / 1000
            file.project = entry["j"] as? String ?? ""
            for row in entry["m"] as? [[NSNumber]] ?? [] where row.count == F.count + 1 {
                file.minutes[row[0].intValue] = row.dropFirst().map { $0.doubleValue }
            }
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
            saved.append(entry)
        }
        let body: [String: Any] = [
            "version": 4, "root": root, "savedAt": Date().timeIntervalSince1970 * 1000,
            "lastCallMs": lastCallMs, "lastPromptMs": lastPromptMs, "files": saved,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        try? FileManager.default.createDirectory(atPath: (storePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard (try? data.write(to: URL(fileURLWithPath: storePath), options: .atomic)) != nil else { return }
        dirty = false
    }
}
