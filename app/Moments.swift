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
        case let .line(_, _, _, ms), let .prompt(_, ms, _), let .ask(_, _, ms), let .decision(_, _, ms), let .edit(_, ms),
             let .run(_, _, _, ms), let .result(_, _, _, _, ms): return ms
        }
    }
}

// MARK: - What the robot shows

struct Card: Equatable {
    let id: String
    let kind: String
    let title: String
    let lines: [String]
    let action: String?                     // "focus": clicking takes you to its session
    let persistent: Bool                    // stays until its reason is gone
    var session = ""                        // the session it is about, where Go to it takes you
}

/// What the desktop robot's panel says: the session you are on, what Claude is doing in it, and
/// the one thing to do next, when there is one. Only from what the logs and hooks say.
struct Glance: Equatable {
    var title = "", place = ""              // the session's title; project · branch
    var claude = "", claudeKind = "idle"    // "needs", "running", "working", "handed", "finished", "idle"
    var next = "", nextFocus = false        // nextFocus: going to it means your terminal or editor
    var session = ""                        // the session it is about

    var json: [String: Any] {
        var out: [String: Any] = ["title": title, "where": place, "claude": ["kind": claudeKind, "text": claude], "session": session]
        out["next"] = next.isEmpty ? NSNull() : ["text": next, "action": nextFocus ? "focus" : NSNull()] as [String: Any]
        return out
    }
}

struct MomentsOutput: Equatable {
    var card: Card?
    var expr = ""                           // "worried", "happy", "cheer", "smile", "wave", "tired", "waiting", "puzzled", "bored" or ""
    var now = ""                            // the Now line
    var glance = Glance()

