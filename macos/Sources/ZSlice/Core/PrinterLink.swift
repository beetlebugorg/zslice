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

import CZslice
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
    @MainActor static func request(_ p: Printer, _ path: String, method: String = "GET", body: Data? = nil,
                                contentType: String? = nil, encoding: String? = nil, key: Bool = true) async throws -> (Data, HTTPURLResponse) {
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
            if let encoding { r.setValue(encoding, forHTTPHeaderField: "Content-Encoding") }
            if key, !p.apiKey.isEmpty { r.setValue(p.apiKey, forHTTPHeaderField: "X-Api-Key") }
            // An https printer: the trust of the system, and the pin of its
            // certificate (Signing.swift).
            let https = u.scheme == "https"
            let host = u.host ?? ""
            if https { CertPins.refused.remove(host) }
            do {
                let (d, resp) = try await (https ? PinningDelegate.session : URLSession.shared).data(for: r)
                if let h = resp as? HTTPURLResponse {
                    worked[p.id] = base
                    return (d, h)
                }
            } catch {
                // A refused certificate stops: no fall back to http.
                if https, CertPins.refused.contains(host) { throw PinError(host: host) }
                last = error
            }
        }
        throw last
    }

    private static func explain(_ e: Error) -> String {
        if let pin = e as? PinError { return pin.localizedDescription }
        return "The printer did not answer (\(e.localizedDescription)). Check the address, and that the printer is on."
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
            if r.statusCode == 422 {
                let why = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["error"] as? String
                return LinkResult(ok: false, message: why ?? "Rejected: not signed by a trusted slicer (key \(Signer.keyID)). Use Get a Key in Settings > Printers so that the printer trusts zslice.")
            }
            guard (200 ..< 300).contains(r.statusCode) else {
                let text = String(decoding: d.prefix(200), as: UTF8.self)
                return LinkResult(ok: false, message: "The printer answered \(r.statusCode)\(text.isEmpty ? "" : ": \(text)").")
            }
        } catch {
            return LinkResult(ok: false, message: explain(error))
        }
        if p.kind == .printdeck && print { return LinkResult(ok: true, message: "Sent to \(p.name). Press Print on its screen to start.") }
        // OctoPrint and Moonraker do not check the signature.
        return LinkResult(ok: true, message: (print ? "Sent to \(p.name) (\(p.kind.title)); the print starts." : "Uploaded to \(p.name) (\(p.kind.title)).") + " Not verified: \(p.kind.title) does not check signatures.")
    }

    /// A test of the connection: the version of the API.
    @MainActor static func test(_ p: Printer) async -> LinkResult {
        if p.kind == .bambu { return await BambuLink.test(p) }
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
        // A new key pins the certificate again, and gives the printer the
        // public key of the app, so the deck can trust the signed prints.
        for a in [p.https, p.url] { if let h = URL(string: a)?.host { CertPins.forget(host: h) } }
        var ask: [String: Any] = ["app": "zslice"]
        if let pk = Signer.publicKey { ask["public_key"] = pk }
        let askBody = (try? JSONSerialization.data(withJSONObject: ask)) ?? Data(#"{"app":"zslice"}"#.utf8)
        do {
            let (d, r) = try await request(p, base, method: "POST", body: askBody, contentType: "application/json", key: false)
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

// MARK: - the status and the estimate

/// The status of a printer, from the core (zs_printer_status).
struct PrinterStatus: Equatable {
    var state = ""
    var job = ""
    var progress = 0.0
    var timeLeft = -1.0
    var layer = 0, layers = 0
    var material = ""
    var roll = ""
    var rollLeft = 0.0
    var bedX = 0.0, bedY = 0.0, height = 0.0, nozzle = 0.0
    /// Why it failed or stopped (zs_printer_status_message), else "".
    var why = ""
    /// The state for the farm (enum zs_farm_printer_state), the same for
    /// each kind of printer (zs_printer_status_farm_state).
    var farmState: Int32 = 1

    /// One line for the print card: "Operational · Gray, 818 g left", or
    /// the job and its progress.
    var line: String {
        var s = state
        if !job.isEmpty {
            s += " · \(job) \(Int((progress * 100).rounded())) %"
            if timeLeft >= 0 { s += ", \(Int((timeLeft / 60).rounded())) min left" }
        } else if !roll.isEmpty {
            s += " · \(roll)" + (rollLeft > 0 ? ", \(Int(rollLeft.rounded())) g left" : "")
        } else if !material.isEmpty {
            s += " · \(material)"
        }
        return s
    }
}

/// The estimate of a printdeck: its own time for the G-code, from its past
/// prints (the start macro, and how its moves compare with the plan).
struct PrinterEstimate: Equatable {
    var total: Double
    var prep: Double
}

extension PrinterLink {
    private static func coreKind(_ k: Printer.Kind) -> Int32 {
        switch k {
        case .octoprint: 1
        case .printdeck: 2
        case .moonraker: 3
        case .bambu: 4
        case .none: 0
        }
    }

    /// The status object of the core for a printer, from each path of
    /// zs_printer_status_paths, or nil if the printer does not answer.
    /// Free it with zs_printer_status_free.
    @MainActor static func statusObject(_ p: Printer) async -> OpaquePointer? {
        if p.kind == .bambu { return await BambuLink.statusObject(p) }
        let kind = coreKind(p.kind)
        guard kind > 0, let s = zs_printer_status_new() else { return nil }
        let paths = coreText(zs_printer_status_paths(kind)).split(separator: "\n").map(String.init)
        for (i, path) in paths.enumerated() {
            guard let (d, r) = try? await request(p, path), (200 ..< 300).contains(r.statusCode) else {
                if i == 0 {
                    zs_printer_status_free(s)
                    return nil
                }
                continue
            }
            _ = d.withUnsafeBytes { zs_printer_status_feed(s, kind, path, $0.bindMemory(to: CChar.self).baseAddress, $0.count) }
        }
        return s
    }

    /// The status of a printer: GET each path of zs_printer_status_paths and
    /// give each reply to the core. nil if the printer does not answer.
    @MainActor static func status(_ p: Printer) async -> PrinterStatus? {
        guard let s = await statusObject(p) else { return nil }
        defer { zs_printer_status_free(s) }
        var info = zs_printer_info()
        guard zs_printer_status_get(s, &info) == 0 else { return nil }
        return PrinterStatus(state: coreText(info.state), job: coreText(info.job), progress: info.progress, timeLeft: info.time_left,
                             layer: Int(info.layer), layers: Int(info.layers), material: coreText(info.material),
                             roll: coreText(info.spool.name), rollLeft: info.spool.left,
                             bedX: info.bed_x, bedY: info.bed_y, height: info.height, nozzle: info.nozzle,
                             why: coreText(zs_printer_status_message(s)), farmState: zs_printer_status_farm_state(s))
    }

    /// The estimate of a printdeck for the G-code: POST it with gzip to
    /// /api/plugin/printdeck/estimate. The printer only reads it: it does
    /// not keep the file or print it.
    @MainActor static func estimate(_ p: Printer, gcode: Data) async -> PrinterEstimate? {
        guard p.kind == .printdeck, let gz = Gzip.compress(gcode),
              let (d, r) = try? await request(p, "/api/plugin/printdeck/estimate", method: "POST", body: gz,
                                              contentType: "text/plain", encoding: "gzip"),
              r.statusCode == 200,
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let total = (j["total"] as? NSNumber)?.doubleValue, total > 0 else { return nil }
        return PrinterEstimate(total: total, prep: (j["prep"] as? NSNumber)?.doubleValue ?? 0)
    }
}
