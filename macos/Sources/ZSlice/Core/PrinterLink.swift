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
//! A redirect keeps the headers of a request in URLSession, so a printer
//! (or a device that answers at its address) could send the API key to
//! any host. Each request with the key goes through a session whose
//! delegate drops X-Api-Key on a redirect to another origin (the scheme,
//! the host, and the port): KeyRedirect. The GTK app does the same
//! (linux/src/net/key-header.c), and the web app refuses redirects.
//!
//! The camera: GET each path of zs_printer_camera_paths with the key, and
//! the core reads the MJPEG stream and the snapshot from the replies
//! (zs_printer_status_camera). Their addresses can be relative to the
//! printer. A printdeck with more printers lists them in its
//! /slicer/printer.json (deckPrinters).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CZslice
import Foundation

/// The API key never follows a redirect to another origin.
final class KeyRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = KeyRedirect()
    /// A session for the requests with a key, over http or https with the
    /// trust of the system.
    static let session = URLSession(configuration: .ephemeral, delegate: shared, delegateQueue: nil)

    /// "http://host:80": the scheme, the host, and the port of a url.
    static func origin(_ u: URL?) -> String? {
        guard let u, let s = u.scheme?.lowercased(), let h = u.host?.lowercased() else { return nil }
        let port = u.port ?? (s == "https" ? 443 : s == "http" ? 80 : -1)
        return "\(s)://\(h):\(port)"
    }

    /// The request of a redirect: with no key when it goes to another
    /// origin than the first request of the task.
    static func redirect(_ next: URLRequest, of task: URLSessionTask) -> URLRequest {
        guard next.value(forHTTPHeaderField: "X-Api-Key") != nil,
              origin(next.url) != origin(task.originalRequest?.url) || origin(next.url) == nil else { return next }
        var r = next
        r.setValue(nil, forHTTPHeaderField: "X-Api-Key")
        return r
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        Self.redirect(request, of: task)
    }
}

struct LinkResult {
    var ok: Bool
    var message: String
    var key: String?
}

enum PrinterLink {
    /// The address that answered last for each printer, in this session.
    @MainActor private static var worked: [UUID: String] = [:]
    /// The printers whose last status read got 401 or 403: the key is
    /// missing or wrong.
    @MainActor static var refused: Set<UUID> = []

    /// The addresses to try, best first: the one that answered last, the
    /// https address, then the http address.
    @MainActor private static func addresses(_ p: Printer) -> [String] {
        var out: [String] = []
        for u in [worked[p.id] ?? "", p.https, p.url].map(fixDoubled) where !u.isEmpty && !out.contains(u) { out.append(u) }
        return out
    }

