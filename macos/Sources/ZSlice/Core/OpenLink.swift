//! zslice://open?file=<https URL>: the "Open in slicer" link of a model
//! site (docs/internals/open-links.md). The rules are in the core
//! (zs_link_*), so each app takes and refuses the same links.
//!
//! The app gets the link as a Get URL Apple event (CFBundleURLTypes in
//! Info.plist), waits until the session of the last run is back in its
//! windows, and gives it to the key window (else the first window). One
//! link at a time. The app checks the link (zs_link_check) and asks the
//! user, with Cancel as the default button: any web page can start a link.
//! After a yes it downloads with no cookie, no credentials, and no proxy.
//! Before each request it resolves the host and refuses a local address
//! (zs_link_address_public). It checks each redirect (zs_link_redirect),
//! the head of the answer (zs_link_check_reply), and the name of the file
//! (zs_link_file_name), and stops at ZS_LINK_MAX_BYTES. A zslice project
//! is refused. The model opens on a new plate when the active plate has
//! parts. A link never starts a print.
//!
//! See REFERENCES.md: PrusaSlicer (the shape of an "Open in slicer" link).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CZslice
import Darwin

/// The links that came before a window could take them, and the one link
/// that is open now.
@MainActor
enum LinkRouter {
    private static var waiting: [String] = []
    private static var timer: Timer?
    static var busy = false

    /// A Get URL event: the link goes to a window once the session is back.
    static func receive(_ text: String) {
        waiting.append(text)
        deliver()
    }

    private static func deliver() {
        guard !waiting.isEmpty else { return }
        guard SessionStore.shared.isRestored, let ws = target else {
            // The windows come back first; try again soon.
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        if SessionStore.shared.isRestored, target != nil {
                            timer?.invalidate()
                            timer = nil
                            deliver()
                        }
                    }
                }
            }
            return
        }
        let text = waiting.removeFirst()
        ws.openLink(text)
        // A link that came while one is open gets its note in openLink.
        if !waiting.isEmpty { DispatchQueue.main.async { deliver() } }
    }

    /// The workspace of the key window, else the first window.
    private static var target: Workspace? {
        if let w = NSApp.keyWindow, let ws = SessionStore.shared.workspace(of: w) { return ws }
        return SessionStore.shared.firstWorkspace
    }
}

/// A checked link (zs_link) with its fields as Swift strings.
struct CheckedLink {
    var raw = zs_link()

    /// The url field is the first of zs_link, at offset 0. Swift does not
    /// import a C array this long, so it reads the bytes of the struct.
    var url: String {
        withUnsafeBytes(of: raw) { b in String(decoding: b.prefix(Int(ZS_LINK_URL_MAX)).prefix(while: { $0 != 0 }), as: UTF8.self) }
    }
    var host: String { Self.text(raw.host) }
    var name: String { Self.text(raw.name) }

    /// A field of fixed bytes up to its NUL byte.
    private static func text<T>(_ field: T) -> String {
        withUnsafeBytes(of: field) { b in String(decoding: b.prefix(while: { $0 != 0 }), as: UTF8.self) }
    }

    /// Sets the URL (the last URL of a download), for zs_link_file_name.
    mutating func setURL(_ s: String) {
        let bytes = Array(s.utf8.prefix(Int(ZS_LINK_URL_MAX) - 1)) + [0]
        withUnsafeMutableBytes(of: &raw) { b in
            for (i, v) in bytes.enumerated() { b[i] = v }
        }
    }
}

/// Why a link stopped: a result of the core, or another reason in words.
struct LinkError: Error {
    var text: String
    init(_ result: Int32) { text = coreText(zs_link_message(result)) }
    init(text: String) { self.text = text }
}