    var json: [String: Any] {
        // "nowLine", not "now": the state's own "now" is the time, which the dashboard reads.
        var out: [String: Any] = ["expr": expr, "nowLine": now, "glance": glance.json]
        if let card {
            out["moment"] = ["id": card.id, "kind": card.kind, "title": card.title, "lines": card.lines,
                             "action": card.action.map { $0 as Any } ?? NSNull(), "persistent": card.persistent,
                             "session": card.session] as [String: Any]
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
    let red: [String]                       // run families still failing when it ended ("test", "build", "typecheck")
}

/// The day's goal as analyze() works it out ("goal"), for the moment it is hit.
struct GoalState: Equatable {
    var wins = 0, target = 0, streak = 0
    var hit = false
    var day = 0                             // which day it is about (local), so tomorrow starts fresh

    init?(_ raw: Any?, now: Double) {
        guard let goal = raw as? [String: Any], let target = (goal["target"] as? NSNumber)?.intValue, target > 0 else { return nil }
        self.target = target
        wins = Int(number(goal["wins"]))
        streak = Int(number(goal["streak"]))
        hit = goal["hitToday"] as? Bool ?? false
        day = Calendar.current.ordinality(of: .day, in: .era, for: Date(timeIntervalSince1970: now / 1000)) ?? 0
    }
}

// MARK: - Detectors, decide, queue

private struct Run {
    let command: String
    let family: Family?
    let core: String
    let git: String?
    var ms: Double                          // when it started (or when the yes it waited for came)
}

private final class LiveSession {
    let id: String
    var project = ""
    var lastLine = 0.0
    var lastPrompt = 0.0
    var running: [String: Run] = [:]
    var ledger = RunLedger()
    var wins: [String] = []
    var commits = 0
    var pr = false
    var doneMinute = 0                      // the last minute counted in a recap
    var checkedLine = 0.0                   // lastLine when it was last checked for being over
    var lastYou = 0.0                       // your last prompt or answer here
    var handedAt = 0.0                      // when Claude handed you the turn (a long turn ended, a question, a plan); 0 = it has not
    var asked: [(ms: Double, words: Set<String>, text: String)] = []   // your last few prompts here
    var redos: [Double] = []                // near-repeats, interrupts and turn-downs since the last progress
    var loopSince = 0.0                     // when going round was noticed; 0 = it is not
    var loopCount = 0                       // redos when it was noticed
    /// Redos in this loop: the ones that started it, and every one since (some may be older than the window by now).
    var tries: Int { loopSince > 0 ? loopCount + redos.filter { $0 > loopSince }.count : redos.count }
    var loopSettled = false                 // said, or judged not a loop: once per loop
    var ended = 0.0                         // when Claude Code said it ended
    var isOver: Bool { ended > 0 && ended >= lastLine }
    init(id: String) { self.id = id }
}

private enum Kind: String {
    case waiting, yourMove = "your-move", breakthrough, done, loop, drift, stretch
    var priority: Int { [.waiting: 4, .breakthrough: 3, .yourMove: 2, .done: 2, .drift: 2, .loop: 1, .stretch: 1][self]! }
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
    var face = ""                           // the face it pulls while it shows ("happy", "cheer", "tired")
}

final class Moments {
    var voice = Voice()
    var isWork: (String) -> Bool = { _ in false }
    /// (session, now, since minute) -> the session as the logs tell it
    var sessionInfo: (String, Double, Int) -> SessionInfo? = { _, _, _ in nil }
    /// now -> the last session remembered, for "Last time: ..."
    var lastSession: (Double) -> (title: String, next: String, red: [String])? = { _ in nil }
    var onSessionDone: ((SessionRecap) -> Void)?
    var trace: ((String) -> Void)?
    /// How long you usually step away between bits of work, in ms (Attention learns it).
    var usualBreak: () -> Double = { 5 * 60_000 }
    /// A break just ended the way breaks do while working (back in a work app, then a prompt): its length in ms.
    var onBreak: ((Double) -> Void)?
    /// Asks Claude whether these prompts are going round (true) or real iteration (false); nil: no answer.
    /// Unset when AI is off, and then the rule alone decides.
    var judgeLoop: ((_ prompts: [String], _ answer: @escaping (Bool?) -> Void) -> Void)?

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
    let runningShownAfter = 20_000.0
    let activeWithin = 10 * 60_000.0
    let nowHold = 20_000.0
    let loopWindow = 20 * 60_000.0          // redos further apart than this are not one loop
    let loopAt = 3                          // redos without progress before it counts as going round
    let loopSayAfter = 15 * 60_000.0        // still going round this much later, with another redo: say so
    let driftAfterPrompt = 30 * 60_000.0    // a session you have not touched for longer is not waiting on you
    let backShown = 60_000.0
    let goalShown = 2 * 60_000.0
    let cheerTries = 4, cheerStuck = 10 * 60_000.0   // green after this many tries, or this long in the red: a cheer
    let smileFor = 2_500.0
    let welcomeAfter = 30 * 60_000.0        // away from the Mac this long, then back: a wave
    let pauseFor = 60_000.0                 // no prompt for this long, Claude done or quiet everywhere: a natural pause
    let stretchSayWithin = 10 * 60_000.0
    static let burnbotApp = "local.burnbot.app"

    /// You are reading the robot's face or its panel: a bubble that is not urgent waits until you are done,
    /// and its time and the bubble budget start when it shows.
    var busy = false

    private var live: [String: LiveSession] = [:]
    private var observations: [Observation] = []
    private var lastBudget = -1e15
    private var transient: (expr: String, until: Double) = ("", 0)
    private var nowShown: (key: String, text: String, priority: Int, since: Double) = ("", "", 0, 0)
    private var lastFront = ""
    private var clockNow = 0.0              // the latest tick's time, for answers that come back later
    private var offWorkSince = 0.0          // when something other than a work app came to the front, you at the Mac
    private var breakEnded: (length: Double, at: Double)?   // the last such stretch, until a prompt says it was a break
    private var drift: (session: String, since: Double, noted: Bool, bubbled: Bool)?
    private var back: (title: String, until: Double) = ("", 0)
    private var goalSeen: GoalState?
    private var goalUntil = 0.0
    private var lastInput = 0.0             // when you last touched the Mac, as the ticks saw it
    private var stretchSaid = false         // the long-stretch bubble, once per stretch
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
    func tick(signals: [LogSignal], hooks: [HookEvent], front: String, idle: Double, level: String,
              goal: GoalState? = nil, stretch: (minutes: Int, long: Int)? = nil, now: Double) -> Bool {
        clockNow = now
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
        loops(atWork: atWork, now: now)
        drifting(front: front, idle: idle, now: now)
        goals(goal, now: now)
        welcome(idle: idle, now: now)
        stretching(stretch, idle: idle, now: now)
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
            s.handedAt = max(s.handedAt, hook.ms)
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
            s.handedAt = 0
            s.redos = []
            s.loopSince = 0
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
            // Claude carrying on by itself: the turn is not yours any more.
            if assistant, agent.isEmpty, s.handedAt > 0, ms > s.handedAt + 1000 { s.handedAt = 0 }
        case let .prompt(id, ms, text):
            let s = session(id)
            s.lastPrompt = max(s.lastPrompt, ms)
            s.lastYou = max(s.lastYou, ms)
            if s.handedAt > 0, ms >= s.handedAt { s.handedAt = 0 }
            drop(now, where: { ($0.kind == .waiting || $0.kind == .yourMove) && $0.session == id && ms > $0.at }, because: "you replied")
            heard(s, text, ms, now)
            if let ended = breakEnded, ms >= ended.at, ms - ended.at <= 5 * 60_000 {
                breakEnded = nil
                note(now, "back to prompting after a break of \(minutesText(ended.length)): learned")
                onBreak?(ended.length)
            }
        case let .ask(id, _, ms):
            let s = session(id)
            s.handedAt = max(s.handedAt, ms)
        case let .decision(id, kind, ms):
            let s = session(id)
            s.lastYou = max(s.lastYou, ms)
            if s.handedAt > 0, ms >= s.handedAt { s.handedAt = 0 }
            switch kind {
            case .interrupt: redo(s, "you stopped Claude", ms, now)
            case .reject: redo(s, "you turned down what Claude proposed", ms, now)
            case .approve: progress(s, "you approved a plan", now)
            case .answer, .permission: break
            }
        case let .edit(id, _):
            progress(session(id), "Claude changed a file", now)
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
                progress(s, git == "commit" ? "a commit" : "a pull request", now)
            }
            guard let family = run.family else { return }
            let event = s.ledger.record(family, core: run.core, verdict: result, ms: ms)
            switch event {
            case .passed, .narrowed, .shrugged, .green: progress(s, "\(family.rawValue) passed", now)
            default: break
            }
            switch event {
            case .unclear:
                note(now, "\(family.rawValue) run in \(id.prefix(8)): unclear outcome, ignored (\(run.core))")
            case let .failed(total):
                if atWork {
                    transient = ("worried", now + 5000)
                    note(now, "\(family.rawValue) failed (\(total) so far): worried face, 5 s")
                } else {
                    note(now, "\(family.rawValue) failed (\(total) so far): silence, you are away")
                }
            case .passed:
                return
            case .narrowed:
                note(now, "\(family.rawValue) passed for \(run.core), others still failing")
            case .shrugged:
                if atWork {
                    transient = ("smile", now + smileFor)
                    note(now, "\(family.rawValue) passed after one quick failure: a small smile, 2.5 s")
                } else {
                    note(now, "\(family.rawValue) passed after one quick failure: nothing to celebrate, you are away")
                }
            case let .green(fails, stuck):
                let tries = fails + 1
                // The story behind it decides how glad: a long fight earns a cheer.
                let big = tries >= cheerTries || stuck >= cheerStuck
                let facts = ["project": project(s, now), "tries": "\(tries) tries", "fails": "\(fails)", "stuck": minutesText(stuck)]
                if let win = voice.line(["facts", "win", family.rawValue], facts) { s.wins.append(win) }
                var observation = Observation(kind: .breakthrough, session: id, key: "breakthrough:\(id):\(family.rawValue)", at: ms,
                                              facts: facts, path: ["breakthrough", family.rawValue], face: big ? "cheer" : "happy")
                if atWork {
                    observation.ttl = topGear ? breakthroughShortTTL : breakthroughTTL
                    observation.deadline = now + 2 * 60_000
                } else {
                    observation.untilBack = true
                    observation.deadline = now + keptUntilBackMax
                }
                transient = big ? ("cheer", now + 8000) : ("happy", now + 5000)
                add(observation, now, because: "\(fails) failures, then a clean pass: \(run.core)\(big ? ", a long fight: cheer" : "")")
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
                                 edited: info.edited.map { ($0 as NSString).lastPathComponent }.sorted(), wins: s.wins, commits: s.commits, pr: s.pr,
                                 red: s.ledger.red(now: now).map { $0.rawValue })
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

    // MARK: Going round

    private static let stopWords: Set<String> = [
        "the", "and", "you", "for", "this", "that", "with", "are", "can", "not", "but", "now", "then", "just", "please",
        "was", "have", "has", "from", "into", "out", "all", "any", "get", "let", "use", "make", "also", "what", "why",
        "how", "there", "here", "them", "they", "your", "our", "one", "again", "still", "should", "would", "could",
    ]

    /// The words that carry a prompt's meaning: 3+ letters, minus the glue.
    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { $0.count >= 3 && !stopWords.contains($0) })
    }

