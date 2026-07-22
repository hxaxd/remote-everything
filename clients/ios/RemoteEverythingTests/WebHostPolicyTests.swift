import XCTest
@testable import RemoteEverything

final class WebHostPolicyTests: XCTestCase {
    func testExternalSchemeAllowlist() {
        XCTAssertTrue(WebHostPolicy.mayOpenExternally(URL(string: "https://example.com")!))
        XCTAssertTrue(WebHostPolicy.mayOpenExternally(URL(string: "mailto:user@example.com")!))
        XCTAssertTrue(WebHostPolicy.mayOpenExternally(URL(string: "tel:+123")!))
        XCTAssertFalse(WebHostPolicy.mayOpenExternally(URL(string: "javascript:alert(1)")!))
        XCTAssertFalse(WebHostPolicy.mayOpenExternally(URL(string: "remote-everything://setup/value")!))
    }

    func testFilenameSanitization() {
        XCTAssertEqual(WebHostPolicy.safeFilename("report:2026?.pdf"), "report_2026_.pdf")
        XCTAssertEqual(WebHostPolicy.safeFilename("\u{0000}"), "download")
        XCTAssertEqual(WebHostPolicy.safeFilename(".."), "download")
        XCTAssertEqual(WebHostPolicy.safeFilename(String(repeating: "a", count: 200)).count, 120)
    }

    func testDownloadsStayWithinGatewayOrigin() {
        let config = ConnectionConfig(
            installationId: String(repeating: "a", count: 64),
            name: "Test",
            mode: .lan,
            gatewayOrigin: "https://gateway.example:9443",
            gatewayFingerprint: String(repeating: "b", count: 64),
            gatewayPublicKeyPin: "pin"
        )

        XCTAssertTrue(WebHostPolicy.mayDownload(
            URL(string: "https://gateway.example:9443/files/result.zip")!,
            config: config
        ))
        XCTAssertFalse(WebHostPolicy.mayDownload(
            URL(string: "https://downloads.example/result.zip")!,
            config: config
        ))
        XCTAssertTrue(WebHostPolicy.mayDownload(
            URL(string: "blob:https://gateway.example:9443/95f57ccd-031b-47f6-aef8-366bc63ca552")!,
            config: config
        ))
        XCTAssertFalse(WebHostPolicy.mayDownload(
            URL(string: "blob:https://gateway.example/95f57ccd-031b-47f6-aef8-366bc63ca552")!,
            config: config
        ))
        XCTAssertFalse(WebHostPolicy.mayDownload(
            URL(string: "blob:https://downloads.example/95f57ccd-031b-47f6-aef8-366bc63ca552")!,
            config: config
        ))
        XCTAssertTrue(WebHostPolicy.mayFollowDownloadRedirect(
            URL(string: "https://gateway.example:9443/files/final.zip")!,
            config: config
        ))
        XCTAssertFalse(WebHostPolicy.mayFollowDownloadRedirect(
            URL(string: "https://downloads.example/final.zip")!,
            config: config
        ))
        XCTAssertFalse(WebHostPolicy.mayFollowDownloadRedirect(
            URL(string: "blob:https://gateway.example:9443/id")!,
            config: config
        ))
    }
}
