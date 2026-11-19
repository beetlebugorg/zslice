//! H264Decoder: decodes the H.264 frames of a printer camera with
//! VideoToolbox, for the RTSP camera of a Bambu Lab printer
//! (Core/Camera.swift, src/rtsp.zig).
//!
//! A frame comes as an access unit in Annex B: each NAL unit after the
//! start code 00 00 00 01. The decoder splits it at the start codes. The
//! SPS (type 7) and PPS (type 8) make the format of the video
//! (CMVideoFormatDescriptionCreateFromH264ParameterSets); a new format
//! makes a new decompression session. The other NAL units go to the
//! session in AVCC form (each after its length, 4 bytes big endian), as
//! one sample. Each decoded picture becomes a CGImage. The decoder skips
//! the CGImage of a picture when `want` says no, so a small card does not
//! pay for each frame, but it still decodes each frame: the next frames
//! need it.
//!
//! See REFERENCES.md: ITU-T H.264 Annex B.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

final class H264Decoder: @unchecked Sendable {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var sps = Data(), pps = Data()
    /// A picture is out: true takes it.
    var want: () -> Bool = { true }
    var onImage: (CGImage) -> Void = { _ in }
    /// The frames that did not decode, for a log.
    private(set) var errors = 0

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    /// The NAL units of an Annex B access unit (with 3- or 4-byte start
    /// codes).
    static func nalUnits(_ au: Data) -> [Data] {
        var out: [Data] = []
        let b = [UInt8](au)
        var i = 0
        var start = -1
        while i + 2 < b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                if start >= 0 {
                    var end = i
                    // The zero byte of a 4-byte start code.
                    if end > start, b[end - 1] == 0 { end -= 1 }
                    if end > start { out.append(Data(b[start ..< end])) }
                }
                i += 3
                start = i
                continue
            }
            i += 1
        }
        if start >= 0, start < b.count { out.append(Data(b[start...])) }
        return out
    }

    /// Decodes one access unit. A frame before the first SPS and PPS waits
    /// for them (it is dropped).
    func decode(_ au: Data) {
        var units: [Data] = []
        var newSets = false
        for n in Self.nalUnits(au) {
            guard let h = n.first else { continue }
            switch h & 0x1F {
            case 7:
                if n != sps { sps = n; newSets = true }
            case 8:
                if n != pps { pps = n; newSets = true }
            // Access unit delimiters and SEI: not for the decoder.
            case 9, 6: break
            default: units.append(n)
            }
        }
        if newSets || session == nil { makeSession() }
        guard let session, let format, !units.isEmpty else { return }
        var avcc = Data()
        for n in units {
            var len = UInt32(n.count).bigEndian
            avcc.append(Data(bytes: &len, count: 4))
            avcc.append(n)
        }
        var block: CMBlockBuffer?
        let count = avcc.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: count, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return }
        let copied = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: count) }
        guard copied == noErr else { return }
        var sample: CMSampleBuffer?
        var size = count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return }
        let take = want()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
            guard let self else { return }
            guard status == noErr, let image else {
                self.errors += 1
                return
            }
            guard take else { return }
            var cg: CGImage?
            if VTCreateCGImageFromCVPixelBuffer(image, options: nil, imageOut: &cg) == noErr, let cg { self.onImage(cg) }
        }
        if status != noErr { errors += 1 }
    }

    /// A session for the SPS and PPS that came last.
    private func makeSession() {
        guard !sps.isEmpty, !pps.isEmpty else { return }
        var desc: CMVideoFormatDescription?
        let rc = sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let ptrs = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: ptrs,
                                                                           parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
            }
        }
        guard rc == noErr, let desc else { return }
        if session != nil, let format, CMFormatDescriptionEqual(format, otherFormatDescription: desc) { return }
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = desc
        // BGRA pictures, which a CGImage takes as they are.
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
        var s: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: desc, decoderSpecification: nil,
                                           imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                                           decompressionSessionOut: &s) == noErr else { return }
        session = s
    }
}
