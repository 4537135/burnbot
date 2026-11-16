// Feeds the desk screen: a small board with a display, plugged in by USB, that
// shows the robot and the level (see desk/). The app sends it one line a
// second; the board draws and animates by itself.
//
// The board appears as a serial port (/dev/cu.usbmodem…). A board that runs
// another program, or none, is left alone.

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
    var log: (String) -> Void = { _ in }

    var status: [String: Any] {
        ["state": state, "port": port ?? NSNull(), "program": program ?? NSNull(), "answering": Date().timeIntervalSince1970 - heardAt < 5]
    }

    private func ports() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []).filter { $0.hasPrefix("cu.usbmodem") }.sorted().map { "/dev/" + $0 }
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
            for line in heard.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
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
    func send(_ line: String) {
        let now = Date().timeIntervalSince1970
        if fd < 0 {
            if now - lookedAt < retryAfter { return }
            lookedAt = now
            connect()
            if fd < 0 { return }
        }
        pending += drain(fd)
        if pending.contains("OK") { heardAt = now }
        if let match = pending.range(of: "Q\\|o=[0-9]", options: .regularExpression) { rotation = Int(String(pending[match].last!)) ?? rotation }
        pending = String(pending.suffix(64))
        if !write(fd, line + "\n") {
            disconnect()
            lookedAt = 0
            return set("absent")
        }
        if now - heardAt > 8 {
            disconnect()
            set("silent", port)
        }
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
func deskLine(_ state: [String: Any], names: [String: String]) -> String {
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
    ].joined(separator: "|")
}
