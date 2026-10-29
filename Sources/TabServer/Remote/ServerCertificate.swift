import CryptoKit
import Darwin
import Foundation
import Security

/// The server's self-signed TLS identity. Phones trust it by pinning the
/// certificate's SHA-256 fingerprint, so its contents only need to be valid
/// X.509: a P-256 key, ECDSA with SHA-256, common name "Tab".
enum ServerCertificate {
    static func generate(commonName: String = "Tab", now: Date = Date()) throws -> StoredIdentity {
        let key = P256.Signing.PrivateKey()
        let algorithm = CertificateDER.sequence([CertificateDER.oid([1, 2, 840, 10045, 4, 3, 2])])
        let name = CertificateDER.sequence([
            CertificateDER.set([CertificateDER.sequence([CertificateDER.oid([2, 5, 4, 3]), CertificateDER.utf8String(commonName)])]),
        ])
        var serial = try secureRandom(16)
        serial[0] &= 0x7f
        serial[0] |= 0x01
        let validity = CertificateDER.sequence([
            CertificateDER.utcTime(now.addingTimeInterval(-86400)),
            CertificateDER.generalizedTime("99991231235959Z"),
        ])
        let extensions = CertificateDER.contextConstructed(3, [
            CertificateDER.sequence([
                // Basic constraints: not a certificate authority.
                CertificateDER.sequence([CertificateDER.oid([2, 5, 29, 19]), CertificateDER.boolean(true), CertificateDER.octetString(CertificateDER.sequence([]))]),
                // Key usage: digital signature.
                CertificateDER.sequence([CertificateDER.oid([2, 5, 29, 15]), CertificateDER.boolean(true),
                              CertificateDER.octetString(CertificateDER.bitString(Data([0x80]), unusedBits: 7))]),
                // Extended key usage: TLS server.
                CertificateDER.sequence([CertificateDER.oid([2, 5, 29, 37]),
                              CertificateDER.octetString(CertificateDER.sequence([CertificateDER.oid([1, 3, 6, 1, 5, 5, 7, 3, 1])]))]),
            ]),
        ])
        let tbs = CertificateDER.sequence([
            CertificateDER.contextConstructed(0, [CertificateDER.integer(Data([2]))]),
            CertificateDER.integer(serial),
            algorithm,
            name,
            validity,
            name,
            key.publicKey.derRepresentation,
            extensions,
        ])
        let signature = try key.signature(for: tbs).derRepresentation
        let certificate = CertificateDER.sequence([tbs, algorithm, CertificateDER.bitString(signature)])
        return StoredIdentity(certificate: certificate, privateKey: key.x963Representation)
    }

    /// A `SecIdentity` for `identity` without touching any keychain.
    static func secIdentity(_ identity: StoredIdentity) throws -> SecIdentity {
        guard let certificate = SecCertificateCreateWithData(nil, identity.certificate as CFData) else {
            throw ServiceError(.persistenceFailed, "The server certificate is invalid")
        }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 256,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(identity.privateKey as CFData, attributes as CFDictionary, &error) else {
            throw ServiceError(.persistenceFailed, "The server key is invalid")
        }
        guard let create = createIdentity, let made = create(nil, certificate, key) else {
            throw ServiceError(.persistenceFailed, "Couldn't create the server's TLS identity")
        }
        return made.takeRetainedValue()
    }

    private typealias CreateIdentity = @convention(c) (CFAllocator?, SecCertificate, SecKey) -> Unmanaged<SecIdentity>?

    /// `SecIdentityCreate` pairs a certificate with an in-memory key. Security
    /// exports it but doesn't declare it in the macOS SDK headers.
    private static let createIdentity: CreateIdentity? = {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW),
              let symbol = dlsym(handle, "SecIdentityCreate") else { return nil }
        return unsafeBitCast(symbol, to: CreateIdentity.self)
    }()
}

/// The few DER encodings a certificate needs.
enum CertificateDER {
    static func tagged(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        let count = content.count
        if count < 0x80 {
            out.append(UInt8(count))
        } else {
            var length = withUnsafeBytes(of: UInt64(count).bigEndian) { Data($0) }
            while length.first == 0 { length.removeFirst() }
            out.append(0x80 | UInt8(length.count))
            out.append(length)
        }
        out.append(content)
        return out
    }

    static func sequence(_ items: [Data]) -> Data { tagged(0x30, items.reduce(Data(), +)) }
    static func set(_ items: [Data]) -> Data { tagged(0x31, items.reduce(Data(), +)) }
    static func contextConstructed(_ number: UInt8, _ items: [Data]) -> Data {
        tagged(0xa0 | number, items.reduce(Data(), +))
    }

    static func boolean(_ value: Bool) -> Data { tagged(0x01, Data([value ? 0xff : 0x00])) }
    static func octetString(_ value: Data) -> Data { tagged(0x04, value) }
    static func utf8String(_ value: String) -> Data { tagged(0x0c, Data(value.utf8)) }

    /// A non-negative integer from big-endian bytes.
    static func integer(_ bytes: Data) -> Data {
        var bytes = bytes
        while bytes.count > 1, bytes.first == 0, let next = bytes.dropFirst().first, next & 0x80 == 0 {
            bytes.removeFirst()
        }
        if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tagged(0x02, bytes)
    }

    static func bitString(_ value: Data, unusedBits: UInt8 = 0) -> Data {
        tagged(0x03, Data([unusedBits]) + value)
    }

    static func oid(_ arcs: [UInt64]) -> Data {
        var body = Data([UInt8(arcs[0] * 40 + arcs[1])])
        for arc in arcs.dropFirst(2) {
            var chunk = [UInt8(arc & 0x7f)]
            var rest = arc >> 7
            while rest > 0 {
                chunk.insert(UInt8(rest & 0x7f) | 0x80, at: 0)
                rest >>= 7
            }
            body.append(contentsOf: chunk)
        }
        return tagged(0x06, body)
    }

    static func utcTime(_ date: Date) -> Data {
        tagged(0x17, Data(timestamp(date, format: "yyMMddHHmmss'Z'").utf8))
    }

    static func generalizedTime(_ text: String) -> Data { tagged(0x18, Data(text.utf8)) }

    private static func timestamp(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
