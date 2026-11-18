//! Gzip: a gzip file (RFC 1952) of some bytes, for the estimate of a
//! printdeck (the G-code of some MB goes down to a few hundred kB). The
//! Compression framework of Apple makes the raw DEFLATE stream (RFC 1951,
//! COMPRESSION_ZLIB); this file adds the gzip header and the trailer (the
//! CRC-32 and the size).
//!
//! Reference: RFC 1951 and RFC 1952 (see REFERENCES.md).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import Compression
import Foundation

enum Gzip {
    static func compress(_ data: Data) -> Data? {
        let cap = data.count + 1024
        var raw = Data(count: cap)
        let n = raw.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, cap,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0 else { return nil }
        var out = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3])
        out.append(raw.prefix(n))
        var crc = crc32(data).littleEndian
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        out.append(Data(bytes: &crc, count: 4))
        out.append(Data(bytes: &size, count: 4))
        return out
    }

    private static let table: [UInt32] = (0 ..< 256).map { i in
        var c = UInt32(i)
        for _ in 0 ..< 8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { b in
            for x in b.bindMemory(to: UInt8.self) { c = table[Int((c ^ UInt32(x)) & 0xff)] ^ (c >> 8) }
        }
        return c ^ 0xFFFF_FFFF
    }
}
