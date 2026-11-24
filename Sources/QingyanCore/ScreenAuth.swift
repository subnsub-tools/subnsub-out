//
//  ScreenAuth.swift
//
//  Sign-in and record encryption for Apple Screen Sharing (RFB with Apple's
//  extensions), ported from the Go client this app used before (auth.go and
//  cipher.go of its applehp package) and checked against it byte for byte.
//
//  A sign-in runs on a thread of its own with blocking I/O, through
//  ScreenIO, in this order:
//
//    handshake      the banner "RFB 003.889" both ways, then the security
//                   types the server offers (Apple's own is 33, 0x21)
//    loginSRP       type 33 as current macOS runs it: the server's RSA key,
//                   the user name sealed to that key, then SRP-6a with
//                   SHA-512 over the server's 4096-bit group (RFC 5054), the
//                   password stretched with PBKDF2-HMAC-SHA512
//    loginNonSRP    the older type 33: user name and password in fields of
//                   64 bytes, AES-128-ECB under a random key that is sealed
//                   to the server's RSA key; for a server that answers the
//                   SRP sign-in with a short challenge (srpFallback), on a
//                   new connection
//
//  Both return the 16-byte wrap key. Once the session's prelude is done the
//  server sends a 36-byte rekey blob (encoding 0x44f); ScreenRecordCipher
//  opens it with the wrap key, and from then on every message each way is a
//  record: a 2-byte length, then AES-128-CBC over the message's length, the
//  message, zero padding and a SHA-1 of a counter and all of that. The CBC
//  chain runs on from record to record, one chain each way.
//
//  Swift has no big integer, so ScreenBigUInt is a small unsigned one (64-bit
//  limbs, Montgomery multiplication for odd moduli). RSA is done with it as
//  well (PKCS #1 v1.5 padding, as Go's rsa.EncryptPKCS1v15 pads), so that
//  every random byte of a sign-in comes from the one source a caller passes
//  in and a test can replay a sign-in exactly.
//
//  Where the Go code would panic (a challenge whose modulus is 0 or 1) this
//  code throws instead. The error texts are the Go client's, without its
//  "applehp: " prefix.
//

import Foundation
import CryptoKit
import CommonCrypto
import Security

// MARK: - I/O, randomness, errors

/// The connection a sign-in runs over. Both calls block.
public protocol ScreenIO: AnyObject {
    /// Reads exactly `count` bytes, blocking; throws on end of stream or error.
    func readFull(_ count: Int) throws -> [UInt8]
    /// Writes all of `bytes`, blocking.
    func write(_ bytes: [UInt8]) throws
}

/// A source of random bytes: returns exactly `count` of them.
public typealias ScreenRandom = (_ count: Int) throws -> [UInt8]

/// Why a sign-in failed.
public enum ScreenAuthError: Error, CustomStringConvertible, LocalizedError {
    /// The server answered the SRP sign-in with a short challenge (an older
    /// macOS): try `loginNonSRP` on a new connection.
    case srpFallback
    /// The server turned the credentials down (wrong name or password, or a
    /// refusal of its own); not worth another try with the same ones.
    case rejected(String)
    /// The connection failed: what was being done, and the error ScreenIO threw.
    case io(String, Error)
    /// Anything else: the server's message broke the format, its key is not
    /// usable, and the like.
    case failed(String)

    public var description: String {
        switch self {
        case .srpFallback: return "server fell back from SRP to legacy auth"
        case .rejected(let detail): return "authentication rejected: " + detail
        case .io(let doing, let error): return doing + ": " + String(describing: error)
        case .failed(let detail): return detail
        }
    }

    public var errorDescription: String? { description }
}

// MARK: - Sign-in

public enum ScreenAuth {
    /// The banner this client sends: "RFB 003.889\n".
    public static let protocolVersion: [UInt8] = Array("RFB 003.889\n".utf8)
    /// RFB security type 33, Apple's RSA1 sign-in (SRP or the older form).
    public static let securityTypeAppleRSA: UInt8 = 0x21

    /// Random bytes from the system (SecRandomCopyBytes).
    public static func systemRandom(_ count: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        if count == 0 { return out }
        let status = out.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else {
            throw ScreenAuthError.failed("random source: SecRandomCopyBytes returned \(status)")
        }
        return out
    }

    /// Reads the server's 12-byte banner, sends `protocolVersion`, and reads the
    /// security types the server offers. The banner comes back one character a
    /// byte (ISO Latin 1), so no byte is lost.
    public static func handshake(_ io: ScreenIO) throws -> (banner: String, securityTypes: [UInt8]) {
        let banner = try readIO(io, 12, "read protocol banner")
        guard banner.starts(with: [0x52, 0x46, 0x42, 0x20]) else {
            throw ScreenAuthError.failed("unexpected protocol banner " + goQuote(banner))
        }
        try writeIO(io, protocolVersion, "write protocol banner")
        let count = Int(try readIO(io, 1, "read security-type count")[0])
        if count == 0 {
            // A refusal may carry a reason; a broken one is still a refusal.
            if let lenBytes = try? io.readFull(4), lenBytes.count == 4 {
                let n = be32(lenBytes, 0)
                if n > 0 && n <= 4096, let reason = try? io.readFull(Int(n)), reason.count == Int(n) {
                    throw ScreenAuthError.failed("server refused handshake: " + String(decoding: reason, as: UTF8.self))
                }
            }
            throw ScreenAuthError.failed("server returned empty security-type list")
        }
        let types = try readIO(io, count, "read security types")
        return (String(banner.map { Character(Unicode.Scalar($0)) }), types)
    }

    /// Security type 33 with SRP-6a. Call after `handshake`, on a server that
    /// offers 0x21. Returns the 16-byte wrap key (the first half of SHA-256 of
    /// the SRP session key). Throws `.srpFallback` for a server that wants the
    /// older sign-in, `.rejected` for credentials it turned down.
    public static func loginSRP(_ io: ScreenIO, username: String, password: String,
                                random: ScreenRandom = ScreenAuth.systemRandom) throws -> [UInt8] {
        let key = try fetchServerKey(io)
        let user = Array(username.utf8)
        var inner: [UInt8] = []
        appendBE32(&inner, UInt32(truncatingIfNeeded: user.count))
        inner += user
        inner += [0, 0, 0]
        var payload: [UInt8] = []
        appendBE32(&payload, UInt32(truncatingIfNeeded: inner.count))
        payload += inner

        let sealed: [UInt8]
        do {
            sealed = try key.encryptPKCS1v15(payload, random: random)
        } catch let failure as RSAFailure {
            throw ScreenAuthError.failed("RSA encrypt SRP identity: " + failure.message)
        }
        guard sealed.count == rsaBlockLen else {
            throw ScreenAuthError.failed("expected \(rsaBlockLen)B RSA ciphertext, got \(sealed.count)")
        }

        var c2s1 = [UInt8](repeating: 0, count: 4 + 650)
        putBE32(&c2s1, 0, 650)
        c2s1[4] = 1
        c2s1[5] = 0
        c2s1.replaceSubrange(6..<10, with: rsa1Tag)
        c2s1[10] = 0x00
        c2s1[11] = 0x02
        putBE16(&c2s1, 12, UInt16(sealed.count))
        c2s1.replaceSubrange(14..<(14 + sealed.count), with: sealed)
        try writeIO(io, c2s1, "send SRP c2s1")

        let s2c1Len = be32(try readIO(io, 4, "read SRP challenge length"), 0)
        guard s2c1Len <= 32768 else {
            throw ScreenAuthError.failed("SRP challenge too large (\(s2c1Len)B)")
        }
        let s2c1 = try readIO(io, Int(s2c1Len), "read SRP challenge")
        if s2c1Len < 1000 {
            throw ScreenAuthError.srpFallback
        }

        let challenge = try parseSRPChallenge(s2c1)
        let proof = try solveSRP(challenge, password: Array(password.utf8), random: random)
        let civ = try draw(random, 16)

        var sd: [UInt8] = []
        sd.reserveCapacity(2 + srpModulusLen + 1 + srpHashLen + 2 + challenge.cap.count + 1 + 16)
        appendBE16(&sd, UInt16(srpModulusLen))
        sd += proof.Ab
        sd.append(UInt8(srpHashLen))
        sd += proof.M1
        appendBE16(&sd, UInt16(truncatingIfNeeded: challenge.cap.count))
        sd += challenge.cap
        sd.append(16)
        sd += civ

        let payLen = max(1076, 14 + sd.count)
        var c2s2 = [UInt8](repeating: 0, count: 4 + payLen)
        putBE32(&c2s2, 0, UInt32(payLen))
        c2s2[4] = 1
        c2s2[5] = 0
        c2s2.replaceSubrange(6..<10, with: rsa1Tag)
        c2s2[10] = 0x00
        c2s2[11] = 0x02
        putBE16(&c2s2, 12, UInt16(truncatingIfNeeded: sd.count + 4))
        putBE32(&c2s2, 14, UInt32(sd.count))
        c2s2.replaceSubrange(18..<(18 + sd.count), with: sd)
        try writeIO(io, c2s2, "send SRP proof")

        let m2Len = be32(try readIO(io, 4, "read SRP M2 length"), 0)
        guard m2Len <= 32768 else {
            throw ScreenAuthError.failed("SRP M2 too large (\(m2Len)B)")
        }
        if m2Len > 0 {
            _ = try readIO(io, Int(m2Len), "read SRP M2")
        }
        let result = be32(try readIO(io, 4, "read SRP SecurityResult"), 0)
        guard result == 0 else {
            throw ScreenAuthError.rejected("SRP result=\(result)")
        }
        return Array(SHA256.hash(data: proof.K).prefix(16))
    }

