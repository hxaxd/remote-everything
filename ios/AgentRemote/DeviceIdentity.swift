import Foundation
import Security

enum IdentityError: LocalizedError {
    case keyCreation(OSStatus)
    case keyUnavailable
    case encoding
    case signing(CFError?)
    case certificate
    case certificateMismatch
    case identity(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keyCreation(let status): return "设备密钥创建失败（\(status)）"
        case .keyUnavailable: return "设备密钥不可用"
        case .encoding: return "设备公钥编码失败"
        case .signing: return "设备签名失败"
        case .certificate: return "服务端证书无效"
        case .certificateMismatch: return "服务端证书与本机私钥不匹配"
        case .identity(let status): return "客户端身份创建失败（\(status)）"
        }
    }
}

struct DeviceProof {
    let nonce: String
    let signature: String
}

final class DeviceIdentity {
    static let shared = DeviceIdentity()
    private let tag = Data("com.hxaxd.agentremote.device-key-v1".utf8)
    private let certificateKey = "agent_remote_certificate"

    private init() {}

    func ensurePrivateKey() throws -> SecKey {
        if let existing = findPrivateKey() { return existing }
        let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            .privateKeyUsage,
            nil
        )!
        let secureAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrAccessControl as String: access
            ]
        ]
        var error: Unmanaged<CFError>?
        if let key = SecKeyCreateRandomKey(secureAttributes as CFDictionary, &error) { return key }
        let fallbackAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
        ]
        error = nil
        guard let key = SecKeyCreateRandomKey(fallbackAttributes as CFDictionary, &error) else {
            let code = (error?.takeRetainedValue() as Error? as NSError?)?.code ?? Int(errSecParam)
            throw IdentityError.keyCreation(OSStatus(code))
        }
        return key
    }

    func publicKeyPEM() throws -> String {
        let privateKey = try ensurePrivateKey()
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let raw = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw IdentityError.encoding
        }
        let algorithm = Data([0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01, 0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
        var body = Data([0x30, 0x59])
        body.append(algorithm)
        body.append(contentsOf: [0x03, 0x42, 0x00])
        body.append(raw)
        let base64 = body.base64EncodedString()
        let lines = stride(from: 0, to: base64.count, by: 64).map { offset -> String in
            let start = base64.index(base64.startIndex, offsetBy: offset)
            let end = base64.index(start, offsetBy: min(64, base64.count - offset))
            return String(base64[start..<end])
        }
        return "-----BEGIN PUBLIC KEY-----\n" + lines.joined(separator: "\n") + "\n-----END PUBLIC KEY-----\n"
    }

    func createProof(deviceName: String) throws -> DeviceProof {
        let privateKey = try ensurePrivateKey()
        var nonce = Data(count: 32)
        let status = nonce.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, 32, bytes.baseAddress!)
        }
        guard status == errSecSuccess else { throw IdentityError.encoding }
        var message = Data("KIMI-REMOTE-ENROLL-V1".utf8)
        message.append(0)
        message.append(Data(deviceName.utf8))
        message.append(0)
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            message as CFData,
            &error
        ) as Data? else {
            throw IdentityError.signing(error?.takeRetainedValue())
        }
        return DeviceProof(nonce: nonce.base64EncodedString(), signature: signature.base64EncodedString())
    }

    func installCertificate(pem: String) throws {
        guard let certificate = Self.certificate(fromPEM: pem),
              let certificateKey = SecCertificateCopyKey(certificate),
              let privatePublic = SecKeyCopyPublicKey(try ensurePrivateKey()),
              let certificateBytes = SecKeyCopyExternalRepresentation(certificateKey, nil) as Data?,
              let privateBytes = SecKeyCopyExternalRepresentation(privatePublic, nil) as Data? else {
            throw IdentityError.certificate
        }
        guard certificateBytes == privateBytes else { throw IdentityError.certificateMismatch }
        UserDefaults.standard.set(pem, forKey: self.certificateKey)
        SecItemDelete([kSecClass as String: kSecClassCertificate, kSecValueRef as String: certificate] as CFDictionary)
        SecItemAdd([
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ] as CFDictionary, nil)
    }

    func certificate() -> SecCertificate? {
        guard let pem = UserDefaults.standard.string(forKey: certificateKey) else { return nil }
        return Self.certificate(fromPEM: pem)
    }

    func identity() throws -> (SecIdentity, [SecCertificate]) {
        guard let certificate = certificate() else { throw IdentityError.certificate }
        var identity: SecIdentity?
        let status = SecIdentityCreateWithCertificate(nil, certificate, &identity)
        guard status == errSecSuccess, let identity else { throw IdentityError.identity(status) }
        return (identity, [certificate])
    }

    var isApproved: Bool { certificate() != nil }

    private func findPrivateKey() -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as! SecKey
    }

    static func certificate(fromPEM pem: String) -> SecCertificate? {
        let body = pem
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard let data = Data(base64Encoded: body) else { return nil }
        return SecCertificateCreateWithData(nil, data as CFData)
    }
}
