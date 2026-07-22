import XCTest
@testable import RemoteEverything

@MainActor
final class WebDataStoreRegistryTests: XCTestCase {
    func testActiveLeaseBlocksRemovalThenSuccessfulRemovalClearsRegistration() async throws {
        let defaults = makeDefaults()
        defer { defaults.removeObject(forKey: "registry") }
        var removed: [UUID] = []
        let registry = WebDataStoreRegistry(
            defaults: defaults,
            storageKey: "registry",
            removeHandler: { identifier in removed.append(identifier) }
        )

        let identifier = try registry.acquire(installationId: "installation", appId: "terminal")
        do {
            try await registry.prepareProfileRemoval(installationId: "installation")
            XCTFail("An active WebView lease must block deletion")
        } catch WebDataStoreRegistry.RegistryError.profileInUse {
            // Expected.
        }

        registry.release(identifier: identifier)
        try await registry.prepareProfileRemoval(installationId: "installation")
        XCTAssertEqual(removed, [identifier])
        XCTAssertTrue(registry.registeredIdentifiers(installationId: "installation").isEmpty)
        XCTAssertTrue(registry.isRemovalInProgress(installationId: "installation"))
        registry.finishProfileRemoval(installationId: "installation")
        XCTAssertFalse(registry.isRemovalInProgress(installationId: "installation"))
    }

    func testFailedRemovalRemainsRegisteredForRetry() async throws {
        let defaults = makeDefaults()
        defer { defaults.removeObject(forKey: "registry") }
        var shouldFail = true
        let registry = WebDataStoreRegistry(
            defaults: defaults,
            storageKey: "registry",
            removeHandler: { _ in
                if shouldFail { throw TestError.expected }
            }
        )

        let identifier = try registry.acquire(installationId: "installation", appId: "chat")
        registry.release(identifier: identifier)
        do {
            try await registry.prepareProfileRemoval(installationId: "installation")
            XCTFail("The injected removal failure must be reported")
        } catch WebDataStoreRegistry.RegistryError.removalFailed(let count, _) {
            XCTAssertEqual(count, 1)
        }
        XCTAssertEqual(
            registry.registeredIdentifiers(installationId: "installation"),
            Set([identifier])
        )

        shouldFail = false
        try await registry.prepareProfileRemoval(installationId: "installation")
        registry.finishProfileRemoval(installationId: "installation")
        XCTAssertTrue(registry.registeredIdentifiers(installationId: "installation").isEmpty)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "WebDataStoreRegistryTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    private enum TestError: Error {
        case expected
    }
}