    /// The older security type 33 (RSA1 and AES-128-ECB). Call after
    /// `handshake`. Returns the 16-byte wrap key (the AES key it made up).
    /// Names and passwords longer than 63 bytes are cut to 63 (each goes in a
    /// 64-byte field ending in a zero, the rest of the field random).
    public static func loginNonSRP(_ io: ScreenIO, username: String, password: String,
                                   random: ScreenRandom = ScreenAuth.systemRandom) throws -> [UInt8] {
        let key = try fetchServerKey(io)
        let aesKey = try draw(random, 16)
        var creds = [UInt8](repeating: 0, count: ardCredLen * 2)
        try packARDField(&creds, at: 0, Array(username.utf8), random: random)
        try packARDField(&creds, at: ardCredLen, Array(password.utf8), random: random)
        let encCreds = try aesECB(CCOperation(kCCEncrypt), key: aesKey, creds)
        let encKey: [UInt8]
        do {
            encKey = try key.encryptPKCS1v15(aesKey, random: random)
        } catch let failure as RSAFailure {
            throw ScreenAuthError.failed("RSA encrypt AES key: " + failure.message)
        }

        var blob: [UInt8] = [0x01, 0x00]
        blob += rsa1Tag
        blob += [0x00, 0x01]
        blob += encCreds
        blob += [0x00, 0x01]
        blob += encKey
        var pkt: [UInt8] = []
        pkt.reserveCapacity(4 + blob.count)
        appendBE32(&pkt, UInt32(blob.count))
        pkt += blob
        try writeIO(io, pkt, "send non-SRP credentials")

        let resp = try readIO(io, 8, "read non-SRP result")
        let result = be32(resp, 4)
        guard result == 0 else {
            throw ScreenAuthError.rejected("non-SRP result=\(result)")
        }
        return aesKey
    }
}

fileprivate let srpHashLen = 64
fileprivate let srpModulusLen = 512
fileprivate let srpPBKDF2Len = 128
fileprivate let rsaBlockLen = 256
fileprivate let ardCredLen = 64
fileprivate let rsa1Tag: [UInt8] = [0x52, 0x53, 0x41, 0x31] // "RSA1"

fileprivate func readIO(_ io: ScreenIO, _ count: Int, _ doing: String) throws -> [UInt8] {
    let bytes: [UInt8]
    do {
        bytes = try io.readFull(count)
    } catch {
        throw ScreenAuthError.io(doing, error)
    }
    guard bytes.count == count else {
        throw ScreenAuthError.io(doing, ShortRead(wanted: count, got: bytes.count))
    }
    return bytes
}

fileprivate func writeIO(_ io: ScreenIO, _ bytes: [UInt8], _ doing: String) throws {
    do {
        try io.write(bytes)
    } catch {
        throw ScreenAuthError.io(doing, error)
    }
}

fileprivate struct ShortRead: Error, CustomStringConvertible {
    let wanted: Int, got: Int
    var description: String { "readFull returned \(got) bytes, not \(wanted)" }
}

fileprivate func draw(_ random: ScreenRandom, _ count: Int) throws -> [UInt8] {
    if count == 0 { return [] }
    let bytes: [UInt8]
    do {
        bytes = try random(count)
    } catch let error as ScreenAuthError {
        throw error
    } catch {
        throw ScreenAuthError.failed("random source: \(error)")
    }
    guard bytes.count == count else {
        throw ScreenAuthError.failed("random source gave \(bytes.count) bytes, want \(count)")
    }
    return bytes
}

// The server's RSA key: a request, then a packet whose bytes 2..<6 are the
// length of the DER key that follows them.
fileprivate func fetchServerKey(_ io: ScreenIO) throws -> RSAPublicKey {
    let request: [UInt8] = [
        ScreenAuth.securityTypeAppleRSA,
        0x00, 0x00, 0x00, 0x0a,
        0x01, 0x00, 0x52, 0x53, 0x41, 0x31,
        0x00, 0x00, 0x00, 0x00,
    ]
    try writeIO(io, request, "send RSA1 init")
    let pktLen = be32(try readIO(io, 4, "read RSA1 pubkey length"), 0)
    guard pktLen >= 6 && pktLen <= 65536 else {
        throw ScreenAuthError.failed("invalid RSA1 pubkey packet length \(pktLen)")
    }
    let pkt = try readIO(io, Int(pktLen), "read RSA1 pubkey")
    let keyLen = be32(pkt, 2)
    guard keyLen != 0 && 6 + UInt64(keyLen) <= UInt64(pkt.count) else {
        throw ScreenAuthError.failed("invalid DER public key length \(keyLen)")
    }
    return try parseRSAPublicKey(Array(pkt[6..<(6 + Int(keyLen))]))
}

fileprivate func packARDField(_ dst: inout [UInt8], at offset: Int, _ value: [UInt8], random: ScreenRandom) throws {
    let width = ardCredLen
    if value.count >= width {
        dst.replaceSubrange(offset..<(offset + width - 1), with: value[0..<(width - 1)])
        dst[offset + width - 1] = 0
        return
    }
    dst.replaceSubrange(offset..<(offset + value.count), with: value)
    dst[offset + value.count] = 0
    if value.count + 1 < width {
        let fill = try draw(random, width - value.count - 1)
        dst.replaceSubrange((offset + value.count + 1)..<(offset + width), with: fill)
    }
}

// MARK: - SRP-6a

fileprivate struct SRPChallenge {
    var N: ScreenBigUInt
    var Nb: [UInt8]     // 512 bytes, as sent
    var g: ScreenBigUInt
    var salt: [UInt8]
    var B: ScreenBigUInt
    var Bb: [UInt8]     // 512 bytes
    var iterations: UInt64
    var cap: [UInt8]
}