    /// A prompt you typed: a near-repeat of one of your last three here is a redo.
    private func heard(_ s: LiveSession, _ text: String, _ ms: Double, _ now: Double) {
        let words = Moments.words(text)
        if words.count >= 3, s.asked.suffix(3).contains(where: { earlier in
            earlier.words.count >= 3 && Double(earlier.words.intersection(words).count) / Double(earlier.words.union(words).count) >= 0.6
        }) {
            redo(s, "you asked for nearly the same again", ms, now)
        }
        s.asked.append((ms, words, String(text.prefix(300))))
        if s.asked.count > 6 { s.asked.removeFirst(s.asked.count - 6) }
    }

    private func redo(_ s: LiveSession, _ what: String, _ ms: Double, _ now: Double) {
        // Stopping Claude and typing the ask again, or turning down a plan and the stop it causes,
        // are one redo, not two.
        if let last = s.redos.last, ms - last < 60_000 { note(now, "\(s.id.prefix(8)): \(what), same redo as a moment ago"); return }
        s.redos.removeAll { ms - $0 > loopWindow }
        s.redos.append(ms)
        note(now, "\(s.id.prefix(8)): \(what) (\(s.redos.count) without progress)")
    }

    private func progress(_ s: LiveSession, _ what: String, _ now: Double) {
        guard !s.redos.isEmpty || s.loopSince > 0 else { return }
        if s.loopSince > 0 { note(now, "\(s.id.prefix(8)) no longer going round: \(what)") }
        s.redos = []
        s.loopSince = 0
        s.loopCount = 0
        s.loopSettled = false
        drop(now, where: { $0.kind == .loop && $0.session == s.id }, because: what)
    }

