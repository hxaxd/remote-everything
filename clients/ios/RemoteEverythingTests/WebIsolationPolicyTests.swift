import XCTest
@testable import RemoteEverything

final class WebIsolationPolicyTests: XCTestCase {

    func testProfileIdentifierIsDeterministic() {
        let a = WebIsolationPolicy.profileIdentifier(
            installationId: String(repeating: "ab", count: 32),
            appId: "editor"
        )
        let b = WebIsolationPolicy.profileIdentifier(
            installationId: String(repeating: "ab", count: 32),
            appId: "editor"
        )
        XCTAssertEqual(a, b)
    }

    func testProfileIdentifiersAreSeparatedByInstallationId() {
        let id1 = String(repeating: "ab", count: 32)
        let id2 = String(repeating: "cd", count: 32)
        let a = WebIsolationPolicy.profileIdentifier(installationId: id1, appId: "app")
        let b = WebIsolationPolicy.profileIdentifier(installationId: id2, appId: "app")
        XCTAssertNotEqual(a, b)
    }

    func testProfileIdentifiersAreSeparatedByAppId() {
        let id = String(repeating: "ab", count: 32)
        let a = WebIsolationPolicy.profileIdentifier(installationId: id, appId: "editor")
        let b = WebIsolationPolicy.profileIdentifier(installationId: id, appId: "terminal")
        XCTAssertNotEqual(a, b)
    }

    func testRoutingCookieFormat() {
        let cookie = WebIsolationPolicy.routingCookie(appId: "editor", origin: "https://example.com")
        XCTAssertEqual(cookie["name"], "RemoteEverythingApp")
        XCTAssertEqual(cookie["value"], "editor")
        XCTAssertEqual(cookie["path"], "/")
        XCTAssertEqual(cookie["secure"], "true")
    }
}