fileprivate func parseSRPChallenge(_ s2c1: [UInt8]) throws -> SRPChallenge {
    func fail(_ s: String) -> ScreenAuthError { ScreenAuthError.failed(s) }
    guard s2c1.count >= 12 + srpModulusLen + 16 else {
        throw fail("SRP challenge truncated (\(s2c1.count)B)")
    }
    // A 10-byte header (u16 0, u16 step = 2, u16 payload length + 4, u32 payload
    // length), then the control byte, then N as a u16 length and its bytes: what
    // macOS 15 sends on Apple silicon and on Intel alike. The specification has
    // a 9-byte header; the last word of the header is the length of what follows
    // it, which settles which.
    let head: Int
    if be32(s2c1, 6) == UInt32(truncatingIfNeeded: s2c1.count - 10) {
        head = 10
    } else if be32(s2c1, 5) == UInt32(truncatingIfNeeded: s2c1.count - 9) {
        head = 9
    } else {
        throw fail("SRP challenge framing not recognised")
    }
    let nLen = be16(s2c1, head + 1)
    var p = head + 3
    let Nb: [UInt8]
    if nLen == srpModulusLen + 1 && s2c1[p] == 0x00 {
        p += 1
        Nb = Array(s2c1[p..<(p + srpModulusLen)])
        p += srpModulusLen
    } else if nLen == srpModulusLen {
        Nb = Array(s2c1[p..<(p + srpModulusLen)])
        p += srpModulusLen
    } else {
        throw fail("unexpected SRP modulus length \(nLen) (marker=0x\(hex2(s2c1[p])))")
    }

    guard p + 2 <= s2c1.count else { throw fail("SRP challenge truncated at gLen") }
    let gLen = be16(s2c1, p)
    p += 2
    guard gLen != 0 && p + gLen + 1 <= s2c1.count else { throw fail("SRP challenge invalid gLen") }
    let g = ScreenBigUInt(bigEndian: s2c1[p..<(p + gLen)])
    p += gLen

    let saltLen = Int(s2c1[p])
    p += 1
    guard p + saltLen + 2 <= s2c1.count else { throw fail("SRP challenge truncated at salt") }
    let salt = Array(s2c1[p..<(p + saltLen)])
    p += saltLen

    let bLen = be16(s2c1, p)
    p += 2
    guard bLen != 0 && p + bLen + 10 <= s2c1.count else { throw fail("SRP challenge truncated at B") }
    let B = ScreenBigUInt(bigEndian: s2c1[p..<(p + bLen)])
    let Bb = B.bigEndianBytes(width: srpModulusLen)
    p += bLen

    let iterations = be64(s2c1, p)
    p += 8
    guard iterations != 0 && iterations <= 1_000_000 else {
        throw fail("SRP iteration count \(iterations) out of range")
    }

    let capLen = be16(s2c1, p)
    p += 2
    guard p + capLen <= s2c1.count else { throw fail("SRP challenge truncated at cap") }
    let cap = Array(s2c1[p..<(p + capLen)])

    return SRPChallenge(N: ScreenBigUInt(bigEndian: Nb), Nb: Nb, g: g, salt: salt, B: B, Bb: Bb,
                        iterations: iterations, cap: cap)
}

fileprivate struct SRPProof {
    var Ab: [UInt8]
    var M1: [UInt8]
    var K: [UInt8]
}

// SRP-6a as Apple runs it: k = H(N | pad(g)), x = H(salt | H(":" | PBKDF2(password))),
// u = H(pad(A) | pad(B)), S = (B - k g^x)^(a + u x), K = H(pad(S)) and
// M1 = H(H(N) xor H(pad(g)) | H("") | salt | pad(A) | pad(B) | K): the user name's
// hash is that of the empty string.
fileprivate func solveSRP(_ ch: SRPChallenge, password: [UInt8], random: ScreenRandom) throws -> SRPProof {
    let gPad = ch.g.bigEndianBytes(width: srpModulusLen)
    let k = ScreenBigUInt(bigEndian: sha512(ch.Nb, gPad))

    let aRand = try draw(random, 64)
    guard ch.N > ScreenBigUInt(1) else {
        // The Go code divides by zero here.
        throw ScreenAuthError.failed("SRP modulus \(ch.N) is too small")
    }
    let nMinus1 = ch.N - ScreenBigUInt(1)
    let a = ScreenBigUInt(bigEndian: aRand) % nMinus1 + ScreenBigUInt(1)

    let A = ch.g.power(a, modulus: ch.N)
    let Ab = A.bigEndianBytes(width: srpModulusLen)
    let u = ScreenBigUInt(bigEndian: sha512(Ab, ch.Bb))

    guard ch.iterations <= UInt64(UInt32.max) else {
        throw ScreenAuthError.failed("PBKDF2: iteration count \(ch.iterations) too large")
    }
    let dk = try pbkdf2SHA512(password: password, salt: ch.salt, rounds: UInt32(ch.iterations), length: srpPBKDF2Len)
    let inner = sha512([0x3a], dk)
    let x = ScreenBigUInt(bigEndian: sha512(ch.salt, inner)) % ch.N

    let gx = ch.g.power(x, modulus: ch.N)
    let kgx = (k * gx) % ch.N
    let base = (ch.B % ch.N + ch.N - kgx) % ch.N
    let exponent = a + u * x
    let S = base.power(exponent, modulus: ch.N)
    let K = sha512(S.bigEndianBytes(width: srpModulusLen))

    let hN = sha512(ch.Nb)
    let hG = sha512(gPad)
    var hXor = [UInt8](repeating: 0, count: 64)
    for i in 0..<64 {
        hXor[i] = hN[i] ^ hG[i]
    }
    let hEmpty = sha512()
    let M1 = sha512(hXor, hEmpty, ch.salt, Ab, ch.Bb, K)
    return SRPProof(Ab: Ab, M1: M1, K: K)
}

fileprivate func pbkdf2SHA512(password: [UInt8], salt: [UInt8], rounds: UInt32, length: Int) throws -> [UInt8] {
    var out = [UInt8](repeating: 0, count: length)
    // Never a null pointer, even for an empty password or salt.
    let pw = password.isEmpty ? [0] : password
    let sl = salt.isEmpty ? [0] : salt
    let status: Int32 = pw.withUnsafeBufferPointer { pwp in
        sl.withUnsafeBufferPointer { sp in
            out.withUnsafeMutableBufferPointer { op in
                pwp.baseAddress!.withMemoryRebound(to: CChar.self, capacity: pw.count) { pwc in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pwc, password.count,
                                         sp.baseAddress!, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), rounds,
                                         op.baseAddress!, length)
                }
            }
        }
    }
    guard status == Int32(kCCSuccess) else {
        throw ScreenAuthError.failed("PBKDF2: CommonCrypto status \(status)")
    }
    return out
}

// MARK: - RSA (PKCS #1 v1.5 encryption, as Go's crypto/rsa does it)

fileprivate struct RSAFailure: Error {
    let message: String
}

fileprivate struct RSAPublicKey {
    let n: ScreenBigUInt
    let e: UInt64 // positive, at most Int64.max

    // The checks and the order of the checks and of the random draws are those
    // of Go's rsa.EncryptPKCS1v15: size, message length, padding, then the
    // modulus and the exponent.
    func encryptPKCS1v15(_ msg: [UInt8], random: ScreenRandom) throws -> [UInt8] {
        let bits = n.bitLength
        guard bits >= 1024 else {
            throw RSAFailure(message: "\(bits)-bit keys are insecure")
        }
        let k = (bits + 7) / 8
        guard msg.count <= k - 11 else {
            throw RSAFailure(message: "message too long for RSA key size")
        }
        // EM = 0x00 || 0x02 || PS || 0x00 || M, PS random and without zeros.
        let psLen = k - msg.count - 3
        var ps = try draw(random, psLen)
        for i in 0..<psLen {
            while ps[i] == 0 {
                ps[i] = try draw(random, 1)[0] ^ 0x42
            }
        }
        guard n.isOdd else { throw RSAFailure(message: "public modulus is even") }
        guard e >= 2 else { throw RSAFailure(message: "public exponent too small or negative") }
        guard e & 1 == 1 else { throw RSAFailure(message: "public exponent is even") }
        guard e <= UInt64(Int32.max) else { throw RSAFailure(message: "public exponent too large") }
        var em: [UInt8] = [0x00, 0x02]
        em.reserveCapacity(k)
        em += ps
        em.append(0x00)
        em += msg
        let c = ScreenBigUInt(bigEndian: em).power(ScreenBigUInt(e), modulus: n)
        return c.bigEndianBytes(width: k)
    }
}

