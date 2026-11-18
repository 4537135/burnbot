// Serves the app's screens (the files in public/) to its own windows, under
// burnbot://app/. Nothing is served over the network.

import Foundation
import WebKit

final class Pages: NSObject, WKURLSchemeHandler {
    static let scheme = "burnbot"
    static let home = "burnbot://app/"

    /// Where the screens live: inside the app, or a folder given with --pages
    /// so they can be edited and reloaded (⌘R) without rebuilding.
    let folder: URL

    init(folder: URL) {
        self.folder = folder
    }

    private static let types = [
        "html": "text/html", "js": "text/javascript", "css": "text/css", "json": "application/json",
        "png": "image/png", "jpg": "image/jpeg", "svg": "image/svg+xml",
    ]

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        if !path.contains(".") { path += ".html" }        // /display, /companion
        let file = folder.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
        // only files inside the folder
        guard file.path.hasPrefix(folder.standardizedFileURL.path + "/"), let data = try? Data(contentsOf: file) else {
            let missing = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])!
            task.didReceive(missing)
            task.didReceive(Data("Not found".utf8))
            task.didFinish()
            return
        }
        let type = Pages.types[file.pathExtension] ?? "application/octet-stream"
        let headers = ["Content-Type": type + (type.hasPrefix("text/") ? "; charset=utf-8" : ""), "Cache-Control": "no-store"]
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