    /// An address saved with the path of a printer of a deck twice
    /// (".../printers/x2d/printers/x2d", from a deck added at the address
    /// of one of its printers) has it once (web/app/link.js fixDoubled).
    nonisolated static func fixDoubled(_ u: String) -> String {
        u.replacingOccurrences(of: #"(/printers/[^/]+)(?:\1)+(?=/|$)"#, with: "$1", options: .regularExpression)
    }

    private static func url(_ base: String, _ path: String) -> URL? {
        var b = base.trimmingCharacters(in: .whitespaces)
        if !b.contains("://") { b = "http://" + b }
        while b.hasSuffix("/") { b.removeLast() }
        return URL(string: b + path)
    }

    /// A request of `path` on the printer: each address in turn.
    @MainActor static func request(_ p: Printer, _ path: String, method: String = "GET", body: Data? = nil,
                                contentType: String? = nil, encoding: String? = nil, key: Bool = true,
                                apiKey: String? = nil) async throws -> (Data, HTTPURLResponse) {
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
            // apiKey: the key of another printer (the root of a deck).
            let k = apiKey ?? p.apiKey
            if key, !k.isEmpty { r.setValue(k, forHTTPHeaderField: "X-Api-Key") }
            // An https printer: the trust of the system, and the pin of its
            // certificate (Signing.swift).
            let https = u.scheme == "https"
            let host = u.host ?? ""
            if https { CertPins.refused.remove(host) }
            do {
                let (d, resp) = try await (https ? PinningDelegate.session : KeyRedirect.session).data(for: r)
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

    static func explain(_ e: Error) -> String {
        if let pin = e as? PinError { return pin.localizedDescription }
        return "The printer did not answer (\(e.localizedDescription)). Check the address, and that the printer is on."
    }

    /// Sends the G-code as `filename`; print: start the print.
    @MainActor static func send(_ p: Printer, filename: String, gcode unsigned: Data, print: Bool, file: Bool = false) async -> LinkResult {
        // Each send is signed here, whatever path called it (an old
        // signature line goes first, so signing twice is the same). A file
        // (file: true, a .gcode.3mf with signed G-code in it) goes as it is.
        let gcode = file ? unsigned : Signer.sign(unsigned)
        guard p.kind != .none, !(p.url.isEmpty && p.https.isEmpty) else { return LinkResult(ok: false, message: "This printer has no connection.") }
        // A deck with more printers: the address must lead to the printer
        // that the user picked.
        if p.kind == .printdeck, let why = await checkDeckTarget(p) { return LinkResult(ok: false, message: why) }
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
        var started = print
        do {
            let (d, r) = try await request(p, path, method: "POST", body: body, contentType: "multipart/form-data; boundary=\(boundary)")
            // OctoPrint and printdeck say if the print started: a printdeck
            // set to ask waits for a press of Print on it.
            if let e = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["effectivePrint"] as? Bool { started = e }
            if r.statusCode == 401 || r.statusCode == 403 { return LinkResult(ok: false, message: "The printer refused the API key.") }
            if r.statusCode == 422 {
                let why = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["error"] as? String
                return LinkResult(ok: false, message: why ?? "Rejected: not signed by a trusted slicer (key \(Signer.keyID)). Use Get a Key in Settings > Printers so that the printer trusts zslice.")
            }
            guard (200 ..< 300).contains(r.statusCode) else {
                let text = String(decoding: d.prefix(200), as: UTF8.self)
                return LinkResult(ok: false, message: "The printer answered \(r.statusCode)\(text.isEmpty ? "" : ": \(text)").")
            }
            // An upload of OctoPrint and printdeck answers JSON with the
            // stored file (files.local, and done). Any other 2xx answer (a
            // web page, a proxy) did not store the file: a send once said
            // "sent", and no file came to the deck.
            if p.kind != .moonraker {
                let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
                let stored = ((j?["files"] as? [String: Any])?["local"] != nil) || (j?["done"] as? Bool == true)
                if !stored {
                    let at = r.url?.absoluteString ?? ""
                    let head = String(String(decoding: d.prefix(400), as: UTF8.self).split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(120))
                    NSLog("zslice: the upload answer is not a stored file: %@ %ld", at, r.statusCode)
                    return LinkResult(ok: false, message: "\(p.name) answered \(r.statusCode)\(at.isEmpty ? "" : " at \(at)"), but not with a stored file\(head.isEmpty ? "" : " (\"\(head)\")"). The file may not be on the printer: check its address in Settings > Printers.")
                }
            }
        } catch {
            return LinkResult(ok: false, message: explain(error))
        }
        if p.kind == .printdeck {
            return LinkResult(ok: true, message: started ? "Sent to \(p.name); the print starts."
                : print ? "Sent to \(p.name). It waits there: press Print on the deck to start it." : "Uploaded to \(p.name).")
        }
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
        // A printdeck pairs at its root: the key is of the deck ("scope":
        // "deck"), good for each of its printers and their list. At the
        // address of one printer the key is of that printer only.
        let p = p.kind == .printdeck ? deckRoot(p) : p
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
            if Task.isCancelled { return LinkResult(ok: false, message: "Cancelled.") }
            wait(Int(Date().timeIntervalSince(start)))
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return LinkResult(ok: false, message: "Cancelled.") }
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

    /// The printers of a printdeck (GET /slicer/printer.json with the key).
    /// A deck with more than one printer lists them, each with the path of
    /// its API under the deck: "" for the first, "/printers/<id>" for
    /// another. nil if the deck does not answer.
    @MainActor static func deckPrinters(_ p: Printer) async -> [DeckPrinter]? {
        guard let (d, r) = try? await request(deckRoot(p), "/slicer/printer.json", apiKey: p.apiKey), (200 ..< 300).contains(r.statusCode),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        return (j["printers"] as? [[String: Any]] ?? []).map { o in
            DeckPrinter(id: o["id"] as? String ?? "", name: o["name"] as? String ?? "", label: o["label"] as? String ?? "",
                        kind: o["kind"] as? String ?? "fdm", path: o["url"] as? String ?? "", model: o["model"] as? String ?? "")
        }
    }

    /// The root of a deck address, and the path of a printer of the deck:
    /// "http://deck/printers/p1" is ("http://deck", "/printers/p1").
    nonisolated static func deckSplit(_ u: String) -> (root: String, path: String) {
        var s = fixDoubled(u.trimmingCharacters(in: .whitespaces))
        while s.hasSuffix("/") { s.removeLast() }
        if let r = s.range(of: "/printers/", options: .backwards) {
            let id = s[r.upperBound...]
            let ok = !id.isEmpty && id.allSatisfy { $0.isLetter || $0.isNumber || "._~-".contains($0) }
            if ok { return (String(s[..<r.lowerBound]), String(s[r.lowerBound...])) }
        }
        return (s, "")
    }

    /// Before a send to a printdeck (web/app/link.js checkDeckTarget): the
    /// list of the deck at its root (/slicer/printer.json). With 2 or more
    /// printers, the send stops when the path of the address is not in the
    /// list, when the saved deck name differs from the printer at that
    /// path, when the name of the user's printer names another printer of
    /// the deck (by its words), or when the address is the deck itself and
    /// neither a saved deck name nor the name of the printer says that it
    /// is the first printer of the deck. A list that does not read lets the
    /// send go. Returns why it stops, or nil.
    @MainActor static func checkDeckTarget(_ p: Printer) async -> String? {
        let (root, path) = deckSplit(p.url.isEmpty ? p.https : p.url)
        var probe = Printer(name: p.name, kind: .printdeck, url: root)
        probe.https = p.https.isEmpty ? "" : deckSplit(p.https).root
        guard let (d, r) = try? await request(probe, "/slicer/printer.json", apiKey: p.apiKey), (200 ..< 300).contains(r.statusCode),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let list = j["printers"] as? [[String: Any]], list.count >= 2 else { return nil }
        func norm(_ v: Any?) -> String { ((v as? String) ?? "").trimmingCharacters(in: .whitespaces).lowercased() }
        guard let at = list.first(where: { ($0["url"] as? String ?? "") == path }) else {
            return "The deck has no printer at \(path.isEmpty ? "its own address" : path). Nothing was sent. Add the printer again from the deck."
        }
        let atName = norm(at["name"])
        let shown = at["name"] as? String ?? ""
        if !p.deckName.isEmpty, norm(p.deckName) != atName {
            return "This address leads to \(shown) on the deck, not to \(p.deckName). Nothing was sent. Add the printer again from the deck."
        }
        // A name names a deck printer when one has all the words of the
        // other ("Bambu Lab X2D" and "X2D"): lower case, split at each
        // character that is not a letter or a digit.
        func words(_ v: Any?) -> [String] {
            norm(v).split(whereSeparator: { !(("a" ... "z").contains($0) || ("0" ... "9").contains($0)) }).map(String.init)
        }
        func names(_ q: [String: Any], _ n: String) -> Bool {
            let a = words(n)
            for t in [q["name"], q["label"]] {
                let b = words(t)
                if a.isEmpty || b.isEmpty { continue }
                if b.allSatisfy(a.contains) || a.allSatisfy(b.contains) { return true }
            }
            return false
        }
        let mine = norm(p.name)
        let other = list.first { q in (q["url"] as? String ?? "") != path && names(q, p.name) }
        if let other, !names(at, p.name) {
            return "\(p.name) is at \(other["url"] as? String ?? "") on the deck, but this printer's address leads to \(shown). Nothing was sent. Add \(p.name) again from the deck."
        }
        // The address of the deck itself leads to its first printer. With
        // more printers on the deck, that must be the printer of the user
        // for sure: its saved deck name, or a name with the words of that
        // printer. A print for the X2D went to the TAZ this way.
        if path.isEmpty, p.deckName.isEmpty, !names(at, p.name), atName != mine {
            return "The address of \(p.name) is the deck itself, which prints on \(shown). zslice cannot tell that \(p.name) is \(shown). Nothing was sent. Add the printer again from the deck, and pick it from the list of the deck."
        }
        return nil
    }

    /// A spool that a deck printer has loaded (GET /api/plugin/printdeck,
    /// "filaments"), in the order of the printer.
    struct LoadedFilament {
        var slot: String
        var material: String
        var color: String
        /// "aux": the spool feeds the second nozzle of a printer with two
        /// (the external spool of an X2D).
        var nozzle: String
    }

    /// The spools that a printdeck printer has loaded: the trays of its
    /// AMS and its external spool, with no empty tray. nil and why when
    /// there is none to read.
    /// `nozzles`: the codes of the nozzles of a Bambu Lab printer ("HS01"),
    /// if the deck tells them.
    @MainActor static func loadedFilaments(_ p: Printer) async -> (list: [LoadedFilament]?, nozzles: [String], why: String, json: Data?) {
        guard p.kind == .printdeck else { return (nil, [], "Only a printdeck printer tells its filaments.", nil) }
        do {
            let (d, r) = try await request(p, "/api/plugin/printdeck")
            if r.statusCode == 401 || r.statusCode == 403 { return (nil, [], "The deck refused the key.", nil) }
            guard (200 ..< 300).contains(r.statusCode) else { return (nil, [], "The deck answered \(r.statusCode).", nil) }
            let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            let nozzles = (j?["nozzles"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String }
            let list = (j?["filaments"] as? [[String: Any]] ?? []).compactMap { f -> LoadedFilament? in
                guard let m = f["material"] as? String, !m.isEmpty else { return nil }
                return LoadedFilament(slot: f["slot"] as? String ?? "", material: m, color: f["color"] as? String ?? "",
                                      nozzle: f["nozzle"] as? String ?? "")
            }
            if list.isEmpty { return (nil, nozzles, "The printer tells no loaded filaments. Update the deck, or load a spool.", d) }
            return (list, nozzles, "", d)
        } catch {
            return (nil, [], explain(error), nil)
        }
    }

    /// The nozzle of a Bambu Lab code (web/app/link.js nozzleOfCode): "HS01"
    /// is hardened steel with standard flow, "HH01" with high flow. The
    /// first letter is the material, the second the flow. The values are
    /// those of machine.nozzle_type and machine.nozzle_flow; nil for a code
    /// that zslice does not know.
    nonisolated static func nozzleOfCode(_ code: String) -> (type: String, flow: String)? {
        let c = code.trimmingCharacters(in: .whitespaces).uppercased()
        guard c.range(of: "^[HST][SH][0-9]*$", options: .regularExpression) != nil else { return nil }
        let chars = Array(c)
        let type = ["H": "hardened_steel", "S": "stainless_steel", "T": "tungsten_carbide"][chars[0]]!
        return (type, chars[1] == "H" ? "high_flow" : "standard")
    }

    /// The camera of a printer, read once: GET each path of
    /// zs_printer_camera_paths with the key. nil: no camera, or no answer.
    @MainActor static func camera(_ p: Printer) async -> CameraSource? {
        if p.kind == .bambu {
            let kind = zs_bambu_camera_kind(p.model)
            return CameraSource(bambu: BambuLink.host(p), code: p.apiKey, serial: p.serial, kind: Int(kind))
        }
        let kind = coreKind(p.kind)
        let paths = coreText(zs_printer_camera_paths(kind)).split(separator: "\n").map(String.init)
        guard !paths.isEmpty, let s = zs_printer_status_new() else { return nil }
        defer { zs_printer_status_free(s) }
        for path in paths {
            guard let (d, r) = try? await request(p, path), (200 ..< 300).contains(r.statusCode) else { continue }
            _ = d.withUnsafeBytes { zs_printer_status_feed(s, kind, path, $0.bindMemory(to: CChar.self).baseAddress, $0.count) }
        }
        var c = zs_printer_camera()
        guard zs_printer_status_camera(s, &c) == 0 else { return nil }
        // The addresses can be relative to the printer.
        let base = worked[p.id] ?? p.url
        func abs(_ u: UnsafePointer<CChar>?) -> URL? {
            let t = coreText(u)
            guard !t.isEmpty else { return nil }
            if t.contains("://") { return URL(string: t) }
            return url(base, t.hasPrefix("/") ? t : "/" + t)
        }
        let src = CameraSource(stream: abs(c.stream), snapshot: abs(c.snapshot), key: p.apiKey, printdeck: p.kind == .printdeck,
                               flipH: c.flip_h != 0, flipV: c.flip_v != 0, rotation: Int(c.rotation))
        return src.stream == nil && src.snapshot == nil ? nil : src
    }

    /// The https address of a printer of a printdeck, or nil: the https
    /// address of the deck (its /slicer/printer.json, at its root) and the
    /// path of the printer under the deck.
    @MainActor static func printdeckHTTPS(_ p: Printer) async -> String? {
        guard let (d, r) = try? await request(deckRoot(p), "/slicer/printer.json", apiKey: p.apiKey), (200 ..< 300).contains(r.statusCode),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              var https = j["https"] as? String, !https.isEmpty else { return nil }
        while https.hasSuffix("/") { https.removeLast() }
        return https + deckSplit(p.url.isEmpty ? p.https : p.url).path
    }

    /// The ids of the deck roots of the printers, for deckRoot.
    @MainActor private static var rootIDs: [UUID: UUID] = [:]

    /// The deck itself of a printer of a printdeck: its root address (the
    /// url and the https address with no "/printers/<id>"), under an id of
    /// its own, so the address that worked for the deck never stands for
    /// the address of the printer (`worked`). It has no key: the requests
    /// pass the key of the printer (setting one writes to the Keychain).
    @MainActor static func deckRoot(_ p: Printer) -> Printer {
        var r = Printer(name: p.name + " (deck)", kind: .printdeck, url: p.url.isEmpty ? "" : deckSplit(p.url).root)
        r.https = p.https.isEmpty ? "" : deckSplit(p.https).root
        if let id = rootIDs[p.id] { r.id = id } else { rootIDs[p.id] = r.id }
        return r
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
    /// The temperatures in °C (zs_printer_status_heat), NaN when not known.
    var nozzleC = Double.nan, nozzleTarget = Double.nan
    var bedC = Double.nan, bedTarget = Double.nan
    var chamberC = Double.nan

    /// "Nozzle 215 / 215 °C    Bed 60 / 60 °C", or "".
    var heat: String {
        var parts: [String] = []
        func part(_ name: String, _ v: Double, _ target: Double) {
            guard !v.isNaN else { return }
            parts.append(target > 0 ? String(format: "%@ %.0f / %.0f °C", name, v, target) : String(format: "%@ %.0f °C", name, v))
        }
        part("Nozzle", nozzleC, nozzleTarget)
        part("Bed", bedC, bedTarget)
        part("Chamber", chamberC, 0)
        return parts.joined(separator: "    ")
    }

    static func == (a: PrinterStatus, b: PrinterStatus) -> Bool {
        a.state == b.state && a.job == b.job && a.progress == b.progress && a.timeLeft == b.timeLeft && a.layer == b.layer
            && a.layers == b.layers && a.material == b.material && a.roll == b.roll && a.rollLeft == b.rollLeft && a.bedX == b.bedX
            && a.bedY == b.bedY && a.height == b.height && a.nozzle == b.nozzle && a.why == b.why && a.farmState == b.farmState
            && a.heat == b.heat
    }

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

/// A printer of a printdeck (its /slicer/printer.json). path: "" for the
/// deck itself, else "/printers/<id>" under the address of the deck.
struct DeckPrinter: Identifiable, Hashable {
    var id: String
    var name: String
    var label: String
    var kind: String
    var path: String
    /// The product name of the printer ("Bambu Lab X2D"), or "".
    var model = ""

    /// "Prusa MK4 (left)", or the name.
    var title: String { label.isEmpty || label == name ? name : "\(name) (\(label))" }
}

/// The estimate of a printdeck: its own time for the G-code, from its past
/// prints (the start macro, and how its moves compare with the plan).
struct PrinterEstimate: Equatable {
    var total: Double
    var prep: Double
}

extension PrinterLink {
    static func coreKind(_ k: Printer.Kind) -> Int32 {
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
            let answer = try? await request(p, path)
            if i == 0 {
                if let r = answer?.1, r.statusCode == 401 || r.statusCode == 403 { refused.insert(p.id) } else { refused.remove(p.id) }
            }
            guard let (d, r) = answer, (200 ..< 300).contains(r.statusCode) else {
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
        return status(of: s)
    }

    /// The status in a status object of the core.
    @MainActor static func status(of s: OpaquePointer) -> PrinterStatus? {
        var info = zs_printer_info()
        guard zs_printer_status_get(s, &info) == 0 else { return nil }
        var st = PrinterStatus(state: coreText(info.state), job: coreText(info.job), progress: info.progress, timeLeft: info.time_left,
                               layer: Int(info.layer), layers: Int(info.layers), material: coreText(info.material),
                               roll: coreText(info.spool.name), rollLeft: info.spool.left,
                               bedX: info.bed_x, bedY: info.bed_y, height: info.height, nozzle: info.nozzle,
                               why: coreText(zs_printer_status_message(s)), farmState: zs_printer_status_farm_state(s))
        var h = zs_printer_heat()
        if zs_printer_status_heat(s, &h) == 0 {
            st.nozzleC = h.nozzle
            st.nozzleTarget = h.nozzle_target
            st.bedC = h.bed
            st.bedTarget = h.bed_target
            st.chamberC = h.chamber
        }
        return st
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
