import XCTest
@testable import RemoteEverything

/// The wire-strictness cases all three clients run, from
/// `clients/behavior/fixtures/wire-cases.json`: every case goes through the same
/// production strict decoders, so a rule this client enforces and another does
/// not shows up here as a failure, and vice versa. The fixture is the arbiter;
/// this test is only its runner.
final class WireCasesTests: XCTestCase {

    func testTheWireIsAsStrictHereAsTheFixtureSays() throws {
        let data = try fixtureData("wire-cases.json")
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let cases = try XCTUnwrap(document["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for entry in cases {
            let name = entry["name"] as? String ?? "?"
            let kind = entry["kind"] as? String ?? "?"
            let want = entry["expect"] as? String ?? "?"
            let payload = try XCTUnwrap(entry["payload"] as? [String: Any], "\(name): payload is not an object")
            let payloadData = try JSONSerialization.data(withJSONObject: payload)
            let outcome: String
            do {
                try decode(kind: kind, data: payloadData)
                outcome = "accepted"
            } catch {
                outcome = "rejected"
            }
            let wanted = want == "accept" ? "accepted" : "rejected"
            let reason = entry["reason"] as? String ?? ""
            XCTAssertEqual(outcome, wanted, "\(name): \(reason)")
        }
    }

    private func decode(kind: String, data: Data) throws {
        let decoder = JSONDecoder()
        switch kind {
        case "nodes":
            _ = try decoder.decode(NodesResponse.self, from: data)
        case "catalog", "apps":
            _ = try decoder.decode(CatalogResponse.self, from: data)
        case "control":
            _ = try decoder.decode(ControlResponse.self, from: data)
        case "pairing":
            _ = try decoder.decode(PairingResponse.self, from: data)
        case "error":
            _ = try decoder.decode(ErrorResponse.self, from: data)
        case "activation":
            try decodeActivation(decoder, data: data)
        case "release":
            _ = try decoder.decode(ReleaseManifest.self, from: data)
        case "setup":
            guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let uri = payload["uri"] as? String else {
                throw NSError(domain: "WireCasesTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "setup case needs a uri"])
            }
            _ = try SetupUri.parse(uri)
        default:
            XCTFail("unknown wire kind \(kind)")
        }
    }

    /// An activation is the connected catalog with code=ready (activation.schema.json),
    /// or a refusal — never the offline catalog, never a connected node that
    /// cannot say what it runs. The same rule the production `activate` applies.
    private func decodeActivation(_ decoder: JSONDecoder, data: Data) throws {
        if let catalog = try? decoder.decode(CatalogResponse.self, from: data) {
            guard catalog.computerConnected, catalog.code == .ready else {
                throw DTORejection.badField("code", "activation")
            }
            return
        }
        // Not a catalog; it must be a refusal.
        _ = try decoder.decode(ErrorResponse.self, from: data)
    }

    // MARK: - Loading

    private static func fixturesDirectory() -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        var directory = thisFile.deletingLastPathComponent()
        for _ in 0..<3 {
            directory = directory.deletingLastPathComponent()
        }
        let fixtures = directory.appendingPathComponent("clients/behavior/fixtures")
        if FileManager.default.fileExists(atPath: fixtures.path) {
            return fixtures
        }
        var candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<6 {
            let probe = candidate.appendingPathComponent("clients/behavior/fixtures")
            if FileManager.default.fileExists(atPath: probe.path) { return probe }
            candidate = candidate.deletingLastPathComponent()
        }
        return fixtures
    }

    private func fixtureData(_ name: String) throws -> Data {
        let url = WireCasesTests.fixturesDirectory().appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(
                domain: "WireCasesTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "fixture \(name) is not where this checkout keeps it (\(url.path))"]
            )
        }
        return try Data(contentsOf: url)
    }
}
