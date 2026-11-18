//! Discovery: finds printers on the local network with mDNS
//! (docs/user/getting-started.md, "Printers on your network").
//!
//! The core builds and reads the packets (zs_discovery, src/discovery.zig);
//! this file does the network I/O, as include/zslice-app.h says:
//!
//! 1. It sends the query of the core over UDP to 224.0.0.251 port 5353,
//!    from a socket on port 5353 in the group (the mDNS service of the
//!    system has the port too, so the socket shares it), where the answers
//!    come, and from a socket of its own port (for a unicast answer). It
//!    sends the query again after 1 s and 3 s, as a packet can get lost.
//! 2. It gives each packet to zs_discovery_feed. When the core has new
//!    questions, it sends the query again.
//! 3. It listens on UDP port 2021 (ZS_DISCOVERY_BAMBU_PORT), where Bambu Lab
//!    printers in LAN mode broadcast SSDP text packets, and gives those to
//!    zs_discovery_feed too.
//! 4. For each new printer, it asks the printer what it is: GET /api/version
//!    (OctoPrint, printdeck, PrusaLink) or /printer/objects/query?toolhead
//!    (Moonraker), with no key, and gives the body to zs_discovery_reply.
//!    A Bambu printer has no HTTP API, so the app does not ask it.
//!
//! The search runs for 8 seconds. The picker shows the printers that it
//! finds under "On Your Network".
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CZslice
import Darwin
import Foundation
import Observation

struct FoundPrinter: Identifiable, Equatable {
    var id: String { url }
    var name: String
    var kind: Int32
    var kindTitle: String
    var url: String
    var model: String
    var bedX: Double, bedY: Double, height: Double
    /// Bambu Lab: the serial number, else "".
    var serial: String

    var bambu: Bool { kind == Int32(ZS_FOUND_BAMBU.rawValue) }

    var printerKind: Printer.Kind {
        switch Int(kind) {
        case Int(ZS_FOUND_PRINTDECK.rawValue): .printdeck
        case Int(ZS_FOUND_MOONRAKER.rawValue): .moonraker
        case Int(ZS_FOUND_BAMBU.rawValue): .bambu
        default: .octoprint
        }
    }
}

@MainActor
@Observable
final class Discovery {
    private(set) var found: [FoundPrinter] = []
    private(set) var searching = false

    @ObservationIgnored private var d: OpaquePointer?
    @ObservationIgnored private var sockets: [Int32] = []
    @ObservationIgnored private var sources: [DispatchSourceRead] = []
    @ObservationIgnored private var asked = Set<String>()

    isolated deinit { stop() }

    func start() {
        stop()
        var p: OpaquePointer?
        guard zs_discovery_new(&p) == 0, let p else { return }
        d = p
        found = []
        asked = []
        searching = true
        sockets = [openSocket(port: 5353, join: true), openSocket(port: 0, join: false),
                   openSocket(port: UInt16(ZS_DISCOVERY_BAMBU_PORT), join: false)].compactMap { $0 }
        for s in sockets {
            let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: .main)
            src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.receive(s) } }
            src.resume()
            sources.append(src)
        }
        for delay in [0.0, 1, 3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.sendQuery() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.stop() }
    }

    func stop() {
        for s in sources { s.cancel() }
        sources = []
        for s in sockets { close(s) }
        sockets = []
        searching = false
        if let d { zs_discovery_free(d) }
        d = nil
    }

    private func openSocket(port: UInt16, join: Bool) -> Int32? {
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard s >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            close(s)
            return nil
        }
        if join {
            var m = ip_mreq(imr_multiaddr: in_addr(s_addr: inet_addr("224.0.0.251")), imr_interface: in_addr(s_addr: INADDR_ANY))
            setsockopt(s, IPPROTO_IP, IP_ADD_MEMBERSHIP, &m, socklen_t(MemoryLayout<ip_mreq>.size))
        }
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
        return s
    }

    private func sendQuery() {
        guard let d else { return }
        var q: UnsafePointer<UInt8>?
        var n = 0
        guard zs_discovery_query(d, &q, &n) == 0, let q else { return }
        var to = sockaddr_in()
        to.sin_family = sa_family_t(AF_INET)
        to.sin_port = UInt16(5353).bigEndian
        to.sin_addr.s_addr = inet_addr("224.0.0.251")
        for s in sockets {
            withUnsafePointer(to: &to) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = sendto(s, q, n, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
    }

    private func receive(_ s: Int32) {
        guard let d else { return }
        var buf = [UInt8](repeating: 0, count: 9000)
        while true {
            let n = recv(s, &buf, buf.count, 0)
            if n <= 0 { break }
            if zs_discovery_feed(d, buf, n) == 1 {
                sendQuery()
                readList()
            }
        }
    }

    private func readList() {
        guard let d else { return }
        found = (0 ..< zs_discovery_count(d)).compactMap { i in
            var f = zs_found_printer()
            guard zs_discovery_get(d, i, &f) == 0 else { return nil }
            return FoundPrinter(name: coreText(f.name), kind: f.kind, kindTitle: coreText(f.kind_title), url: coreText(f.url),
                                model: coreText(f.model), bedX: f.bed_x, bedY: f.bed_y, height: f.height,
                                serial: coreText(f.serial))
        }
        for (i, f) in found.enumerated() where !f.url.isEmpty && !f.bambu && !asked.contains(f.url) {
            asked.insert(f.url)
            ask(i, f)
        }
    }

    /// Asks a new printer what it is, with no key.
    private func ask(_ i: Int, _ f: FoundPrinter) {
        let moonraker = f.kind == Int32(ZS_FOUND_MOONRAKER.rawValue)
        guard let url = URL(string: f.url + (moonraker ? "/printer/objects/query?toolhead" : "/api/version")) else { return }
        var r = URLRequest(url: url)
        r.timeoutInterval = 4
        Task { @MainActor [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(for: r), let self, let d = self.d else { return }
            let what = Int32(moonraker ? ZS_FOUND_REPLY_TOOLHEAD.rawValue : ZS_FOUND_REPLY_VERSION.rawValue)
            let changed = data.withUnsafeBytes { b in
                zs_discovery_reply(d, i, what, b.bindMemory(to: CChar.self).baseAddress, b.count)
            }
            if changed == 1 { self.readList() }
        }
    }
}
