// What the robot reacts to, and how.
//
//   signals (logs, hooks, where you are)
//     -> detectors   notice something: an Observation, with how sure they are
//     -> decide      given where you are and what is already showing: silence,
//                    a face, a short speech bubble, or a bubble that stays until handled
//     -> queue       one bubble at a time, the most important first, no repeats,
//                    gone when its reason is gone, and few bubbles that are not urgent
//
// Everything here takes the time as an argument and never reads the clock, so a
// recorded session replays the same way every time (--dump-timeline).

import Foundation

// MARK: - Commands Claude runs

enum Family: String { case test, build, typecheck }

enum Verdict: String { case pass, fail, unknown }

private func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
    try! NSRegularExpression(pattern: pattern, options: options)
}

private extension NSRegularExpression {
    func found(in text: String) -> Bool { firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
    func removed(from text: String, with replacement: String = "") -> String {
        stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
    }
}

private let heredoc = regex("<<-?\\s*['\"]?(\\w+)['\"]?[\\s\\S]*?\\n\\s*\\1\\b")
private let quoted = regex("'[^']*'|\"(?:[^\"\\\\]|\\\\.)*\"")
private let separators = regex("&&|\\|\\||;|\\||\\n")
private let envPrefix = regex("^(?:\\s*[A-Za-z_][A-Za-z0-9_]*=\\S*\\s+)+")
// Segments that only look at things: a test command named inside them is not a run.
private let lookers: Set<String> = ["git", "gh", "echo", "printf", "cat", "grep", "rg", "sed", "awk", "ls", "find", "head", "tail",
                                    "wc", "open", "which", "command", "type", "man", "cd", "export", "source", "less", "more", "diff"]
private let testCommand = regex(
    "(?:^|[\\s/(])(?:pytest|py\\.test|jest|vitest|mocha|rspec|phpunit|ctest|tox|nox)(?:\\s|$)" +
    "|(?:^|\\s)(?:npm|pnpm|yarn|bun)\\s+(?:run\\s+)?test(?::\\S+)?(?:\\s|$)" +
    "|\\b(?:cargo\\s+(?:test|nextest)|go\\s+test|swift\\s+test|deno\\s+test|mix\\s+test|dotnet\\s+test|playwright\\s+test" +
    "|python3?\\s+-m\\s+(?:pytest|unittest)|make\\s+(?:test|check)|bundle\\s+exec\\s+rspec|rails\\s+test)\\b" +
    "|\\bxcodebuild\\b.*\\btest\\b|(?:^|\\s)(?:\\./)?(?:gradlew?|mvnw?)\\b.*\\b(?:test|check|verify)\\b")
private let typecheckCommand = regex(
    "(?:^|[\\s/])(?:tsc|vue-tsc|mypy|pyright|basedpyright)(?:\\s|$)" +
    "|(?:^|\\s)(?:npm|pnpm|yarn|bun)\\s+(?:run\\s+)?(?:typecheck|type-check|check-types|types|tsc)(?:\\s|$)|\\bcargo\\s+check\\b")
private let buildCommand = regex(
    "(?:^|\\s)(?:npm|pnpm|yarn|bun)\\s+(?:run\\s+)?build(?::\\S+)?(?:\\s|$)" +
    "|\\b(?:cargo|go|swift|dotnet|bazel)\\s+build\\b|(?:^|[\\s/])(?:swiftc|xcodebuild|ninja|webpack)(?:\\s|$)" +
    "|\\bcmake\\s+--build\\b|\\b(?:next|vite|astro|nuxt)\\s+build\\b|^make(?:\\s+[\\w.=-]+)*$" +
    "|(?:^|\\s)(?:\\./)?gradlew?\\b.*\\b(?:build|assemble)\\b|(?:^|\\s)mvnw?\\b.*\\b(?:package|compile|install)\\b" +
    "|(?:^|[\\s/])build[\\w-]*\\.sh(?:\\s|$)")
private let selector = regex("\\S+\\.(?:py|ts|tsx|js|jsx|mjs|cjs|go|rs|swift|rb|java|kt|php|exs?)\\b|::|\\s-k\\s|\\s-t\\s|--filter|\\s-run\\s|--grep|--testNamePattern|-only-testing|\\btests?/\\S+")
private let noise = regex("\\s(?:2>&1|>\\s*/dev/null|-q|--quiet|-v+|--verbose|-s|--silent|--no-color|--color(?:=\\S+)?)(?=\\s|$)")
private let filterPipe = regex("\\|\\s*(?:tail|head|grep|rg|less|more|cat|tee|sed|awk|cut|sort|uniq|wc|xcpretty|xcbeautify|jq)\\b")
private let pipefail = regex("pipefail")
private let swallowed = regex("\\|\\|\\s*(?:true|:|echo\\b|printf\\b|exit\\s+0)|;\\s*(?:true|:)\\s*$")
private let failMarker = regex(
    "\\b[1-9]\\d*\\s+(?:failed|failing|failures?|errors?)\\b|\\bFAIL(?:ED|URES?)?\\b|[✗✖❌]|(?:^|\\s)error(?:\\[E\\d+\\])?:" +
    "|\\berror TS\\d+|\\bTests? failed\\b|\\bpanicked at\\b|Traceback \\(most recent call last\\)|\\bcommand not found\\b")
private let passMarker = regex(
    "\\b[1-9]\\d*\\s+(?:passed|passing)\\b|\\btests? passed\\b|\\ball tests passed\\b|\\btest result: ok\\b|(?:^|\\n)ok\\s+\\S+\\s+[\\d.]+s" +
    "|(?:^|\\n)OK(?:\\s*\\(|\\s*$)|Executed \\d+ tests?, with 0 failures|Test Suite '.*' passed|\\bBUILD SUCCEEDED\\b|\\bBUILD SUCCESSFUL\\b" +
    "|Build complete!|Compiled successfully|\\bFinished\\b.*\\bin [\\d.]+s|\\bbuilt in [\\d.]+\\s*m?s\\b|Found 0 errors|Success: no issues found",
    [.caseInsensitive, .anchorsMatchLines])

/// The command with heredocs and quoted text taken out, split into the commands it runs.
private func segments(_ command: String) -> [String] {
    let bare = quoted.removed(from: heredoc.removed(from: command), with: "''")
    return separators.removed(from: bare, with: "\u{1}").split(separator: "\u{1}").map {
        envPrefix.removed(from: String($0)).trimmingCharacters(in: .whitespaces)
    }.filter { !$0.isEmpty }
}

/// What kind of run this is, and the part of the command that makes it so.
func classify(_ command: String) -> (family: Family, core: String)? {
    let parts = segments(command).filter { !lookers.contains(String($0.split(separator: " ").first ?? "")) }
    for (family, pattern) in [(Family.test, testCommand), (.typecheck, typecheckCommand), (.build, buildCommand)] {
        if let part = parts.first(where: { pattern.found(in: $0) }) {
            let core = noise.removed(from: " " + part + " ").split(separator: " ").joined(separator: " ")
            return (family, core)
        }
    }
    return nil
}

/// Whether a git commit or a new pull request is what this runs.
func gitAction(_ command: String) -> String? {
    for part in segments(command) {
        if part.hasPrefix("git commit") { return "commit" }
        if part.hasPrefix("gh pr create") { return "pr" }
    }
    return nil
}

/// Did it pass? Only says so with evidence: anything unclear is .unknown, and the robot stays quiet.
func verdict(_ command: String, _ result: RunResult) -> Verdict {
    if result.denied || result.interrupted { return .unknown }
    if let exit = result.exit, exit == 126 || exit == 127 { return .unknown }
    let piped = filterPipe.found(in: command) && !pipefail.found(in: command)
    let swallows = swallowed.found(in: command)
    let failed = failMarker.found(in: result.output)
    let bad = result.error || (result.exit ?? 0) != 0
    if bad { return piped && !failed ? .unknown : .fail }       // a pipe's exit belongs to its last command
    if failed { return piped || swallows ? .fail : .unknown }
    if piped || swallows { return passMarker.found(in: result.output) ? .pass : .unknown }
    return .pass
}

// MARK: - The robot's words

/// Everything the robot says, from public/voice.json: lists of variations, with {blanks} the app fills in.
struct Voice {
    var raw: [String: Any] = [:]

