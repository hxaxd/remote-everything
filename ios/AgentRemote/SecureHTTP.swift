import Foundation
import Security

enum NetworkError: LocalizedError {
    case bootstrap
    case response(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .bootstrap: return "注册凭证不可用"
        case .response(let status, _): return "服务器返回错误（\(status)）"
        case .invalidResponse: return "服务器响应无效"
        }
    }
}

final class ClientIdentityDelegate: NSObject, URLSessionDelegate {
    private let identity: SecIdentity
    private let certificates: [SecCertificate]

    init(identity: SecIdentity, certificates: [SecCertificate]) {
        self.identity = identity
        self.certificates = certificates
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate {
            let credential = URLCredential(identity: identity, certificates: certificates, persistence: .forSession)
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

final class SecureHTTP {
    private let delegate: ClientIdentityDelegate
    private let session: URLSession

    init(identity: SecIdentity, certificates: [SecCertificate]) {
        delegate = ClientIdentityDelegate(identity: identity, certificates: certificates)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    static func bootstrap() throws -> SecureHTTP {
        guard let url = Bundle.main.url(forResource: "bootstrap-client", withExtension: "p12"),
              let data = try? Data(contentsOf: url) else { throw NetworkError.bootstrap }
        var result: CFArray?
        let status = SecPKCS12Import(
            data as CFData,
            [kSecImportExportPassphrase as String: AppConfig.bootstrapPassword] as CFDictionary,
            &result
        )
        guard status == errSecSuccess,
              let item = (result as? [[String: Any]])?.first,
              let identityValue = item[kSecImportItemIdentity as String],
              let certificates = item[kSecImportItemCertChain as String] as? [SecCertificate] else {
            throw NetworkError.bootstrap
        }
        let identity = identityValue as! SecIdentity
        return SecureHTTP(identity: identity, certificates: certificates)
    }

    static func permanent() throws -> SecureHTTP {
        let (identity, certificates) = try DeviceIdentity.shared.identity()
        return SecureHTTP(identity: identity, certificates: certificates)
    }

    func json(
        url: URL,
        method: String,
        headers: [String: String] = [:],
        body: [String: Any]? = nil
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NetworkError.invalidResponse }
        let text = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(http.statusCode) else { throw NetworkError.response(http.statusCode, text) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetworkError.invalidResponse
        }
        return json
    }
}
