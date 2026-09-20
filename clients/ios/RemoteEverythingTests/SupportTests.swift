import XCTest
@testable import RemoteEverything

/// The pieces the rest is built on: digests and file names, the host rules a
/// client certificate is presented under, and the staged pairing file.
final class SupportTests: XCTestCase {

    // MARK: - Digests

    func testSHA256OfAKnownInput() {
        XCTAssertEqual(
            Digest.sha256Hex("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testAliasIsStableASCIIAndNotTheOrigin() {
        let origin = "https://192.168.1.4:8443"
        let alias = Digest.originAlias(origin)
        XCTAssertTrue(alias.hasPrefix("re-"))
        XCTAssertEqual(alias.count, 3 + 32)
        XCTAssertFalse(alias.contains(origin))
        XCTAssertFalse(alias.contains(":"))
        XCTAssertNotEqual(alias, Digest.originAlias("https://gw.example.com"))
    }

    func testFingerprintsAreGroupedEveryEight() {
        let fingerprint = String(repeating: "ab", count: 32)
        let grouped = groupedFingerprint(fingerprint.uppercased())
        let groups = grouped.split(separator: " ")
        XCTAssertEqual(groups.count, 8)
        XCTAssertTrue(groups.allSatisfy { $0.count == 8 })
        XCTAssertEqual(grouped, grouped.lowercased())
    }

    // MARK: - Host rules

    func testHostIsTakenFromTheOrigin() {
        XCTAssertEqual(GatewayChallengeHandler.host(ofOrigin: "https://gw.example.com"), "gw.example.com")
        XCTAssertEqual(GatewayChallengeHandler.host(ofOrigin: "https://GW.Example.com:8443"), "gw.example.com")
        XCTAssertEqual(GatewayChallengeHandler.host(ofOrigin: "https://192.168.1.4:8443"), "192.168.1.4")
    }

    func testACertificateIsPresentedOnlyToTheGateway() {
        let handler = GatewayChallengeHandler(gatewayOrigin: "https://gw.example.com", pin: nil, credential: nil)
        XCTAssertTrue(handler.isGatewayHost("gw.example.com"))
        XCTAssertTrue(handler.isGatewayHost("GW.EXAMPLE.COM"))
        // An application origin of a gateway with a domain is a subdomain of it.
        XCTAssertTrue(handler.isGatewayHost("notes.abcd1234.gw.example.com"))
        XCTAssertFalse(handler.isGatewayHost("evil-example.com"))
        XCTAssertFalse(handler.isGatewayHost("gw.example.com.evil.com"))
        XCTAssertFalse(handler.isGatewayHost("example.com"))
        XCTAssertFalse(handler.isGatewayHost(""))
    }

    func testALanGatewayIsReachedByItsOwnAddress() {
        let handler = GatewayChallengeHandler(gatewayOrigin: "https://192.168.1.4:8443", pin: nil, credential: nil)
        XCTAssertTrue(handler.isGatewayHost("192.168.1.4"))
        XCTAssertFalse(handler.isGatewayHost("192.168.1.5"))
    }

    func testADifferentHostIsNotTheGateway() {
        let handler = GatewayChallengeHandler(gatewayOrigin: "https://gw.example.com", pin: nil, credential: nil)
        XCTAssertFalse(handler.isGatewayHost("other.example.com"))
    }

    // MARK: - Pairing tokens

    func testCredentialPasswordHasTheShapeTheGatewayAccepts() {
        let password = PairingCoordinator.makeCredentialPassword()
        XCTAssertEqual(password.count, 43)
        XCTAssertTrue(password.allSatisfy { character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
        })
        XCTAssertNotEqual(password, PairingCoordinator.makeCredentialPassword())
    }

    func testOnlyFinalRefusalsEndAnAttempt() {
        XCTAssertTrue(PairingCoordinator.endsTheAttempt(.invitationExpired))
        XCTAssertTrue(PairingCoordinator.endsTheAttempt(.invitationDenied))
        XCTAssertTrue(PairingCoordinator.endsTheAttempt(.activationFailed))
        XCTAssertTrue(PairingCoordinator.endsTheAttempt(.pairingFailed))
        XCTAssertFalse(PairingCoordinator.endsTheAttempt(.computerOffline))
        XCTAssertFalse(PairingCoordinator.endsTheAttempt(.rateLimited))
        XCTAssertFalse(PairingCoordinator.endsTheAttempt(.serverBusy))
        XCTAssertFalse(PairingCoordinator.endsTheAttempt(.approvalPending))
    }

    // MARK: - Staged setups on disk

    private func stagedSetup(origin: String) -> StagedSetup {
        StagedSetup(
            origin: origin,
            nodeID: String(repeating: "c", count: 64),
            nodeName: "Desk",
            deviceName: "phone",
            certificateFingerprint: String(repeating: "a", count: 64),
            credentialRef: "re-x",
            serverPin: ServerPin(certFingerprint: String(repeating: "b", count: 64), publicKeyPin: String(repeating: "A", count: 43) + "="),
            pendingExpiresAt: Date().addingTimeInterval(600),
            createdAt: Date()
        )
    }

    func testAStagedSetupSurvivesARoundTrip() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = StagedSetupStore(directory: directory)
        let origin = "https://gw.example.com"
        let setup = stagedSetup(origin: origin)
        do {
            try store.stage(setup)
        } catch {
            XCTFail("staging failed: \(error)")
            return
        }
        let loaded = store.load(origin: origin)
        XCTAssertEqual(loaded?.origin, origin)
        XCTAssertEqual(loaded?.credentialRef, "re-x")
        XCTAssertEqual(loaded?.serverPin?.publicKeyPin, setup.serverPin?.publicKeyPin)
        XCTAssertEqual(store.loadAll().count, 1)
        store.clear(origin: origin)
        XCTAssertNil(store.load(origin: origin))
        XCTAssertTrue(store.loadAll().isEmpty)
        try? FileManager.default.removeItem(at: directory)
    }

    func testAnUnreadableStageIsNoStage() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = StagedSetupStore(directory: directory)
        let origin = "https://gw.example.com"
        let url = directory.appendingPathComponent("\(Digest.originAlias(origin)).json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("not json".utf8).write(to: url)
        } catch {
            XCTFail("could not write the fixture: \(error)")
            return
        }
        XCTAssertNil(store.load(origin: origin))
        XCTAssertTrue(store.loadAll().isEmpty)
        try? FileManager.default.removeItem(at: directory)
    }