    init(file: URL? = nil) {
        if let file, let data = try? Data(contentsOf: file), let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { self.raw = raw }
    }

    private func node(_ path: [String]) -> Any? {
        var at: Any? = raw
        for key in path { at = (at as? [String: Any])?[key] }
        return at
    }

    /// The text with its blanks filled, or nil when a blank has nothing to go in it.
    static func fill(_ template: String, _ facts: [String: String]) -> String? {
        var out = template
        while let open = out.range(of: "{"), let close = out.range(of: "}", range: open.upperBound..<out.endIndex) {
            let name = String(out[open.upperBound..<close.lowerBound])
            guard let value = facts[name], !value.isEmpty else { return nil }
            out.replaceSubrange(open.lowerBound..<close.upperBound, with: value)
        }
        return out
    }

    static func seed(_ text: String) -> Int {
        var h: UInt32 = 5381
        for byte in text.utf8 { h = (h &* 33) ^ UInt32(byte) }
        return Int(h % 9973)
    }

    /// A speech bubble: a title and up to three lines. The variation is fixed per moment.
    func card(_ path: [String], seed: String, facts: [String: String]) -> (title: String, lines: [String]) {
        let choices = node(path) as? [[String: String]] ?? []
        guard !choices.isEmpty else { return (path.last?.uppercased() ?? "", []) }
        let pick = choices[Voice.seed(seed) % choices.count]
        let title = (pick["t"].flatMap { Voice.fill($0, facts) } ?? "").uppercased()
        let lines = ["a", "b", "c"].compactMap { pick[$0].flatMap { Voice.fill($0, facts) } }
        return (title, lines)
    }

