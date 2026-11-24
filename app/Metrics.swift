// Turns minute buckets into what the screens show: live token burn, today's
// totals, a personal baseline, and the level the person is at.
//
// It calibrates itself. Nothing here is an absolute number of tokens or
// keystrokes: every time it runs it re-reads the person's last 30 days and
//   1. ranks each signal against their own hands-on time,
//   2. ranks the blend of those against their own hands-on time again, which is
//      the 0-100 intensity, so 75 always means "hotter than 75% of your time",
//   3. cuts the levels at fixed points of that personal scale, and
//   4. times autopilot from the gaps they usually leave between prompts.
// So "locked in" is always "your own top quarter, sustained", whoever you are,
// and it drifts with you as your habits change.

import Foundation

/// The states, in ladder order. The first six are levels 0 to 5; autopilot sits
/// off the ladder (Claude is working but the person is away). The screens give
/// them their names: chilling, warming up, cooking, locked in, on fire.
let stateNames = ["asleep", "idle", "warming", "cruising", "locked", "overdrive", "autopilot"]
private enum S { static let asleep = 0, idle = 1, warming = 2, cruising = 3, locked = 4, overdrive = 5, autopilot = 6 }
let topLevel = 5

struct Config {
    var days = 30                   // history used for calibration
    var burnWindow = 15             // minutes of tokens behind the burn signal
    var typeWindow = 30             // minutes of typing behind the typing signal
    var actWindow = 15              // minutes of prompts + tool calls behind the activity signal
    var weightBurn = 0.4, weightTyping = 0.35, weightActions = 0.25
    var idleAfter = 5               // minutes without an API call -> chilling
    var asleepAfter = 30            // -> asleep
    var streakGap = 10              // a gap this long ends a streak
    // Autopilot: Claude still working, no prompt for longer than the person usually
    // leaves between prompts. Learned from their own gaps, within limits.
    var autopilotAfter = 25         // used until enough gaps have been seen
    var autopilotQuantile = 0.85
    var autopilotRange = (15, 60)
    // Level cut-offs on the personal intensity scale: cooking is everything above
    // your quietest 30%, locked in is your top quarter, on fire your top 7%.
    var cruiseAt = 30.0
    var lockAt = 75.0
    var lockHold = 62.0             // once locked in, stay locked down to here
    var lockMinStreak = 20          // minutes of continuous work before lock-in can start
    var overdriveAt = 93.0
    var overdriveHold = 88.0
    var minWindows = 120            // hands-on minutes of history needed before the baseline is trusted
    // The daily goal: wins (a green after red, a commit, a pull request, a plan you approved).
    var goalDefault = 3             // until there are enough working days to go by
    var goalMinDays = 7
    var workingDayMin = 30          // a day with less hands-on time than this neither counts nor breaks a streak
    // A stretch with Claude: minutes at Warming up or above, ended by this long without one.
    var stretchGap = 15
    var stretchDefault = 90         // your long one, until enough stretches are known
    var stretchQuantile = 0.9
    var stretchRange = (75, 180)
    var stretchSamples = 10         // stretches of 30 min or more needed to learn it
    // Used until there is enough history: the value that counts as "typical".
    var defaultBurn = 3e6, defaultTyping = 400.0, defaultActions = 20.0
}

private func prefix(_ a: [Double]) -> [Double] {
    var p = [Double](repeating: 0, count: a.count + 1)
    for i in 0..<a.count { p[i + 1] = p[i] + a[i] }
    return p
}

private func win(_ p: [Double], _ i: Int, _ w: Int) -> Double { p[i + 1] - p[max(0, i + 1 - w)] }

/// Share of sorted samples strictly below v, 0-100.
private func rank(_ sorted: [Double], _ v: Double) -> Double {
    var lo = 0
    var hi = sorted.count
    while lo < hi {
        let mid = (lo + hi) >> 1
        if sorted[mid] < v { lo = mid + 1 } else { hi = mid }
    }
    return sorted.isEmpty ? 0 : Double(lo) / Double(sorted.count) * 100
}

private func quantile(_ sorted: [Double], _ q: Double) -> Double {
    sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int((q * Double(sorted.count)).rounded(.down)))]
}

private func median(_ values: [Double]) -> Double {
    if values.isEmpty { return 0 }
    let s = values.sorted()
    let m = s.count / 2
    return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
}