// The key as Go's x509 reads it: SubjectPublicKeyInfo first, a bare PKCS #1
// RSAPublicKey if that fails.
fileprivate func parseRSAPublicKey(_ der: [UInt8]) throws -> RSAPublicKey {
    let spkiError: String
    switch parseSPKI(der) {
    case .key(let key):
        return key
    case .otherAlgorithm:
        throw ScreenAuthError.failed("unexpected server public key type (not RSA)")
    case .invalid(let why):
        spkiError = why
    }
    if let key = parsePKCS1PublicKey(der) {
        return key
    }
    throw ScreenAuthError.failed("parse server RSA public key: " + spkiError)
}

fileprivate enum SPKIResult {
    case key(RSAPublicKey)
    case otherAlgorithm
    case invalid(String)
}

fileprivate let oidRSAEncryption: [UInt8] = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01]

fileprivate func parseSPKI(_ der: [UInt8]) -> SPKIResult {
    guard let outer = derRead(der, 0, der.count), outer.tag == 0x30 else {
        return .invalid("not a SubjectPublicKeyInfo")
    }
    guard outer.end == der.count else {
        return .invalid("trailing data after ASN.1 of public-key")
    }
    guard let alg = derRead(der, outer.start, outer.end), alg.tag == 0x30,
          let bits = derRead(der, alg.end, outer.end), bits.tag == 0x03 else {
        return .invalid("not a SubjectPublicKeyInfo")
    }
    guard let oid = derRead(der, alg.start, alg.end), oid.tag == 0x06 else {
        return .invalid("not a SubjectPublicKeyInfo")
    }
    guard Array(der[oid.start..<oid.end]) == oidRSAEncryption else {
        return .otherAlgorithm
    }
    // RSA keys carry a NULL as their parameters (RFC 3279, 2.3.1).
    guard let params = derRead(der, oid.end, alg.end), params.tag == 0x05, params.start == params.end else {
        return .invalid("RSA key missing NULL parameters")
    }
    guard bits.end > bits.start, der[bits.start] == 0 else {
        return .invalid("public key BIT STRING with unused bits")
    }
    // RSAPublicKey inside the BIT STRING; what follows it is not looked at.
    guard let seq = derRead(der, bits.start + 1, bits.end), seq.tag == 0x30 else {
        return .invalid("invalid RSA public key")
    }
    guard let nTLV = derRead(der, seq.start, seq.end), nTLV.tag == 0x02,
          let n = derPositiveInteger(der, nTLV) else {
        return .invalid("invalid RSA modulus")
    }
    guard let eTLV = derRead(der, nTLV.end, seq.end), eTLV.tag == 0x02,
          let e = derInt64(der, eTLV) else {
        return .invalid("invalid RSA public exponent")
    }
    guard !n.isZero else { return .invalid("RSA modulus is not a positive number") }
    guard e > 0 else { return .invalid("RSA public exponent is not a positive number") }
    return .key(RSAPublicKey(n: n, e: UInt64(e)))
}

fileprivate func parsePKCS1PublicKey(_ der: [UInt8]) -> RSAPublicKey? {
    guard let outer = derRead(der, 0, der.count), outer.tag == 0x30, outer.end == der.count,
          let nTLV = derRead(der, outer.start, outer.end), nTLV.tag == 0x02,
          let n = derPositiveInteger(der, nTLV),
          let eTLV = derRead(der, nTLV.end, outer.end), eTLV.tag == 0x02,
          let e = derInt64(der, eTLV) else {
        return nil
    }
    guard !n.isZero, e > 0, e <= Int64(Int32.max) else { return nil }
    return RSAPublicKey(n: n, e: UInt64(e))
}

fileprivate struct DERItem {
    let tag: UInt8
    let start: Int // content
    let end: Int
}

// One DER element at `pos`, inside `pos..<limit`: low tag numbers only, lengths
// in their shortest form, as Go's parsers insist.
fileprivate func derRead(_ b: [UInt8], _ pos: Int, _ limit: Int) -> DERItem? {
    guard pos + 2 <= limit else { return nil }
    let tag = b[pos]
    if tag & 0x1f == 0x1f { return nil }
    var p = pos + 2
    var len = Int(b[pos + 1])
    if len & 0x80 != 0 {
        let count = len & 0x7f
        guard count >= 1 && count <= 4, p + count <= limit, b[p] != 0 else { return nil }
        len = 0
        for i in 0..<count {
            len = len << 8 | Int(b[p + i])
        }
        guard len >= 0x80 else { return nil }
        p += count
    }
    guard len <= limit - p else { return nil }
    return DERItem(tag: tag, start: p, end: p + len)
}

fileprivate func derMinimalInteger(_ b: [UInt8], _ item: DERItem) -> Bool {
    let n = item.end - item.start
    if n == 0 { return false }
    if n == 1 { return true }
    let b0 = b[item.start], b1 = b[item.start + 1]
    if b0 == 0x00 && b1 & 0x80 == 0 { return false }
    if b0 == 0xff && b1 & 0x80 != 0 { return false }
    return true
}

// A non-negative INTEGER's value; nil for a malformed or negative one.
fileprivate func derPositiveInteger(_ b: [UInt8], _ item: DERItem) -> ScreenBigUInt? {
    guard derMinimalInteger(b, item), b[item.start] & 0x80 == 0 else { return nil }
    return ScreenBigUInt(bigEndian: b[item.start..<item.end])
}

fileprivate func derInt64(_ b: [UInt8], _ item: DERItem) -> Int64? {
    guard derMinimalInteger(b, item), item.end - item.start <= 8 else { return nil }
    var v: Int64 = b[item.start] & 0x80 != 0 ? -1 : 0
    for i in item.start..<item.end {
        v = v << 8 | Int64(b[i])
    }
    return v
}

// MARK: - Record cipher

/// Apple's encrypted record layer after sign-in (Go: RecordCipher, "enc1103"):
/// AES-128-CBC whose chain runs on from record to record, one chain each way,
/// and a SHA-1 of a record counter and the framed message as its integrity
/// check. Safe to use from several threads.
public final class ScreenRecordCipher: @unchecked Sendable {
    /// The CBC key both directions use (other parts of a session derive keys from it).
    public let cbcKey: [UInt8]

    private let lock = NSLock()
    private let encryptor: CCCryptorRef
    private let decryptor: CCCryptorRef
    private var encCounter: UInt32 = 0
    private var decCounter: UInt32 = 0

    private static let macLen = 20
    private static let blockSize = 16
    // A record's counter may be the one expected, the one before, or up to five
    // after (a server that pipelines).
    private static let lookahead: UInt32 = 6

