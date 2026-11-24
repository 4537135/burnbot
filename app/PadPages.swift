// The Claude Pad's Usage and Today pages (firmware 6 and later): the U and D lines.
//
// Usage comes from Claude Code's status line. Claude Code runs status.sh (ClaudeHooks) with what
// it knows as JSON: status.json keeps the latest, and rates.json the latest that carried the plan's
// usage (rate_limits, only there for Pro and Max, once Claude has replied). Today comes from
// analyze() (Metrics.swift), like the dashboard's.
import Foundation

/// Text the pad can draw: capitals, its own letters, single spaces, at most `limit` long.
func padText(_ text: String, _ limit: Int) -> String {
    let letters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -.,!%/:+&\"()?=_*#;<>@$[]~")
    var out = ""
    for c in text.uppercased() {
        let mapped: Character = c == "|" ? "/" : c == "'" || c == "`" ? "\"" : c == "{" ? "(" : c == "}" ? ")" : c
        let next: Character = letters.contains(mapped) ? mapped : " "
        if next == " " && out.last == " " { continue }
        out.append(next)
    }
    return String(out.trimmingCharacters(in: .whitespaces).prefix(limit))
}

/// "4H 20M", "25M".
func padDuration(minutes: Int) -> String {
    let m = max(0, minutes)
    return m >= 60 ? "\(m / 60)H \(m % 60)M" : "\(m)M"
}

/// Tokens, short: "71M", "12.4K".
func padTokens(_ n: Double) -> String {
    if n >= 1e9 { return String(format: "%.1fB", n / 1e9) }
    if n >= 1e6 { return String(format: n >= 1e7 ? "%.0fM" : "%.1fM", n / 1e6) }
    if n >= 1e3 { return String(format: n >= 1e4 ? "%.0fK" : "%.1fK", n / 1e3) }
    return String(Int(n.rounded()))
}

/// When a limit resets, as the pad says it after "RESETS ": "IN 2H 10M" within a day, else "TUE 09:00".
func padResets(_ at: Double, now: Double) -> String {
    let left = at - now
    if left < 86_400 { return "IN " + padDuration(minutes: Int((left / 60).rounded(.up))) }
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.dateFormat = "EEE HH:mm"
    return format.string(from: Date(timeIntervalSince1970: at)).uppercased()
}

private func readJSON(_ path: String) -> (object: [String: Any], modified: Double)? {
    guard let data = FileManager.default.contents(atPath: path),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date else { return nil }
    return (object, modified.timeIntervalSince1970)
}

/// The U line: h/hr the 5-hour limit and when it resets, w/wr the weekly one, x/xn how full the
/// latest session's context is and its project, ag minutes since Claude Code last reported usage.
/// A field with nothing known is left out, so the pad says so. `now`: seconds.
func usageLine(dataFolder: String, now: Double) -> String {
    var fields = ["U"]
    func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
    if let (rates, modified) = readJSON(dataFolder + "/rates.json"),
       let limits = rates["rate_limits"] as? [String: Any] {
        var any = false
        for (key, label) in [("five_hour", "h"), ("seven_day", "w")] {
            guard let limit = limits[key] as? [String: Any], let used = number(limit["used_percentage"]) else { continue }
            let resets = number(limit["resets_at"]) ?? 0
            if resets > 0 && resets <= now { continue }         // that window is over: nothing known yet
            fields.append("\(label)=\(Int(used.rounded()))")
            if resets > 0 { fields.append("\(label)r=" + padResets(resets, now: now)) }
            any = true
        }
        if any { fields.append("ag=\(max(0, Int((now - modified) / 60)))") }
    }
    if let (status, modified) = readJSON(dataFolder + "/status.json"), now - modified < 12 * 3600,
       let used = number((status["context_window"] as? [String: Any])?["used_percentage"]) {
        fields.append("x=\(Int(used.rounded()))")
        let workspace = status["workspace"] as? [String: Any]
        let folder = workspace?["project_dir"] as? String ?? workspace?["current_dir"] as? String ?? status["cwd"] as? String ?? ""
        let name = padText((folder as NSString).lastPathComponent, 18)
        if !name.isEmpty { fields.append("xn=" + name) }
    }
    return fields.joined(separator: "|")
}

/// The D line: b today's tokens per hour as 24 bars (0-99, the busiest hour 99), fm focus time
/// (minutes at Warming up or above), ss sessions today, pk the peak burn against your usual one.
func todayLine(_ state: [String: Any]) -> String {
    guard let today = state["today"] as? [String: Any] else { return "" }
    func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
    var hours = [Double](repeating: 0, count: 24)
    if let bins = today["bins"] as? [String: Any], let tokens = bins["tokens"] as? [NSNumber] {
        let start = number(bins["start"]), step = max(1, number(bins["step"]))
        for (k, value) in tokens.enumerated() where value.doubleValue > 0 {
            let at = Date(timeIntervalSince1970: (start + Double(k) * step * 60_000) / 1000)
            hours[Calendar.current.component(.hour, from: at)] += value.doubleValue
        }
    }
    let most = hours.max() ?? 0
    let bars = hours.map { $0 <= 0 || most <= 0 ? 0 : max(1, Int(($0 / most * 99).rounded())) }
    var fields = ["D", "b=" + bars.map(String.init).joined(separator: ",")]
    fields.append("fm=" + padDuration(minutes: Int(number(today["engagedMin"]).rounded())))
    if let sessions = today["sessions"] as? NSNumber { fields.append("ss=\(sessions.intValue)") }
    let peak = number(today["peakPerHour"])
    let usual = ((state["baseline"] as? [String: Any])?["burn"] as? [NSNumber])?.first?.doubleValue ?? 0
    if peak > 0 {
        let times = peak / max(usual, 1)
        fields.append("pk=" + (usual > 0 ? String(format: times >= 10 ? "%.0fX" : "%.1fX", times) : padTokens(peak) + "/H"))
    }
    return fields.joined(separator: "|")
}