/// The address of each IP of a host is public (getaddrinfo); a local one
/// stops the link (ZS_LINK_LOCAL_ADDRESS).
func linkHostIsPublic(_ host: String) -> Bool {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, "443", &hints, &res) == 0, let first = res else { return false }
    defer { freeaddrinfo(first) }
    var any = false
    var p: UnsafeMutablePointer<addrinfo>? = first
    while let a = p {
        if let sa = a.pointee.ai_addr {
            var ok: Int32 = 0
            if a.pointee.ai_family == AF_INET {
                sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { s in
                    var addr = s.pointee.sin_addr
                    ok = withUnsafeBytes(of: &addr) { zs_link_address_public($0.bindMemory(to: UInt8.self).baseAddress, 4) }
                }
            } else if a.pointee.ai_family == AF_INET6 {
                sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { s in
                    var addr = s.pointee.sin6_addr
                    ok = withUnsafeBytes(of: &addr) { zs_link_address_public($0.bindMemory(to: UInt8.self).baseAddress, 16) }
                }
            }
            if ok == 0 { return false }
            any = true
        }
        p = a.pointee.ai_next
    }
    return any
}

/// The download of a link: no cookie, no credentials, no proxy, each
/// redirect and the answer checked by the core, at most ZS_LINK_MAX_BYTES.
final class LinkDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var link: CheckedLink
    private var data = Data()
    private var redirects = 0
    private var error: LinkError?
    private var done: CheckedContinuation<(CheckedLink, Data), Error>?
    private let lock = NSLock()

    init(_ link: CheckedLink) { self.link = link }

    func run() async throws -> (CheckedLink, Data) {
        guard linkHostIsPublic(link.host) else { throw LinkError(Int32(ZS_LINK_LOCAL_ADDRESS.rawValue)) }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.urlCredentialStorage = nil
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        guard let url = URL(string: link.url) else { throw LinkError(Int32(ZS_LINK_NOT_PUBLIC.rawValue)) }
        var r = URLRequest(url: url)
        r.httpShouldHandleCookies = false
        return try await withCheckedThrowingContinuation { c in
            lock.withLock { done = c }
            session.dataTask(with: r).resume()
        }
    }

    private func fail(_ e: LinkError, _ task: URLSessionTask) {
        lock.withLock { if error == nil { error = e } }
        task.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= Int(ZS_LINK_MAX_REDIRECTS) else {
            fail(LinkError(Int32(ZS_LINK_TOO_MANY_REDIRECTS.rawValue)), task)
            return completionHandler(nil)
        }
        let location = response.value(forHTTPHeaderField: "Location") ?? request.url?.absoluteString ?? ""
        let rc = location.withCString { zs_link_redirect($0, &link.raw) }
        guard rc == ZS_LINK_OK.rawValue else {
            fail(LinkError(rc), task)
            return completionHandler(nil)
        }
        guard linkHostIsPublic(link.host) else {
            fail(LinkError(Int32(ZS_LINK_LOCAL_ADDRESS.rawValue)), task)
            return completionHandler(nil)
        }
        guard let next = URL(string: link.url) else {
            fail(LinkError(Int32(ZS_LINK_BAD_REDIRECT.rawValue)), task)
            return completionHandler(nil)
        }
        var r = URLRequest(url: next)
        r.httpShouldHandleCookies = false
        completionHandler(r)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let h = response as? HTTPURLResponse, (200 ..< 300).contains(h.statusCode) else {
            fail(LinkError(text: "The site answered \((response as? HTTPURLResponse)?.statusCode ?? 0)."), dataTask)
            return completionHandler(.cancel)
        }
        let type = h.value(forHTTPHeaderField: "Content-Type") ?? ""
        var rc = type.withCString { zs_link_check_reply($0, h.expectedContentLength) }
        guard rc == ZS_LINK_OK.rawValue else {
            fail(LinkError(rc), dataTask)
            return completionHandler(.cancel)
        }
        if let u = h.url?.absoluteString { link.setURL(u) }
        if let d = h.value(forHTTPHeaderField: "Content-Disposition") {
            rc = d.withCString { zs_link_file_name($0, &link.raw) }
        } else {
            rc = zs_link_file_name(nil, &link.raw)
        }
        guard rc == ZS_LINK_OK.rawValue else {
            fail(LinkError(rc), dataTask)
            return completionHandler(.cancel)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive d: Data) {
        data.append(d)
        if UInt64(data.count) > ZS_LINK_MAX_BYTES { fail(LinkError(Int32(ZS_LINK_TOO_LARGE.rawValue)), dataTask) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError err: Error?) {
        let c = lock.withLock { () -> CheckedContinuation<(CheckedLink, Data), Error>? in
            defer { done = nil }
            return done
        }
        if let e = lock.withLock({ error }) {
            c?.resume(throwing: e)
        } else if let err {
            c?.resume(throwing: LinkError(text: err.localizedDescription))
        } else {
            c?.resume(returning: (link, data))
        }
    }
}

extension Workspace {
    /// A link to open a model: the check, the question, the download, and
    /// the model on a new plate. One link at a time.
    func openLink(_ text: String) {
        guard !LinkRouter.busy else {
            showNote("Finish the link that is open, then try this one.")
            return
        }
        var link = CheckedLink()
        let rc = text.withCString { zs_link_check($0, &link.raw) }
        guard rc == ZS_LINK_OK.rawValue else {
            linkFailed(LinkError(rc))
            return
        }
        LinkRouter.busy = true
        Task { @MainActor in
            defer { LinkRouter.busy = false }
            let yes = ProcessInfo.processInfo.environment["ZSLICE_LINK_YES"] != nil ? true : await askLink(link)
            guard yes else { return }
            showNote("Downloading \(link.name.isEmpty ? "the model" : link.name) from \(link.host)…", seconds: 60)
            do {
                let (final, data) = try await LinkDownload(link).run()
                openLinked(final, data)
            } catch let e as LinkError {
                linkFailed(e)
            } catch {
                linkFailed(LinkError(text: error.localizedDescription))
            }
        }
    }

    /// Open this model? A sheet on the window. Cancel is the default
    /// button, so Enter does not download.
    private func askLink(_ link: CheckedLink) async -> Bool {
        let a = NSAlert()
        a.messageText = "Open this model?"
        a.informativeText = "\(link.name.isEmpty ? "A model file" : link.name)\nFrom \(link.host)\n\nzslice downloads the file and opens it on a new plate. It does not start a print."
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Download and open")
        // Return and Esc are Cancel; the download needs a click.
        a.buttons[0].keyEquivalent = "\r"
        a.buttons[1].keyEquivalent = ""
        guard let w = canvas.window else { return a.runModal() == .alertSecondButtonReturn }
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        return await withCheckedContinuation { c in
            a.beginSheetModal(for: w) { c.resume(returning: $0 == .alertSecondButtonReturn) }
        }
    }

    private func linkFailed(_ e: LinkError) {
        if ProcessInfo.processInfo.environment["ZSLICE_LINK_YES"] != nil { NSLog("zslice link: did not open: %@", e.text) }
        let a = NSAlert()
        a.messageText = "This link did not open"
        a.informativeText = e.text
        if ProcessInfo.processInfo.environment["ZSLICE_LINK_YES"] != nil {
            showNote("This link did not open. \(e.text)")
        } else {
            a.runModal()
        }
    }

    /// The bytes of a link: never a project; a new plate when the active
    /// plate has parts. Never a print.
    private func openLinked(_ link: CheckedLink, _ data: Data) {
        let isProject = data.withUnsafeBytes { zs_project_file_is($0.bindMemory(to: UInt8.self).baseAddress, $0.count) } == 1
        guard !isProject else {
            linkFailed(LinkError(Int32(ZS_LINK_PROJECT.rawValue)))
            return
        }
        let name = link.name.isEmpty ? "model.stl" : link.name
        do {
            if zs_app_part_count(model.core) > 0 {
                model.addPlate()
                try model.add(name: name, data: data)
            } else {
                try model.load(name: name, data: data)
            }
            fitAfterSlice = true
            showNote("Opened \(name) from \(link.host).")
            if ProcessInfo.processInfo.environment["ZSLICE_LINK_YES"] != nil {
                NSLog("zslice link: opened %@ from %@, %ld bytes, plates %ld, parts %ld", name, link.host, data.count, model.plates.count, zs_app_part_count(model.core))
            }
        } catch {
            linkFailed(LinkError(text: "The file did not open: \(error.localizedDescription)"))
        }
    }
}