    /// Opens the 36-byte rekey blob (encoding 0x44f: 4 bytes, then the CBC key
    /// and the CBC IV, each AES-128-ECB under the wrap key) with the wrap key a
    /// sign-in returned (its first 16 bytes).
    public init(rekeyBlob: [UInt8], wrapKey: [UInt8]) throws {
        guard rekeyBlob.count == 36 else {
            throw ScreenAuthError.failed("invalid 0x44f rekey blob: got \(rekeyBlob.count) bytes, want 36")
        }
        guard wrapKey.count >= 16 else {
            throw ScreenAuthError.failed("invalid 0x44f rekey blob: wrap key length \(wrapKey.count) < 16")
        }
        let wrap = Array(wrapKey[0..<16])
        let key = try aesECB(CCOperation(kCCDecrypt), key: wrap, Array(rekeyBlob[4..<20]))
        let iv = try aesECB(CCOperation(kCCDecrypt), key: wrap, Array(rekeyBlob[20..<36]))
        let enc = try makeCBC(CCOperation(kCCEncrypt), key: key, iv: iv)
        let dec: CCCryptorRef
        do {
            dec = try makeCBC(CCOperation(kCCDecrypt), key: key, iv: iv)
        } catch {
            CCCryptorRelease(enc)
            throw error
        }
        cbcKey = key
        encryptor = enc
        decryptor = dec
    }

    deinit {
        CCCryptorRelease(encryptor)
        CCCryptorRelease(decryptor)
    }

    /// One message as one record, its 2-byte length in front. Messages of more
    /// than 65498 bytes do not fit a record; their lengths wrap, as in the Go code.
    public func encrypt<D: ContiguousBytes>(_ plaintext: D) -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return plaintext.withUnsafeBytes { encryptLocked($0) }
    }

    /// Encrypts and writes under one lock, so that record counters follow the
    /// order of the writes even from several threads. Throws what `io` throws.
    public func encryptAndSend<D: ContiguousBytes>(_ plaintext: D, to io: ScreenIO) throws {
        lock.lock()
        defer { lock.unlock() }
        let frame = plaintext.withUnsafeBytes { encryptLocked($0) }
        try io.write(frame)
    }

    /// The same with any writer.
    public func encryptAndSend<D: ContiguousBytes>(_ plaintext: D, using write: ([UInt8]) throws -> Void) rethrows {
        lock.lock()
        defer { lock.unlock() }
        let frame = plaintext.withUnsafeBytes { encryptLocked($0) }
        try write(frame)
    }

    /// One record without its length prefix; nil when it is too short, not
    /// whole blocks, fails its check, or holds a length longer than itself. A
    /// record of whole blocks advances the CBC chain whether or not it passes.
    public func decryptRecord<D: ContiguousBytes>(_ ciphertext: D) -> [UInt8]? {
        ciphertext.withUnsafeBytes { decryptRecord(raw: $0) }
    }

    /// Every complete record in `data`, and how many bytes they took. A record
    /// that fails is skipped; a partial one at the end is left for the caller
    /// to keep until more bytes come; a length of 0 or not a multiple of 16
    /// stops the reading there.
    public func decryptStream<D: ContiguousBytes>(_ data: D) -> (messages: [[UInt8]], consumed: Int) {
        data.withUnsafeBytes { raw in
            var messages: [[UInt8]] = []
            var pos = 0
            while pos + 2 <= raw.count {
                let recLen = Int(raw[pos]) << 8 | Int(raw[pos + 1])
                if recLen == 0 || recLen % Self.blockSize != 0 {
                    break
                }
                if pos + 2 + recLen > raw.count {
                    break
                }
                if let message = decryptRecord(raw: UnsafeRawBufferPointer(rebasing: raw[(pos + 2)..<(pos + 2 + recLen)])) {
                    messages.append(message)
                }
                pos += 2 + recLen
            }
            return (messages, pos)
        }
    }

    private func encryptLocked(_ plaintext: UnsafeRawBufferPointer) -> [UInt8] {
        let n = plaintext.count
        let pad = (Self.blockSize - ((2 + n + Self.macLen) % Self.blockSize)) % Self.blockSize
        let framedLen = 2 + n + pad
        let blockLen = framedLen + Self.macLen
        var block = [UInt8](repeating: 0, count: blockLen)
        var out = [UInt8](repeating: 0, count: 2 + blockLen)
        block.withUnsafeMutableBytes { bp in
            bp[0] = UInt8(truncatingIfNeeded: n >> 8)
            bp[1] = UInt8(truncatingIfNeeded: n)
            if n > 0 {
                UnsafeMutableRawBufferPointer(rebasing: bp[2..<(2 + n)]).copyMemory(from: plaintext)
            }
            var hasher = Insecure.SHA1()
            var counter = encCounter.bigEndian
            withUnsafeBytes(of: &counter) { hasher.update(bufferPointer: $0) }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: bp[0..<framedLen]))
            let digest = hasher.finalize()
            digest.withUnsafeBytes { d in
                UnsafeMutableRawBufferPointer(rebasing: bp[framedLen..<blockLen]).copyMemory(from: d)
            }
            out.withUnsafeMutableBytes { op in
                op[0] = UInt8(truncatingIfNeeded: blockLen >> 8)
                op[1] = UInt8(truncatingIfNeeded: blockLen)
                var moved = 0
                let status = CCCryptorUpdate(encryptor, bp.baseAddress, blockLen, op.baseAddress! + 2, blockLen, &moved)
                precondition(status == Int32(kCCSuccess) && moved == blockLen, "ScreenRecordCipher: CBC encryption failed (\(status))")
            }
        }
        encCounter &+= 1
        return out
    }

    private func decryptRecord(raw ciphertext: UnsafeRawBufferPointer) -> [UInt8]? {
        let n = ciphertext.count
        guard n >= 32, n % Self.blockSize == 0 else { return nil }
        let bodyLen = n - Self.macLen
        var plain = [UInt8](repeating: 0, count: n)

        lock.lock()
        let decrypted: Bool = plain.withUnsafeMutableBytes { pp in
            var moved = 0
            let status = CCCryptorUpdate(decryptor, ciphertext.baseAddress, n, pp.baseAddress, n, &moved)
            return status == Int32(kCCSuccess) && moved == n
        }
        let start = decCounter
        decCounter = start &+ 1
        guard decrypted else {
            lock.unlock()
            return nil
        }
        var matched: UInt32?
        plain.withUnsafeBytes { pp in
            let body = UnsafeRawBufferPointer(rebasing: pp[0..<bodyLen])
            let mac = UnsafeRawBufferPointer(rebasing: pp[bodyLen..<n])
            var candidate: UInt32 = start > 0 ? start - 1 : 0
            let limit = start &+ Self.lookahead
            while candidate < limit {
                var hasher = Insecure.SHA1()
                var counter = candidate.bigEndian
                withUnsafeBytes(of: &counter) { hasher.update(bufferPointer: $0) }
                hasher.update(bufferPointer: body)
                let digest = hasher.finalize()
                let same: Bool = digest.withUnsafeBytes { d in
                    var diff: UInt8 = 0
                    for i in 0..<Self.macLen {
                        diff |= d[i] ^ mac[i]
                    }
                    return diff == 0
                }
                if same {
                    matched = candidate
                    break
                }
                candidate += 1
            }
        }
        guard let counter = matched else {
            lock.unlock()
            return nil
        }
        decCounter = counter &+ 1
        lock.unlock()

        let innerLen = Int(plain[0]) << 8 | Int(plain[1])
        guard 2 + innerLen <= bodyLen else { return nil }
        return Array(plain[2..<(2 + innerLen)])
    }
}

// MARK: - Hashes and AES

fileprivate func sha512(_ parts: [UInt8]...) -> [UInt8] {
    var hasher = SHA512()
    for part in parts {
        hasher.update(data: part)
    }
    return Array(hasher.finalize())
}

fileprivate func aesECB(_ op: CCOperation, key: [UInt8], _ input: [UInt8]) throws -> [UInt8] {
    var out = [UInt8](repeating: 0, count: input.count)
    var moved = 0
    let status = CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                         key, key.count, nil, input, input.count, &out, out.count, &moved)
    guard status == Int32(kCCSuccess), moved == input.count else {
        throw ScreenAuthError.failed("AES-ECB: CommonCrypto status \(status)")
    }
    return out
}

