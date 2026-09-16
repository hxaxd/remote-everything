import XCTest
@testable import RemoteEverything

final class GatewaySecurityPolicyTests: XCTestCase {

    func testFingerprintIsDeterministic() {
        let data = Data("test-certificate-data".utf8)
        let fp1 = GatewaySecurityPolicy.fingerprint(certificateData: data)
        let fp2 = GatewaySecurityPolicy.fingerprint(certificateData: data)
        XCTAssertEqual(fp1, fp2)
        XCTAssertEqual(fp1.count, 64) // SHA-256 hex = 64 chars
    }

    func testFingerprintDifferentDataProducesDifferentHash() {
        let data1 = Data("cert-a".utf8)
        let data2 = Data("cert-b".utf8)
        let fp1 = GatewaySecurityPolicy.fingerprint(certificateData: data1)
        let fp2 = GatewaySecurityPolicy.fingerprint(certificateData: data2)
        XCTAssertNotEqual(fp1, fp2)
    }

    func testFingerprintOnlyLowercaseHex() {
        let data = Data("sample".utf8)
        let fp = GatewaySecurityPolicy.fingerprint(certificateData: data)
        let allowedChars = CharacterSet(charactersIn: "0123456789abcdef")
        XCTAssertTrue(fp.unicodeScalars.allSatisfy { allowedChars.contains($0) })
    }

    // Every paired device presents the certificate it was issued, so the client
    // certificate is limited to the gateway endpoint rather than to one mode.
    func testLANModeAllowsClientCertificateOnlyForGateway() {
        let config = try! SetupParser.create(
            installationId: String(repeating: "ab", count: 32),
            name: "LAN PC",
            mode: "lan",
            origin: "https://192.168.1.5:60001",
            fingerprint: String(repeating: "cd", count: 32),
            publicKeyPin: String(repeating: "A", count: 43) + "="
        )
        XCTAssertTrue(GatewaySecurityPolicy.allowsClientCertificate(
            config: config, identityPresent: true, host: "192.168.1.5", port: 60001
        ))
        XCTAssertFalse(GatewaySecurityPolicy.allowsClientCertificate(
            config: config, identityPresent: false, host: "192.168.1.5", port: 60001
        ))
        XCTAssertFalse(GatewaySecurityPolicy.allowsClientCertificate(
            config: config, identityPresent: true, host: "192.168.1.5", port: 443
        ))
    }

    func testPublicModeAllowsClientCertificateOnlyForGateway() {
        let config = try! SetupParser.create(
            installationId: String(repeating: "ab", count: 32),
            name: "Public PC",
            mode: "public",
            origin: "https://remote.example.com"
        )
        // Correct host+port
        XCTAssertTrue(GatewaySecurityPolicy.allowsClientCertificate(
            config: config, identityPresent: true, host: "remote.example.com", port: 443
        ))
        // Wrong host
        XCTAssertFalse(GatewaySecurityPolicy.allowsClientCertificate(
            config: config, identityPresent: true, host: "evil.example.com", port: 443
        ))
        // No identity
        XCTAssertFalse(GatewaySecurityPolicy.allowsClientCertificate(
            config: config, identityPresent: false, host: "remote.example.com", port: 443
        ))
    }

    func testGatewayOriginValidation() {
        let config = try! SetupParser.create(
            installationId: String(repeating: "ab", count: 32),
            name: "PC",
            mode: "public",
            origin: "https://remote.example.com:8443"
        )
        XCTAssertTrue(GatewaySecurityPolicy.isGatewayOrigin(
            URL(string: "https://remote.example.com:8443/__remote_everything/apps")!, config: config
        ))
        XCTAssertFalse(GatewaySecurityPolicy.isGatewayOrigin(
            URL(string: "https://remote.example.com/apps")!, config: config
        )) // port mismatch (443 vs 8443)
        XCTAssertFalse(GatewaySecurityPolicy.isGatewayOrigin(
            URL(string: "http://remote.example.com:8443/apps")!, config: config
        )) // http not https
    }

    func testOpensInsideWebViewForGatewayURLs() {
        let config = try! SetupParser.create(
            installationId: String(repeating: "ab", count: 32),
            name: "PC",
            mode: "public",
            origin: "https://gateway.example.com"
        )
        XCTAssertTrue(GatewaySecurityPolicy.opensInsideWebView(
            config: config, url: "https://gateway.example.com/__remote_everything/open/editor#main"
        ))
        XCTAssertFalse(GatewaySecurityPolicy.opensInsideWebView(
            config: config, url: "https://external-site.com/page"
        ))
    }
}
