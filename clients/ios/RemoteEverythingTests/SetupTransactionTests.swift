import XCTest
@testable import RemoteEverything

final class SetupTransactionTests: XCTestCase {
    private let installationId = String(repeating: "ab", count: 32)

    // MARK: - LAN Tests

    // A LAN entrance admits devices the way the public one does: the client
    // redeems its invitation for a credential and then activates it. Only the
    // approval differs, and that is the server's answer to make.
    func testLANConnectionPairsAndActivatesLikeThePublicOne() async throws {
        let store = FakeProfileStore()
        let identityStore = FakeIdentityStore()
        let transport = FakeTransport()
        transport.requestHandler = { url, _, _ in
            if url.contains("pair") {
                return HTTPResult(status: 200, body: FakeTransport.pairedResponse().data(using: .utf8)!)
            } else {
                return HTTPResult(status: 200, body: FakeTransport.readyResponse().data(using: .utf8)!)
            }
        }

        let transaction = SetupTransaction(
            settings: store,
            identity: identityStore,
            deviceName: "Test Device",
            transport: transport
        )

        let config = try SetupParser.create(
            installationId: installationId,
            name: "Test LAN",
            mode: "lan",
            origin: "https://192.168.1.5:60001",
            fingerprint: String(repeating: "cd", count: 32),
            publicKeyPin: String(repeating: "A", count: 43) + "="
        )

        let result = await transaction.begin(
            SetupPayload(profile: config, invitation: String(repeating: "B", count: 43))
        )
        guard case .ready = result else {
            XCTFail("Expected ready, got \(result)")
            return
        }
        XCTAssertTrue(identityStore.promoted)
        XCTAssertFalse(identityStore.staged)
        XCTAssertNotNil(store.committedProfile)
    }

    // MARK: - Public Tests

    func testPublicPairingExposesPhasesAndCommitsAfterCredentialPromotion() async throws {
        let store = FakeProfileStore()
        let identityStore = FakeIdentityStore()

        let transport = FakeTransport()
        transport.requestHandler = { url, _, _ in
            if url.contains("pair") {
                return HTTPResult(status: 200, body: FakeTransport.pairedResponse().data(using: .utf8)!)
            } else {
                return HTTPResult(status: 200, body: FakeTransport.readyResponse().data(using: .utf8)!)
            }
        }

        let transaction = SetupTransaction(
            settings: store,
            identity: identityStore,
            deviceName: "😀".prefix(80).description, // <= 80 code points
            transport: transport
        )

        let config = try SetupParser.create(
            installationId: installationId,
            name: "Test Public",
            mode: "public",
            origin: "https://remote.example.com"
        )
        let setup = SetupPayload(profile: config, invitation: String(repeating: "A", count: 43))

        let result = await transaction.begin(setup)
        guard case .ready = result else {
            XCTFail("Expected ready, got \(result)")
            return
        }
        XCTAssertTrue(identityStore.promoted)
        XCTAssertFalse(identityStore.staged)
    }

    func testActivationFailureRetriesActivationWithoutPairingAgain() async throws {
        let store = FakeProfileStore()
        let identityStore = FakeIdentityStore()
        var pairCalls = 0
        var activationCalls = 0

        let transport = FakeTransport()
        transport.requestHandler = { url, _, _ in
            if url.contains("pair") {
                pairCalls += 1
                return HTTPResult(status: 200, body: FakeTransport.pairedResponse().data(using: .utf8)!)
            } else {
                activationCalls += 1
                if activationCalls == 1 {
                    return HTTPResult(status: 503, body: Data())
                } else {
                    return HTTPResult(status: 200, body: FakeTransport.readyResponse().data(using: .utf8)!)
                }
            }
        }

        let config = try SetupParser.create(
            installationId: installationId,
            name: "Public",
            mode: "public",
            origin: "https://remote.example.com"
        )
        let setup = SetupPayload(profile: config, invitation: String(repeating: "A", count: 43))

        let transaction = SetupTransaction(
            settings: store,
            identity: identityStore,
            deviceName: "device",
            transport: transport
        )

        let first = await transaction.begin(setup)
        guard case .failed(_, _, let action) = first else {
            XCTFail("Expected failed, got \(first)")
            return
        }
        XCTAssertEqual(action, .retryActivation)
        XCTAssertTrue(identityStore.staged)

        let second = await transaction.retryActivation(config: config)
        guard case .ready = second else {
            XCTFail("Expected ready, got \(second)")
            return
        }
        XCTAssertEqual(pairCalls, 1)
        XCTAssertEqual(activationCalls, 2)
    }