    /// One line of text (the Now line, recap facts).
    func line(_ path: [String], _ facts: [String: String] = [:]) -> String? {
        (node(path) as? String).flatMap { Voice.fill($0, facts) }
    }
}

func minutesText(_ ms: Double) -> String {
    let minutes = max(1, Int((ms / 60000).rounded()))
    return minutes < 60 ? "\(minutes) min" : "\(minutes / 60)h \(minutes % 60)m"
}

private func elapsedText(_ ms: Double) -> String {
    let seconds = max(0, Int(ms / 1000))
    return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
}

private func clock(_ ms: Double) -> String {
    let format = DateFormatter()
    format.dateFormat = "HH:mm:ss"
    return format.string(from: Date(timeIntervalSince1970: ms / 1000))
}

extension LogSignal {
    var ms: Double {
        switch self {
        case let .line(_, _, _, ms), let .prompt(_, ms), let .run(_, _, _, ms), let .result(_, _, _, _, ms): return ms
        }
    }
}

// MARK: - What the robot shows

struct Card: Equatable {
    let id: String
    let kind: String
    let title: String
    let lines: [String]
    let action: String?                     // "focus": clicking brings your work app forward
    let persistent: Bool                    // stays until its reason is gone
}

struct MomentsOutput: Equatable {
    var card: Card?
    var expr = ""                           // "worried", "happy", "waiting" or ""
    var now = ""                            // the Now line

