import XCTest
@testable import RemoteEverything

final class RemoteAPITests: XCTestCase {
    private let config = try! SetupParser.create(
        installationId: String(repeating: "ab", count: 32),
        name: "Public",
        mode: "public",
        origin: "https://remote.example.com"
    )

    func testCatalogRequiresExactSchemaAndConsistentAppState() throws {
        let valid: [String: Any] = [
            "ok": true,
            "computer_connected": true,
            "code": "ready",
            "apps": [[
                "id": "editor",
                "name": "Editor",
                "description": "",
                "icon": "E",
                "accent": "#2563eb",
                "launch_fragment": "#workspace=main",
                "computer_connected": true,
                "enabled": false,
                "running": false,
                "code": "stopped",
            ]],
        ]
        let snapshot = try RemoteAPI.decodeCatalog(config: config, json: valid)
        XCTAssertEqual(snapshot.apps.first?.code, .stopped)
        XCTAssertTrue(snapshot.apps.first!.openUrl.hasPrefix("https://remote.example.com/__remote_everything/open/editor"))

        var unknown = valid
        unknown["legacy"] = true
        XCTAssertThrowsError(try RemoteAPI.decodeCatalog(config: config, json: unknown))

        var inconsistent = valid
        var app = inconsistent["apps"] as! [[String: Any]]
        app[0]["code"] = "ready"
        inconsistent["apps"] = app
        XCTAssertThrowsError(try RemoteAPI.decodeCatalog(config: config, json: inconsistent))
    }

    func testOfflineCatalogMustBeEmpty() throws {
        let invalid: [String: Any] = [
            "ok": true,
            "computer_connected": false,
            "code": "computer_offline",
            "apps": [[:]],
        ]
        XCTAssertThrowsError(try RemoteAPI.decodeCatalog(config: config, json: invalid))
    }

    func testPairingDeadlineMustBeAnInstant() throws {
        let invalid: [String: Any] = [
            "ok": true,
            "device_name": "phone",
            "certificate_fingerprint": String(repeating: "cd", count: 32),
            "credential_format": "pkcs12",
            "credential_pkcs12": "credential",
            "pending_expires_at": "later",
        ]
        XCTAssertThrowsError(try RemoteAPI.decodePairingCredential(json: invalid))
    }
}
