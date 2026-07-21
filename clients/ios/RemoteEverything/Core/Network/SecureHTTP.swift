import Foundation
import Security

// MARK: - Types

/// A client certificate identity for mTLS. Mirrors Android's `ClientIdentity`.
struct ClientIdentity {
    let identity: SecIdentity
    let certificateChain: [SecCertificate]
}

/// Result of an HTTP request. Mirrors Android's `HttpResult`.
struct HTTPResult {
    let status: Int
    let body: Data

    func json() throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw RemoteAPI.APIError.invalidFields("响应不是 JSON 对象")
        }
        return obj
    }
}

// MARK: - URLSession Delegate

/// Handles TLS challenges: client certificate presentation (public mTLS)
/// and server certificate pinning (LAN mode).
private final class GatewaySessionDelegate: NSObject, URLSessionTaskDelegate {
    let config: ConnectionConfig
    let identity: ClientIdentity?

    init(config: ConnectionConfig, identity: ClientIdentity?) {
        self.config = config
        self.identity = identity
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let host = challenge.protectionSpace.host
        let port = challenge.protectionSpace.port

        // Verify the challenge is for our gateway
        guard config.isGatewayEndpoint(host: host, port: port) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate {
            guard config.mode == .public, let identity else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(
                .useCredential,
                URLCredential(
                    identity: identity.identity,
                    certificates: identity.certificateChain,
                    persistence: .forSession
                )
            )
            return
        }

        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        if config.mode == .lan {
            // LAN: pin the server certificate against expected fingerprint
            let expectedFingerprint = config.gatewayFingerprint
            if GatewaySecurityPolicy.validateLANTrust(
                trust: trust,
                host: host,
                expectedFingerprint: expectedFingerprint
            ) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        } else {
            // Public: use system trust (standard Web PKI)
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

// MARK: - SecureHTTP

enum SecureHTTP {

    private static let timeout: TimeInterval = 12

    /// Perform an HTTP request to the gateway with appropriate TLS configuration.
    /// - For LAN mode: pins the server certificate to the expected fingerprint.
    /// - For public mode: presents mTLS client certificate + system trust.
    /// - Never follows redirects. Enforces same-origin-only requests.
    static func request(
        config: ConnectionConfig,
        url: String,
        method: String,
        identity: ClientIdentity?,
        headers: [String: String] = [:],
        body: String? = nil
    ) async throws -> HTTPResult {
        guard let requestURL = URL(string: url),
              GatewaySecurityPolicy.isGatewayOrigin(requestURL, config: config) else {
            throw RemoteAPI.APIError.invalidFields("请求地址不属于配置的服务")
        }

        var urlRequest = URLRequest(url: requestURL)
        urlRequest.httpMethod = method
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        for (key, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        if let body = body {
            urlRequest.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = body.data(using: .utf8)
        }

        let delegate = GatewaySessionDelegate(config: config, identity: identity)
        let session = URLSession(
            configuration: .ephemeral,
            delegate: delegate,
            delegateQueue: nil
        )

        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteAPI.APIError.invalidFields("响应不是 HTTP 响应")
        }

        return HTTPResult(status: httpResponse.statusCode, body: data)
    }

    /// Verify WebView SSL errors for LAN certificate pinning.
    /// Mirrors Android's `acceptsPinnedWebViewError()`.
    static func acceptsPinnedWebViewError(
        config: ConnectionConfig,
        error: Error,
        url: URL,
        serverTrust: SecTrust?
    ) -> Bool {
        guard config.mode == .lan,
              GatewaySecurityPolicy.isGatewayOrigin(url, config: config),
              let trust = serverTrust else {
            return false
        }

        return GatewaySecurityPolicy.validateLANTrust(
            trust: trust,
            host: url.host ?? "",
            expectedFingerprint: config.gatewayFingerprint
        )
    }
}