    var json: [String: Any] {
        var out: [String: Any] = ["expr": expr, "now": now]
        if let card {
            out["moment"] = ["id": card.id, "kind": card.kind, "title": card.title, "lines": card.lines,
                             "action": card.action.map { $0 as Any } ?? NSNull(), "persistent": card.persistent] as [String: Any]
        } else {
            out["moment"] = NSNull()
        }
        return out
    }
}

/// A finished session, for the recap and for memory.
struct SessionRecap {
    let id: String
    let project: String
    let title: String
    let branch: String
    let start: Double, end: Double          // ms
    let minutes: Int                        // hands-on
    let edited: [String]
    let wins: [String]
    let commits: Int
    let pr: Bool
}

// MARK: - Detectors, decide, queue

private struct Run {
    let command: String
    let family: Family?
    let core: String
    let git: String?
    var ms: Double                          // when it started (or when the yes it waited for came)
}

private struct Streak {
    var failing: [String: Int] = [:]        // command -> failures
    var total = 0
    var first = 0.0, last = 0.0
}

private final class LiveSession {
    let id: String
    var project = ""
    var lastLine = 0.0
    var lastPrompt = 0.0
    var running: [String: Run] = [:]
    var streaks: [String: Streak] = [:]
    var wins: [String] = []
    var commits = 0
    var pr = false
    var doneMinute = 0                      // the last minute counted in a recap
    var checkedLine = 0.0                   // lastLine when it was last checked for being over
    var ended = 0.0                         // when Claude Code said it ended
    var isOver: Bool { ended > 0 && ended >= lastLine }
    init(id: String) { self.id = id }
}

private enum Kind: String {
    case waiting, yourMove = "your-move", breakthrough, done
    var priority: Int { [.waiting: 4, .breakthrough: 3, .yourMove: 2, .done: 2][self]! }
}

private enum Presentation: Equatable {
    case silence(String)
    case expression(String)
    case bubble(urgent: Bool, exempt: Bool)
}

private struct Observation {
    let kind: Kind
    let session: String
    let key: String
    var at: Double
    var agent = ""
    var facts: [String: String] = [:]
    var path: [String] = []                 // where its words are in voice.json
    var ttl = 0.0                           // how long it shows, once shown
    var deadline = 0.0                      // the latest it may first show
    var untilBack = false                   // keep it until you are back at work, then a little longer
    var backAt: Double?
    var handled = false                     // waiting: you have been back at a work app since it asked
    var shownAt: Double?
    var happy = false                       // shows the happy face with it
}

final class Moments {
    var voice = Voice()
    var isWork: (String) -> Bool = { _ in false }
    /// (session, now, since minute) -> the session as the logs tell it
    var sessionInfo: (String, Double, Int) -> SessionInfo? = { _, _, _ in nil }
    /// now -> the last session remembered, for "Last time: ..."
    var lastSession: (Double) -> (title: String, next: String)? = { _ in nil }
    var onSessionDone: ((SessionRecap) -> Void)?
    var trace: ((String) -> Void)?

    // Tuning
    let awayAfterIdle = 120.0               // seconds without input: you are not looking at your work app
    let turnForYourMove = 2 * 60_000.0      // a turn this long, ending while you are away, is worth a bubble
    let yourMoveTTL = 60_000.0
    let breakthroughTTL = 8_000.0, breakthroughShortTTL = 4_000.0
    let keptUntilBackMax = 10 * 60_000.0
    let doneTTL = 2 * 60_000.0
    let doneAfterQuiet = 30 * 60_000.0
    let doneMinMinutes = 20
    let budgetGap = 10 * 60_000.0           // at most one bubble that is not urgent per 10 minutes
    let stuckFor = 5 * 60_000.0
    let streakForgotten = 2 * 3_600_000.0
    let runningShownAfter = 20_000.0
    let activeWithin = 10 * 60_000.0
    let nowHold = 20_000.0

    private var live: [String: LiveSession] = [:]
    private var observations: [Observation] = []
    private var lastBudget = -1e15
    private var transient: (expr: String, until: Double) = ("", 0)
    private var nowShown: (key: String, text: String, priority: Int, since: Double) = ("", "", 0, 0)
    private var lastFront = ""
    private(set) var output = MomentsOutput()

    private func note(_ now: Double, _ text: String) { trace?("\(clock(now))  \(text)") }

    private func session(_ id: String) -> LiveSession {
        if let found = live[id] { return found }
        let made = LiveSession(id: id)
        live[id] = made
        return made
    }

    private func project(_ s: LiveSession, _ now: Double) -> String {
        if s.project.isEmpty, let info = sessionInfo(s.id, now, 0) { s.project = info.project }
        return s.project.isEmpty ? "Claude Code" : s.project
    }

    private func add(_ observation: Observation, _ now: Double, because reason: String) {
        if let index = observations.firstIndex(where: { $0.key == observation.key }) {
            var replaced = observation
            replaced.shownAt = observations[index].shownAt
            observations[index] = replaced
            note(now, "\(observation.key) again: updated, not repeated (\(reason))")
        } else {
            observations.append(observation)
            note(now, "\(observation.key) noticed (\(reason))")
        }
    }

