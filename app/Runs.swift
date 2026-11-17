// The commands Claude runs, as the robot and the tracker both read them: what kind of run
// it is (test, build, typecheck, a commit), whether it passed (only with evidence), and
// the red-to-green bookkeeping that turns a fight with failing runs into a win.

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


// MARK: - Red to green

/// One session's fight with failing runs, per family, until a clean pass. A win (`.green`) is a
/// clean pass after two or more failures, or after five minutes or more in the red: one quick
/// failure and a fix is just work. The robot cheers the wins; the tracker counts them for the goal.
struct RunLedger {
    static let stuckFor = 5 * 60_000.0                  // this long in the red also makes it a fight
    static let forgotten = 2 * 3_600_000.0              // a red this old no longer counts

    enum Event {
        case unclear                                    // no evidence either way
        case failed(total: Int)                         // failures so far in this fight
        case narrowed                                   // a selected test passed, others still fail
        case passed                                     // green, and nothing was red
        case shrugged                                   // green after one quick failure
        case green(fails: Int, stuck: Double)           // a win
    }

    private struct Streak {
        var failing: [String: Int] = [:]                // command -> failures
        var total = 0
        var first = 0.0, last = 0.0
    }
    private var streaks: [Family: Streak] = [:]

    /// The families still red, as of `now`.
    func red(now: Double) -> [Family] {
        streaks.filter { !$0.value.failing.isEmpty && now - $0.value.last <= RunLedger.forgotten }.map { $0.key }
            .sorted { $0.rawValue < $1.rawValue }
    }

    mutating func record(_ family: Family, core: String, verdict: Verdict, ms: Double) -> Event {
        switch verdict {
        case .unknown:
            return .unclear
        case .fail:
            var streak = streaks[family] ?? Streak()
            if streak.total > 0, ms - streak.last > RunLedger.forgotten { streak = Streak() }
            streak.failing[core, default: 0] += 1
            streak.total += 1
            streak.last = ms
            if streak.first == 0 { streak.first = ms }
            streaks[family] = streak
            return .failed(total: streak.total)
        case .pass:
            guard var streak = streaks[family], !streak.failing.isEmpty else { return .passed }
            // A run narrowed to some tests only clears those; a whole run clears them all.
            let whole = family != .test || !selector.found(in: " " + core + " ")
            if whole { streak.failing = [:] } else { streak.failing[core] = nil }
            guard streak.failing.isEmpty else {
                streaks[family] = streak
                return .narrowed
            }
            streaks[family] = nil
            let stuck = ms - streak.first
            guard streak.total >= 2 || stuck >= RunLedger.stuckFor else { return .shrugged }
            return .green(fails: streak.total, stuck: stuck)
        }
    }
}
