import CoreFoundation
import Foundation
import Security

/// Reading a credential the gateway issued: a PKCS#12 holding the device's
/// private key and the certificate chain it chains to. Everything here is
/// checked before the material is trusted — a credential that cannot be opened,
/// holds no key, or whose key does not match its certificate is a broken
/// credential, and finding that out at pairing time beats finding it out as a
/// TLS failure later.
enum CredentialMaterial {

    enum Failure: Error, Equatable {
        case unreadable(OSStatus)
        case noIdentity
        case noCertificate
        case unsupportedKey
        case keyPairMismatch
        case fingerprintMismatch
    }

    struct Imported {
        let identity: SecIdentity
        let certificates: [SecCertificate]

        var credential: DeviceCredential {
            DeviceCredential(identity: identity, certificates: certificates)
        }

        var leaf: SecCertificate? { certificates.first }
    }

    /// Opens a PKCS#12 with the one-shot password. The bytes and the password
    /// exist only as long as this call needs them.
    static func importPKCS12(_ data: Data, password: String) throws -> Imported {
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        let status = SecPKCS12Import(data as CFData, options, &items)
        guard status == errSecSuccess else { throw Failure.unreadable(status) }

        guard let results = items as? [Any], let first = results.first,
              let dictionary = first as? [String: Any]
        else { throw Failure.noIdentity }

        // `as? SecIdentity` never succeeds on this CFTypeRef, which is why the
        // type id is checked first and the pointer is reinterpreted after it:
        // the check is the contract, the cast is only how Swift spells it.
        guard let identityValue = dictionary[kSecImportItemIdentity as String] else {
            throw Failure.noIdentity
        }
        let identityObject = identityValue as AnyObject
        guard CFGetTypeID(identityObject) == SecIdentityGetTypeID() else { throw Failure.noIdentity }
        let identity = unsafeBitCast(identityObject, to: SecIdentity.self)

        var leaf: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &leaf) == errSecSuccess, let leaf else {
            throw Failure.noCertificate
        }

        var chain: [SecCertificate] = []
        if let value = dictionary[kSecImportItemCertChain as String], let certificates = value as? [SecCertificate] {
            chain = certificates
        }
        let leafFingerprint = fingerprint(of: leaf)
        if chain.first.map({ fingerprint(of: $0) }) != leafFingerprint {
            chain.removeAll { fingerprint(of: $0) == leafFingerprint }
            chain.insert(leaf, at: 0)
        }

        return Imported(identity: identity, certificates: chain)
    }

    /// SHA-256 of the DER certificate, lowercase hex — the fingerprint the wire
    /// calls `certificate_fingerprint`.
    static func fingerprint(of certificate: SecCertificate) -> String {
        CertificateInspection.fingerprint(of: certificate)
    }

    /// Proves the private key belongs to the certificate by signing a challenge
    /// with one and verifying with the other. The algorithm follows the key's
    /// own type: a hard-coded one would reject the other type rather than a
    /// broken credential.
    static func verifyKeyPair(_ imported: Imported) throws {
        var privateKey: SecKey?
        guard SecIdentityCopyPrivateKey(imported.identity, &privateKey) == errSecSuccess,
              let privateKey
        else { throw Failure.noIdentity }
        guard let certificate = imported.leaf, let publicKey = SecCertificateCopyKey(certificate) else {
            throw Failure.noCertificate
        }

        var challenge = [UInt8](repeating: 0, count: 32)
        for index in challenge.indices {
            challenge[index] = UInt8.random(in: UInt8.min...UInt8.max)
        }
        let payload = Data(challenge)

        guard let signingAlgorithm = signingAlgorithm(for: privateKey, operation: .sign),
              let verifyingAlgorithm = signingAlgorithm(for: publicKey, operation: .verify)
        else { throw Failure.unsupportedKey }

        // `try?` around a Security call that may or may not be imported as
        // throwing: either way the absent result is the failure.
        let signatureBox: CFData? = try? SecKeyCreateSignature(privateKey, signingAlgorithm, payload as CFData, nil)
        guard let signature = signatureBox else { throw Failure.unsupportedKey }

        let verified = SecKeyVerifySignature(
            publicKey,
            verifyingAlgorithm,
            payload as CFData,
            signature,
            nil
        )
        guard verified else { throw Failure.keyPairMismatch }
    }

    /// A credential is only the gateway's when the fingerprint it computes
    /// locally equals the one the pairing response named.
    static func verifyFingerprint(_ imported: Imported, expected: String) throws {
        guard let leaf = imported.leaf else { throw Failure.noCertificate }
        let actual = fingerprint(of: leaf)
        guard actual.caseInsensitiveCompare(expected) == .orderedSame else { throw Failure.fingerprintMismatch }
    }

    /// The signature algorithm a key can actually use, asked of the key itself:
    /// ECDSA for an EC key, RSA for an RSA key.
    static func signingAlgorithm(for key: SecKey, operation: SecKeyOperationType) -> SecKeyAlgorithm? {
        let ecdsa = SecKeyAlgorithm.ecdsaSignatureMessageX962SHA256
        let rsa = SecKeyAlgorithm.rsaSignatureMessagePKCS1v15SHA256

        let attributes = SecKeyCopyAttributes(key) as? [String: Any]
        let type = attributes?[kSecAttrKeyType as String] as? String
        if type == (kSecAttrKeyTypeECSECPrimeRandom as String), SecKeyIsAlgorithmSupported(key, operation, ecdsa) {
            return ecdsa
        }
        if type == (kSecAttrKeyTypeRSA as String), SecKeyIsAlgorithmSupported(key, operation, rsa) {
            return rsa
        }
        if SecKeyIsAlgorithmSupported(key, operation, ecdsa) { return ecdsa }
        if SecKeyIsAlgorithmSupported(key, operation, rsa) { return rsa }
        return nil
    }
}
