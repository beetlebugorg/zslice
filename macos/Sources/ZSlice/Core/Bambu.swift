//! Bambu Lab printers in LAN mode. Untested with a real printer.
//!
//! The core makes the files and the messages (src/bambu.zig): the
//! .gcode.3mf of a plate (zs_bambu_file), the MQTT message that starts a
//! print (zs_bambu_start_message), and the request for a full report
//! (zs_bambu_push_all_message). It reads the reports into a status
//! (zs_printer_status kind 4, the path "report"). This file does the
//! network, with Network.framework:
//!
//! 1. FTPS, implicit TLS on port 990, user "bblp", the access code as the
//!    password: TYPE I, PBSZ 0, PROT P, PASV, then STOR of the file on a
//!    data connection with TLS too. The server starts the TLS of the data
//!    connection after STOR, so the app opens it, sends STOR, waits for
//!    the 150 reply, and then waits for the TLS.
//! 2. MQTT 3.1.1 over TLS on port 8883, with the same user and password:
//!    CONNECT, SUBSCRIBE device/<serial>/report, PUBLISH to
//!    device/<serial>/request. The core makes the packets and reads the
//!    ones that come (zs_mqtt_*, zs_bambu_push_all_packet,
//!    zs_bambu_start_packet). The status asks for a full report and reads
//!    the reports for a few seconds.
//!
//! A Bambu printer has a certificate of its own, which no authority signs.
//! The app trusts it on the first connection, keeps its SHA-256 fingerprint
//! (bambu-pins.json in the settings folder), and from then on accepts only
//! that certificate at that address. The app says so when it pins one.
//!
//! A print starts only after a fresh confirmation of the user that the
//! plate is clear (Workspace.send), never from a timer or a retry.
//!
//! See REFERENCES.md: RFC 959, RFC 4217, MQTT 3.1.1, and the LAN mode of
//! Bambu Lab printers.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import CZslice
import Foundation
import Network
import Security

struct BambuError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The pinned certificate of each Bambu printer, by its address.
@MainActor
enum BambuPins {
    private static var file: URL { SavedSettings.folder.appendingPathComponent("bambu-pins.json") }
    private static let fresh = ProcessInfo.processInfo.environment["ZSLICE_FRESH"] != nil
    private static var memory: [String: String] = [:]

    static var all: [String: String] {
        get {
            if fresh { return memory }
            guard let d = try? Data(contentsOf: file), let m = try? JSONDecoder().decode([String: String].self, from: d) else { return [:] }
            return m
        }
        set {
            if fresh {
                memory = newValue
                return
            }
            try? FileManager.default.createDirectory(at: SavedSettings.folder, withIntermediateDirectories: true)
            if let d = try? JSONEncoder().encode(newValue) { try? d.write(to: file, options: .atomic) }
        }
    }

    static func pin(for host: String) -> String? { all[host] }
    static func set(_ fingerprint: String?, for host: String) { all[host] = fingerprint }
}