fileprivate func makeCBC(_ op: CCOperation, key: [UInt8], iv: [UInt8]) throws -> CCCryptorRef {
    var ref: CCCryptorRef?
    let status = CCCryptorCreateWithMode(op, CCMode(kCCModeCBC), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                                         iv, key, key.count, nil, 0, 0, CCModeOptions(0), &ref)
    guard status == Int32(kCCSuccess), let cryptor = ref else {
        throw ScreenAuthError.failed("AES-CBC: CommonCrypto status \(status)")
    }
    return cryptor
}

// MARK: - Bytes

@inline(__always) fileprivate func be16(_ b: [UInt8], _ i: Int) -> Int {
    Int(b[i]) << 8 | Int(b[i + 1])
}

@inline(__always) fileprivate func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
    UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
}

fileprivate func be64(_ b: [UInt8], _ i: Int) -> UInt64 {
    var v: UInt64 = 0
    for j in 0..<8 {
        v = v << 8 | UInt64(b[i + j])
    }
    return v
}

fileprivate func appendBE16(_ a: inout [UInt8], _ v: UInt16) {
    a.append(UInt8(v >> 8))
    a.append(UInt8(truncatingIfNeeded: v))
}

fileprivate func appendBE32(_ a: inout [UInt8], _ v: UInt32) {
    a.append(UInt8(v >> 24))
    a.append(UInt8(truncatingIfNeeded: v >> 16))
    a.append(UInt8(truncatingIfNeeded: v >> 8))
    a.append(UInt8(truncatingIfNeeded: v))
}

fileprivate func putBE16(_ a: inout [UInt8], _ i: Int, _ v: UInt16) {
    a[i] = UInt8(v >> 8)
    a[i + 1] = UInt8(truncatingIfNeeded: v)
}

fileprivate func putBE32(_ a: inout [UInt8], _ i: Int, _ v: UInt32) {
    a[i] = UInt8(v >> 24)
    a[i + 1] = UInt8(truncatingIfNeeded: v >> 16)
    a[i + 2] = UInt8(truncatingIfNeeded: v >> 8)
    a[i + 3] = UInt8(truncatingIfNeeded: v)
}

fileprivate let hexDigits: [Character] = Array("0123456789abcdef")

fileprivate func hex2(_ b: UInt8) -> String {
    String([hexDigits[Int(b >> 4)], hexDigits[Int(b & 15)]])
}

// Bytes quoted the way Go's %q quotes a string: printable characters as they
// are, the usual backslash escapes, \xNN for bytes that are not UTF-8.
fileprivate func goQuote(_ bytes: [UInt8]) -> String {
    var out = "\""
    var i = 0
    while i < bytes.count {
        let (scalar, width) = decodeUTF8(bytes, i)
        guard let s = scalar else {
            out += "\\x" + hex2(bytes[i])
            i += 1
            continue
        }
        i += width
        switch s.value {
        case 0x22: out += "\\\""
        case 0x5c: out += "\\\\"
        case 0x07: out += "\\a"
        case 0x08: out += "\\b"
        case 0x0c: out += "\\f"
        case 0x0a: out += "\\n"
        case 0x0d: out += "\\r"
        case 0x09: out += "\\t"
        case 0x0b: out += "\\v"
        case 0x20...0x7e: out.unicodeScalars.append(s)
        case 0..<0x20, 0x7f: out += "\\x" + hex2(UInt8(s.value))
        default:
            switch s.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .nonspacingMark, .spacingMark, .enclosingMark,
                 .decimalNumber, .letterNumber, .otherNumber,
                 .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
                 .initialPunctuation, .finalPunctuation, .otherPunctuation,
                 .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
                out.unicodeScalars.append(s)
            default:
                let h = String(s.value, radix: 16)
                out += s.value < 0x10000
                    ? "\\u" + String(repeating: "0", count: 4 - h.count) + h
                    : "\\U" + String(repeating: "0", count: 8 - h.count) + h
            }
        }
    }
    return out + "\""
}

// One UTF-8 sequence at `i`, as Go decodes it (nil for a byte that does not start one).
fileprivate func decodeUTF8(_ b: [UInt8], _ i: Int) -> (Unicode.Scalar?, Int) {
    let b0 = b[i]
    if b0 < 0x80 { return (Unicode.Scalar(b0), 1) }
    let width: Int
    var value: UInt32
    var low: UInt8 = 0x80, high: UInt8 = 0xbf
    switch b0 {
    case 0xc2...0xdf: width = 2; value = UInt32(b0 & 0x1f)
    case 0xe0: width = 3; value = 0; low = 0xa0
    case 0xe1...0xec, 0xee...0xef: width = 3; value = UInt32(b0 & 0x0f)
    case 0xed: width = 3; value = 0x0d; high = 0x9f
    case 0xf0: width = 4; value = 0; low = 0x90
    case 0xf1...0xf3: width = 4; value = UInt32(b0 & 0x07)
    case 0xf4: width = 4; value = 4; high = 0x8f
    default: return (nil, 1)
    }
    guard i + width <= b.count else { return (nil, 1) }
    for j in 1..<width {
        let c = b[i + j]
        let lo: UInt8 = j == 1 ? low : 0x80
        let hi: UInt8 = j == 1 ? high : 0xbf
        guard c >= lo && c <= hi else { return (nil, 1) }
        value = value << 6 | UInt32(c & 0x3f)
    }
    return (Unicode.Scalar(value), width)
}

// MARK: - Big unsigned integer

/// An unsigned integer of any size, as much of one as SRP-6a and RSA need:
/// addition, subtraction, multiplication, division with remainder, modular
/// exponentiation, and big-endian bytes both ways. Not constant-time.
public struct ScreenBigUInt: Sendable, Hashable, Comparable, CustomStringConvertible, ExpressibleByIntegerLiteral {
    // Little-endian 64-bit limbs, no zero limb at the top; zero has none.
    fileprivate var limbs: [UInt64]

    public init() { limbs = [] }

    public init(_ value: UInt64) { limbs = value == 0 ? [] : [value] }

    public init(integerLiteral value: UInt64) { self.init(value) }

    fileprivate init(limbs: [UInt64]) {
        self.limbs = limbs
        BigLimbs.normalize(&self.limbs)
    }

    /// The number whose big-endian bytes these are (leading zeros allowed).
    public init<C: Collection>(bigEndian bytes: C) where C.Element == UInt8 {
        var out = [UInt64](repeating: 0, count: (bytes.count + 7) / 8)
        var index = 0
        var shift: UInt64 = 0
        for byte in bytes.reversed() {
            out[index] |= UInt64(byte) << shift
            shift += 8
            if shift == 64 {
                shift = 0
                index += 1
            }
        }
        self.init(limbs: out)
    }

    /// Big-endian bytes without leading zeros (none at all for zero).
    public var bigEndianBytes: [UInt8] {
        guard let top = limbs.last else { return [] }
        let topBytes = (64 - top.leadingZeroBitCount + 7) / 8
        var out = [UInt8]()
        out.reserveCapacity(topBytes + 8 * (limbs.count - 1))
        for i in stride(from: topBytes - 1, through: 0, by: -1) {
            out.append(UInt8(truncatingIfNeeded: top >> (UInt64(i) * 8)))
        }
        for limb in limbs.dropLast().reversed() {
            for i in stride(from: 7, through: 0, by: -1) {
                out.append(UInt8(truncatingIfNeeded: limb >> (UInt64(i) * 8)))
            }
        }
        return out
    }

    /// Exactly `width` big-endian bytes: zeros in front of a shorter number, and
    /// only the last `width` bytes of a longer one (as the Go code's padBigIntBE).
    public func bigEndianBytes(width: Int) -> [UInt8] {
        let b = bigEndianBytes
        if b.count >= width {
            return Array(b[(b.count - width)...])
        }
        return [UInt8](repeating: 0, count: width - b.count) + b
    }

    public var isZero: Bool { limbs.isEmpty }

