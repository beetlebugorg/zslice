//! Signed prints (src/sign.zig, docs/user/getting-started.md): each G-code
//! that the app exports or sends ends with a signature line, "; zslice-
//! signature: ed25519 <key id> <base64>", over the SHA-256 of the bytes
//! before it (zs_sign_gcode). A printdeck that trusts the key of the app
//! prints it; a printdeck that does not answers 422.
//!
//! The secret key of the app: 32 random bytes of the OS (SecRandomCopyBytes),
//! made once and kept in the Keychain, as a key text of the core
//! (zs_sign_key_from_seed). "Get a Key" gives the printer the public key,
//! and the app shows its key id while the printer asks the person, so they
//! can see that it is the same on the deck.
//!
//! A printdeck with a certificate (its https address): the app pins the
//! certificate of the printer (the SHA-256 of the leaf, and the time from
//! which it is valid). A later certificate moves the pin, as the deck
//! renews its key every 60 days. An older or another certificate stops the
//! request with a warning, and the app does not fall back to http then.
//! "Get a Key" pins again.
//!
//! See REFERENCES.md: RFC 8032 (Ed25519).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import CZslice
import Foundation
import Security

@MainActor
enum Signer {
    private static let account = "zslice-signing-key"
    private static var cached: String?

    /// The secret key text, made once.
    static var secret: String? {
        if let cached { return cached }
        // A test run (ZSLICE_FRESH) keeps a key of its own in memory only.
        let fresh = ProcessInfo.processInfo.environment["ZSLICE_FRESH"] != nil
        if !fresh, let k = Keychain.read(account: account), !k.isEmpty {
            cached = k
            return k
        }
        var seed = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, seed.count, &seed) == errSecSuccess else { return nil }
        defer { for k in seed.indices { seed[k] = 0 } }
        var out = [CChar](repeating: 0, count: Int(ZS_SIGN_TEXT_MAX))
        guard zs_sign_key_from_seed(seed, seed.count, &out, out.count) == 0 else { return nil }
        let k = out.withUnsafeBufferPointer { coreText($0.baseAddress) }
        if !fresh { Keychain.write(k, account: account, label: "zslice signing key") }
        cached = k
        return k
    }

    static var publicKey: String? {
        guard let s = secret else { return nil }
        var out = [CChar](repeating: 0, count: Int(ZS_SIGN_TEXT_MAX))
        guard zs_sign_public_key(s, &out, out.count) == 0 else { return nil }
        return out.withUnsafeBufferPointer { coreText($0.baseAddress) }
    }

    /// The short id of the key, as the deck shows it.
    static var keyID: String {
        guard let p = publicKey else { return "" }
        var out = [CChar](repeating: 0, count: 17)
        guard zs_sign_key_id(p, &out, out.count) == 0 else { return "" }
        return out.withUnsafeBufferPointer { coreText($0.baseAddress) }
    }

    /// The G-code with the signature line at its end (the G-code as it is
    /// if the key is missing).
    static func sign(_ gcode: Data) -> Data {
        guard let s = secret else { return gcode }
        var out: UnsafeMutablePointer<UInt8>?
        var len = 0
        let rc = gcode.withUnsafeBytes { zs_sign_gcode(s, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, &out, &len) }
        guard rc == 0, let out else { return gcode }
        defer { zs_buffer_free(out, len) }
        return Data(bytes: out, count: len)
    }
}

/// The pinned certificates of the https printers, by host: the SHA-256 of
/// the leaf, and the time from which it is valid.
@MainActor
enum CertPins {
    struct Pin: Codable {
        var sha: String
        var notBefore: Double
    }

    private static var file: URL { SavedSettings.folder.appendingPathComponent("https-pins.json") }
    private static let fresh = ProcessInfo.processInfo.environment["ZSLICE_FRESH"] != nil
    private static var memory: [String: Pin] = [:]
    /// The hosts whose certificate the last request refused.
    static var refused: Set<String> = []

    static var all: [String: Pin] {
        get {
            if fresh { return memory }
            guard let d = try? Data(contentsOf: file), let m = try? JSONDecoder().decode([String: Pin].self, from: d) else { return [:] }
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

    static func forget(host: String) { all[host] = nil }

    /// Checks the leaf of a host: true to go on. The first one pins; a later
    /// one moves the pin; an older or another one refuses.
    static func check(host: String, sha: String, notBefore: Double) -> Bool {
        guard let pin = all[host] else {
            all[host] = Pin(sha: sha, notBefore: notBefore)
            return true
        }
        if pin.sha == sha { return true }
        if notBefore > pin.notBefore {
            all[host] = Pin(sha: sha, notBefore: notBefore)
            return true
        }
        refused.insert(host)
        return false
    }
}

/// The URLSession of the https printers: the trust of the system first,
/// then the pin.
final class PinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    static let shared = PinningDelegate()
    static let session = URLSession(configuration: .ephemeral, delegate: shared, delegateQueue: nil)

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        guard SecTrustEvaluateWithError(trust, nil),
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return (.cancelAuthenticationChallenge, nil)
        }
        let sha = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        var notBefore = 0.0
        if let values = SecCertificateCopyValues(leaf, [kSecOIDX509V1ValidityNotBefore] as CFArray, nil) as? [CFString: Any],
           let entry = values[kSecOIDX509V1ValidityNotBefore] as? [CFString: Any],
           let v = entry[kSecPropertyKeyValue] as? NSNumber {
            notBefore = v.doubleValue
        }
        let host = challenge.protectionSpace.host
        let ok = await MainActor.run { CertPins.check(host: host, sha: sha, notBefore: notBefore) }
        return ok ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
    }
}

/// A request that a pin refused: never fall back to http then.
struct PinError: LocalizedError {
    let host: String
    var errorDescription: String? {
        "The certificate of \(host) is older than, or not the same as, the one that zslice trusts. Nothing was sent. If the printer was reset, use Get a Key in Settings > Printers to trust it again."
    }
}