    private func drop(_ now: Double, where test: (Observation) -> Bool, because reason: String) {
        for gone in observations where test(gone) { note(now, "\(gone.key) over (\(reason))") }
        observations.removeAll(where: test)
    }

    /// One step. Returns whether what the robot shows changed.
    @discardableResult
    func tick(signals: [LogSignal], hooks: [HookEvent], front: String, idle: Double, level: String, now: Double) -> Bool {
        let atWork = isWork(front) && idle < awayAfterIdle
        if front != lastFront {
            note(now, "front app: \(front.isEmpty ? "none" : front)\(isWork(front) ? " (work)" : "")")
            lastFront = front
        }
        let topGear = level == "locked" || level == "overdrive"

        for hook in hooks where hook.ms >= now - 600_000 { take(hook, atWork: atWork, now: now) }
        // A log seen for the first time can be old: only what happened in the last 10 minutes is news.
        for signal in signals where signal.ms >= now - 600_000 { take(signal, atWork: atWork, topGear: topGear, now: now) }
        quietSessions(now)
        expire(atWork: atWork, idle: idle, now: now)

        let next = present(atWork: atWork, now: now)
        guard next != output else { return false }
        if next.card != output.card { note(now, next.card.map { "SHOW \($0.kind): \($0.title) / \($0.lines.joined(separator: " / "))" } ?? "SHOW nothing") }
        if next.expr != output.expr { note(now, "FACE \(next.expr.isEmpty ? "normal" : next.expr)") }
        output = next
        return true
    }

    /// You closed a bubble, or clicked it.
    func dismiss(_ cardId: String, now: Double) {
        drop(now, where: { "\($0.key)@\(Int($0.at))" == cardId }, because: "you closed it")
        output = present(atWork: false, now: now, dryRun: true)
    }

    // MARK: Detectors

    private func take(_ hook: HookEvent, atWork: Bool, now: Double) {
        let s = session(hook.session)
        if !hook.project.isEmpty { s.project = hook.project }
        switch hook.event {
        case "PermissionRequest":
            var facts = ["project": project(s, now), "tool": hook.tool, "detail": hook.detail]
            if facts["detail"]!.isEmpty { facts["detail"] = hook.tool }
            let which = hook.tool == "Bash" ? "Bash" : ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(hook.tool) ? "edit" : "other"
            add(Observation(kind: .waiting, session: s.id, key: "waiting:\(s.id)", at: hook.ms, agent: hook.agent, facts: facts,
                            path: ["waiting", which], deadline: hook.ms + 3 * 3_600_000), now, because: "\(hook.tool) needs a yes")
        case "Stop":
            drop(now, where: { $0.kind == .waiting && $0.session == s.id && $0.agent.isEmpty && $0.at < hook.ms }, because: "Claude stopped")
            let started = max(s.lastPrompt, sessionInfo(s.id, now, 0)?.lastPrompt ?? 0)
            guard started > 0, hook.ms - started >= turnForYourMove else {
                note(now, "Claude stopped in \(s.id.prefix(8)): short turn, nothing to say")
                return
            }
            if atWork {
                note(now, "Claude stopped after \(minutesText(hook.ms - started)): silence, you are at your work app")
                return
            }
            add(Observation(kind: .yourMove, session: s.id, key: "your-move:\(s.id)", at: hook.ms,
                            facts: ["project": project(s, now), "duration": minutesText(hook.ms - started)],
                            path: ["yourMove"], ttl: yourMoveTTL, deadline: hook.ms + yourMoveTTL), now, because: "stopped while you were away")
        case "SessionEnd":
            s.ended = max(s.ended, hook.ms)
            s.running = [:]
            drop(now, where: { ($0.kind == .waiting || $0.kind == .yourMove) && $0.session == s.id }, because: "session ended")
            finish(s, now: now, because: "session ended (\(hook.reason.isEmpty ? "closed" : hook.reason))")
        default:
            break
        }
    }