    /// Three redos without progress: a puzzled face and a line. Still at it 15 minutes and another
    /// redo later: one bubble, if Claude (when AI is on) agrees it is a loop and not real iteration.
    private func loops(atWork: Bool, now: Double) {
        for s in live.values {
            if s.loopSince == 0 {
                s.redos.removeAll { now - $0 > loopWindow }
                guard s.redos.count >= loopAt else { continue }
                s.loopSince = now
                s.loopCount = s.redos.count
                if atWork { transient = ("puzzled", now + 6000) }
                note(now, "\(s.id.prefix(8)) going round: \(s.redos.count) redos in \(minutesText(now - s.redos[0])), no progress\(atWork ? ": puzzled face, 6 s" : "")")
                continue
            }
            guard let last = s.redos.last else { continue }
            if now - last > loopWindow {
                note(now, "\(s.id.prefix(8)): no redo for \(minutesText(now - last)), no longer going round")
                s.redos = []
                s.loopSince = 0
                s.loopSettled = false
                drop(now, where: { $0.kind == .loop && $0.session == s.id }, because: "quiet")
                continue
            }
            // Fifteen minutes on and you are still at it: another redo since it was noticed.
            guard !s.loopSettled, now - s.loopSince >= loopSayAfter, last > s.loopSince else { continue }
            s.loopSettled = true
            guard let judge = judgeLoop else {
                sayLoop(s, now)
                continue
            }
            let since = s.loopSince
            note(now, "\(s.id.prefix(8)) still going round after \(minutesText(now - since)): asking Claude whether it is a loop")
            judge(s.asked.map { $0.text }) { [weak self, weak s] verdict in
                guard let self, let s, s.loopSince == since else { return }
                let at = self.clockNow
                switch verdict {
                case true?: self.sayLoop(s, at)
                case false?: self.note(at, "\(s.id.prefix(8)): Claude reads it as real iteration, nothing said")
                case nil: self.note(at, "\(s.id.prefix(8)): no answer from Claude, nothing said")
                }
            }
        }
    }

    private func sayLoop(_ s: LiveSession, _ now: Double) {
        add(Observation(kind: .loop, session: s.id, key: "loop:\(s.id):\(Int(s.loopSince))", at: now,
                        facts: ["project": project(s, now), "tries": "\(s.tries)",
                                "minutes": minutesText(now - (s.redos.first ?? now))],
                        path: ["loop"], ttl: yourMoveTTL, deadline: now + budgetGap),
            now, because: "still going round \(minutesText(now - s.loopSince)) after it was noticed")
    }

