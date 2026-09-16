import Foundation
import CryptoKit
import Security

/// Certificate pinning, fingerprint calculation, and host validation.
/// Mirrors Android's `GatewaySecurityPolicy`.
enum GatewaySecurityPolicy {

    // MARK: - Fingerprint

    /// SHA-256 fingerprint of a DER-encoded certificate, as lowercase hex.
    /// Mirrors Android's `GatewaySecurityPolicy.fingerprint()`.
    static func fingerprint(certificateData: Data) -> String {
        SHA256.hash(data: certificateData)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Extract SHA-256 fingerprint from a SecCertificate.
    static func fingerprint(certificate: SecCertificate) -> String {
        let data = SecCertificateCopyData(certificate) as Data
        return fingerprint(certificateData: data)
    }

    // MARK: - LAN Trust Evaluation

    /// Validate a server trust against a pinned fingerprint for LAN mode.
    /// Checks: certificate expiry, system hostname validation, fingerprint match.
    /// Returns true only if all checks pass. No "continue anyway" fallback.
    static func validateLANTrust(
        trust: SecTrust,
        host: String,
        expectedFingerprint: String
    ) -> Bool {
        // Get the leaf certificate (index 0) from the evaluated chain.
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            return false
        }

        let actualFingerprint = fingerprint(certificate: leaf)
        guard actualFingerprint == expectedFingerprint else {
            return false
        }

        // Treat only the pinned leaf as the local trust anchor, while retaining
        // the system SSL policy so expiry and hostname validation still run.
        guard SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString)) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [leaf] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else {
            return false
        }
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            return false
        }

        return true
    }

    // MARK: - Origin Validation

    /// Verify that a URL is within the gateway's origin.
    static func isGatewayOrigin(_ url: URL, config: ConnectionConfig) -> Bool {
        guard url.scheme == "https",
              let urlHost = url.host else {
            return false
        }
        let port = url.port ?? 443
        return config.isGatewayEndpoint(host: urlHost, port: port)
    }

    /// Determine whether to offer a client certificate for a given authentication challenge.
    /// A device is admitted by the certificate it was issued in every mode: what
    /// differs between them is who signs the entrance, not who the client is.
    /// Mirrors Android's `allowsClientCertificate()`.
    static func allowsClientCertificate(
        config: ConnectionConfig,
        identityPresent: Bool,
        host: String?,
        port: Int
    ) -> Bool {
        return identityPresent && config.isGatewayEndpoint(host: host, port: port)
    }

    /// Determine whether a URL should open inside the WebView or be sent to the system browser.
    /// Mirrors Android's `opensInsideWebView()`.
    static func opensInsideWebView(config: ConnectionConfig, url: String) -> Bool {
        return config.isGatewayUrl(url)
    }
}