    public var isOdd: Bool { (limbs.first ?? 0) & 1 == 1 }

    /// The number of bits up to and including the highest one set (0 for zero).
    public var bitLength: Int {
        guard let top = limbs.last else { return 0 }
        return limbs.count * 64 - top.leadingZeroBitCount
    }

    /// Lowercase hexadecimal.
    public var description: String {
        guard let top = limbs.last else { return "0" }
        var s = String(top, radix: 16)
        for limb in limbs.dropLast().reversed() {
            let h = String(limb, radix: 16)
            s += String(repeating: "0", count: 16 - h.count) + h
        }
        return s
    }

    public static func < (lhs: ScreenBigUInt, rhs: ScreenBigUInt) -> Bool {
        BigLimbs.compare(lhs.limbs, rhs.limbs) < 0
    }

    public static func + (lhs: ScreenBigUInt, rhs: ScreenBigUInt) -> ScreenBigUInt {
        ScreenBigUInt(limbs: BigLimbs.add(lhs.limbs, rhs.limbs))
    }

    /// Traps when `rhs` is larger than `lhs`.
    public static func - (lhs: ScreenBigUInt, rhs: ScreenBigUInt) -> ScreenBigUInt {
        precondition(BigLimbs.compare(lhs.limbs, rhs.limbs) >= 0, "ScreenBigUInt: subtraction below zero")
        return ScreenBigUInt(limbs: BigLimbs.sub(lhs.limbs, rhs.limbs))
    }

    public static func * (lhs: ScreenBigUInt, rhs: ScreenBigUInt) -> ScreenBigUInt {
        ScreenBigUInt(limbs: BigLimbs.mul(lhs.limbs, rhs.limbs))
    }

    /// Traps when `divisor` is zero.
    public func quotientAndRemainder(dividingBy divisor: ScreenBigUInt) -> (quotient: ScreenBigUInt, remainder: ScreenBigUInt) {
        precondition(!divisor.isZero, "ScreenBigUInt: division by zero")
        let (q, r) = BigLimbs.divMod(limbs, divisor.limbs)
        return (ScreenBigUInt(limbs: q), ScreenBigUInt(limbs: r))
    }

    /// Traps when `rhs` is zero.
    public static func % (lhs: ScreenBigUInt, rhs: ScreenBigUInt) -> ScreenBigUInt {
        lhs.quotientAndRemainder(dividingBy: rhs).remainder
    }

    /// `self` to the power `exponent`, modulo `modulus` (which must not be zero):
    /// a result below `modulus`, so 0 when it is 1. Montgomery multiplication
    /// for an odd modulus, plain multiplication and division for an even one.
    public func power(_ exponent: ScreenBigUInt, modulus: ScreenBigUInt) -> ScreenBigUInt {
        precondition(!modulus.isZero, "ScreenBigUInt: modulus is zero")
        if modulus.limbs == [1] { return ScreenBigUInt() }
        if exponent.isZero { return ScreenBigUInt(1) }
        let base = self < modulus ? self : self % modulus
        if modulus.isOdd {
            return ScreenBigUInt(limbs: BigLimbs.montgomeryPower(base.limbs, exponent.limbs, modulus.limbs))
        }
        var result = ScreenBigUInt(1)
        for i in stride(from: exponent.bitLength - 1, through: 0, by: -1) {
            result = (result * result) % modulus
            if (exponent.limbs[i / 64] >> UInt64(i % 64)) & 1 == 1 {
                result = (result * base) % modulus
            }
        }
        return result
    }
}

