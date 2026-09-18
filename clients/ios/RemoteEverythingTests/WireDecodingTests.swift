import XCTest
@testable import RemoteEverything

/// The wire bodies are decoded strictly: a field the client does not know, a
/// field that is missing, and an enum value that is not in the contract are all
/// refusals. These tests are the client's half of that rule.
final class WireDecodingTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func app(id: String = "notes", enabled: Bool = true, running: Bool = true) -> String {
        let code = enabled ? (running ? "ready" : "starting") : (running ? "stopping" : "stopped")
        return """
        {"id":"\(id)","name":"Notes","description":"","icon":"N","accent":"#2563eb",
         "launch_fragment":"#/home","computer_connected":true,"enabled":\(enabled),
         "running":\(running),"code":"\(code)"}
        """
    }

    func testDecodesANodesAnswer() throws {
        let response = try decode(NodesResponse.self, """
        {"ok":true,"nodes":[{"id":"\(String(repeating: "a", count: 64))","name":"Desk"}]}
        """)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.nodes.count, 1)
        XCTAssertEqual(response.nodes.first?.name, "Desk")
    }

    func testRejectsAnUnknownFieldInNodes() {
        XCTAssertThrowsError(try decode(NodesResponse.self, """
        {"ok":true,"nodes":[],"count":0}
        """))
    }

    func testRejectsAMissingFieldInNodes() {
        XCTAssertThrowsError(try decode(NodesResponse.self, """
        {"ok":true}
        """))
    }

    func testDecodesACatalog() throws {
        let response = try decode(CatalogResponse.self, """
        {"ok":true,"computer_connected":true,"code":"ready","apps":[\(app())]}
        """)
        XCTAssertTrue(response.computerConnected)
        XCTAssertEqual(response.applicationInfos.first?.launchFragment, "#/home")
        XCTAssertEqual(response.applicationInfos.first?.code, .ready)
    }

    func testRejectsAnAppWhoseCodeDisagreesWithItsFlags() {
        XCTAssertThrowsError(try decode(CatalogResponse.self, """
        {"ok":true,"computer_connected":true,"code":"ready","apps":[
          {"id":"notes","name":"Notes","description":"","icon":"","accent":"#2563eb",
           "launch_fragment":"","computer_connected":true,"enabled":true,"running":true,"code":"stopped"}]}
        """))
    }

    func testRejectsACatalogThatSaysOfflineWithApps() {
        XCTAssertThrowsError(try decode(CatalogResponse.self, """
        {"ok":true,"computer_connected":false,"code":"computer_offline","apps":[\(app())]}
        """))
    }

    func testRejectsACatalogWhoseCodeDisagreesWithConnection() {
        XCTAssertThrowsError(try decode(CatalogResponse.self, """
        {"ok":true,"computer_connected":false,"code":"ready","apps":[]}
        """))
    }

    func testAcceptsAnOfflineCatalog() throws {
        let response = try decode(CatalogResponse.self, """
        {"ok":true,"computer_connected":false,"code":"computer_offline","apps":[]}
        """)
        XCTAssertFalse(response.computerConnected)
        XCTAssertTrue(response.apps.isEmpty)
    }

    func testRejectsAnAccentThatIsNotHex() {
        XCTAssertThrowsError(try decode(CatalogResponse.self, """
        {"ok":true,"computer_connected":true,"code":"ready","apps":[
          {"id":"notes","name":"Notes","description":"","icon":"","accent":"blue",
           "launch_fragment":"","computer_connected":true,"enabled":true,"running":true,"code":"ready"}]}
        """))
    }

    func testRejectsALaunchFragmentThatDoesNotStartWithAHash() {
        XCTAssertThrowsError(try decode(CatalogResponse.self, """
        {"ok":true,"computer_connected":true,"code":"ready","apps":[
          {"id":"notes","name":"Notes","description":"","icon":"","accent":"#2563eb",
           "launch_fragment":"/home","computer_connected":true,"enabled":true,"running":true,"code":"ready"}]}
        """))
    }

    func testRejectsDuplicateApplicationIDs() {
        XCTAssertThrowsError(try decode(CatalogResponse.self, """
        {"ok":true,"computer_connected":true,"code":"ready","apps":[\(app()),\(app())]}
        """))
    }

    func testDecodesAControlAnswer() throws {
        let response = try decode(ControlResponse.self, """
        {"ok":true,"action":"start","computer_connected":true,"enabled":true,"running":true,"code":"ready"}
        """)
        XCTAssertEqual(response.action, .start)
        XCTAssertEqual(response.code, .ready)
        XCTAssertNil(response.app)
    }

    func testAcceptsAnOfflineControlAnswer() throws {
        let response = try decode(ControlResponse.self, """
        {"ok":false,"action":"stop","computer_connected":false,"enabled":false,"running":false,"code":"computer_offline"}
        """)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.code, .computerOffline)
    }

    func testRejectsAnUnknownControlAction() {
        XCTAssertThrowsError(try decode(ControlResponse.self, """
        {"ok":true,"action":"restart","computer_connected":true,"enabled":true,"running":true,"code":"ready"}
        """))
    }

    func testRejectsAnUnlistedErrorCode() {
        XCTAssertThrowsError(try decode(ErrorResponse.self, """
        {"ok":false,"code":"too_many_devices"}
        """))
    }

    func testDecodesEveryErrorCodeTheContractNames() throws {
        // All nineteen, spelled as errors.schema.json spells them.
        let codes = [
            "node_required", "unauthorized", "invitation_denied", "invitation_expired", "approval_pending",
            "node_not_found", "app_not_found", "not_found", "forbidden", "computer_offline", "activation_failed",
            "invalid_device_name", "invalid_credential_password", "invalid_body", "invalid_json",
            "rate_limited", "server_busy", "pairing_failed", "internal_error",
        ]
        XCTAssertEqual(codes.count, 19)
        for code in codes {
            let response = try decode(ErrorResponse.self, "{\"ok\":false,\"code\":\"\(code)\"}")
            XCTAssertEqual(response.code.rawValue, code)
        }
    }

    func testDecodesAPairingAnswer() throws {
        let response = try decode(PairingResponse.self, """
        {"ok":true,"device_name":"hxaxd 的手机","certificate_fingerprint":"\(String(repeating: "a", count: 64))",
         "credential_format":"pkcs12","credential_pkcs12":"MIIB","pending_expires_at":"2026-09-17T10:00:00Z"}
        """)
        XCTAssertEqual(response.credentialFormat, "pkcs12")
        XCTAssertNotNil(response.pendingExpiry)
    }

    func testRejectsAPairingAnswerThatIsNotPKCS12() {
        XCTAssertThrowsError(try decode(PairingResponse.self, """
        {"ok":true,"device_name":"phone","certificate_fingerprint":"\(String(repeating: "a", count: 64))",
         "credential_format":"pem","credential_pkcs12":"MIIB","pending_expires_at":"2026-09-17T10:00:00Z"}
        """))
    }

    func testRejectsAPairingExpiryThatIsNotATimestamp() {
        XCTAssertThrowsError(try decode(PairingResponse.self, """
        {"ok":true,"device_name":"phone","certificate_fingerprint":"\(String(repeating: "a", count: 64))",
         "credential_format":"pkcs12","credential_pkcs12":"MIIB","pending_expires_at":"soon"}
        """))
    }

    func testDecodesTheReleaseManifest() throws {
        let manifest = try decode(ReleaseManifest.self, """
        {"schema":1,"versionName":"3.5.0","buildNumber":28,"protocolVersion":1,
         "minimumPlatforms":{"androidSdk":30,"ios":"17.0","harmonyApi":"24"}}
        """)
        XCTAssertEqual(manifest.versionName, "3.5.0")
        XCTAssertEqual(manifest.buildNumber, 28)
        XCTAssertEqual(manifest.minimumPlatforms.ios, "17.0")
    }

    func testRejectsAReleaseManifestWithAnUnknownPlatform() {
        XCTAssertThrowsError(try decode(ReleaseManifest.self, """
        {"schema":1,"versionName":"3.5.0","buildNumber":28,"protocolVersion":1,
         "minimumPlatforms":{"androidSdk":30,"ios":"17.0","harmonyApi":"24","windows":"11"}}
        """))
    }

    func testAppStateIsConsistentWithItsFlags() {
        XCTAssertEqual(AppState(rawValue: "ready"), .ready)
        XCTAssertTrue(AppState.ready.isSteady)
        XCTAssertFalse(AppState.starting.isSteady)
    }
}
