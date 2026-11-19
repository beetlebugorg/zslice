// enc.swift: encodes two pictures to H.264 with VideoToolbox, for the test
// camera tools/fake_rtsps.py on a Mac with no ffmpeg. It draws the pictures
// (ten frames each, in turn) with a red square that moves, so the P frames
// have motion: Baseline profile, 640x480, a key frame each 10 frames.
// The output (.aus): for each frame, a u32 big endian length and the Annex
// B bytes; a key frame has its SPS and PPS in front.
//
//   swiftc -O macos/tools/enc.swift -o /tmp/enc
//   /tmp/enc a.jpg b.jpg video.aus 40
//
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import CoreMedia
import VideoToolbox
let args = CommandLine.arguments
let imgs = [args[1], args[2]].map { NSImage(contentsOfFile: $0)!.cgImage(forProposedRect: nil, context: nil, hints: nil)! }
let w = 640, h = 480, count = Int(args[4]) ?? 40
var out = Data()
var session: VTCompressionSession?
VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                           imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
let s = session!
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 10 as CFNumber)
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: 1_500_000 as CFNumber)
let sc: [UInt8] = [0, 0, 0, 1]
for k in 0 ..< count {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb!), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb!),
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.draw(imgs[(k / 10) % 2], in: CGRect(x: 0, y: 0, width: w, height: h))
    // A bar that moves, so the P frames have motion.
    ctx.setFillColor(NSColor.systemRed.cgColor)
    ctx.fill(CGRect(x: (k * 15) % w, y: 20, width: 40, height: 40))
    CVPixelBufferUnlockBaseAddress(pb!, [])
    VTCompressionSessionEncodeFrame(s, imageBuffer: pb!, presentationTimeStamp: CMTime(value: Int64(k), timescale: 10), duration: .invalid,
                                    frameProperties: nil, infoFlagsOut: nil) { status, _, sample in
        guard status == noErr, let sample, let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var au = Data()
        let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let key = !(atts?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        if key, let fmt = CMSampleBufferGetFormatDescription(sample) {
            for i in 0 ..< 2 {
                var p: UnsafePointer<UInt8>?
                var n = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &p, parameterSetSizeOut: &n, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                au.append(contentsOf: sc); au.append(p!, count: n)
            }
        }
        var len = 0
        var ptr: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
        let raw = Data(bytes: ptr!, count: len)
        var i = 0
        while i + 4 <= raw.count {
            let n = Int(raw[i]) << 24 | Int(raw[i + 1]) << 16 | Int(raw[i + 2]) << 8 | Int(raw[i + 3])
            au.append(contentsOf: sc); au.append(raw.subdata(in: i + 4 ..< i + 4 + n))
            i += 4 + n
        }
        var l = UInt32(au.count).bigEndian
        out.append(Data(bytes: &l, count: 4)); out.append(au)
    }
}
VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
try! out.write(to: URL(fileURLWithPath: args[3]))
print("wrote", out.count, "bytes")