private func dayStart(_ ms: Double, _ deltaDays: Int = 0) -> Double {
    let calendar = Calendar.current
    let start = calendar.startOfDay(for: Date(timeIntervalSince1970: ms / 1000))
    return (calendar.date(byAdding: .day, value: deltaDays, to: start) ?? start).timeIntervalSince1970 * 1000
}

private func rounded(_ x: Double) -> Double { (x + 0.5).rounded(.down) }      // as JavaScript's Math.round

/// Everything the screens need, as plain JSON-ready values.
/// `askedAt`: Claude has been waiting for your answer to a question or a plan since then, and you
/// are at the Mac: those minutes are you reading, so they count as hands-on.
/// `goal`: the daily goal you set (0 = worked out from your days). `before`: the days older than the
/// window (olderHistory), so a streak can run past it.
func analyze(files: [LogFile], lastCallMs: Double, lastPromptMs: Double, now: Double, askedAt: Double = 0,
             goal: Int = 0, before: [[String: Any]] = [], config cfg: Config = Config()) -> [String: Any] {
    let nowMin = Int((now / 60000).rounded(.down))
    let today0 = dayStart(now)
    let startMin = Int(dayStart(now, -(cfg.days - 1)) / 60000)
    let todayIdx = Int(today0 / 60000) - startMin
    let weekStartMin = Int(dayStart(now, -6) / 60000)
    let weekStartMs = Double(weekStartMin) * 60000
    let N = nowMin - startMin + 1
    func zeros() -> [Double] { [Double](repeating: 0, count: N) }

    // ---- dense per-minute series over the calibration window ----
    var tok = zeros(), out = zeros(), chars = zeros(), prompts = zeros(), tools = zeros(), lines = zeros(), pasted = zeros(), calls = zeros()
    var hands = zeros(), wins = zeros()
    var winKinds = [Double](repeating: 0, count: 4)     // today: greens, commits, prs, plans
    var sessions = [Int](repeating: 0, count: N), agents = [Int](repeating: 0, count: N)
    var split = [Double](repeating: 0, count: 6)        // input, output, cacheWrite, cacheRead, thinking, calls
    var familyToday = [Double](repeating: 0, count: modelFamilies.count), familyWeek = familyToday
    var projectWeek: [String: Double] = [:], projectToday: [String: Double] = [:], projectMonth: [String: Double] = [:]
    var projectOrder: [String] = []
    var sessionsToday = Set<String>()                   // main sessions with any activity today

    for file in files {
        let recent = file.modified * 1000 >= weekStartMs
        let name = file.project.isEmpty ? "unknown" : file.project
        for (minute, v) in file.minutes {
            let i = minute - startMin
            if i < 0 || i >= N { continue }
            let total = totalTokens(v)
            tok[i] += total
            out[i] += v[F.output]
            chars[i] += v[F.chars]
            pasted[i] += v[F.pasted]
            prompts[i] += v[F.prompts]
            tools[i] += v[F.tools]
            lines[i] += v[F.lines]
            calls[i] += v[F.calls]
            hands[i] += v[F.hands]
            wins[i] += v[F.greens] + v[F.commits] + v[F.prs] + v[F.plans]
            if file.side { agents[i] += 1 } else { sessions[i] += 1 }
            if !file.side && i >= todayIdx { sessionsToday.insert(file.session.isEmpty ? file.path : file.session) }
            if projectMonth[name] == nil { projectOrder.append(name) }
            projectMonth[name, default: 0] += total
            if minute >= weekStartMin {
                for k in 0..<familyWeek.count { familyWeek[k] += v[F.family + k] }
                if recent {
                    projectWeek[name, default: 0] += total
                    if i >= todayIdx { projectToday[name, default: 0] += total }
                }
            }
            if i >= todayIdx {
                for k in 0..<familyToday.count { familyToday[k] += v[F.family + k] }
                split[0] += v[F.input]
                split[1] += v[F.output]
                split[2] += v[F.cacheWrite]
                split[3] += v[F.cacheRead]
                split[4] += v[F.thinking]
                split[5] += v[F.calls]
                for k in 0..<4 { winKinds[k] += v[F.greens + k] }
            }
        }
    }
    var acts = zeros(), active = zeros()
    var human = [Bool](repeating: false, count: N)
    // Answering Claude (a question, a plan, a permission, stopping it) is you at work, like a prompt.
    if askedAt > 0 {
        for i in max(0, Int((askedAt / 60000).rounded(.down)) - startMin)..<N { hands[i] = max(hands[i], 1) }
    }
    for i in 0..<N {
        acts[i] = prompts[i] + tools[i] + hands[i]
        if calls[i] > 0 || prompts[i] > 0 || hands[i] > 0 { active[i] = 1 }
        human[i] = prompts[i] > 0 || hands[i] > 0
    }

    let pTok = prefix(tok), pOut = prefix(out), pChars = prefix(chars), pActs = prefix(acts), pActive = prefix(active)
    let pPrompts = prefix(prompts), pTools = prefix(tools), pLines = prefix(lines), pPasted = prefix(pasted)
    let pHands = prefix(hands), pWins = prefix(wins)

    // ---- autopilot timing: how long this person usually goes between prompts ----
    var gaps: [Double] = []
    do {
        var lastPrompt = -1
        var lastSeen = -1_000_000_000
        var broken = true           // a break long enough to fall asleep sits between the two prompts
        for i in 0..<N where active[i] > 0 {
            if i - lastSeen >= cfg.asleepAfter { broken = true }
            lastSeen = i
            if !human[i] { continue }
            if !broken, lastPrompt >= 0 { gaps.append(Double(i - lastPrompt)) }
            lastPrompt = i
            broken = false
        }
    }
    gaps.sort()
    let autopilotLearned = gaps.count >= 20
    let autopilotAfter = autopilotLearned
        ? max(cfg.autopilotRange.0, min(cfg.autopilotRange.1, Int(quantile(gaps, cfg.autopilotQuantile))))
        : cfg.autopilotAfter

    // ---- personal baseline: how each signal is distributed over this person's
    // hands-on time (working, and prompted recently enough not to be on autopilot) ----
    var burnSamples: [Double] = [], typeSamples: [Double] = [], actSamples: [Double] = []
    var qualified = [Bool](repeating: false, count: N)
    do {
        var lastPrompt = -1_000_000_000
        for i in 0..<N {
            if human[i] { lastPrompt = i }
            if win(pActive, i, 15) < 3 || i - lastPrompt > autopilotAfter { continue }
            qualified[i] = true
            burnSamples.append(win(pTok, i, cfg.burnWindow))
            typeSamples.append(win(pChars, i, cfg.typeWindow))
            actSamples.append(win(pActs, i, cfg.actWindow))
        }
    }
    let n = burnSamples.count
    burnSamples.sort()
    typeSamples.sort()
    actSamples.sort()
    let calibrated = n >= cfg.minWindows
    func soft(_ v: Double, _ reference: Double) -> Double { 100 * (1 - pow(2, -v / reference)) }
    func pBurn(_ v: Double) -> Double { calibrated ? rank(burnSamples, v) : soft(v, cfg.defaultBurn) }
    func pType(_ v: Double) -> Double { calibrated ? rank(typeSamples, v) : soft(v, cfg.defaultTyping) }
    func pActn(_ v: Double) -> Double { calibrated ? rank(actSamples, v) : soft(v, cfg.defaultActions) }

    // ---- intensity: the blend of the three ranks, ranked against yourself again ----
    var raw = [Float](repeating: 0, count: N)
    var rawSamples: [Double] = []
    for i in 0..<N {
        if win(pActive, i, cfg.idleAfter) == 0 { continue }      // asleep or chilling: no intensity
        let blend = cfg.weightBurn * pBurn(win(pTok, i, cfg.burnWindow))
            + cfg.weightTyping * pType(win(pChars, i, cfg.typeWindow))
            + cfg.weightActions * pActn(win(pActs, i, cfg.actWindow))
        raw[i] = Float(blend)
        if qualified[i] { rawSamples.append(Double(raw[i])) }
    }
    rawSamples.sort()
    func score(_ i: Int) -> Double { calibrated ? rank(rawSamples, Double(raw[i])) : Double(raw[i]) }

    // ---- state per minute ----
    var state = [Int](repeating: S.asleep, count: N)
    var intensity = [Float](repeating: 0, count: N)
    var lastActive = -1_000_000_000
    var lastHuman = -1_000_000_000
    var streakStart = 0
    var previous = S.asleep
    for i in 0..<N {
        if active[i] > 0 {
            if i - lastActive >= cfg.streakGap { streakStart = i }
            lastActive = i
        }
        if human[i] { lastHuman = i }
        let idle = i - lastActive
        var s: Int
        if idle >= cfg.asleepAfter {
            s = S.asleep
        } else if idle >= cfg.idleAfter {
            s = S.idle
        } else {
            let I = Float(score(i))
            intensity[i] = I
            let value = Double(I)
            let streak = i - streakStart
            if i - lastHuman > autopilotAfter {
                s = S.autopilot
            } else if (value >= cfg.overdriveAt && streak >= cfg.lockMinStreak) || (previous == S.overdrive && value >= cfg.overdriveHold) {
                s = S.overdrive
            } else if (value >= cfg.lockAt && streak >= cfg.lockMinStreak) || ((previous == S.locked || previous == S.overdrive) && value >= cfg.lockHold) {
                s = S.locked
            } else if value >= cfg.cruiseAt {
                s = S.cruising
            } else {
                s = S.warming
            }
        }
        state[i] = s
        previous = s
    }

    // ---- stretches with Claude ----
    // Only minutes you and Claude are at it count: at Warming up or above, with Claude or you doing
    // something in that minute. Autopilot is Claude alone, and a break in Safari while Claude is idle
    // adds nothing, so a stretch is those minutes, not the time on the clock.
    var stretches: [Double] = []
    var stretchRun = 0
    var lastWorking = -1_000_000
    for m in 0..<N where state[m] >= S.warming && state[m] <= S.overdrive && active[m] > 0 {
        if m - lastWorking >= cfg.stretchGap {
            if stretchRun > 0 { stretches.append(Double(stretchRun)) }
            stretchRun = 0
        }
        stretchRun += 1
        lastWorking = m
    }
    let stretchMin = N - 1 - lastWorking < cfg.stretchGap ? stretchRun : 0
    if stretchMin == 0 && stretchRun > 0 { stretches.append(Double(stretchRun)) }
    let stretchSeen = stretches.filter { $0 >= 30 }.sorted()
    let longStretch = stretchSeen.count >= cfg.stretchSamples
        ? max(cfg.stretchRange.0, min(cfg.stretchRange.1, Int(quantile(stretchSeen, cfg.stretchQuantile).rounded())))
        : cfg.stretchDefault

    /// The state most of the minutes from a up to b were in; asleep only wins outright.
    func dominant(_ a: Int, _ b: Int) -> Int {
        var tally = [Int](repeating: 0, count: stateNames.count)
        for i in a..<b { tally[state[i]] += 1 }
        var best = 0
        for s in 1..<tally.count where tally[s] >= tally[best] && tally[s] > 0 { best = s }
        return best
    }

    // ---- days ----
    struct Day { var t = 0.0, a = 0, b = 0, values: [String: Any] = [:], tokens = 0.0, engaged = 0, active = 0.0, wins = 0.0 }
    var days: [Day] = []
    for d in 0..<cfg.days {
        let t = dayStart(now, d - (cfg.days - 1))
        let a = Int(t / 60000) - startMin
        let b = min(N, Int(dayStart(now, d - (cfg.days - 2)) / 60000) - startMin)
        var locked = 0, engaged = 0, autopilot = 0
        var peak = 0.0
        var levelMin = [Int](repeating: 0, count: stateNames.count)     // minutes in each state
        var strip = ""                                                  // the state of each quarter hour, one digit each
        if a < b {
            for q in stride(from: a, to: b, by: 15) { strip.append(Character(UnicodeScalar(UInt8(48 + dominant(q, min(b, q + 15)))))) }
            for i in a..<b {
                let s = state[i]
                levelMin[s] += 1
                if s == S.locked || s == S.overdrive { locked += 1 }
                if s >= S.warming && s <= S.overdrive { engaged += 1 }
                if s == S.autopilot { autopilot += 1 }
                peak = max(peak, win(pTok, i, cfg.burnWindow))
            }
        }
        var day = Day(t: t, a: a, b: b)
        day.tokens = pTok[b] - pTok[a]
        day.engaged = engaged
        day.active = pActive[b] - pActive[a]
        day.wins = pWins[b] - pWins[a]
        day.values = [
            "wins": day.wins, "handsMin": pHands[b] - pHands[a],
            "t": t, "tokens": day.tokens, "output": pOut[b] - pOut[a], "prompts": pPrompts[b] - pPrompts[a],
            "chars": pChars[b] - pChars[a], "pasted": pPasted[b] - pPasted[a], "tools": pTools[b] - pTools[a],
            "lines": pLines[b] - pLines[a], "activeMin": day.active, "engagedMin": engaged, "lockedMin": locked,
            "autopilotMin": autopilot, "peakPerHour": rounded(peak * 60 / Double(cfg.burnWindow)),
            "levelMin": levelMin, "strip": strip,
        ]
        days.append(day)
    }
    let past = days.dropLast().filter { $0.active >= 20 }
    let minuteOfDay = N - 1 - todayIdx
    let typicalDay = median(past.map { $0.tokens })
    let usualByNow = median(past.map { pTok[min($0.b, $0.a + minuteOfDay + 1)] - pTok[$0.a] })
    let typicalEngaged = median(past.map { Double($0.engaged) })
    // The same, for every quarter hour of the day: the curve a usual day follows.
    let usualCurve = (1...96).map { q in median(past.map { pTok[min($0.b, $0.a + q * 15)] - pTok[$0.a] }) }

    // The level this person usually reaches around this time of day: the middle
    // of the best level hit within half an hour either side, over their working days.
    var reached: [Double] = []
    for day in past {
        var best = 0
        let from = max(day.a, day.a + minuteOfDay - 30)
        let to = min(day.b, day.a + minuteOfDay + 31)
        if from < to {
            for i in from..<to {
                let level = state[i] == S.autopilot ? S.idle : state[i]
                best = max(best, level)
            }
        }
        reached.append(Double(best))
    }
    let usual: Any = reached.count >= 3 ? stateNames[Int(median(reached).rounded(.down))] : NSNull()

    // ---- the daily goal and the streak ----
    // Working days: enough hands-on time to count. Older days (before the window) only help a streak along.
    let workingDays = days.dropLast().filter { $0.active >= Double(cfg.workingDayMin) }
    let auto = workingDays.count >= cfg.goalMinDays ? max(1, Int(median(workingDays.map { $0.wins }).rounded())) : cfg.goalDefault
    let target = goal > 0 ? goal : auto
    let winsToday = days[days.count - 1].wins
    var streak = 0
    var counting = true
    for day in workingDays.reversed() where counting {
        if day.wins >= Double(target) { streak += 1 } else { counting = false }
    }
    if counting {
        for day in before.reversed() where counting && (day["activeMin"] as? Double ?? 0) >= Double(cfg.workingDayMin) {
            if (day["wins"] as? Double ?? 0) >= Double(target) { streak += 1 } else { counting = false }
        }
    }
    let hitToday = winsToday >= Double(target)
    if hitToday { streak += 1 }

    // ---- weekday x hour heatmap, averaged over the weeks on record ----
    var heat = [[Double]](repeating: [Double](repeating: 0, count: 24), count: 7)
    var heatDays = [Double](repeating: 0, count: 7)
    if let firstDay = days.firstIndex(where: { $0.active > 0 }), firstDay < days.count - 1 {
        for d in firstDay..<(days.count - 1) {
            let weekday = Calendar.current.component(.weekday, from: Date(timeIntervalSince1970: days[d].t / 1000)) - 1   // 0 Sunday
            heatDays[weekday] += 1
            for hour in 0..<24 {
                let a = min(days[d].b, days[d].a + hour * 60)
                let b = min(days[d].b, a + 60)
                heat[weekday][hour] += pTok[b] - pTok[a]
            }
        }
        for weekday in 0..<7 {
            for hour in 0..<24 { heat[weekday][hour] = heatDays[weekday] > 0 ? rounded(heat[weekday][hour] / heatDays[weekday]) : 0 }
        }
    }

    // ---- today in 5-minute bins ----
    let step = 5
    let binCount = (minuteOfDay + step) / step
    var binTokens: [Double] = [], binChars: [Double] = [], binPrompts: [Double] = [], binTools: [Double] = [], binState: [Int] = []
    for k in 0..<binCount {
        let a = todayIdx + k * step
        let b = min(N, a + step)
        binTokens.append(pTok[b] - pTok[a])
        binChars.append(pChars[b] - pChars[a])
        binPrompts.append(pPrompts[b] - pPrompts[a])
        binTools.append(pTools[b] - pTools[a])
        binState.append(dominant(a, b))
    }

    // ---- right now ----
    let i = N - 1
    // The current minute is only partly over, so a rate's window is that
    // fraction plus the full minutes before it.
    let part = now.truncatingRemainder(dividingBy: 60000) / 60000
    func rate(_ p: [Double], _ w: Int) -> Double { win(p, i, w) * 60 / (Double(w - 1) + part) }
    let burnNow = win(pTok, i, cfg.burnWindow), typeNow = win(pChars, i, cfg.typeWindow), actNow = win(pActs, i, cfg.actWindow)
    let s = state[i]
    let I = Double(intensity[i])
    var lockedRun = 0
    var k = i
    while k >= 0, state[k] == S.locked || state[k] == S.overdrive {
        lockedRun += 1
        k -= 1
    }
    var sessionsNow = 0, agentsNow = 0
    for m in max(0, i - 2)...i {
        sessionsNow = max(sessionsNow, sessions[m])
        agentsNow = max(agentsNow, agents[m])
    }
    let idleMin = min(i - lastActive, 1_000_000)
    let streakMin = active[i] > 0 || idleMin < cfg.streakGap ? i - streakStart : 0

    // How hard the fire burns: the last five minutes of tokens against the baseline.
    let flamePct = pBurn(rate(pTok, 5) / 60 * Double(cfg.burnWindow))
    let flame = win(pTok, i, 3) > 0 ? 0.12 + 0.88 * pow(flamePct / 100, 1.3) : (idleMin < cfg.asleepAfter ? 0.04 : 0)

    // What it takes to climb one level from here.
    var next: Any = NSNull()
    if s >= S.warming && s < topLevel {
        let floors = [S.warming: 0.0, S.cruising: cfg.cruiseAt, S.locked: cfg.lockAt, S.overdrive: cfg.overdriveAt]
        let from = floors[s]!, to = floors[s + 1]!
        next = [
            "state": stateNames[s + 1], "intensity": to,
            "progress": max(0, min(1, (I - from) / (to - from))),
            // Lock-in also needs unbroken work; say how much is still missing.
            "streakLeftMin": s + 1 >= S.locked ? max(0, cfg.lockMinStreak - streakMin) : 0,
        ] as [String: Any]
    }

    func perHour(_ v: Double, _ w: Int) -> Double { rounded(v * 60 / Double(w)) }
    func family(_ values: [Double]) -> [[String: Any]] {
        zip(modelFamilies, values).filter { $0.1 > 0 }.map { ["name": $0.0, "tokens": $0.1] }
    }
    func top(_ totals: [String: Double]) -> [[String: Any]] {
        // biggest first; equal totals keep the order they were found in
        projectOrder.filter { (totals[$0] ?? 0) > 0 }.enumerated()
            .sorted { totals[$0.element]! != totals[$1.element]! ? totals[$0.element]! > totals[$1.element]! : $0.offset < $1.offset }
            .map { ["name": $0.element, "tokens": totals[$0.element]!] }
    }
    func signal(_ value: Double, _ window: Int, _ pct: Double) -> [String: Any] { ["perHour": perHour(value, window), "pct": rounded(pct)] }
    func marks(_ sorted: [Double], _ window: Int) -> [Double] { [0.5, 0.75, 0.9].map { perHour(quantile(sorted, $0), window) } }

    var today = days[days.count - 1].values
    today["split"] = ["input": split[0], "output": split[1], "cacheWrite": split[2], "cacheRead": split[3], "thinking": split[4], "calls": split[5]]
    today["typicalDay"] = typicalDay
    today["usualByNow"] = usualByNow
    today["typicalEngaged"] = rounded(typicalEngaged)
    today["usualCurve"] = usualCurve
    today["usualDays"] = past.count
    today["bins"] = ["start": today0, "step": step, "tokens": binTokens, "chars": binChars, "prompts": binPrompts, "tools": binTools, "state": binState] as [String: Any]
    today["models"] = family(familyToday)
    today["projects"] = top(projectToday)
    today["sessions"] = sessionsToday.count
    today["winKinds"] = ["greens": winKinds[0], "commits": winKinds[1], "prs": winKinds[2], "plans": winKinds[3]]

    return [
        "now": now,
        "live": [
            "state": stateNames[s],
            "level": s == S.autopilot ? NSNull() : s as Any,
            "topLevel": topLevel,
            "next": next,
            "usual": usual,
            "intensity": rounded(I),
            "hotterThan": calibrated ? rounded(I) as Any : NSNull(),
            "tokensPerHour": rounded(rate(pTok, 10)),
            "outputPerHour": rounded(rate(pOut, 10)),
            "lastHourTokens": win(pTok, i, 60),
            "flame": rounded(flame * 1e4) / 1e4,
            "idleMin": idleMin,
            "humanIdleMin": min(i - lastHuman, 1_000_000),
            "streakMin": streakMin,
            "stretchMin": stretchMin,
            "lockedRunMin": lockedRun,
            "sessions": sessionsNow,
            "agents": agentsNow,
            "lastCallMs": lastCallMs,
            "lastPromptMs": lastPromptMs,
            "signals": [
                "burn": signal(burnNow, cfg.burnWindow, pBurn(burnNow)),
                "typing": signal(typeNow, cfg.typeWindow, pType(typeNow)),
                "actions": signal(actNow, cfg.actWindow, pActn(actNow)),
            ],
        ] as [String: Any],
        "today": today,
        "goal": [
            "wins": winsToday, "target": target, "auto": goal <= 0, "suggested": auto,
            "streak": streak, "hitToday": hitToday, "workingDays": workingDays.count,
        ] as [String: Any],
        "baseline": [
            "calibrated": calibrated,
            "activeMinutes": n,
            "needMinutes": cfg.minWindows,
            "daysOnRecord": days.filter { $0.active > 0 }.count,
            "windowDays": cfg.days,
            "burn": marks(burnSamples, cfg.burnWindow),
            "typing": marks(typeSamples, cfg.typeWindow),
            "actions": marks(actSamples, cfg.actWindow),
            "thresholds": ["cruise": cfg.cruiseAt, "lock": cfg.lockAt, "overdrive": cfg.overdriveAt],
            "lockMinStreak": cfg.lockMinStreak,
            "autopilotAfter": autopilotAfter,
            "autopilotLearned": autopilotLearned,
            "promptGapsSeen": gaps.count,
            "longStretch": longStretch,
        ] as [String: Any],
        "history": [
            "days": days.map { $0.values },
            "heat": heat,
            "models": family(familyWeek),
            "projects": top(projectWeek),
            "projectsMonth": top(projectMonth),
        ] as [String: Any],
    ]
}

