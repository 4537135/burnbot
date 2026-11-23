// Feeds the desk screen: a small board with a display, plugged in by USB, that
// shows the robot and the level (see desk/). The app sends it one line a
// second; the board draws and animates by itself.
//
// The board appears as a serial port (/dev/cu.usbmodem… for the XIAO,
// /dev/cu.usbserial-… for an ESP32). A board that runs another program, or
// none, is left alone.

import Foundation

final class DeskScreen {
    private var fd: Int32 = -1
    private var lookedAt = 0.0
    private var heardAt = 0.0
    private var retryAfter = 4.0            // seconds between looks for a board; grows while a port stays silent
    private var silentPort = ""
    private var pending = ""
    private var rotation = 0                // which way up the board draws: 0 or 2 (it remembers this itself)
    private(set) var state = "absent"       // absent, connected, other (another program), silent (a port that does not answer)
    private(set) var port: String?
    private(set) var program: String?
    private var said = ""                   // the last M line sent (what the robot is saying)
    private var saidAt = 0.0
    private(set) var feelsKnocks = false    // the board has a motion sensor and it answered ("k=1")
    private(set) var sensitivity = 1        // how hard a knock has to be, as the board keeps it: 0 light, 1 medium, 2 firm
    var log: (String) -> Void = { _ in }
    /// Someone knocked twice on the case (called on the engine's queue).
    var onKnock: (() -> Void)?

    /// The board's program can show the robot's faces and speech bubbles: "BURNBOT 2" or later.
    /// One on "BURNBOT 1" still shows the levels, and the dashboard says its program is out of date.
    var speaks: Bool { state == "connected" && version >= 2 }
    /// "BURNBOT 3" and later report knocks, when the board has the sensor for it.
    var knocks: Bool { state == "connected" && version >= 3 && feelsKnocks }
    private var version: Int { program.flatMap { Int($0.split(separator: " ").last ?? "") } ?? 0 }
    static let current = 3                  // the program in desk/burnbot_screen

    var status: [String: Any] {
        ["state": state, "port": port ?? NSNull(), "program": program ?? NSNull(), "answering": Date().timeIntervalSince1970 - heardAt < 5,
         "outdated": state == "connected" && version < DeskScreen.current, "knocks": knocks, "sensitivity": sensitivity]
    }

    /// The XIAO shows up as cu.usbmodem…; an ESP32 board as its USB chip names it
    /// (cu.usbserial-… for a CP2102 or CH340, cu.SLAB_USBtoUART or cu.wchusbserial… with their makers' drivers).
    private static let portNames = ["cu.usbmodem", "cu.usbserial", "cu.SLAB_USBtoUART", "cu.wchusbserial"]

