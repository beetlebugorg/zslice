//! PrinterLink: sends G-code to a printer, tests the connection, and asks
//! a printer for an API key (web/app/link.js, linux/src/net/printer-link.c).
//!
//! printdeck and OctoPrint: the OctoPrint API, POST /api/files/local.
//! Moonraker (Klipper): POST /server/files/upload. Both take a multipart
//! form with the file and print=true or false, and the API key in
//! X-Api-Key.
//!
//! A printdeck with a certificate has an https address too
//! (https://<name>.d.printdeck.beetlebug.org). The app tries it first, so
//! the API key does not travel in clear text. A network failure there (a
//! router that blocks public names of local addresses, a TLS failure, a
//! time-out) goes on to the http address with no error. An answer of the
//! printer, of any status, ends it.
//!
//! Get a Key: the App Keys flow of OctoPrint (printdeck and OctoPrint).
//! The printer asks its user "Allow zslice?" (on the touch screen of a
//! printdeck, in the web page of OctoPrint), and the app gets a key of its
//! own after "Allow". The printer keeps a request for 2 minutes.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

struct LinkResult {
    var ok: Bool
    var message: String
    var key: String?
}

enum PrinterLink {
    /// The address that answered last for each printer, in this session.
    @MainActor private static var worked: [UUID: String] = [:]

    /// The addresses to try, best first: the one that answered last, the
    /// https address, then the http address.
    @MainActor private static func addresses(_ p: Printer) -> [String] {
        var out: [String] = []
        for u in [worked[p.id] ?? "", p.https, p.url] where !u.isEmpty && !out.contains(u) { out.append(u) }
        return out
    }

    private static func url(_ base: String, _ path: String) -> URL? {
        var b = base.trimmingCharacters(in: .whitespaces)
        if !b.contains("://") { b = "http://" + b }
        while b.hasSuffix("/") { b.removeLast() }
        return URL(string: b + path)
    }

    /// A request of `path` on the printer: each address in turn.
    @MainActor private static func request(_ p: Printer, _ path: String, method: String = "GET", body: Data? = nil,
                                contentType: String? = nil, key: Bool = true) async throws -> (Data, HTTPURLResponse) {
        let list = addresses(p)
        var last: Error = URLError(.badURL)
        for (k, base) in list.enumerated() {
            guard let u = url(base, path) else { continue }
            var r = URLRequest(url: u)
            r.httpMethod = method
            r.httpBody = body
            r.cachePolicy = .reloadIgnoringLocalCacheData
            // A short wait for an address with a next one to try.
            r.timeoutInterval = k < list.count - 1 ? 4 : 120
            if let contentType { r.setValue(contentType, forHTTPHeaderField: "Content-Type") }
            if key, !p.apiKey.isEmpty { r.setValue(p.apiKey, forHTTPHeaderField: "X-Api-Key") }
            do {
                let (d, resp) = try await URLSession.shared.data(for: r)
                if let h = resp as? HTTPURLResponse {
                    worked[p.id] = base
                    return (d, h)
                }
            } catch {
                last = error
            }
        }
        throw last
    }

    private static func explain(_ e: Error) -> String {
        "The printer did not answer (\(e.localizedDescription)). Check the address, and that the printer is on."
    }

    /// Sends the G-code as `filename`; print: start the print.
    @MainActor static func send(_ p: Printer, filename: String, gcode: Data, print: Bool) async -> LinkResult {
        guard p.kind != .none, !(p.url.isEmpty && p.https.isEmpty) else { return LinkResult(ok: false, message: "This printer has no connection.") }
        let boundary = "zslice-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(gcode)
        body.append(Data("\r\n".utf8))
        field("print", print ? "true" : "false")
        body.append(Data("--\(boundary)--\r\n".utf8))
        let path = p.kind == .moonraker ? "/server/files/upload" : "/api/files/local"
        do {
            let (d, r) = try await request(p, path, method: "POST", body: body, contentType: "multipart/form-data; boundary=\(boundary)")
            if r.statusCode == 401 || r.statusCode == 403 { return LinkResult(ok: false, message: "The printer refused the API key.") }
            guard (200 ..< 300).contains(r.statusCode) else {
                let text = String(decoding: d.prefix(200), as: UTF8.self)
                return LinkResult(ok: false, message: "The printer answered \(r.statusCode)\(text.isEmpty ? "" : ": \(text)").")
            }
        } catch {
            return LinkResult(ok: false, message: explain(error))
        }
        if p.kind == .printdeck && print { return LinkResult(ok: true, message: "Sent to \(p.name). Press Print on its screen to start.") }
        return LinkResult(ok: true, message: print ? "Sent to \(p.name) (\(p.kind.title)); the print starts." : "Uploaded to \(p.name) (\(p.kind.title)).")
    }

