import XCTest
@testable import RemoteEverything

final class ClientSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var settings: ClientSettings!

    override func setUp() {
        super.setUp()
        let suite = "ClientSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        settings = ClientSettings(defaults: defaults)
    }

    func testDefaultsAndAppOverridesResolveLikeAndroid() {
        XCTAssertEqual(settings.globalOrientation, "system")
        XCTAssertEqual(settings.globalDisplayMode, "phone")
        XCTAssertEqual(settings.appOrientation(installationId: "one", appId: "pi"), "global")
        XCTAssertEqual(settings.appDisplayMode(installationId: "one", appId: "pi"), "global")

        settings.setGlobalOrientation("portrait")
        settings.setGlobalDisplayMode("desktop")
        XCTAssertEqual(settings.resolvedOrientation(installationId: "one", appId: "pi"), "portrait")
        XCTAssertEqual(settings.resolvedDisplayMode(installationId: "one", appId: "pi"), "desktop")

        settings.setAppOrientation("landscape", installationId: "one", appId: "pi")
        settings.setAppDisplayMode("phone", installationId: "one", appId: "pi")
        XCTAssertEqual(settings.resolvedOrientation(installationId: "one", appId: "pi"), "landscape")
        XCTAssertEqual(settings.resolvedDisplayMode(installationId: "one", appId: "pi"), "phone")
    }

    func testInvalidValuesFailClosedToDocumentedDefaults() {
        settings.setGlobalOrientation("sideways")
        settings.setGlobalDisplayMode("television")
        settings.setThemeMode("blue")
        settings.setAppOrientation("sideways", installationId: "one", appId: "pi")
        settings.setAppDisplayMode("tablet", installationId: "one", appId: "pi")

        XCTAssertEqual(settings.globalOrientation, "system")
        XCTAssertEqual(settings.globalDisplayMode, "phone")
        XCTAssertEqual(settings.themeMode, "system")
        XCTAssertEqual(settings.appOrientation(installationId: "one", appId: "pi"), "global")
        XCTAssertEqual(settings.appDisplayMode(installationId: "one", appId: "pi"), "global")
    }

    func testRemovingProfileClearsOnlyItsScopedValues() {
        settings.setAppOrientation("portrait", installationId: "one", appId: "pi")
        settings.setAppDisplayMode("desktop", installationId: "one", appId: "pi")
        settings.setAppOrientation("landscape", installationId: "two", appId: "pi")
        settings.setAppOrder(["pi", "claude"], installationId: "one")

        settings.removeAppScopedValues(installationId: "one")

        XCTAssertEqual(settings.appOrientation(installationId: "one", appId: "pi"), "global")
        XCTAssertEqual(settings.appDisplayMode(installationId: "one", appId: "pi"), "global")
        XCTAssertEqual(settings.appOrder(installationId: "one"), [])
        XCTAssertEqual(settings.appOrientation(installationId: "two", appId: "pi"), "landscape")
    }

    func testAppOrderDropsEmptyAndDuplicateIdentifiers() {
        settings.setAppOrder(["pi", "", "pi", "claude"], installationId: "one")
        XCTAssertEqual(settings.appOrder(installationId: "one"), ["pi", "claude"])
    }
}