    func testAtomicFileReplacesInOneMove() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("value.json")
        do {
            try AtomicFile.write(Data("one".utf8), to: url)
            try AtomicFile.write(Data("two".utf8), to: url)
        } catch {
            XCTFail("writing failed: \(error)")
            return
        }
        XCTAssertEqual(AtomicFile.read(url).map { String(decoding: $0, as: UTF8.self) }, "two")
        AtomicFile.remove(url)
        XCTAssertNil(AtomicFile.read(url))
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Settings

    func testSettingsRoundTripThroughTheStore() {
        let defaults = UserDefaults(suiteName: "com.remoteeverything.tests") ?? .standard
        defaults.removeObject(forKey: "settings")
        let store = ClientStore(defaults: defaults)
        var settings = store.loadSettings()
        XCTAssertEqual(settings.language, .system)
        XCTAssertEqual(settings.appearance, .system)
        settings.language = .zh
        settings.appearance = .dark
        store.saveSettings(settings)
        let reloaded = store.loadSettings()
        XCTAssertEqual(reloaded.language, .zh)
        XCTAssertEqual(reloaded.appearance, .dark)

        let identity = Identity(
            origin: "https://gw.example.com",
            deviceName: "phone",
            certFingerprint: String(repeating: "a", count: 64),
            credentialRef: "re-x",
            serverPin: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        store.saveIdentities([identity])
        XCTAssertEqual(store.loadIdentities(), [identity])
        store.saveIdentities([])
        XCTAssertTrue(store.loadIdentities().isEmpty)
        defaults.removeObject(forKey: "settings")
        defaults.removeObject(forKey: "identities")
    }

    func testTheNodeCacheRemembersOneAnswerPerOrigin() {
        let defaults = UserDefaults(suiteName: "com.remoteeverything.tests") ?? .standard
        let store = ClientStore(defaults: defaults)
        let origin = "https://gw.example.com"
        XCTAssertNil(store.cachedNodes(origin: origin))
        let response = NodesResponse(ok: true, nodes: [.init(id: String(repeating: "a", count: 64), name: "Desk", link: nil)])
        store.saveCachedNodes(response, origin: origin)
        XCTAssertEqual(store.cachedNodes(origin: origin)?.nodes.first?.name, "Desk")
        store.clearCachedNodes(origin: origin)
        XCTAssertNil(store.cachedNodes(origin: origin))
    }

    func testLanguageResolutionFollowsTheSystemForTheSystemSetting() {
        XCTAssertEqual(Language.zh.resolved, .zh)
        XCTAssertEqual(Language.en.resolved, .en)
        // Whatever the machine prefers, the resolved value is a real language.
        XCTAssertNotEqual(Language.system.resolved, .system)
    }

    func testResolveSystemLanguage() {
        XCTAssertEqual(Language.resolveSystemLanguage(["zh-Hans", "en"]), .zh)
        XCTAssertEqual(Language.resolveSystemLanguage(["zh-CN"]), .zh)
        XCTAssertEqual(Language.resolveSystemLanguage(["zh"]), .zh)
        XCTAssertEqual(Language.resolveSystemLanguage(["en-US", "zh"]), .en)
        XCTAssertEqual(Language.resolveSystemLanguage(["en"]), .en)
        XCTAssertEqual(Language.resolveSystemLanguage(["ja-JP", "en"]), .en)
        XCTAssertEqual(Language.resolveSystemLanguage([]), .en)
    }
}