    private func take(_ signal: LogSignal, atWork: Bool, topGear: Bool, now: Double) {
        switch signal {
        case let .line(id, agent, assistant, ms):
            let s = session(id)
            s.lastLine = max(s.lastLine, ms)
            // Claude only writes again once the question is answered.
            if assistant { drop(now, where: { $0.kind == .waiting && $0.session == id && $0.agent == agent && ms > $0.at }, because: "Claude carried on") }
        case let .prompt(id, ms):
            let s = session(id)
            s.lastPrompt = max(s.lastPrompt, ms)
            drop(now, where: { ($0.kind == .waiting || $0.kind == .yourMove) && $0.session == id && ms > $0.at }, because: "you replied")
        case let .run(id, tool, command, ms):
            let kind = classify(command)
            let git = gitAction(command)
            guard kind != nil || git != nil else { return }
            session(id).running[tool] = Run(command: command, family: kind?.family, core: kind?.core ?? "", git: git, ms: ms)
        case let .result(id, tool, command, outcome, ms):
            let s = session(id)
            drop(now, where: { $0.kind == .waiting && $0.session == id && $0.facts["detail"] == shortened(command, 48) && ms > $0.at },
                 because: "the command it asked about has run")
            guard let run = s.running.removeValue(forKey: tool) else { return }
            let result = verdict(command, outcome)
            if let git = run.git, result != .fail, !outcome.error, !outcome.denied {
                if git == "commit" { s.commits += 1 } else { s.pr = true }
            }
            guard let family = run.family else { return }
            switch result {
            case .unknown:
                note(now, "\(family.rawValue) run in \(id.prefix(8)): unclear outcome, ignored (\(run.core))")
            case .fail:
                var streak = s.streaks[family.rawValue] ?? Streak()
                if streak.total > 0, ms - streak.last > streakForgotten { streak = Streak() }
                streak.failing[run.core, default: 0] += 1
                streak.total += 1
                streak.last = ms
                if streak.first == 0 { streak.first = ms }
                s.streaks[family.rawValue] = streak
                if atWork {
                    transient = ("worried", now + 5000)
                    note(now, "\(family.rawValue) failed (\(streak.total) so far): worried face, 5 s")
                } else {
                    note(now, "\(family.rawValue) failed (\(streak.total) so far): silence, you are away")
                }
            case .pass:
                guard var streak = s.streaks[family.rawValue], !streak.failing.isEmpty else { return }
                let whole = family != .test || !selector.found(in: " " + run.core + " ")
                if whole { streak.failing = [:] } else { streak.failing[run.core] = nil }
                guard streak.failing.isEmpty else {
                    s.streaks[family.rawValue] = streak
                    note(now, "\(family.rawValue) passed for \(run.core), others still failing")
                    return
                }
                s.streaks[family.rawValue] = nil
                let stuck = ms - streak.first
                guard streak.total >= 2 || stuck >= stuckFor else {
                    note(now, "\(family.rawValue) passed after one quick failure: nothing to celebrate")
                    return
                }
                let tries = streak.total + 1
                let facts = ["project": project(s, now), "tries": "\(tries) tries", "fails": "\(streak.total)", "stuck": minutesText(stuck)]
                if let win = voice.line(["facts", "win", family.rawValue], facts) { s.wins.append(win) }
                var observation = Observation(kind: .breakthrough, session: id, key: "breakthrough:\(id):\(family.rawValue)", at: ms,
                                              facts: facts, path: ["breakthrough", family.rawValue], happy: true)
                if atWork {
                    observation.ttl = topGear ? breakthroughShortTTL : breakthroughTTL
                    observation.deadline = now + 2 * 60_000
                } else {
                    observation.untilBack = true
                    observation.deadline = now + keptUntilBackMax
                }
                transient = ("happy", now + 5000)
                add(observation, now, because: "\(streak.total) failures, then a clean pass: \(run.core)")
            }
        }
    }

    /// A session that has been quiet for half an hour is over.
    private func quietSessions(_ now: Double) {
        for s in live.values where s.lastLine > s.checkedLine && now - s.lastLine >= doneAfterQuiet {
            finish(s, now: now, because: "quiet for \(minutesText(now - s.lastLine))")
        }
    }

