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
    /// Checks: certificate expiry, hostname match (SAN), fingerprint match.
    /// Returns true only if all checks pass. No "continue anyway" fallback.
    static func validateLANTrust(
        trust: SecTrust,
        host: String,
        expectedFingerprint: String
    ) -> Bool {
        // Get the leaf certificate (index 0)
        guard SecTrustGetCertificateCount(trust) > 0,
              let leaf = SecTrustGetCertificateAtIndex(trust, 0) else {
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

        // Verify the certificate covers the host (SAN check)
        guard certificateCoversHost(certificate: leaf, host: host) else {
            return false
        }

        return true
    }

    // MARK: - Host Validation

    /// Check if a certificate's Subject Alternative Names cover the given host.
    /// Mirrors Android's `subjectAlternativeNamesCoverHost()`.
    static func certificateCoversHost(certificate: SecCertificate, host: String) -> Bool {
        guard let names = SecCertificateCopyValues(certificate, [kSecOIDSubjectAltName] as CFArray, nil) as? [String: Any],
              let sanDict = names[kSecOIDSubjectAltName as String] as? [String: Any],
              let sanValue = sanDict[kSecPropertyKeyValue as String] as? [[String: Any]] else {
            return false
        }

        let isNumericHost = host.contains(":") || host.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil

        for entry in sanValue {
            guard let label = entry[kSecPropertyKeyLabel as String] as? String,
                  let value = entry[kSecPropertyKeyValue as String] as? String else {
                continue
            }

            if label == "DNS Name" && !isNumericHost {
                if value.caseInsensitiveCompare(host) == .orderedSame {
                    return true
                }
            } else if label == "IP Address" && isNumericHost {
                if value == host {
                    return true
                }
            }
        }

        return false
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
    /// Only for public mode, only when identity is available, only for the gateway host/port.
    /// Mirrors Android's `allowsClientCertificate()`.
    static func allowsClientCertificate(
        config: ConnectionConfig,
        identityPresent: Bool,
        host: String?,
        port: Int
    ) -> Bool {
        return config.mode == .public && identityPresent && config.isGatewayEndpoint(host: host, port: port)
    }

    /// Determine whether a URL should open inside the WebView or be sent to the system browser.
    /// Mirrors Android's `opensInsideWebView()`.
    static func opensInsideWebView(config: ConnectionConfig, url: String) -> Bool {
        return config.isGatewayUrl(url)
    }
}