/// The days before the calibration window, oldest first, and tokens by project
/// over all time. Each stretch of older days is judged the way it was at the
/// time: against the 30 days that ended with it. Old days do not change, so
/// this is worked out once a day rather than every few seconds.
func olderHistory(files: [LogFile], now: Double, config cfg: Config = Config()) -> [String: Any] {
    var earliest = Int.max
    var totals: [String: Double] = [:]
    for file in files {
        var sum = 0.0
        for (minute, v) in file.minutes {
            if minute < earliest { earliest = minute }
            sum += totalTokens(v)
        }
        if sum > 0 { totals[file.project.isEmpty ? "unknown" : file.project, default: 0] += sum }
    }
    var days: [[String: Any]] = []
    if earliest != Int.max {
        let firstDay = dayStart(Double(earliest) * 60000)
        var end = dayStart(now, -(cfg.days - 1))        // where the live window begins
        while end > firstDay {
            let stretch = analyze(files: files, lastCallMs: 0, lastPromptMs: 0, now: end - 1, config: cfg)
            let found = ((stretch["history"] as? [String: Any])?["days"] as? [[String: Any]]) ?? []
            days.insert(contentsOf: found.filter { ($0["t"] as? Double ?? 0) >= firstDay }.map { day in
                var day = day
                day["strip"] = nil
                return day
            }, at: 0)
            end = dayStart(end - 1, -(cfg.days - 1))
        }
    }
    let projects = totals.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        .map { ["name": $0.key, "tokens": $0.value] as [String: Any] }
    return ["days": days, "projects": projects]
}