    /// A test of the connection: the version of the API.
    @MainActor static func test(_ p: Printer) async -> LinkResult {
        guard !(p.url.isEmpty && p.https.isEmpty) else { return LinkResult(ok: false, message: "No address.") }
        do {
            let (d, r) = try await request(p, p.kind == .moonraker ? "/server/info" : "/api/version")
            if r.statusCode == 401 || r.statusCode == 403 { return LinkResult(ok: false, message: "The printer refused the API key.") }
            guard (200 ..< 300).contains(r.statusCode) else { return LinkResult(ok: false, message: "The printer answered \(r.statusCode).") }
            let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            let result = j?["result"] as? [String: Any]
            let v = (j?["server"] ?? j?["text"] ?? result?["moonraker_version"] ?? result?["klippy_state"]) as? String ?? ""
            return LinkResult(ok: true, message: "Connected\(v.isEmpty ? "" : ": \(v)").")
        } catch {
            return LinkResult(ok: false, message: explain(error))
        }
    }

    /// Asks the printer for an API key (App Keys). wait(seconds): called
    /// each second while the user decides on the printer.
    @MainActor static func requestKey(_ p: Printer, wait: @MainActor (Int) -> Void) async -> LinkResult {
        guard !(p.url.isEmpty && p.https.isEmpty) else { return LinkResult(ok: false, message: "No address.") }
        if p.kind == .moonraker {
            return LinkResult(ok: false, message: "Moonraker gives no API keys this way: it needs none, or the key of its config.")
        }
        let base = "/plugin/appkeys/request"
        let token: String
        do {
            let (d, r) = try await request(p, base, method: "POST", body: Data(#"{"app":"zslice"}"#.utf8), contentType: "application/json", key: false)
            if r.statusCode == 404 { return LinkResult(ok: false, message: "The printer does not give keys to apps (App Keys is off or missing).") }
            guard (200 ..< 300).contains(r.statusCode) else { return LinkResult(ok: false, message: "The printer answered \(r.statusCode).") }
            guard let t = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["app_token"] as? String else {
                return LinkResult(ok: false, message: "The printer gave no request token.")
            }
            token = t
        } catch {
            return LinkResult(ok: false, message: explain(error))
        }
        let start = Date()
        while Date().timeIntervalSince(start) < 125 {
            wait(Int(Date().timeIntervalSince(start)))
            try? await Task.sleep(for: .seconds(1))
            do {
                let (d, r) = try await request(p, "\(base)/\(token.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? token)", key: false)
                if r.statusCode == 202 { continue }
                if r.statusCode == 404 { return LinkResult(ok: false, message: "The printer did not allow it (Deny), or the request waited too long.") }
                guard (200 ..< 300).contains(r.statusCode),
                      let key = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["api_key"] as? String else {
                    return LinkResult(ok: false, message: "The printer answered \(r.statusCode).")
                }
                return LinkResult(ok: true, message: "The printer gave zslice a key.", key: key)
            } catch {
                return LinkResult(ok: false, message: explain(error))
            }
        }
        return LinkResult(ok: false, message: "No answer on the printer in 2 minutes.")
    }

    /// The https address of a printdeck, from its /slicer/printer.json, or nil.
    @MainActor static func printdeckHTTPS(_ p: Printer) async -> String? {
        guard let (d, r) = try? await request(p, "/slicer/printer.json"), (200 ..< 300).contains(r.statusCode),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let https = j["https"] as? String, !https.isEmpty else { return nil }
        return https
    }
}
