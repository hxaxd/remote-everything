import Foundation
import XCTest
@testable import RemoteEverything

final class PairingAndTimeoutTests: XCTestCase {
    @MainActor
    func testCancellingReplacementKeepsExistingConnectionsAndCredentials() throws {
        let name = "com.remoteeverything.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let vault = IdentityVault(keychain: KeychainCredentialStore(service: name))
        let store = ClientStore(defaults: defaults)
        let stages = StagedSetupStore(directory: directory)
        let origin = "https://gateway.example"
        let otherOrigin = "https://other.example"
        let oldRef = try vault.store(origin: origin, pkcs12: Data([1]), password: "old")
        let otherRef = try vault.store(origin: otherOrigin, pkcs12: Data([2]), password: "other")
        let pendingRef = try vault.storePending(pkcs12: Data([3]), password: "pending")
        defer {
            for ref in [oldRef, otherRef, pendingRef] { vault.forget(aliasRef: ref) }
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
        let old = Identity(origin: origin, deviceName: "Old", certFingerprint: String(repeating: "a", count: 64),
                           credentialRef: oldRef, serverPin: nil, createdAt: Date())
        let other = Identity(origin: otherOrigin, deviceName: "Other", certFingerprint: String(repeating: "b", count: 64),
                             credentialRef: otherRef, serverPin: nil, createdAt: Date())
        store.saveIdentities([old, other])
        try stages.stage(StagedSetup(origin: origin, nodeID: String(repeating: "c", count: 64), nodeName: "New node", deviceName: "Phone",
            certificateFingerprint: String(repeating: "d", count: 64), credentialRef: pendingRef, serverPin: nil,
            pendingExpiresAt: Date().addingTimeInterval(600), createdAt: Date()))
        let service = PairingService(vault: vault, stages: stages, store: store) { origin, credential, pin in
            GatewayClient(origin: origin, credential: credential, pin: pin)
        }
        service.cancelPending()
        XCTAssertTrue(stages.loadAll().isEmpty)
        XCTAssertTrue(vault.hasCredential(aliasRef: oldRef))
        XCTAssertTrue(vault.hasCredential(aliasRef: otherRef))
        XCTAssertFalse(vault.hasCredential(aliasRef: pendingRef))
        XCTAssertEqual(store.loadIdentities(), [old, other])
    }

    @MainActor
    func testCancelledRedeemReplyCannotStageOrPromote() async throws {
        let name = "com.remoteeverything.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: directory) }
        let vault = IdentityVault(keychain: KeychainCredentialStore(service: name))
        let stages = StagedSetupStore(directory: directory)
        let store = ClientStore(defaults: defaults)
        var service: PairingService!
        service = PairingService(vault: vault, stages: stages, store: store) { origin, credential, pin in
            service.cancelPending()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PairingAndTimeoutProtocol.self]
            return GatewayClient(origin: origin, credential: credential, pin: pin, configuration: configuration)
        }
        let invitation = SetupURI.Invitation(node: String(repeating: "a", count: 64), nodeName: "Desk",
            origin: "https://gateway.example", invitation: String(repeating: "x", count: 43), serverPin: nil)
        do {
            _ = try await service.run(PairingService.Attempt(invitation: invitation, deviceName: "Phone"))
            XCTFail("Cancelled pairing must not accept its late reply")
        } catch is CancellationError { }
        XCTAssertTrue(stages.loadAll().isEmpty)
        XCTAssertTrue(store.loadIdentities().isEmpty)
    }

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
