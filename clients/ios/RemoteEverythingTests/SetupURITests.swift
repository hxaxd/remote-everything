import XCTest
@testable import RemoteEverything

/// The invitation parser is a boundary: what it accepts is what the client will
/// act on, so the tests here are mostly refusals.
final class SetupURITests: XCTestCase {

    private let nodeID = String(repeating: "ab", count: 32)
    private let invitation = String(repeating: "A", count: 43)
    private let fingerprint = String(repeating: "cd", count: 32)
    private let pin = String(repeating: "A", count: 43) + "="

    private func uri(_ query: String) -> String {
        "remote-everything://setup?\(query)"
    }

    private func baseQuery(extra: String = "") -> String {
        let base = "node=\(nodeID)&node_name=Desk&origin=https://gw.example.com&invitation=\(invitation)"
        return extra.isEmpty ? base : base + "&" + extra
    }

    func testParsesAMinimalInvitation() throws {
        let parsed = try SetupURI.parse(uri(baseQuery()))
        XCTAssertEqual(parsed.node, nodeID)
        XCTAssertEqual(parsed.nodeName, "Desk")
        XCTAssertEqual(parsed.origin, "https://gw.example.com")
        XCTAssertEqual(parsed.invitation, invitation)
        XCTAssertNil(parsed.serverPin)
    }

    func testParsesAPinPair() throws {
        let parsed = try SetupURI.parse(uri(baseQuery(extra: "fingerprint=\(fingerprint)&public_key_pin=\(pin)")))
        XCTAssertEqual(parsed.serverPin?.certFingerprint, fingerprint)
        XCTAssertEqual(parsed.serverPin?.publicKeyPin, pin)
    }

    func testRejectsHalfAPin() {
        XCTAssertThrowsError(try SetupURI.parse(uri(baseQuery(extra: "fingerprint=\(fingerprint)"))))
        XCTAssertThrowsError(try SetupURI.parse(uri(baseQuery(extra: "public_key_pin=\(pin)"))))
    }

    func testRejectsAnUnknownParameter() {
        XCTAssertThrowsError(try SetupURI.parse(uri(baseQuery(extra: "mode=lan"))))
    }

    func testRejectsADuplicateParameter() {
        XCTAssertThrowsError(try SetupURI.parse(uri(baseQuery(extra: "node=\(nodeID)"))))
    }

    func testRejectsAMissingParameter() {
        let query = "node=\(nodeID)&node_name=Desk&invitation=\(invitation)"
        XCTAssertThrowsError(try SetupURI.parse(uri(query)))
    }

    func testRejectsAMalformedPair() {
        XCTAssertThrowsError(try SetupURI.parse(uri("node&node_name=Desk&origin=https://gw.example.com&invitation=\(invitation)")))
    }

    func testRejectsAnUppercaseNodeID() {
        let query = "node=\(nodeID.uppercased())&node_name=Desk&origin=https://gw.example.com&invitation=\(invitation)"
        XCTAssertThrowsError(try SetupURI.parse(uri(query)))
    }

    func testRejectsAnOriginWithAPath() {
        let query = "node=\(nodeID)&node_name=Desk&origin=https://gw.example.com/setup&invitation=\(invitation)"
        XCTAssertThrowsError(try SetupURI.parse(uri(query)))
    }

    func testRejectsANonHTTPSOrigin() {
        let query = "node=\(nodeID)&node_name=Desk&origin=http://gw.example.com&invitation=\(invitation)"
        XCTAssertThrowsError(try SetupURI.parse(uri(query)))
    }

    func testAcceptsAHostWithAPort() throws {
        let query = "node=\(nodeID)&node_name=Desk&origin=https://192.168.1.4:8443&invitation=\(invitation)"
        let parsed = try SetupURI.parse(uri(query))
        XCTAssertEqual(parsed.origin, "https://192.168.1.4:8443")
    }

    // MARK: - IPv6 origins (bracketed hosts)

    func testAcceptsABracketedIPv6Host() throws {
        let query = "node=\(nodeID)&node_name=Desk&origin=https://[::1]&invitation=\(invitation)"
        let parsed = try SetupURI.parse(uri(query))
        XCTAssertEqual(parsed.origin, "https://[::1]")
    }