    // MARK: Drift

    /// Claude handed you the turn, you are at the Mac, and something else is in front: past your
    /// usual break a bored face and a line; past twice that, one bubble. Back at work: "Back to".
    private func drifting(front: String, idle: Double, now: Double) {
        if !front.isEmpty, front != Moments.burnbotApp {
            if isWork(front) || idle >= awayAfterIdle {                         // at work, or away from the Mac altogether
                if offWorkSince > 0, isWork(front), now - offWorkSince >= 30_000 { breakEnded = (now - offWorkSince, now) }
                offWorkSince = 0
            } else if offWorkSince == 0 { offWorkSince = now }
        }
        var waitingOn: (s: LiveSession, since: Double)?
        if offWorkSince > 0 {
            for s in live.values where !s.isOver && s.lastYou > 0 && now - s.lastYou < driftAfterPrompt {
                var handed = s.handedAt
                if let asked = observations.filter({ $0.kind == .waiting && $0.session == s.id }).map({ $0.at }).min() {
                    handed = handed > 0 ? min(handed, asked) : asked
                }
                guard handed > 0 else { continue }
                let since = max(offWorkSince, handed)
                if waitingOn == nil || since < waitingOn!.since { waitingOn = (s, since) }
            }
        }
        let usual = usualBreak()
        if let (s, since) = waitingOn {
            if drift?.session != s.id { drift = (s.id, since, false, false) }
            drift!.since = since
            let drifted = now - since
            if drifted >= usual, !drift!.noted {
                drift!.noted = true
                note(now, "drifted: \(project(s, now)) has waited \(minutesText(drifted)) with \(front) in front (usual break \(minutesText(usual))): bored face")
            }
            if drifted >= 2 * usual, !drift!.bubbled {
                drift!.bubbled = true
                if observations.contains(where: { $0.kind == .waiting && $0.session == s.id && !$0.handled }) {
                    note(now, "still drifted, but its own question is already asking")
                } else {
                    add(Observation(kind: .drift, session: s.id, key: "drift:\(s.id):\(Int(since))", at: now,
                                    facts: ["project": project(s, now), "waited": minutesText(drifted)],
                                    path: ["drift"], ttl: 2 * 60_000, deadline: now + budgetGap),
                        now, because: "still drifted after \(minutesText(drifted))")
                }
            }
        } else if let d = drift {
            drift = nil
            drop(now, where: { $0.kind == .drift }, because: "the drift is over")
            if d.noted, offWorkSince == 0, isWork(front), let s = live[d.session] {
                let title = (sessionInfo(s.id, now, 0)?.title).flatMap { $0.isEmpty ? nil : $0 } ?? project(s, now)
                back = (title, now + backShown)
                note(now, "back at work after drifting: \"Back to\" for 60 s")
            }
        }
    }

    // MARK: Goal

    private func goals(_ goal: GoalState?, now: Double) {
        guard let goal else { return }
        defer { goalSeen = goal }
        guard let seen = goalSeen, seen.day == goal.day, !seen.hit, goal.hit else { return }
        goalUntil = now + goalShown
        transient = ("happy", now + 8000)
        note(now, "daily goal hit: \(goal.wins) of \(goal.target) wins, \(goal.streak)-day streak: happy face 8 s")
    }

    /// Back at the Mac after a long time away, or for the first time today: a wave.
    private func welcome(idle: Double, now: Double) {
        let input = now - idle * 1000
        defer { lastInput = max(lastInput, input) }
        guard lastInput > 0, input - lastInput >= 1000 else { return }
        let away = input - lastInput
        let calendar = Calendar.current
        let newDay = !calendar.isDate(Date(timeIntervalSince1970: input / 1000), inSameDayAs: Date(timeIntervalSince1970: lastInput / 1000))
        guard away >= welcomeAfter || (newDay && away >= pauseFor) else { return }
        transient = ("wave", now + 3000)
        note(now, "back at the Mac after \(minutesText(away))\(newDay ? ", a new day" : ""): a wave, 3 s")
    }