    private func ports() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? [])
            .filter { name in DeskScreen.portNames.contains { name.hasPrefix($0) } }.sorted().map { "/dev/" + $0 }
    }

    /// Opens a port for plain lines at 115200. Never 1200: that speed tells these boards to wait for a new program.
    private func open(_ path: String) -> Int32 {
        let descriptor = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else { return -1 }
        var options = termios()
        tcgetattr(descriptor, &options)
        cfmakeraw(&options)
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        cfsetspeed(&options, speed_t(B115200))
        tcsetattr(descriptor, TCSANOW, &options)
        return descriptor
    }

    /// Everything the board has said since the last look, without waiting.
    private func drain(_ descriptor: Int32) -> String {
        var text = ""
        var buffer = [UInt8](repeating: 0, count: 512)
        while true {
            let n = read(descriptor, &buffer, buffer.count)
            if n <= 0 { break }
            text += String(decoding: buffer[0..<n], as: UTF8.self)
        }
        return text
    }

    /// false means the board is gone; a busy board (it is drawing) counts as sent.
    private func write(_ descriptor: Int32, _ text: String) -> Bool {
        let bytes = Array(text.utf8)
        let n = Darwin.write(descriptor, bytes, bytes.count)
        return n >= 0 || errno == EAGAIN
    }

    /// Asks a port which program its board runs: "BURNBOT 1", "FOOOCUS 2", or "" for silence.
    private func ask(_ path: String) -> String {
        let descriptor = open(path)
        guard descriptor >= 0 else { return "" }
        defer { close(descriptor) }
        _ = drain(descriptor)
        guard write(descriptor, "\nV\n") else { return "" }
        var heard = ""
        for _ in 0..<15 {
            usleep(100_000)
            heard += drain(descriptor)
            // isNewline, not == "\n": in Swift "\r\n" is one Character, and println ends lines with it.
            for line in heard.split(whereSeparator: { $0.isNewline }) {
                let answer = line.trimmingCharacters(in: .whitespaces)
                if answer.range(of: "^[A-Z]+ [0-9]+$", options: .regularExpression) != nil { return answer }
            }
        }
        return ""
    }

    private func set(_ newState: String, _ newPort: String? = nil, _ newProgram: String? = nil) {
        let changed = newState != state || newPort != port || newProgram != program
        state = newState
        port = newPort
        program = newProgram
        guard changed else { return }
        switch newState {
        case "connected": log("Desk screen connected on \(newPort ?? "?") (\(newProgram ?? "?"))")
        case "other": log("The board on \(newPort ?? "?") runs \(newProgram ?? "?"), not Burnbot's screen program")
        case "absent": log("Desk screen unplugged")
        default: break
        }
    }

    private func disconnect() {
        if fd >= 0 { close(fd) }
        fd = -1
        said = ""
        pending = ""
        feelsKnocks = false
    }

    private func connect() {
        let found = ports()
        guard !found.isEmpty else {
            retryAfter = 4
            silentPort = ""
            return set("absent")
        }
        for path in found {
            let answer = ask(path)
            if answer.hasPrefix("BURNBOT") {
                fd = open(path)
                guard fd >= 0 else { continue }
                heardAt = Date().timeIntervalSince1970
                pending = ""
                retryAfter = 4
                _ = write(fd, "Q\n")        // ask which way up it is
                return set("connected", path, answer)
            } else if !answer.isEmpty {
                retryAfter = 10
                return set("other", path, answer)
            }
        }
        // A silent board may be waiting for a new program. Ask less and less
        // often, so an upload in progress is not disturbed.
        retryAfter = silentPort == found[0] ? min(60, retryAfter * 2) : 4
        silentPort = found[0]
        set("silent", found[0])
    }

    /// Call once a second with the line to show. Finds the board, sends, and notices when it is unplugged.
    /// `moment`: the M line, for a board that speaks. It goes when it changes and again every
    /// few seconds, so a board that restarted, or missed it, catches up.
    func send(_ line: String, moment: String? = nil) {
        let now = Date().timeIntervalSince1970
        if fd < 0 {
            if now - lookedAt < retryAfter { return }
            lookedAt = now
            connect()
            if fd < 0 { return }
        }
        // What the board said, a whole line at a time; a part line waits for the rest.
        pending += drain(fd)
        var lines = pending.components(separatedBy: "\n")
        pending = String((lines.removeLast()).suffix(200))
        for raw in lines {
            let reply = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if reply == "OK" { heardAt = now }
            else if reply == "K" { heardAt = now; onKnock?() }
            else if reply.hasPrefix("Q|") {
                heardAt = now
                for field in reply.split(separator: "|").dropFirst() {
                    let pair = field.split(separator: "=", maxSplits: 1)
                    guard pair.count == 2, let value = Int(pair[1]) else { continue }
                    switch pair[0] {
                    case "o": rotation = value
                    case "k": feelsKnocks = value == 1
                    case "n": sensitivity = value
                    default: break
                    }
                }
            }
        }
        var out = line + "\n"
        if speaks, let moment, moment != said || now - saidAt >= 5 {
            out += moment + "\n"
            said = moment
            saidAt = now
        }
        if !write(fd, out) {
            disconnect()
            lookedAt = 0
            return set("absent")
        }
        if now - heardAt > 8 {
            disconnect()
            set("silent", port)
        }
    }

    /// How hard a knock has to be: 0 light, 1 medium, 2 firm. The board remembers it.
    func setSensitivity(_ level: Int) {
        guard fd >= 0, version >= 3, (0...2).contains(level), write(fd, "S\(level)\nQ\n") else { return }
        sensitivity = level
    }

    /// Turns the picture the other way up, for a screen mounted with its pins at the top.
    @discardableResult
    func flip() -> Bool {
        guard fd >= 0 else { return false }
        let next = rotation == 2 ? 0 : 2
        guard write(fd, "O\(next)\n") else { return false }
        rotation = next
        return true
    }

    func shutDown() { disconnect() }
}