// Arithmetic on little-endian limb arrays.
fileprivate enum BigLimbs {
    static func normalize(_ a: inout [UInt64]) {
        while let last = a.last, last == 0 {
            a.removeLast()
        }
    }

    static func compare(_ a: [UInt64], _ b: [UInt64]) -> Int {
        if a.count != b.count { return a.count < b.count ? -1 : 1 }
        var i = a.count - 1
        while i >= 0 {
            if a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
            i -= 1
        }
        return 0
    }

    static func add(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        let (long, short) = a.count >= b.count ? (a, b) : (b, a)
        var out = [UInt64](repeating: 0, count: long.count + 1)
        var carry: UInt64 = 0
        for i in 0..<long.count {
            let (s1, o1) = long[i].addingReportingOverflow(i < short.count ? short[i] : 0)
            let (s2, o2) = s1.addingReportingOverflow(carry)
            out[i] = s2
            carry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        out[long.count] = carry
        normalize(&out)
        return out
    }

    // a - b for a >= b.
    static func sub(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        var out = a
        var borrow: UInt64 = 0
        for i in 0..<a.count {
            let (d1, b1) = a[i].subtractingReportingOverflow(i < b.count ? b[i] : 0)
            let (d2, b2) = d1.subtractingReportingOverflow(borrow)
            out[i] = d2
            borrow = (b1 || b2) ? 1 : 0
        }
        normalize(&out)
        return out
    }

    static func mul(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        if a.isEmpty || b.isEmpty { return [] }
        var out = [UInt64](repeating: 0, count: a.count + b.count)
        a.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in
                out.withUnsafeMutableBufferPointer { op in
                    let nb = bp.count
                    for i in 0..<ap.count {
                        let ai = ap[i]
                        var carry: UInt64 = 0
                        if ai != 0 {
                            for j in 0..<nb {
                                let (hi, lo) = ai.multipliedFullWidth(by: bp[j])
                                let (s1, o1) = lo.addingReportingOverflow(op[i + j])
                                let (s2, o2) = s1.addingReportingOverflow(carry)
                                op[i + j] = s2
                                carry = hi &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
                            }
                        }
                        op[i + nb] = carry
                    }
                }
            }
        }
        normalize(&out)
        return out
    }

    // a << s for 0 <= s < 64, one limb longer than a (not normalised).
    static func shiftLeft(_ a: [UInt64], _ s: Int) -> [UInt64] {
        var out = [UInt64](repeating: 0, count: a.count + 1)
        if s == 0 {
            for i in 0..<a.count { out[i] = a[i] }
            return out
        }
        let r = UInt64(64 - s), l = UInt64(s)
        var carry: UInt64 = 0
        for i in 0..<a.count {
            out[i] = a[i] << l | carry
            carry = a[i] >> r
        }
        out[a.count] = carry
        return out
    }

    // (a / b, a % b), b not zero. Knuth's algorithm D (TAOCP 4.3.1) on 64-bit digits.
    static func divMod(_ a: [UInt64], _ b: [UInt64]) -> ([UInt64], [UInt64]) {
        if compare(a, b) < 0 { return ([], a) }
        if b.count == 1 {
            let d = b[0]
            var q = [UInt64](repeating: 0, count: a.count)
            var r: UInt64 = 0
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                let (qi, ri) = d.dividingFullWidth((r, a[i]))
                q[i] = qi
                r = ri
            }
            normalize(&q)
            return (q, r == 0 ? [] : [r])
        }
        let n = b.count
        let m = a.count - n
        let s = b[n - 1].leadingZeroBitCount
        var v = shiftLeft(b, s)
        v.removeLast() // b's top limb has room for the shift
        var u = shiftLeft(a, s)
        var q = [UInt64](repeating: 0, count: m + 1)
        let vTop = v[n - 1], vNext = v[n - 2]
        for j in stride(from: m, through: 0, by: -1) {
            // Estimate this digit of the quotient from the top of what is left.
            var qhat: UInt64
            var rhat: UInt64
            var rhatOverflow = false
            if u[j + n] >= vTop {
                qhat = UInt64.max
                let (r, o) = u[j + n - 1].addingReportingOverflow(vTop)
                rhat = r
                rhatOverflow = o
            } else {
                (qhat, rhat) = vTop.dividingFullWidth((u[j + n], u[j + n - 1]))
            }
            while !rhatOverflow {
                let (ph, pl) = qhat.multipliedFullWidth(by: vNext)
                if ph > rhat || (ph == rhat && pl > u[j + n - 2]) {
                    qhat -= 1
                    let (r, o) = rhat.addingReportingOverflow(vTop)
                    rhat = r
                    rhatOverflow = o
                } else {
                    break
                }
            }
            // Multiply and subtract; add back once if the estimate was one too big.
            var borrow: UInt64 = 0
            var carry: UInt64 = 0
            for i in 0..<n {
                let (ph, pl) = qhat.multipliedFullWidth(by: v[i])
                let (p, c1) = pl.addingReportingOverflow(carry)
                carry = ph &+ (c1 ? 1 : 0)
                let (d1, b1) = u[i + j].subtractingReportingOverflow(p)
                let (d2, b2) = d1.subtractingReportingOverflow(borrow)
                u[i + j] = d2
                borrow = (b1 || b2) ? 1 : 0
            }
            let (t1, tb1) = u[j + n].subtractingReportingOverflow(carry)
            let (t2, tb2) = t1.subtractingReportingOverflow(borrow)
            u[j + n] = t2
            if tb1 || tb2 {
                qhat -= 1
                var c: UInt64 = 0
                for i in 0..<n {
                    let (s1, o1) = u[i + j].addingReportingOverflow(v[i])
                    let (s2, o2) = s1.addingReportingOverflow(c)
                    u[i + j] = s2
                    c = (o1 || o2) ? 1 : 0
                }
                u[j + n] = u[j + n] &+ c
            }
            q[j] = qhat
        }
        // The remainder is u's low n limbs, shifted back.
        var r = [UInt64](repeating: 0, count: n)
        if s == 0 {
            for i in 0..<n { r[i] = u[i] }
        } else {
            let l = UInt64(64 - s), sr = UInt64(s)
            for i in 0..<n {
                r[i] = u[i] >> sr | u[i + 1] << l
            }
        }
        normalize(&q)
        normalize(&r)
        return (q, r)
    }

    // base^e mod m for an odd m > 1 and base < m, with a fixed window of 4 bits.
    static func montgomeryPower(_ base: [UInt64], _ e: [UInt64], _ m: [UInt64]) -> [UInt64] {
        let n = m.count
        // -m^-1 mod 2^64 by Newton's iteration (an odd m0 is its own inverse mod 8).
        let m0 = m[0]
        var inv = m0
        for _ in 0..<5 {
            inv = inv &* (2 &- m0 &* inv)
        }
        let mInv = 0 &- inv
        // R^2 mod m, R = 2^(64 n).
        var rr = [UInt64](repeating: 0, count: 2 * n + 1)
        rr[2 * n] = 1
        var r2 = divMod(rr, m).1
        r2 += [UInt64](repeating: 0, count: n - r2.count)
        var x = base
        x += [UInt64](repeating: 0, count: n - x.count)
        var one = [UInt64](repeating: 0, count: n)
        one[0] = 1

        let windows = (e.count * 64 - e[e.count - 1].leadingZeroBitCount + 3) / 4
        var result = [UInt64](repeating: 0, count: n)
        m.withUnsafeBufferPointer { mp in
            let mptr = mp.baseAddress!
            let table = UnsafeMutablePointer<UInt64>.allocate(capacity: 16 * n)
            let acc = UnsafeMutablePointer<UInt64>.allocate(capacity: n)
            let scratch = UnsafeMutablePointer<UInt64>.allocate(capacity: n + 2)
            table.initialize(repeating: 0, count: 16 * n)
            acc.initialize(repeating: 0, count: n)
            scratch.initialize(repeating: 0, count: n + 2)
            defer {
                table.deallocate()
                acc.deallocate()
                scratch.deallocate()
            }
            r2.withUnsafeBufferPointer { r2p in
                one.withUnsafeBufferPointer { onep in
                    x.withUnsafeBufferPointer { xp in
                        // table[k] = base^k R mod m
                        montMul(r2p.baseAddress!, onep.baseAddress!, mptr, n, mInv, scratch, table)
                        montMul(xp.baseAddress!, r2p.baseAddress!, mptr, n, mInv, scratch, table + n)
                    }
                }
            }
            for k in 2..<16 {
                montMul(table + (k - 1) * n, table + n, mptr, n, mInv, scratch, table + k * n)
            }
            e.withUnsafeBufferPointer { ep in
                func window(_ w: Int) -> Int {
                    Int((ep[(w * 4) / 64] >> UInt64((w * 4) % 64)) & 0xf)
                }
                let top = window(windows - 1)
                acc.update(from: table + top * n, count: n)
                var w = windows - 2
                while w >= 0 {
                    montMul(acc, acc, mptr, n, mInv, scratch, acc)
                    montMul(acc, acc, mptr, n, mInv, scratch, acc)
                    montMul(acc, acc, mptr, n, mInv, scratch, acc)
                    montMul(acc, acc, mptr, n, mInv, scratch, acc)
                    let k = window(w)
                    if k != 0 {
                        montMul(acc, table + k * n, mptr, n, mInv, scratch, acc)
                    }
                    w -= 1
                }
            }
            one.withUnsafeBufferPointer { onep in
                result.withUnsafeMutableBufferPointer { rp in
                    montMul(acc, onep.baseAddress!, mptr, n, mInv, scratch, rp.baseAddress!)
                }
            }
        }
        normalize(&result)
        return result
    }

    // out = a b R^-1 mod m (CIOS), for a, b < m; out may be a or b. t has n + 2 limbs.
    @inline(__always)
    static func montMul(_ a: UnsafePointer<UInt64>, _ b: UnsafePointer<UInt64>, _ m: UnsafePointer<UInt64>,
                        _ n: Int, _ mInv: UInt64, _ t: UnsafeMutablePointer<UInt64>, _ out: UnsafeMutablePointer<UInt64>) {
        t.update(repeating: 0, count: n + 2)
        var i = 0
        while i < n {
            let bi = b[i]
            var c: UInt64 = 0
            var j = 0
            while j < n {
                let (hi, lo) = a[j].multipliedFullWidth(by: bi)
                let (s1, o1) = lo.addingReportingOverflow(t[j])
                let (s2, o2) = s1.addingReportingOverflow(c)
                t[j] = s2
                c = hi &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
                j += 1
            }
            let (sn, on) = t[n].addingReportingOverflow(c)
            t[n] = sn
            t[n + 1] = on ? 1 : 0

            let q = t[0] &* mInv
            let (hi0, lo0) = q.multipliedFullWidth(by: m[0])
            let (_, o0) = lo0.addingReportingOverflow(t[0])
            c = hi0 &+ (o0 ? 1 : 0)
            j = 1
            while j < n {
                let (hi, lo) = q.multipliedFullWidth(by: m[j])
                let (s1, o1) = lo.addingReportingOverflow(t[j])
                let (s2, o2) = s1.addingReportingOverflow(c)
                t[j - 1] = s2
                c = hi &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
                j += 1
            }
            let (s3, o3) = t[n].addingReportingOverflow(c)
            t[n - 1] = s3
            t[n] = t[n + 1] &+ (o3 ? 1 : 0)
            i += 1
        }
        // t < 2m: subtract m once if t >= m.
        var atLeast = t[n] != 0
        if !atLeast {
            atLeast = true
            var k = n - 1
            while k >= 0 {
                if t[k] != m[k] {
                    atLeast = t[k] > m[k]
                    break
                }
                k -= 1
            }
        }
        if atLeast {
            var borrow: UInt64 = 0
            var k = 0
            while k < n {
                let (d1, b1) = t[k].subtractingReportingOverflow(m[k])
                let (d2, b2) = d1.subtractingReportingOverflow(borrow)
                out[k] = d2
                borrow = (b1 || b2) ? 1 : 0
                k += 1
            }
        } else {
            out.update(from: t, count: n)
        }
    }
}
