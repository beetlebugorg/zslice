//! Recorder: a video of the window, for the docs and for demos
//! (ZSLICE_RECORD=path.mov). It plays a script of the app frame by frame:
//! each step changes the view (the camera, the colors, the replay, the
//! layer slider), draws one frame, and appends the image of the window to
//! the movie (AVAssetWriter, H.264, 30 frames a second). The frames are
//! made one by one, so the movie is smooth whatever the time of a frame.
//! It needs no permission to record the screen.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import CZslice
import CoreVideo
import Foundation

@MainActor
enum Recorder {
    static let fps: Int32 = 30

    /// Records the demo into a movie file, and logs when it is done.
    static func record(_ ws: Workspace, to url: URL) async {
        guard let v = ws.canvas.view, let first = await ws.canvas.captureWindow() else { return }
        // H.264 wants even sizes.
        let w = first.width & ~1, h = first.height & ~1
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        var n: Int64 = 0

        func frame() async {
            guard let img = await ws.canvas.captureWindow(), let pool = adaptor.pixelBufferPool else { return }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { return }
            CVPixelBufferLockBaseAddress(pb, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            while !input.isReadyForMoreMediaData { try? await Task.sleep(for: .milliseconds(5)) }
            adaptor.append(pb, withPresentationTime: CMTime(value: n, timescale: fps))
            n += 1
            if n % 30 == 0 { NSLog("zslice record: frame %lld", n) }
        }

        func orbit(_ frames: Int, dx: Float) async {
            for _ in 0 ..< frames {
                zs_view_orbit(v, dx, 0)
                await frame()
            }
        }

        // 1. The print in its filament color: a slow turn.
        ws.colorMode = 0
        await orbit(75, dx: 2.4)
        // 2. One color for each line type, and a turn back.
        ws.colorMode = 1
        await orbit(60, dx: -2.4)
        // 3. The layer slider goes down, and back up.
        let top = max(1, ws.layerCount - 1)
        for i in 0 ..< 45 {
            ws.setRange(lo: 0, hi: top - (top * 6 / 10) * i / 44)
            await frame()
        }
        // 4. The replay: the nozzle prints a few layers.
        let (t0, _) = ws.layerTimes(ws.hi)
        let (_, t1) = ws.layerTimes(min(top, ws.hi + 2))
        for i in 0 ..< 90 {
            let t = t0 + (t1 - t0) * Double(i) / 89
            zs_view_set_time(v, t)
            ws.canvas.layer2D = Int(zs_view_layer_at_time(v, t))
            await frame()
        }
        ws.setRange(lo: 0, hi: top)
        // 5. The speed ramp, and a turn.
        ws.colorMode = 2
        await orbit(60, dx: 2.4)
        // 6. The 2D layer view.
        ws.colorMode = 1
        ws.page = .twoD
        ws.setRange(lo: 0, hi: top / 3)
        for _ in 0 ..< 45 { await frame() }
        ws.page = .threeD
        await orbit(30, dx: -2.4)

        input.markAsFinished()
        await writer.finishWriting()
        NSLog("zslice record: %lld frames to %@ (%@)", n, url.path, writer.error?.localizedDescription ?? "ok")
    }
}
