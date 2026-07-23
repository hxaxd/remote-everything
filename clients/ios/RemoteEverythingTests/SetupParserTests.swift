import XCTest
@testable import RemoteEverything

final class SetupParserTests: XCTestCase {
    private let installationId = String(repeating: "ab", count: 32)

    func testParsesStrictLanSetup() throws {
        let uri = buildURI([
            "v": "2",
            "id": installationId,
            "name": "Home PC",
            "mode": "lan",
            "origin": "https://192.168.1.5:60001",
            "fingerprint": String(repeating: "cd", count: 32),
            "public_key_pin": String(repeating: "A", count: 43) + "=",
            "token": String(repeating: "01", count: 32),
        ])
        let setup = try SetupParser.parse(uri)
        XCTAssertEqual(setup.profile.installationId, installationId)
        XCTAssertEqual(setup.profile.gatewayOrigin, "https://192.168.1.5:60001")
        XCTAssertEqual(setup.invitation, "")
    }

    func testParsesStrictPublicSetup() throws {
        let invitation = String(repeating: "A", count: 43)
        let uri = buildURI([
            "v": "2",
            "id": installationId,
            "name": "Public PC",
            "mode": "public",
            "origin": "https://remote.example.com",
            "invitation": invitation,
        ])
        let setup = try SetupParser.parse(uri)
        XCTAssertEqual(setup.profile.mode, .public)
        XCTAssertEqual(setup.invitation, invitation)
    }

    func testRejectsDuplicatesUnknownFieldsAndInsecureOrigins() throws {
        let base = buildURI([
            "v": "2",
            "id": installationId,
            "name": "PC",
            "mode": "lan",
            "origin": "http://127.0.0.1:58626",
            "fingerprint": String(repeating: "cd", count: 32),
            "public_key_pin": String(repeating: "A", count: 43) + "=",
            "token": String(repeating: "01", count: 32),
        ])
        XCTAssertThrowsError(try SetupParser.parse(base))

        let httpsBase = base.replacingOccurrences(of: "http%3A", with: "https%3A")
        XCTAssertThrowsError(try SetupParser.parse(httpsBase + "&mode=lan"))
        XCTAssertThrowsError(try SetupParser.parse(httpsBase + "&extra=x"))
    }

    func testNameCountsUnicodeCodePoints() throws {
        let emoji = "😀"
        _ = try SetupParser.create(
            installationId: installationId,
            name: String(repeating: emoji, count: 80),
            mode: "public",
            origin: "https://remote.example.com"
        )
        XCTAssertThrowsError(try SetupParser.create(
            installationId: installationId,
            name: String(repeating: emoji, count: 81),
            mode: "public",
            origin: "https://remote.example.com"
        ))
    }

    // MARK: - Helpers

    private func buildURI(_ params: [String: String]) -> String {
        let query = params
            .map { "\(urlEncode($0))=\(urlEncode($1))" }
            .joined(separator: "&")
        return "remote-everything://setup?\(query)"
    }

    private func urlEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }
}