    private func finish(_ s: LiveSession, now: Double, because reason: String) {
        s.checkedLine = s.lastLine
        guard let info = sessionInfo(s.id, now, s.doneMinute), info.lastMinute > s.doneMinute else { return }   // nothing new since the last recap
        let lastMinute = info.lastMinute
        let fresh = info.activeMinutes
        s.doneMinute = lastMinute
        let recap = SessionRecap(id: s.id, project: info.project, title: info.title, branch: info.branch,
                                 start: Double(info.firstMinute) * 60_000, end: Double(info.lastMinute + 1) * 60_000, minutes: fresh,
                                 edited: info.edited.map { ($0 as NSString).lastPathComponent }.sorted(), wins: s.wins, commits: s.commits, pr: s.pr)
        s.wins = []
        s.commits = 0
        s.pr = false
        guard fresh >= doneMinMinutes else {
            note(now, "session \(s.id.prefix(8)) over, \(fresh) min: too short for a recap")
            return
        }
        onSessionDone?(recap)
        var facts = ["project": info.project, "title": info.title.isEmpty ? info.project : info.title,
                     "duration": minutesText(Double(fresh) * 60_000)]
        var extras: [String] = recap.wins
        if recap.pr, let text = voice.line(["facts", "pr"]) { extras.append(text) }
        if recap.commits > 0, let text = voice.line(["facts", recap.commits == 1 ? "commit" : "commits"], ["count": "\(recap.commits)"]) { extras.append(text) }
        if !recap.edited.isEmpty, let text = voice.line(["facts", recap.edited.count == 1 ? "edited1" : "edited"], ["count": "\(recap.edited.count)"]) { extras.append(text) }
        for (index, extra) in extras.prefix(2).enumerated() { facts["fact\(index + 1)"] = extra }
        add(Observation(kind: .done, session: s.id, key: "done:\(s.id):\(lastMinute)", at: now, facts: facts, path: ["done"],
                        ttl: doneTTL, deadline: now + budgetGap), now, because: reason)
    }

    // MARK: Decide

    private func expire(atWork: Bool, idle: Double, now: Double) {
        for index in observations.indices {
            var o = observations[index]
            if o.kind == .waiting, !o.handled, atWork, now - o.at > 2000, idle < (now - o.at) / 1000 - 2 {
                o.handled = true
                note(now, "\(o.key): you have been at your work app since it asked, so it is handled")
                // What it asked to run only starts once you say yes: about now.
                if let s = live[o.session] {
                    for (tool, run) in s.running where run.ms <= o.at { s.running[tool]?.ms = now }
                }
            }
            if o.untilBack, atWork, o.backAt == nil, o.shownAt != nil { o.backAt = now }
            observations[index] = o
        }
        drop(now, where: { o in
            if o.kind == .yourMove, atWork { return true }
            if o.untilBack { return now > o.deadline || (o.backAt.map { now > $0 + self.breakthroughTTL } ?? false) }
            if let shown = o.shownAt, o.ttl > 0 { return now > shown + o.ttl }
            return now > o.deadline
        }, because: "its time is up, or you are back")
    }

    private func decide(_ o: Observation, atWork: Bool) -> Presentation {
        switch o.kind {
        case .waiting:
            if o.handled { return .silence("handled") }
            return atWork ? .expression("waiting") : .bubble(urgent: true, exempt: true)
        case .yourMove:
            return .bubble(urgent: false, exempt: true)
        case .breakthrough, .done:
            return .bubble(urgent: false, exempt: false)
        }
    }