    func testAcceptsABracketedIPv6HostWithAPort() throws {
        let query = "node=\(nodeID)&node_name=Desk&origin=https://[2001:db8::1]:8443&invitation=\(invitation)"
        let parsed = try SetupURI.parse(uri(query))
        XCTAssertEqual(parsed.origin, "https://[2001:db8::1]:8443")
    }

    func testRejectsABracketedHostWithNoClosingBracket() {
        let query = "node=\(nodeID)&node_name=Desk&origin=https://[::1&invitation=\(invitation)"
        XCTAssertThrowsError(try SetupURI.parse(uri(query)))
    }

    func testRejectsABracketedHostWithJunkAfterTheBracket() {
        XCTAssertFalse(SetupURI.isOrigin("https://[::1]junk"))
        XCTAssertFalse(SetupURI.isOrigin("https://[::1]:"))
        XCTAssertFalse(SetupURI.isOrigin("https://[::1]:0"))
        XCTAssertFalse(SetupURI.isOrigin("https://[::1]:99999"))
    }

    func testDirectOriginChecks() {
        XCTAssertTrue(SetupURI.isOrigin("https://gw.example.com"))
        XCTAssertTrue(SetupURI.isOrigin("https://192.168.1.4:8443"))
        XCTAssertFalse(SetupURI.isOrigin("http://gw.example.com"))
        XCTAssertFalse(SetupURI.isOrigin("https://"))
        XCTAssertFalse(SetupURI.isOrigin("https://gw.example.com/path"))
        XCTAssertFalse(SetupURI.isOrigin("https://user@gw.example.com"))
    }

    func testRejectsAShortInvitationToken() {
        let query = "node=\(nodeID)&node_name=Desk&origin=https://gw.example.com&invitation=\(String(repeating: "A", count: 42))"
        XCTAssertThrowsError(try SetupURI.parse(uri(query)))
    }

    func testDecodesPercentEscapesAndPlus() throws {
        let query = "node=\(nodeID)&node_name=My%20Desk%2B1&origin=https%3A%2F%2Fgw.example.com&invitation=\(invitation)"
        let parsed = try SetupURI.parse(uri(query))
        XCTAssertEqual(parsed.nodeName, "My Desk+1")
        XCTAssertEqual(parsed.origin, "https://gw.example.com")
    }

    func testDecodesMultiByteEscapes() throws {
        let query = "node=\(nodeID)&node_name=%E4%B9%A6%E6%88%BF&origin=https://gw.example.com&invitation=\(invitation)"
        let parsed = try SetupURI.parse(uri(query))
        XCTAssertEqual(parsed.nodeName, "书房")
        XCTAssertEqual(parsed.nodeName.unicodeScalars.count, 2)
    }

    func testRejectsABrokenPercentEscape() {
        let query = "node=\(nodeID)&node_name=Desk%2&origin=https://gw.example.com&invitation=\(invitation)"
        XCTAssertThrowsError(try SetupURI.parse(uri(query)))
    }

    func testRejectsPaddedAndControlCharacterNames() {
        XCTAssertFalse(SetupURI.isValidNodeName(" Desk"))
        XCTAssertFalse(SetupURI.isValidNodeName("Desk "))
        XCTAssertFalse(SetupURI.isValidNodeName("De\u{0}sk"))
        XCTAssertFalse(SetupURI.isValidNodeName(""))
        XCTAssertFalse(SetupURI.isValidNodeName(String(repeating: "a", count: 81)))
        XCTAssertTrue(SetupURI.isValidNodeName(String(repeating: "a", count: 80)))
    }

    func testRejectsSomethingThatIsNotASetupURI() {
        XCTAssertThrowsError(try SetupURI.parse("https://gw.example.com/?node=\(nodeID)"))
        XCTAssertThrowsError(try SetupURI.parse("remote-everything://other?\(baseQuery())"))
        XCTAssertThrowsError(try SetupURI.parse("remote-everything://setup"))
    }

    func testTrimsSurroundingWhitespace() throws {
        let parsed = try SetupURI.parse("  \(uri(baseQuery()))\n")
        XCTAssertEqual(parsed.node, nodeID)
    }
}
