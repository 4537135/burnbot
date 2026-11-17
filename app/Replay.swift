// --dump-timeline <fixture>: replays a recorded session, second by second, through the
// same tracker and moments the app runs, and returns what the robot noticed and did.
// tools/check-moments.sh runs every fixture in tools/fixtures/ and compares.
//
// A fixture is a folder:
//   logs/<project>/<session>.jsonl   Claude Code logs; each line is written when its time comes
//   hooks.jsonl                      hook events as Claude Code sends them, plus "at" (ISO time)
//   attention.txt                    "<ISO time> <bundle id of the app in front> <seconds idle>",
//                                    idle growing on its own until the next line
//   fixture.json                     optional: {"start": ISO, "end": ISO}
//   expected.txt                     what the replay should print

import Foundation

/// Play Every Moment: a replay's seconds, squeezed. Each stretch where the robot shows the same
/// thing plays for about as long as it takes to take in (a bubble 7 s at most, a face 4 s, a quiet
/// spell 1 to 2 s), keeping its order and the order of what changes inside it (a run's timer).
func squeeze(_ frames: [(Double, MomentsOutput)]) -> [(at: Double, output: MomentsOutput)] {
    func key(_ output: MomentsOutput) -> String {
        "\(output.card?.id ?? "")|\(output.expr)|\(output.now.filter { !$0.isNumber })"
    }
    // Stretches of seconds that look the same.
    var stretches: [[(Double, MomentsOutput)]] = []
    for frame in frames {
        if let last = stretches.last?.last, key(last.1) == key(frame.1) {
            stretches[stretches.count - 1].append(frame)
        } else {
            stretches.append([frame])
        }
    }
    var out: [(at: Double, output: MomentsOutput)] = []
    var clock = 0.0
    for (i, stretch) in stretches.enumerated() {
        let begins = stretch[0].0
        let ends = i + 1 < stretches.count ? stretches[i + 1][0].0 : stretch[stretch.count - 1].0 + 1000
        let real = max(1000, ends - begins)
        let look = stretch[0].1
        let (least, most): (Double, Double) =
            look.card != nil ? (3000, 7000) : !look.expr.isEmpty ? (2000, 4000)
            : look.now.contains(where: { $0.isNumber }) ? (1500, 3000) : (1200, 2000)
        let shown = min(most, max(least, real))
        for (t, output) in stretch where out.last?.output != output {
            out.append((clock + (t - begins) * shown / real, output))
        }
        clock += shown
    }
    out.append((clock, MomentsOutput()))
    return out
}

/// `frame`, when given, also gets what the robot showed at each second (Play Every Moment uses it).
func replayTimeline(_ folder: String, voice: Voice, frame: ((Double, MomentsOutput) -> Void)? = nil) -> String {
    let manager = FileManager.default
    let root = NSTemporaryDirectory() + "burnbot-replay-\(getpid())-\(UUID().uuidString.prefix(8))"
    try? manager.removeItem(atPath: root)
    try? manager.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? manager.removeItem(atPath: root) }

    // Every log line with its time. Lines without one go with the line before them.
    var lines: [(ms: Double, order: Int, path: String, text: String)] = []
    let logs = folder + "/logs"
    let names = (manager.enumerator(atPath: logs)?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".jsonl") }.sorted()
    for relative in names {
        let text = (try? String(contentsOfFile: logs + "/" + relative, encoding: .utf8)) ?? ""
        var last = 0.0
        for line in text.split(separator: "\n") {
            if let raw = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
               let ms = (raw["timestamp"] as? String).flatMap(milliseconds) { last = ms }
            lines.append((last, lines.count, root + "/" + relative, String(line)))
        }
    }
    lines.sort { ($0.ms, $0.order) < ($1.ms, $1.order) }
    let hooks = HookInbox.scripted(folder + "/hooks.jsonl").sorted { $0.ms < $1.ms }

    var places: [(ms: Double, front: String, idle: Double)] = []
    for row in ((try? String(contentsOfFile: folder + "/attention.txt", encoding: .utf8)) ?? "").split(separator: "\n") {
        let parts = row.split(separator: " ").map(String.init)
        guard parts.count >= 3, let ms = milliseconds(parts[0]), let idle = Double(parts[2]) else { continue }
        places.append((ms, parts[1], idle))
    }
    places.sort { $0.ms < $1.ms }

    var settings: [String: Any] = [:]
    if let data = manager.contents(atPath: folder + "/fixture.json") { settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }
    let times = lines.map(\.ms).filter { $0 > 0 } + hooks.map(\.ms)
    guard let first = times.min(), let last = times.max() else { return "empty fixture\n" }
    let start = (settings["start"] as? String).flatMap(milliseconds) ?? (first / 1000).rounded(.down) * 1000
    let end = (settings["end"] as? String).flatMap(milliseconds) ?? last + 40 * 60_000

    // Anything before the start is history: there before the app was.
    var next = 0
    func write(upTo ms: Double) -> Bool {
        var grouped: [String: String] = [:]
        var order: [String] = []
        while next < lines.count && lines[next].ms <= ms {
            let line = lines[next]
            if grouped[line.path] == nil { order.append(line.path) }
            grouped[line.path, default: ""] += line.text + "\n"
            next += 1
        }
        for path in order {
            try? manager.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if !manager.fileExists(atPath: path) { manager.createFile(atPath: path, contents: nil) }
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(Data(grouped[path]!.utf8))
                handle.closeFile()
            }
        }
        return !order.isEmpty
    }
    _ = write(upTo: start - 1)

    let tracker = Tracker(root: root, storePath: "/nonexistent/store.json")
    tracker.scanAll()
    let attention = Attention(remember: false)
    var now = start
    attention.scripted = {
        guard let current = places.last(where: { $0.ms <= now }) else { return ("", 0) }
        return (current.front, current.idle + (now - current.ms) / 1000)
    }

    var out: [String] = []
    let moments = Moments()
    moments.voice = voice
    moments.isWork = { attention.isWork($0) }
    moments.sessionInfo = { id, at, since in tracker.session(id, now: at, since: since) }
    moments.trace = { out.append($0) }

    var hookIndex = 0
    var level = ""
    while now <= end {
        if write(upTo: now) { _ = tracker.poll(walkNow: true) }
        let signals = tracker.takeSignals()
        var due: [HookEvent] = []
        while hookIndex < hooks.count && hooks[hookIndex].ms <= now { due.append(hooks[hookIndex]); hookIndex += 1 }
        // The level only matters to a run's result (how long a breakthrough shows), and working it out is slow.
        if signals.contains(where: { if case .result = $0 { return true } else { return false } }) {
            level = analyze(files: Array(tracker.files.values), lastCallMs: tracker.lastCallMs, lastPromptMs: tracker.lastPromptMs, now: now)["state"] as? String ?? ""
        }
        let place = attention.now
        moments.tick(signals: signals, hooks: due, front: place.front, idle: place.idle, level: level, now: now)
        frame?(now, moments.output)
        now += 1000
    }
    return out.joined(separator: "\n") + "\n"
}