    private func present(atWork: Bool, now: Double, dryRun: Bool = false) -> MomentsOutput {
        if dryRun {
            // Only take the closed bubble away; the next tick works out what comes next.
            var out = output
            if let card = out.card, !observations.contains(where: { "\($0.key)@\(Int($0.at))" == card.id }) { out.card = nil }
            return out
        }
        var out = MomentsOutput()
        var faces: [String] = []

        // One bubble: the most important that may show.
        var best: Int?
        for (index, o) in observations.enumerated() {
            switch decide(o, atWork: atWork) {
            case .expression(let face): faces.append(face)
            case .silence: break
            case .bubble(_, let exempt):
                let allowed = o.shownAt != nil || exempt || now - lastBudget >= budgetGap
                guard allowed else { continue }
                if let current = best {
                    let c = observations[current]
                    if (o.kind.priority, o.at) > (c.kind.priority, c.at) { best = index }
                } else {
                    best = index
                }
            }
        }
        if let index = best {
            var o = observations[index]
            if o.shownAt == nil {
                o.shownAt = now
                if case .bubble(_, false) = decide(o, atWork: atWork) { lastBudget = now }
                observations[index] = o
            }
            let words = voice.card(o.path, seed: o.key, facts: o.facts)
            out.card = Card(id: "\(o.key)@\(Int(o.at))", kind: o.kind.rawValue, title: words.title, lines: words.lines,
                            action: o.kind == .waiting || o.kind == .yourMove ? "focus" : nil, persistent: o.kind == .waiting)
            if o.kind == .waiting { faces.insert("waiting", at: 0) }
            if o.happy { faces.insert("happy", at: 0) }
        }
        if now < transient.until { faces.append(transient.expr) }
        out.expr = faces.first ?? ""
        out.now = nowLine(now)
        return out
    }

    // MARK: Now line

    private func nowLine(_ now: Double) -> String {
        var key = "", text = "", priority = 0
        let words = ["test": "running_test", "build": "running_build", "typecheck": "running_typecheck"]
        let waiting = observations.filter { $0.kind == .waiting && !$0.handled }
        let asking = Set(waiting.map { $0.session })
        if let o = waiting.max(by: { $0.at < $1.at }) {
            (key, priority) = ("waiting", 4)
            text = voice.line(["now", "waiting"], o.facts) ?? ""
        } else if let run = live.values.filter({ !asking.contains($0.id) }).flatMap({ $0.running.values })
                    .filter({ $0.family != nil && now - $0.ms >= runningShownAfter }).min(by: { $0.ms < $1.ms }) {
            (key, priority) = ("running", 3)
            text = voice.line(["now", words[run.family!.rawValue]!], ["elapsed": elapsedText(now - run.ms)]) ?? ""
        } else {
            // The session you are on is the one you last typed into; one Claude is busy in on its own
            // does not take the line from it every time it writes something.
            let active = live.values.filter { $0.lastLine > 0 && now - $0.lastLine < activeWithin && !$0.isOver }
                .sorted { ($0.lastPrompt, $0.lastLine) > ($1.lastPrompt, $1.lastLine) }
            if let first = active.first {
                let info = sessionInfo(first.id, now, 0)
                let title = (info?.title).flatMap { $0.isEmpty ? nil : $0 } ?? project(first, now)
                (key, priority) = ("on", 2)
                text = (active.count > 1 ? voice.line(["now", "onMore"], ["title": shortened(title, 40), "more": "\(active.count - 1)"])
                                         : voice.line(["now", "on"], ["title": shortened(title, 40)])) ?? ""
            } else if let last = lastSession(now) {
                (key, priority) = ("last", 1)
                text = (voice.line(["now", "lastNext"], ["title": shortened(last.title, 34), "next": shortened(last.next, 40)])
                        ?? voice.line(["now", "last"], ["title": shortened(last.title, 40)])) ?? ""
            }
        }
        // One line, held at least 20 s. Something more important replaces it at once; so does
        // the end of a waiting question or a run, since showing those after they are over would be wrong.
        let held = now - nowShown.since
        let switching = key != nowShown.key
        let allowed: Bool
        if nowShown.text.isEmpty { allowed = true }
        else if switching { allowed = priority > nowShown.priority || nowShown.key == "waiting" || nowShown.key == "running" || held >= nowHold }
        else { allowed = key == "running" || key == "waiting" || text == nowShown.text || held >= nowHold }
        if allowed && (switching || text != nowShown.text) {
            if switching || key == "on" { nowShown.since = now }
            if switching || key != "running" { note(now, "NOW \(text.isEmpty ? "-" : text)") }
            nowShown = (key, text, priority, nowShown.since)
        }
        return nowShown.text
    }
}