    /// A long stretch with Claude (stretch.minutes, from the levels), longer than your usual long one:
    /// once per stretch, at the first natural pause, a tired face and a word about a break. Never mid-focus.
    private func stretching(_ stretch: (minutes: Int, long: Int)?, idle: Double, now: Double) {
        guard let stretch else { return }
        if stretch.minutes == 0 {
            if stretchSaid { note(now, "the long stretch is over: a break of 15 min or more") }
            stretchSaid = false
            return
        }
        guard !stretchSaid, stretch.minutes >= stretch.long, idle < awayAfterIdle else { return }
        // A natural pause: nothing asking for you, nothing running, every session handed back or quiet, no prompt for a minute.
        let sessions = live.values.filter { $0.lastLine > 0 && now - $0.lastLine < activeWithin && !$0.isOver }
        let paused = !sessions.isEmpty && !observations.contains { $0.kind == .waiting }
            && sessions.allSatisfy { $0.running.isEmpty && ($0.handedAt > 0 || now - $0.lastLine >= pauseFor) && now - max($0.lastPrompt, $0.lastYou) >= pauseFor }
        guard paused else { return }
        stretchSaid = true
        let observation = Observation(kind: .stretch, session: "", key: "stretch:\(Int(now / 60_000))", at: now,
                                      facts: ["minutes": minutesText(Double(stretch.minutes) * 60_000)], path: ["stretch"],
                                      ttl: yourMoveTTL, deadline: now + stretchSayWithin, face: "tired")
        add(observation, now, because: "\(stretch.minutes) min with Claude, past your long one (\(stretch.long)), and a natural pause")
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
        case .breakthrough, .done, .loop, .drift, .stretch:
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
            case .bubble(let urgent, let exempt):
                if busy, o.shownAt == nil, !urgent {
                    if !o.face.isEmpty { faces.append(o.face) }   // the face still changes
                    continue
                }
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
                            action: [.waiting, .yourMove, .drift].contains(o.kind) ? "focus" : nil, persistent: o.kind == .waiting,
                            session: o.session)
            if o.kind == .waiting { faces.insert("waiting", at: 0) }
            if !o.face.isEmpty { faces.insert(o.face, at: 0) }
        }
        if now < transient.until { faces.append(transient.expr) }
        if drift?.noted == true { faces.append("bored") }
        out.expr = faces.first ?? ""
        out.now = nowLine(now)
        out.glance = glance(now)
        return out
    }

    // MARK: The panel

    private func glance(_ now: Double) -> Glance {
        var g = Glance()
        func say(_ key: String, _ facts: [String: String] = [:]) -> String { voice.line(["glance", key], facts) ?? "" }
        let ask = observations.filter { $0.kind == .waiting && !$0.handled }.max(by: { $0.at < $1.at })
        let active = live.values.filter { $0.lastLine > 0 && now - $0.lastLine < activeWithin && !$0.isOver }
            .sorted { ($0.lastPrompt, $0.lastLine) > ($1.lastPrompt, $1.lastLine) }
        // The session it is about: one asking for you, or else the one you are on.
        guard let s = ask.flatMap({ live[$0.session] }) ?? active.first else {
            g.claude = say("idle")
            if let last = lastSession(now) {
                g.title = last.title
                g.next = last.next.isEmpty ? "" : say("nextLast", ["next": shortened(last.next, 60)])
            }
            return g
        }
        let info = sessionInfo(s.id, now, 0)
        let name = project(s, now)
        g.session = s.id
        g.title = (info?.title).flatMap { $0.isEmpty ? nil : $0 } ?? name
        g.place = [name, info?.branch ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        if let ask {
            let detail = ask.facts["detail"] ?? ""
            (g.claudeKind, g.claude) = ("needs", say("needs", ["detail": detail]))
            (g.next, g.nextFocus) = (say("nextNeeds", ["detail": detail, "project": name]), true)
        } else if let run = s.running.values.filter({ $0.family != nil }).min(by: { $0.ms < $1.ms }) {
            (g.claudeKind, g.claude) = ("running", say("running_" + run.family!.rawValue))
        } else if s.handedAt > 0 {
            (g.claudeKind, g.claude) = ("handed", say("handed", ["ago": minutesText(now - s.handedAt)]))
        } else if now - s.lastLine < pauseFor && s.lastLine >= s.lastPrompt {
            (g.claudeKind, g.claude) = ("working", say("working"))
        } else {
            (g.claudeKind, g.claude) = ("finished", say("finished", ["ago": minutesText(now - s.lastLine)]))
        }
        if g.next.isEmpty, s.handedAt > 0 { (g.next, g.nextFocus) = (say("nextReply", ["project": name]), true) }
        if g.next.isEmpty, let red = s.ledger.red(now: now).first, let what = voice.line(["facts", "red", red.rawValue]) {
            g.next = say("nextRed", ["red": what.prefix(1).uppercased() + what.dropFirst(), "project": name])
        }
        return g
    }

    // MARK: Now line

    private func nowLine(_ now: Double) -> String {
        var key = "", text = "", priority = 0
        func offer(_ k: String, _ p: Int, _ t: String?) {
            guard let t, !t.isEmpty, p > priority else { return }
            (key, priority, text) = (k, p, t)
        }
        let words = ["test": "running_test", "build": "running_build", "typecheck": "running_typecheck"]
        let waiting = observations.filter { $0.kind == .waiting && !$0.handled }
        let asking = Set(waiting.map { $0.session })
        if let d = drift, d.noted, let s = live[d.session] {
            offer("drift", 6, voice.line(["now", "drift"], ["project": project(s, now), "waited": minutesText(now - d.since)]))
        }
        if let o = waiting.max(by: { $0.at < $1.at }) { offer("waiting", 5, voice.line(["now", "waiting"], o.facts)) }
        if let run = live.values.filter({ !asking.contains($0.id) }).flatMap({ $0.running.values })
            .filter({ $0.family != nil && now - $0.ms >= runningShownAfter }).min(by: { $0.ms < $1.ms }) {
            offer("running", 4, voice.line(["now", words[run.family!.rawValue]!], ["elapsed": elapsedText(now - run.ms)]))
        }
        if now < back.until { offer("back", 3, voice.line(["now", "back"], ["title": shortened(back.title, 40)])) }
        if now < goalUntil, let g = goalSeen {
            offer("goal", 3, voice.line(["now", g.streak >= 2 ? "goal" : "goal1"],
                                        ["wins": "\(g.wins)", "target": "\(g.target)", "streak": "\(g.streak)"]))
        }
        if let s = live.values.filter({ $0.loopSince > 0 }).min(by: { $0.loopSince < $1.loopSince }) {
            offer("loop", 3, voice.line(["now", "loop"], ["tries": "\(s.tries)"]))
        }
        if priority < 2 {
            // The session you are on is the one you last typed into; one Claude is busy in on its own
            // does not take the line from it every time it writes something.
            let active = live.values.filter { $0.lastLine > 0 && now - $0.lastLine < activeWithin && !$0.isOver }
                .sorted { ($0.lastPrompt, $0.lastLine) > ($1.lastPrompt, $1.lastLine) }
            if let first = active.first {
                let info = sessionInfo(first.id, now, 0)
                let title = (info?.title).flatMap { $0.isEmpty ? nil : $0 } ?? project(first, now)
                offer("on", 2, active.count > 1 ? voice.line(["now", "onMore"], ["title": shortened(title, 40), "more": "\(active.count - 1)"])
                                                 : voice.line(["now", "on"], ["title": shortened(title, 40)]))
            } else if let last = lastSession(now) {
                let red = last.red.compactMap { voice.line(["facts", "red", $0]) }.joined(separator: " and ")
                offer("last", 1, (red.isEmpty ? nil : voice.line(["now", "lastRed"], ["title": shortened(last.title, 34), "red": red]))
                        ?? voice.line(["now", "lastNext"], ["title": shortened(last.title, 34), "next": shortened(last.next, 40)])
                        ?? voice.line(["now", "last"], ["title": shortened(last.title, 40)]))
            }
        }
        // One line, held at least 20 s. Something more important replaces it at once; so does
        // the end of a waiting question or a run, since showing those after they are over would be wrong.
        let held = now - nowShown.since
        let switching = key != nowShown.key
        let allowed: Bool
        if nowShown.text.isEmpty { allowed = true }
        // A line gives way to a lower one only when it is over, and every line but "On" and "Last time"
        // is over the moment its reason is; those two hold their 20 s.
        else if switching { allowed = priority > nowShown.priority || !["on", "last"].contains(nowShown.key) || held >= nowHold }
        else { allowed = !["on", "last"].contains(key) || text == nowShown.text || held >= nowHold }
        if allowed && (switching || text != nowShown.text) {
            if switching || key == "on" { nowShown.since = now }
            if switching || !["running", "drift"].contains(key) { note(now, "NOW \(text.isEmpty ? "-" : text)") }
            nowShown = (key, text, priority, nowShown.since)
        }
        return nowShown.text
    }
}