/// The line for the board, from the app's state. `names` maps a state to what it is called on screen.
/// `expr`: the robot's reaction (worried, happy, waiting), for a board that speaks; "" for none.
func deskLine(_ state: [String: Any], names: [String: String], expr: String = "") -> String {
    guard let live = state["live"] as? [String: Any] else { return "" }
    func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
    func clean(_ text: String) -> String {
        String(text.uppercased().filter { "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,!%/:+-".contains($0) }.prefix(18))
    }
    func tokens(_ n: Double) -> String {
        if n >= 1e9 { return String(format: "%.2fB", n / 1e9) }
        if n >= 1e6 { return String(format: n >= 1e8 ? "%.0fM" : n >= 1e7 ? "%.1fM" : "%.2fM", n / 1e6) }
        if n >= 1e4 { return String(format: n >= 1e5 ? "%.0fK" : "%.1fK", n / 1e3) }
        return String(Int(n.rounded()))
    }
    let name = live["state"] as? String ?? "asleep"
    let level = live["level"] is NSNull ? -1 : int(live["level"])
    let top = int(live["topLevel"])
    let usual = (live["usual"] as? String).flatMap { stateNames.firstIndex(of: $0) } ?? -1
    let cuts = (state["baseline"] as? [String: Any])?["thresholds"] as? [String: Any] ?? [:]
    let clock = Calendar.current.dateComponents([.hour, .minute], from: Date())
    // Today's wins against the goal, and the streak; boards before 3 ignore keys they do not know.
    var goal = ""
    if let g = state["goal"] as? [String: Any], int(g["target"]) > 0 {
        goal = "|gl=\(int(g["wins"]))/\(int(g["target"]))|sk=\(int(g["streak"]))"
    }
    return [
        "B",
        "s=\(stateNames.firstIndex(of: name) ?? 0)",
        "lv=\(level)",
        "tp=\(top)",
        "u=\(usual)",
        "i=\(int(live["intensity"]))",
        "f=\(Int((((live["flame"] as? NSNumber)?.doubleValue ?? 0) * 100).rounded()))",
        "c=\(int(cuts["cruise"])),\(int(cuts["lock"])),\(int(cuts["overdrive"]))",
        "nm=\(clean(names[name] ?? name))",
        "cp=\(level < 0 ? "OFF LADDER" : "LEVEL \(level) OF \(top)")",
        "rt=\(tokens((live["tokensPerHour"] as? NSNumber)?.doubleValue ?? 0))",
        String(format: "tm=%02d:%02d", clock.hour ?? 0, clock.minute ?? 0),
    ].joined(separator: "|") + goal
        + (expr.isEmpty ? "" : "|ex=" + (deskFace(expr).isEmpty ? "-" : deskFace(expr)))
}

/// The desk's letter for a reaction ("ex=" in the B line), or "" for the level's own face. The desk
/// draws five faces: worried, happy, waiting, puzzled, bored. A cheer and a wave are its happy face;
/// a small smile and a tired face are its level face.
func deskFace(_ expr: String) -> String {
    ["worried": "w", "happy": "h", "cheer": "h", "wave": "h", "waiting": "a", "puzzled": "p", "bored": "d"][expr] ?? ""
}

/// What the robot is saying, as the desk draws it: capitals, the board's own letters, the words
/// wrapped to its 18 columns and four rows. A long first line (a session's name) gets two rows and
/// "..", so the rest still shows; later lines that do not fit are left off whole, so the bubble
/// never ends mid-thought. "M|" when it is saying nothing.
func deskMoment(_ card: Card?) -> String {
    guard let card else { return "M|" }
    func clean(_ text: String) -> String {
        var swapped = text
        for (from, to) in [("·", "-"), ("…", "..."), ("—", "-"), ("–", "-"), ("’", "'"), ("‘", "'"), ("“", "\""), ("”", "\""), ("→", "-")] {
            swapped = swapped.replacingOccurrences(of: from, with: to)
        }
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,!%/:+-&'\"()?=_*#;<>@$[]~"
        return String(swapped.uppercased().filter { letters.contains($0) })
    }
    func wrap(_ text: String) -> [String] {
        var rows: [String] = [], row = ""
        for word in clean(text).split(separator: " ").map({ String($0.prefix(18)) }) {
            if row.isEmpty { row = word } else if row.count + 1 + word.count <= 18 { row += " " + word } else { rows.append(row); row = word }
        }
        return row.isEmpty ? rows : rows + [row]
    }
    func cut(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        let start = String(text.prefix(limit - 2))
        let words = start.contains(" ") ? String(start[..<start.lastIndex(of: " ")!]) : start
        return words + ".."
    }
    var rows: [String] = [], head = 0
    for (i, line) in card.lines.enumerated() {
        var wrapped = wrap(line)
        if i == 0, wrapped.count > 2, card.lines.count > 1 { wrapped = [wrapped[0], cut(wrapped[1...].joined(separator: " "), 18)] }
        if rows.count + wrapped.count > 4 {
            if i == 0 { rows = Array(wrapped.prefix(4)); head = rows.count }
            break
        }
        rows += wrapped
        if i == 0 { head = wrapped.count }
    }
    let kind = ["waiting": "w", "breakthrough": "b", "your-move": "m", "done": "d", "loop": "l", "drift": "r"][card.kind] ?? "m"
    var fields = ["M", "k=\(kind)", "h=\(max(1, head))", "t=" + cut(clean(card.title), 19)]
    for (i, row) in rows.enumerated() { fields.append("\(["a", "b", "c", "d"][i])=\(row)") }
    return fields.joined(separator: "|")
}
