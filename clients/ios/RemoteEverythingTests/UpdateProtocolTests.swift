import XCTest
@testable import RemoteEverything

final class UpdateProtocolTests: XCTestCase {
    func testReleaseParsingAndVersionComparison() throws {
        let body = """
        {
          "draft": false,
          "prerelease": false,
          "tag_name": "v3.5.0",
          "html_url": "https://github.com/hxaxd/remote-everything/releases/tag/v3.5.0"
        }
        """
        let release = try UpdateProtocol.parseLatestRelease(body: body)
        XCTAssertEqual(release.versionName, "3.5.0")
        XCTAssertEqual(try UpdateProtocol.compareVersions("3.10.0", "3.9.9"), 1)
        XCTAssertEqual(try UpdateProtocol.compareVersions("v3.4.0", "3.4.0"), 0)
        XCTAssertEqual(try UpdateProtocol.compareVersions("2.9.9", "3.0.0"), -1)
    }

    func testReleaseParsingRejectsUntrustedPage() {
        let body = """
        {
          "draft": false,
          "prerelease": false,
          "tag_name": "v3.5.0",
          "html_url": "https://example.com/releases/tag/v3.5.0"
        }
        """
        XCTAssertThrowsError(try UpdateProtocol.parseLatestRelease(body: body))
    }
}
