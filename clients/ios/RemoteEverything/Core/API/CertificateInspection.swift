import Foundation
import Security

/// What a client can learn from a certificate before trusting it: its
/// fingerprint, the digest of its public key, and whether that key is the one
/// the invitation pinned.
enum CertificateInspection {

    static func certificateData(_ certificate: SecCertificate) -> Data {
        SecCertificateCopyData(certificate) as Data
    }

    /// SHA-256 of the DER certificate, lowercase hex.
    static func fingerprint(of certificate: SecCertificate) -> String {
        Digest.sha256Hex(certificateData(certificate))
    }

    /// Base64 of the SHA-256 digest of the certificate's SubjectPublicKeyInfo —
    /// what the setup URI calls `public_key_pin`. It survives a renewal that
    /// keeps the key, which a fingerprint does not.
    static func publicKeyPin(of certificate: SecCertificate) -> String? {
        guard let spki = subjectPublicKeyInfo(of: certificate) else { return nil }
        return Digest.base64(Digest.sha256(spki))
    }

    /// The `subjectPublicKeyInfo` field of an X.509 certificate, verbatim: the
    /// DER element with its tag and length, which is what the digest is taken
    /// over. It is read by walking the certificate's own structure — a hard-coded
    /// prefix per key type would only be right for the key types it was written
    /// for.
    static func subjectPublicKeyInfo(of certificate: SecCertificate) -> Data? {
        let bytes = [UInt8](certificateData(certificate))
        guard let outer = element(in: bytes, at: 0), outer.tag == 0x30 else { return nil }
        guard let tbs = element(in: bytes, at: outer.contentOffset), tbs.tag == 0x30 else { return nil }
        let tbsEnd = tbs.contentOffset + tbs.contentLength

        var cursor = tbs.contentOffset
        if let version = element(in: bytes, at: cursor), version.tag == 0xA0 {
            cursor = version.contentOffset + version.contentLength
        }
        // serialNumber, signature, issuer, validity, subject — then the key.
        for _ in 0..<5 {
            guard let field = element(in: bytes, at: cursor) else { return nil }
            let end = field.contentOffset + field.contentLength
            guard end <= tbsEnd else { return nil }
            cursor = end
        }
        guard let spki = element(in: bytes, at: cursor), spki.tag == 0x30 else { return nil }
        let end = spki.contentOffset + spki.contentLength
        guard end <= bytes.count else { return nil }
        return Data(bytes[spki.contentOffset..<end])
    }

    private struct DERElement {
        let tag: UInt8
        let contentOffset: Int
        let contentLength: Int
    }

    private static func element(in bytes: [UInt8], at offset: Int) -> DERElement? {
        guard offset >= 0, offset < bytes.count else { return nil }
        let tag = bytes[offset]
        var cursor = offset + 1
        guard cursor < bytes.count else { return nil }
        var length = Int(bytes[cursor])
        cursor += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count > 0, count <= 4, cursor + count <= bytes.count else { return nil }
            var value = 0
            for _ in 0..<count {
                value = (value << 8) | Int(bytes[cursor])
                cursor += 1
            }
            length = value
        }
        guard length >= 0, cursor + length <= bytes.count else { return nil }
        return DERElement(tag: tag, contentOffset: cursor, contentLength: length)
    }
}

/// How a gateway whose certificate nothing signed is trusted: by the pin its
/// invitation carried. The public key pin is the primary one — it survives a
/// renewal that keeps the key — and the certificate fingerprint is the fallback
/// for a gateway that generated its key and certificate together.
///
/// Expiry and the certificate covering the host still have to hold: the leaf is
/// made the only anchor and the trust is evaluated against the policy the
/// TLS stack attached, so it is still the system saying yes, not this code.
/// A pin that does not match is a failed connection with no way to continue.
enum PinnedTrust {

    static func evaluate(_ trust: SecTrust, pin: ServerPin) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else { return false }

        SecTrustSetAnchorCertificates(trust, [leaf] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)

        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else { return false }

        if let pinned = CertificateInspection.publicKeyPin(of: leaf), pinned == pin.publicKeyPin {
            return true
        }
        return CertificateInspection.fingerprint(of: leaf) == pin.certFingerprint
    }
}