/// One TCP connection with TLS, with async send and receive. It accepts
/// the certificate of the server when its fingerprint is `pin`, or any
/// certificate when `pin` is nil; `seen` gets the fingerprint.
final class TLSStream: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "zslice.bambu")
    private var buffer = Data()
    private let seenBox = Box()

    /// The fingerprint of the certificate of the server, after the TLS.
    var seen: String? { seenBox.value }

    init(host: String, port: UInt16, pin: String?, serverName: String?) {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        if let serverName { sec_protocol_options_set_tls_server_name(sec, serverName) }
        // The data connection of FTPS resumes the TLS session of the control
        // connection, which some FTP servers ask for.
        sec_protocol_options_set_tls_resumption_enabled(sec, true)
        let box = seenBox
        sec_protocol_options_set_verify_block(sec, { _, trust, complete in
            let t = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(t) as? [SecCertificate], let leaf = chain.first else {
                complete(false)
                return
            }
            let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
            let fp = digest.map { String(format: "%02x", $0) }.joined(separator: ":")
            box.value = fp
            complete(pin == nil || pin == fp)
        }, queue)
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(tls: tls))
    }

    /// Starts the connection, with no wait (see ready).
    func start() { connection.start(queue: queue) }

    /// Waits until the TLS is up. A failed or refused TLS throws.
    func ready(timeout: Double = 8) async throws {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            let once = Once()
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: once.run { k.resume() }
                case let .failed(e), let .waiting(e):
                    if case .tls = e, self?.seen != nil {
                        once.run { k.resume(throwing: BambuError(message: "The certificate of the printer is not the one that zslice trusts.")) }
                    } else {
                        once.run { k.resume(throwing: BambuError(message: "No connection: \(e.localizedDescription)")) }
                    }
                case .cancelled: once.run { k.resume(throwing: BambuError(message: "The connection closed.")) }
                default: break
                }
            }
            if connection.state == .setup { connection.start(queue: queue) }
            queue.asyncAfter(deadline: .now() + timeout) { once.run { k.resume(throwing: BambuError(message: "The printer did not answer.")) } }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { e in
                if let e { k.resume(throwing: BambuError(message: e.localizedDescription)) } else { k.resume() }
            })
        }
    }

    /// Sends the end of the stream (an FTP data connection ends the file so).
    func finish() async throws {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { e in
                if let e { k.resume(throwing: BambuError(message: e.localizedDescription)) } else { k.resume() }
            })
        }
    }

    /// Some bytes, at most `max`; empty at the end of the stream.
    private func receiveSome(timeout: Double) async throws -> Data {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Data, Error>) in
            let once = Once()
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { d, _, done, e in
                if let e { once.run { k.resume(throwing: BambuError(message: e.localizedDescription)) } } else if let d, !d.isEmpty { once.run { k.resume(returning: d) } } else if done { once.run { k.resume(returning: Data()) } } else { once.run { k.resume(returning: Data()) } }
            }
            queue.asyncAfter(deadline: .now() + timeout) { once.run { k.resume(throwing: BambuError(message: "The printer did not answer in time.")) } }
        }
    }

    /// The bytes that come next, at least one; empty at the end of the
    /// stream.
    func some(timeout: Double = 8) async throws -> Data {
        if !buffer.isEmpty {
            defer { buffer.removeAll() }
            return buffer
        }
        return try await receiveSome(timeout: timeout)
    }

    /// Exactly n bytes.
    func read(_ n: Int, timeout: Double = 8) async throws -> Data {
        while buffer.count < n {
            let d = try await receiveSome(timeout: timeout)
            if d.isEmpty { throw BambuError(message: "The connection closed.") }
            buffer.append(d)
        }
        let out = buffer.prefix(n)
        buffer.removeFirst(n)
        return Data(out)
    }

    /// One line, with no CR LF.
    func readLine(timeout: Double = 8) async throws -> String {
        while true {
            if let r = buffer.range(of: Data("\r\n".utf8)) {
                let line = String(decoding: buffer[..<r.lowerBound], as: UTF8.self)
                buffer.removeSubrange(..<r.upperBound)
                return line
            }
            let d = try await receiveSome(timeout: timeout)
            if d.isEmpty { throw BambuError(message: "The connection closed.") }
            buffer.append(d)
        }
    }

    func close() { connection.cancel() }
}

/// A value for more threads.
private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?
    var value: String? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// Runs a closure once, from any thread.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ f: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { f() }
    }
}

@MainActor
enum BambuLink {
    static let user = "bblp"
    /// 990; tests on a Mac with no right to port 990 set ZSLICE_BAMBU_FTP_PORT.
    static var ftpPort: UInt16 { ProcessInfo.processInfo.environment["ZSLICE_BAMBU_FTP_PORT"].flatMap(UInt16.init) ?? 990 }

    /// The host of the printer: its address with no scheme, port, or path.
    static func host(_ p: Printer) -> String {
        var h = p.url.trimmingCharacters(in: .whitespaces)
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
        if let i = h.firstIndex(where: { $0 == "/" || $0 == ":" }) { h = String(h[..<i]) }
        return h
    }

    /// A TLS stream to the printer, with its pinned certificate. A first
    /// connection pins the certificate, and `pinned` says so.
    private static func open(_ p: Printer, port: UInt16, pinned: inout String?) async throws -> TLSStream {
        let h = host(p)
        guard !h.isEmpty else { throw BambuError(message: "The printer has no address.") }
        let pin = BambuPins.pin(for: h)
        let s = TLSStream(host: h, port: port, pin: pin, serverName: p.serial.isEmpty ? nil : p.serial)
        try await s.ready()
        if pin == nil, let fp = s.seen {
            BambuPins.set(fp, for: h)
            pinned = fp
        }
        return s
    }

    // MARK: - FTPS

    /// A reply of the FTP server: its code and its last line.
    private static func reply(_ s: TLSStream) async throws -> (Int, String) {
        var line = try await s.readLine()
        // A reply of more lines: "123-" up to "123 ".
        if line.count >= 4, line[line.index(line.startIndex, offsetBy: 3)] == "-" {
            let code = line.prefix(3)
            repeat { line = try await s.readLine() } while !(line.hasPrefix(code + " "))
        }
        return (Int(line.prefix(3)) ?? 0, line)
    }

