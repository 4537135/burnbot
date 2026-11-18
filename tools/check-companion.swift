// tools/check-companion.sh builds this with app/Companion.swift and app/Pages.swift: the real desktop
// robot and its page, on screen for a few seconds, checked for one thing. A page that is hidden stops
// running, so it cannot say it is no longer being looked at; hiding the robot while its head is open
// or its panel is up must let go of the bubbles held back for you, and the robot must come back at rest.

import Cocoa
import WebKit

func log(_ message: String) {}

final class Check: NSObject, WKScriptMessageHandler {
    var messages: [[String: Any]] = []
    var companion: Companion!
    var hidden = 0
    var failures = 0

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        messages.append(body)
        if body["type"] as? String == "where" { companion.tellPlace() }
        if body["type"] as? String == "error" { fail("page error: \(body["text"] ?? "")") }
    }

    func busy() -> Bool? { messages.last(where: { $0["type"] as? String == "busy" })?["on"] as? Bool }

    func fail(_ text: String) { failures += 1; print("FAIL  \(text)") }
    func ok(_ text: String) { print("ok    \(text)") }
    func expect(_ condition: Bool, _ text: String) { condition ? ok(text) : fail(text) }

    func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    func page(_ script: String) -> Any? {
        var result: Any?
        var done = false
        companion.view.evaluateJavaScript(script) { value, _ in result = value; done = true }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return result
    }

    func run(pages: URL) -> Int32 {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(Pages(folder: pages), forURLScheme: Pages.scheme)
        configuration.userContentController.add(self, name: "burnbot")
        let report = "window.addEventListener('error', (e) => webkit.messageHandlers.burnbot.postMessage({ type: 'error', text: e.message }));"
        configuration.userContentController.addUserScript(WKUserScript(source: report, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = FirstClickWebView(frame: .zero, configuration: configuration)
        companion = Companion(view: view, remember: false)
        companion.onHide = { [unowned self] in self.hidden += 1 }
        view.load(URLRequest(url: URL(string: Pages.home + "companion")!))
        companion.show(on: NSScreen.main, onTop: true)
        wait(2)

        // 1. Its head open (as when you rest the pointer on it), then hidden.
        if let box = page("JSON.stringify(window.burnbot.robotBox())") as? String,
           let r = try? JSONSerialization.jsonObject(with: Data(box.utf8)) as? [String: Double],
           let x = r["x"], let y = r["y"], let w = r["w"], let h = r["h"] {
            _ = page("window.burnbotPointer(\(x + w / 2), \(y + h * 0.3))")
        } else { fail("the page did not say where the robot is") }
        wait(1)
        expect(busy() == true, "pointing at the robot holds bubbles back")
        companion.hide()
        wait(0.5)
        expect(hidden == 1, "hiding it lets go of them (the app is told)")
        expect(page("document.hidden") as? Bool == true, "hidden, its page knows it is hidden (so it stops drawing)")

        // 2. Back on the desktop: at rest, holding nothing back.
        let before = messages.count
        companion.show(on: NSScreen.main, onTop: true)
        wait(1.5)
        let after = messages[before...].filter { $0["type"] as? String == "busy" }
        expect(!after.contains { $0["on"] as? Bool == true }, "back on the desktop, it holds nothing back")
        expect(page("document.getElementById('sTitle').classList.contains('on')") as? Bool == false, "and its head is a face again")
        expect(page("document.hidden") as? Bool == false, "and it is drawing again")

        // 3. Its panel open, then sent away (as to the second screen: the same hide).
        _ = page("window.burnbot.setPanel(true)")
        wait(0.5)
        expect(busy() == true, "reading its panel holds bubbles back")
        companion.hide()
        wait(0.5)
        expect(hidden == 2, "sending it away lets go of them")
        expect(messages.last(where: { $0["type"] as? String == "panel" })?["open"] as? Bool == false, "its panel is closed")
        let again = messages.count
        companion.show(on: NSScreen.main, onTop: true)
        wait(1.5)
        expect(page("document.getElementById('panel').classList.contains('on')") as? Bool == false, "back on the desktop, its panel stays closed")
        expect(!messages[again...].contains { $0["type"] as? String == "busy" && $0["on"] as? Bool == true }, "and it holds nothing back")

        companion.hide()
        return failures == 0 ? 0 : 1
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let pages = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "public")
// Inside the app's own run loop: a page in a window that has not reached the screen never draws.
RunLoop.main.add(Timer(timeInterval: 0.1, repeats: false) { _ in exit(Check().run(pages: pages)) }, forMode: .common)
app.run()
