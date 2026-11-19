//! Camera: the live picture of a printer camera, for the Printers page
//! (web/app/camera.js, linux/src/ui/camera-view.c).
//!
//! The addresses come from the printer (PrinterLink.camera, from
//! zs_printer_status_camera). A feed reads one of three sources:
//!
//! - An MJPEG stream (multipart/x-mixed-replace, RFC 2046): URLSession
//!   reads the parts itself, with a new response for each part. A part
//!   is whole at its JPEG end marker, or when the next part starts.
//!   A printdeck takes w= and fps= in the query, so a small card asks for
//!   a small picture at a low rate.
//! - Snapshots only (a WebRTC camera of Moonraker): the feed loads the
//!   snapshot again every few seconds.
//! - A Bambu Lab printer: the JPEG frames of port 6000 over TLS (P1 and
//!   A1). The feed sends the 80 bytes of zs_bambu_camera_auth, and the
//!   core cuts the frames (zs_bambu_jpeg_reader). The X1, H2, P2S, and X2D
//!   stream H.264 over RTSPS on port 322, which the Mac app cannot play
//!   yet: the feed says so.
//!
//! The API key goes in the X-Api-Key header. A feed plays only while its
//! view shows (start and stop), and the decode of a frame runs off the
//! main thread, with one frame on its way at a time. No bytes in 12 s, or
//! an error: the feed says why and tries again after 20 s.
//!
//! See REFERENCES.md: RFC 2046 (MJPEG over HTTP), and the LAN mode of
//! Bambu Lab printers (the camera of port 6000).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CZslice
import Foundation
import ImageIO
import Observation

/// Where the picture of a printer comes from.
struct CameraSource: Equatable {
    var stream: URL?
    var snapshot: URL?
    var key = ""
    var printdeck = false
    var flipH = false, flipV = false
    /// Degrees clockwise: 0, 90, 180, or 270.
    var rotation = 0
    /// Bambu Lab: the host, the access code, the serial number, and the
    /// kind of zs_bambu_camera_kind (0 not known, 1 RTSPS, 2 JPEG).
    var bambuHost = ""
    var bambuCode = ""
    var bambuSerial = ""
    var bambuKind = -1

    init(stream: URL?, snapshot: URL?, key: String, printdeck: Bool, flipH: Bool, flipV: Bool, rotation: Int) {
        self.stream = stream
        self.snapshot = snapshot
        self.key = key
        self.printdeck = printdeck
        self.flipH = flipH
        self.flipV = flipV
        self.rotation = rotation
    }

    init(bambu host: String, code: String, serial: String, kind: Int) {
        bambuHost = host
        bambuCode = code
        bambuSerial = serial
        bambuKind = kind
    }

    var bambu: Bool { bambuKind >= 0 }
}

@MainActor
@Observable
final class CameraFeed {
    static let firstWait = 12.0, retryWait = 20.0
    static let snapTile = 5.0, snapLarge = 1.0

    let source: CameraSource
    let large: Bool
    private(set) var image: CGImage?
    /// What the picture area says: "Connecting…", or why it has none.
    private(set) var message = "Connecting…"
    private(set) var frames = 0

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var decoding = false
    @ObservationIgnored private var playing = false

    init(source: CameraSource, large: Bool) {
        self.source = source
        self.large = large
    }

    func start() {
        guard !playing else { return }
        playing = true
        task = Task { [weak self] in await self?.run() }
    }

    func stop() {
        playing = false
        task?.cancel()
        task = nil
    }

    /// Plays until stop: each failure waits, then tries again.
    private func run() async {
        while playing, !Task.isCancelled {
            let why = await playOnce()
            guard playing, !Task.isCancelled else { return }
            if let why { message = why }
            try? await Task.sleep(for: .seconds(Self.retryWait))
        }
    }

    /// One try of the source. Returns why it ended, or nil.
    private func playOnce() async -> String? {
        if source.bambu {
            if source.bambuKind == 1 {
                return "This printer streams its camera over RTSP, which the Mac app cannot play yet."
            }
            return await playBambu()
        }
        if let s = source.stream { return await playStream(s) }
        if let s = source.snapshot { return await playSnapshots(s) }
        return "No camera"
    }