    func testApprovalPendingContinuesWithoutPairingAgain() async throws {
        let store = FakeProfileStore()
        let identityStore = FakeIdentityStore()
        var pairCalls = 0
        var activationCalls = 0

        let transport = FakeTransport()
        transport.requestHandler = { url, _, _ in
            if url.contains("pair") {
                pairCalls += 1
                return HTTPResult(status: 200, body: FakeTransport.pairedResponse().data(using: .utf8)!)
            } else {
                activationCalls += 1
                if activationCalls == 1 {
                    return HTTPResult(status: 202, body: #"{"ok":false,"code":"approval_pending"}"#.data(using: .utf8)!)
                } else {
                    return HTTPResult(status: 200, body: FakeTransport.readyResponse().data(using: .utf8)!)
                }
            }
        }

        let config = try SetupParser.create(
            installationId: installationId,
            name: "Public",
            mode: "public",
            origin: "https://remote.example.com"
        )
        let setup = SetupPayload(profile: config, invitation: String(repeating: "A", count: 43))

        let transaction = SetupTransaction(
            settings: store,
            identity: identityStore,
            deviceName: "device",
            transport: transport
        )

        let first = await transaction.begin(setup)
        guard case .awaitingApproval = first else {
            XCTFail("Expected awaitingApproval, got \(first)")
            return
        }
        XCTAssertTrue(identityStore.staged)

        let second = await transaction.retryActivation(config: config)
        guard case .ready = second else {
            XCTFail("Expected ready, got \(second)")
            return
        }
        XCTAssertEqual(pairCalls, 1)
        XCTAssertEqual(activationCalls, 2)
    }

    func testDeniedInvitationDiscardsLocalTransaction() async throws {
        let store = FakeProfileStore()
        let identityStore = FakeIdentityStore()

        let transport = FakeTransport()
        transport.requestHandler = { _, _, _ in
            return HTTPResult(status: 401, body: Data())
        }

        let config = try SetupParser.create(
            installationId: installationId,
            name: "Public",
            mode: "public",
            origin: "https://remote.example.com"
        )
        let setup = SetupPayload(profile: config, invitation: String(repeating: "A", count: 43))

        let transaction = SetupTransaction(
            settings: store,
            identity: identityStore,
            deviceName: "device",
            transport: transport
        )

        let result = await transaction.begin(setup)
        guard case .failed(_, _, let action) = result else {
            XCTFail("Expected failed, got \(result)")
            return
        }
        XCTAssertEqual(action, .restartSetup)
    }

    func testRecoveryReturnsOnlyActivatablePublicTransaction() async throws {
        let config = try SetupParser.create(
            installationId: installationId,
            name: "Public",
            mode: "public",
            origin: "https://remote.example.com"
        )

        let store = FakeProfileStore(staged: config)
        let identityStore = FakeIdentityStore()
        identityStore.staged = true

        let transaction = SetupTransaction(
            settings: store,
            identity: identityStore,
            deviceName: "device",
            transport: FakeTransport()
        )

        let recovered = transaction.recover()
        XCTAssertNotNil(recovered)

        // Every mode pairs for a credential, so every mode recovers the same way.
        let lanConfig = try SetupParser.create(
            installationId: installationId,
            name: "LAN",
            mode: "lan",
            origin: "https://192.168.1.5:60001",
            fingerprint: String(repeating: "cd", count: 32),
            publicKeyPin: String(repeating: "A", count: 43) + "="
        )
        store.stagedProfileValue = lanConfig
        XCTAssertNotNil(transaction.recover())

        // Without its credential the staged profile cannot be activated.
        identityStore.staged = false
        XCTAssertNil(transaction.recover())
    }
}

// MARK: - Fakes

final class FakeProfileStore: SetupProfileStore {
    var stagedProfileValue: ConnectionConfig?
    var committedProfile: ConnectionConfig?

    init(staged: ConnectionConfig? = nil) {
        self.stagedProfileValue = staged
    }

    func stagedProfile() -> ConnectionConfig? { stagedProfileValue }
    func stageProfile(_ value: ConnectionConfig) { stagedProfileValue = value }
    func commitStagedProfile() -> ConnectionConfig {
        let profile = stagedProfileValue!
        committedProfile = profile
        stagedProfileValue = nil
        return profile
    }
    func discardStagedProfile() { stagedProfileValue = nil }
}

final class FakeIdentityStore: SetupIdentityStore {
    var staged = false
    var promoted = false
    var discarded = false

    func credentialPassword(installationId: String) throws -> String {
        return "test-password-123"
    }

    func stageCredential(installationId: String, encoded: String, password: String, expectedFingerprint: String) throws {
        staged = true
    }

    func stagedClientIdentity(installationId: String) throws -> ClientIdentity? {
        guard staged else { throw KeychainStore.KeychainError.notFound }
        return nil
    }

    func promoteCredential(installationId: String) throws {
        guard staged else { throw KeychainStore.KeychainError.notFound }
        promoted = true
    }

    func hasStagedCredential(installationId: String) throws -> Bool { staged }

    func discardStagedCredential(installationId: String) throws {
        discarded = true
        staged = false
    }
}

final class FakeTransport: SetupTransport {
    var requestHandler: ((String, [String: String], String?) -> HTTPResult)?

    func request(
        config: ConnectionConfig,
        url: String,
        method: String,
        identity: ClientIdentity?,
        headers: [String: String],
        body: String?
    ) async throws -> HTTPResult {
        return requestHandler?(url, headers, body) ?? HTTPResult(status: 500, body: Data())
    }

    static func pairedResponse() -> String {
        #"{"ok":true,"device_name":"device","certificate_fingerprint":"\#(String(repeating: "cd", count: 32))","credential_format":"pkcs12","credential_pkcs12":"dGVzdA==","pending_expires_at":"2027-01-01T00:00:00Z"}"#
    }

    static func readyResponse() -> String {
        #"{"ok":true,"computer_connected":true,"code":"ready","apps":[]}"#
    }
}