    private static func command(_ s: TLSStream, _ text: String, expect: ClosedRange<Int>) async throws -> String {
        try await s.send(Data((text + "\r\n").utf8))
        let (code, line) = try await reply(s)
        guard expect.contains(code) else {
            let shown = text.hasPrefix("PASS") ? "PASS" : text
            throw BambuError(message: code == 530 ? "The printer refused the access code." : "The printer answered \(shown) with \(line).")
        }
        return line
    }

    /// Uploads a file to the root of the printer.
    static func upload(_ p: Printer, name: String, data: Data, pinned: inout String?) async throws {
        let ctl = try await open(p, port: ftpPort, pinned: &pinned)
        defer { ctl.close() }
        let (hello, _) = try await reply(ctl)
        guard hello == 220 else { throw BambuError(message: "The printer did not greet as an FTP server.") }
        _ = try await command(ctl, "USER \(user)", expect: 331 ... 331)
        _ = try await command(ctl, "PASS \(p.apiKey)", expect: 230 ... 230)
        _ = try await command(ctl, "TYPE I", expect: 200 ... 200)
        _ = try await command(ctl, "PBSZ 0", expect: 200 ... 200)
        _ = try await command(ctl, "PROT P", expect: 200 ... 200)
        let pasv = try await command(ctl, "PASV", expect: 227 ... 227)
        // 227 Entering Passive Mode (h1,h2,h3,h4,p1,p2): the port. The host
        // is the one of the printer (a printer behind NAT gives another).
        guard let open = pasv.firstIndex(of: "("), let close = pasv.firstIndex(of: ")") else { throw BambuError(message: "A bad PASV reply.") }
        let n = pasv[pasv.index(after: open) ..< close].split(separator: ",").compactMap { Int($0) }
        guard n.count == 6 else { throw BambuError(message: "A bad PASV reply.") }
        let dataPort = UInt16(n[4] * 256 + n[5])
        let pin = BambuPins.pin(for: host(p))
        let dc = TLSStream(host: host(p), port: dataPort, pin: pin, serverName: p.serial.isEmpty ? nil : p.serial)
        dc.start()
        defer { dc.close() }
        _ = try await command(ctl, "STOR \(name)", expect: 125 ... 150)
        try await dc.ready()
        var at = 0
        while at < data.count {
            let end = min(at + 256 * 1024, data.count)
            try await dc.send(data.subdata(in: at ..< end))
            at = end
        }
        try await dc.finish()
        dc.close()
        let (done, line) = try await reply(ctl)
        guard done == 226 || done == 250 else { throw BambuError(message: "The upload did not end well: \(line).") }
        try? await ctl.send(Data("QUIT\r\n".utf8))
    }

    // MARK: - MQTT

    /// The bytes of a packet that the core makes (freed here), or nil.
    private static func packet(_ make: (UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, UnsafeMutablePointer<Int>) -> Int32) -> Data? {
        var out: UnsafeMutablePointer<UInt8>?
        var len = 0
        guard make(&out, &len) == 0, let out else { return nil }
        defer { zs_buffer_free(out, len) }
        return Data(bytes: out, count: len)
    }

    /// A session: CONNECT, its CONNACK, and SUBSCRIBE to the reports.
    private static func mqtt(_ p: Printer, pinned: inout String?) async throws -> MQTTSession {
        guard !p.serial.isEmpty else { throw BambuError(message: "The printer has no serial number. Find it on the printer, or add the printer from the search of the network.") }
        let s = try await open(p, port: 8883, pinned: &pinned)
        let m = MQTTSession(s)
        let id = "zslice-\(UUID().uuidString.prefix(8))"
        guard let connect = packet({ zs_mqtt_connect_packet(id, user, p.apiKey, 60, $0, $1) }),
              let subscribe = packet({ zs_mqtt_subscribe_packet("device/\(p.serial)/report", 1, $0, $1) }) else {
            m.close()
            throw BambuError(message: "The MQTT packets did not build.")
        }
        do {
            try await m.stream.send(connect)
            let ack = try await m.next(timeout: 8)
            guard ack.kind == 2 else { throw BambuError(message: "The printer did not answer as an MQTT broker.") }
            if ack.code == 4 || ack.code == 5 { throw BambuError(message: "The printer refused the access code.") }
            guard ack.code == 0 else { throw BambuError(message: "The printer refused the connection (\(ack.code)).") }
            try await m.stream.send(subscribe)
        } catch {
            m.close()
            throw error
        }
        return m
    }