    /// A frame came: decode it off the main thread, one at a time.
    nonisolated private func frame(_ jpeg: Data) {
        Task { @MainActor in
            guard self.playing, !self.decoding else { return }
            self.decoding = true
            let img = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
                return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            }.value
            self.decoding = false
            guard self.playing, let img else { return }
            self.image = img
            self.message = ""
            self.frames += 1
        }
    }

    private func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.cachePolicy = .reloadIgnoringLocalCacheData
        if !source.key.isEmpty { r.setValue(source.key, forHTTPHeaderField: "X-Api-Key") }
        return r
    }

    // MARK: - MJPEG

    private func playStream(_ url: URL) async -> String? {
        var u = url
        // printdeck: a small picture at a low rate for a card (webcam.go).
        if source.printdeck, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            var q = c.queryItems ?? []
            q.removeAll { $0.name == "w" || $0.name == "fps" }
            q += large ? [URLQueryItem(name: "fps", value: "10")] : [URLQueryItem(name: "w", value: "480"), URLQueryItem(name: "fps", value: "4")]
            c.queryItems = q
            u = c.url ?? url
        }
        // No bytes for 12 s: the request times out.
        var r = request(u)
        r.timeoutInterval = Self.firstWait
        let reader = StreamReader { [weak self] jpeg in self?.frame(jpeg) }
        let session = URLSession(configuration: .ephemeral, delegate: reader, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (k: CheckedContinuation<String?, Never>) in
                reader.done = { why in k.resume(returning: why) }
                session.dataTask(with: r).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    // MARK: - snapshots

    private func playSnapshots(_ url: URL) async -> String? {
        while playing, !Task.isCancelled {
            var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let items = c?.queryItems ?? []
            c?.queryItems = items + [URLQueryItem(name: "_", value: String(Int(Date().timeIntervalSince1970 * 1000)))]
            var r = request(c?.url ?? url)
            r.timeoutInterval = Self.firstWait
            do {
                let (d, resp) = try await URLSession.shared.data(for: r)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 401 || code == 403 { return "The printer refused the API key for its camera." }
                guard (200 ..< 300).contains(code), !d.isEmpty else { return "The camera gave no picture. It can be off, or have no picture now." }
                frame(d)
            } catch {
                if Task.isCancelled { return nil }
                return "The camera did not answer. The printer can be off, or out of reach of this computer."
            }
            try? await Task.sleep(for: .seconds(large ? Self.snapLarge : Self.snapTile))
        }
        return nil
    }

    // MARK: - Bambu Lab, port 6000

    /// 6000; tests set ZSLICE_BAMBU_CAMERA_PORT.
    static var bambuPort: UInt16 { ProcessInfo.processInfo.environment["ZSLICE_BAMBU_CAMERA_PORT"].flatMap(UInt16.init) ?? 6000 }

    private func playBambu() async -> String? {
        guard !source.bambuHost.isEmpty, !source.bambuCode.isEmpty else { return "The printer has no address or access code." }
        var auth = [UInt8](repeating: 0, count: 80)
        guard zs_bambu_camera_auth(source.bambuCode, &auth) == 0 else { return "The access code is too long." }
        // The pin of the certificate, as for MQTT (Bambu.swift).
        let pin = BambuPins.pin(for: source.bambuHost)
        let s = TLSStream(host: source.bambuHost, port: Self.bambuPort, pin: pin,
                          serverName: source.bambuSerial.isEmpty ? nil : source.bambuSerial)
        defer { s.close() }
        guard let reader = zs_bambu_jpeg_reader_new() else { return "No memory." }
        defer { zs_bambu_jpeg_reader_free(reader) }
        do {
            try await s.ready()
            if pin == nil, let fp = s.seen { BambuPins.set(fp, for: source.bambuHost) }
            try await s.send(Data(auth))
            while playing, !Task.isCancelled {
                let d = try await s.some(timeout: Self.firstWait)
                if d.isEmpty { return "The camera stream ended." }
                let rc = d.withUnsafeBytes { zs_bambu_jpeg_reader_feed(reader, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
                if rc < 0 { return "The printer sent no camera frames. Check the access code." }
                var p: UnsafePointer<UInt8>?
                var n = 0
                while true {
                    let k = zs_bambu_jpeg_reader_next(reader, &p, &n)
                    if k < 0 { return "The printer sent no camera frames. Check the access code." }
                    guard k == 1, let p else { break }
                    frame(Data(bytes: p, count: n))
                }
            }
            return nil
        } catch {
            if Task.isCancelled { return nil }
            return "The camera did not answer: \(error.localizedDescription)"
        }
    }
}

/// The delegate of one MJPEG stream: the frames, and why it ended.
final class StreamReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let onFrame: (Data) -> Void
    /// Runs once, with why the stream ended (nil: stopped).
    var done: ((String?) -> Void)?
    private var part = Data()
    private var ended = false
    private let lock = NSLock()

    init(onFrame: @escaping (Data) -> Void) {
        self.onFrame = onFrame
    }

    private func finish(_ why: String?) {
        lock.lock()
        let first = !ended
        ended = true
        lock.unlock()
        if first { done?(why) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        if let h = response as? HTTPURLResponse, !(200 ..< 300).contains(h.statusCode) {
            finish(h.statusCode == 401 || h.statusCode == 403 ? "The printer refused the API key for its camera." : "The camera answered \(h.statusCode).")
            return .cancel
        }
        // A new part: the one before it is whole. (The first response is
        // the multipart envelope, with no body.)
        if !part.isEmpty { onFrame(part) }
        part = Data()
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        part.append(data)
        // A part with its end marker: show it now.
        if part.count > 4, part[part.endIndex - 2] == 0xFF, part[part.endIndex - 1] == 0xD9 {
            onFrame(part)
            part = Data()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error as? URLError, e.code == .cancelled {
            finish(nil)
        } else if error != nil {
            finish("The camera did not answer. The printer can be off, or out of reach of this computer.")
        } else {
            finish("The camera stream ended.")
        }
    }
}
