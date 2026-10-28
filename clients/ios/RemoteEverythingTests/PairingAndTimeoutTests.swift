import Foundation
import XCTest
@testable import RemoteEverything

final class PairingAndTimeoutTests: XCTestCase {
    @MainActor
    func testExpiredStageDoesNotInvalidateNewPairing() async throws {
        try await checkPairingAfterExpiredStage(invalidateNewAttempt: false)
    }

    @MainActor
    func testExternalCredentialRemovalStillInvalidatesNewPairing() async throws {
        try await checkPairingAfterExpiredStage(invalidateNewAttempt: true)
    }

    @MainActor
    private func checkPairingAfterExpiredStage(invalidateNewAttempt: Bool) async throws {
        let origin = "https://gateway.example"
        let name = "com.remoteeverything.tests.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
        let vault = IdentityVault(keychain: KeychainCredentialStore(service: name))
        let stages = StagedSetupStore(directory: directory)
        let nodeID = String(repeating: "a", count: 64)
        try stages.stage(StagedSetup(
            origin: origin, nodeID: nodeID, nodeName: "Desk", deviceName: "Phone",
            certificateFingerprint: String(repeating: "b", count: 64),
            credentialRef: IdentityVault.alias(forOrigin: origin), serverPin: nil,
            pendingExpiresAt: Date().addingTimeInterval(-60), createdAt: Date().addingTimeInterval(-600)
        ))
        let service = PairingService(vault: vault, stages: stages, store: ClientStore(defaults: defaults)) { origin, credential, pin in
            if invalidateNewAttempt { vault.forget(origin: origin) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PairingAndTimeoutProtocol.self]
            return GatewayClient(origin: origin, credential: credential, pin: pin, configuration: configuration)
        }
        let invitation = SetupURI.Invitation(node: nodeID, nodeName: "Desk", origin: origin,
                                             invitation: String(repeating: "x", count: 43), serverPin: nil)
        do {
            _ = try await service.run(PairingService.Attempt(invitation: invitation, deviceName: "Phone"))
            XCTFail("The deliberately invalid PKCS12 must be refused")
        } catch is CancellationError {
            XCTAssertTrue(invalidateNewAttempt, "Cleaning up an expired stage must not cancel its replacement")
        } catch let error as ClientError {
            XCTAssertFalse(invalidateNewAttempt, "External removal must discard the pairing response before import")
            // Reaching credential import proves the pairing response survived the version guard.
            XCTAssertEqual(error.code, .pairingFailed)
        }
        XCTAssertNil(stages.load(origin: origin))
        XCTAssertFalse(vault.hasCredential(origin: origin))
    }

    func testStopRequestIsNotClippedBySessionResourceDeadline() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PairingAndTimeoutProtocol.self]
        let client = GatewayClient(origin: "https://gateway.example", credential: nil, pin: nil, configuration: configuration)
        XCTAssertGreaterThanOrEqual(configuration.timeoutIntervalForResource, 30)
        let answer = try await client.stop(nodeID: String(repeating: "a", count: 64), appID: "dsh")
        XCTAssertTrue(answer.ok)
        XCTAssertEqual(answer.code, .stopped)
    }
}

private final class PairingAndTimeoutProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let body: String
        if url.path == GatewayClient.Paths.pair {
            body = """
            {"ok":true,"device_name":"Phone","certificate_fingerprint":"\(String(repeating: "b", count: 64))","credential_format":"pkcs12","credential_pkcs12":"AA==","pending_expires_at":"2099-01-01T00:00:00Z"}
            """
        } else {
            XCTAssertEqual(url.path, GatewayClient.Paths.stop("dsh"))
            XCTAssertEqual(request.timeoutInterval, 30)
            body = """
            {"ok":true,"action":"stop","computer_connected":true,"enabled":false,"running":false,"code":"stopped"}
            """
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}