    /// The P1 and A1 printers take the file as "ftp://<file>" (flag 8);
    /// the X1 printers as a path on the SD card.
    static func ftpURL(_ p: Printer) -> Bool {
        let m = p.model.lowercased()
        return m.hasPrefix("bambu-lab-p1") || m.hasPrefix("bambu-lab-a1")
    }

    /// Starts the print of a file on the printer, with the MD5 of its
    /// G-code and bed leveling. Call it only after the user said that the
    /// plate is clear.
    static func start(_ p: Printer, file: String, title: String, gcode: Data, pinned: inout String?) async throws {
        var md5 = [CChar](repeating: 0, count: 33)
        _ = gcode.withUnsafeBytes { zs_bambu_md5($0.bindMemory(to: UInt8.self).baseAddress, $0.count, &md5) }
        let flags: Int32 = 1 | (ftpURL(p) ? 8 : 0)
        let serial = p.serial
        let start = md5.withUnsafeBufferPointer { m in packet({ zs_bambu_start_packet(serial, file, title, m.baseAddress, flags, $0, $1) }) }
        guard let start else { throw BambuError(message: "The start message did not build.") }
        let s = try await mqtt(p, pinned: &pinned)
        defer { s.close() }
        try await s.stream.send(start)
    }

    /// The status: a full report, read for up to 3 seconds, into a status
    /// object of the core (kind 4). Free it with zs_printer_status_free.
    static func statusObject(_ p: Printer) async -> OpaquePointer? {
        var pinned: String?
        guard let s = try? await mqtt(p, pinned: &pinned), let st = zs_printer_status_new() else { return nil }
        defer { s.close() }
        let serial = p.serial
        if let push = packet({ zs_bambu_push_all_packet(serial, $0, $1) }) { try? await s.stream.send(push) }
        let end = Date().addingTimeInterval(3)
        var reports = 0
        while Date() < end {
            guard let pk = try? await s.next(timeout: max(0.2, end.timeIntervalSinceNow)) else { break }
            guard pk.kind == 3 else { continue }
            let payload = pk.payload
            _ = payload.withUnsafeBytes { zs_printer_status_feed(st, 4, "report", $0.bindMemory(to: CChar.self).baseAddress, $0.count) }
            reports += 1
            // The full report has the state; one is enough.
            if payload.range(of: Data("gcode_state".utf8)) != nil { break }
        }
        if reports == 0 {
            zs_printer_status_free(st)
            return nil
        }
        return st
    }

    /// Tests the connection: the MQTT login, which checks the access code
    /// and the serial number.
    static func test(_ p: Printer) async -> LinkResult {
        var pinned: String?
        do {
            let s = try await mqtt(p, pinned: &pinned)
            s.close()
            var m = "Connected. (Bambu support is untested with a real printer.)"
            if let pinned { m += " zslice trusts the certificate of this printer from now on: SHA-256 \(pinned.prefix(23))…" }
            return LinkResult(ok: true, message: m)
        } catch {
            return LinkResult(ok: false, message: error.localizedDescription)
        }
    }
}

/// An MQTT session over a TLS stream, with the reader of the core
/// (zs_mqtt_reader): the packets that come, whole.
final class MQTTSession: @unchecked Sendable {
    let stream: TLSStream
    private let reader: OpaquePointer?

    init(_ stream: TLSStream) {
        self.stream = stream
        reader = zs_mqtt_reader_new()
    }

    deinit { zs_mqtt_reader_free(reader) }

    /// The next packet: its kind (2 CONNACK, 3 PUBLISH, ...), the return
    /// code of a CONNACK, and the payload of a PUBLISH.
    func next(timeout: Double) async throws -> (kind: Int32, code: Int32, payload: Data) {
        while true {
            var pk = zs_mqtt_packet()
            let rc = zs_mqtt_reader_next(reader, &pk)
            if rc < 0 { throw BambuError(message: "The printer did not answer as an MQTT broker.") }
            if rc == 1 {
                let payload = pk.payload.map { Data(bytes: $0, count: pk.payload_len) } ?? Data()
                return (pk.kind, pk.return_code, payload)
            }
            let d = try await stream.some(timeout: timeout)
            if d.isEmpty { throw BambuError(message: "The connection closed.") }
            _ = d.withUnsafeBytes { zs_mqtt_reader_feed(reader, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        }
    }

    /// DISCONNECT, then the close of the stream.
    func close() {
        let s = stream
        Task {
            try? await s.send(Data([0xE0, 0]))
            s.close()
        }
    }
}
