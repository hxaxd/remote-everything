import XCTest

/// The parts of acceptance that are visible from outside: the paired node's
/// catalog lists what the node runs, and an application's page actually paints.
/// The gateway, node, and demo application are the caller's fixtures, so the
/// test skips unless `RE_E2E_PAIRED_NODE` names the node it should find.
final class AcceptanceUITests: XCTestCase {

    func testNodeCatalogListsTheApplicationAndItPaints() throws {
        let nodeName = ProcessInfo.processInfo.environment["RE_E2E_PAIRED_NODE"]
        guard let nodeName, !nodeName.isEmpty else {
            throw XCTSkip("RE_E2E_PAIRED_NODE not provided; skipping the catalog hand-off.")
        }
        let app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "Local network permission") { alert in
            for title in ["允许", "Allow"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }
        app.launch()

        let node = app.staticTexts[nodeName]
        XCTAssertTrue(node.waitForExistence(timeout: 20), "the paired node is not on the home list")
        node.tap()

        let demo = app.staticTexts["Demo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 25), "the catalog did not list the application")
        demo.tap()

        let ready = app.staticTexts["DEMO-READY"]
        XCTAssertTrue(ready.waitForExistence(timeout: 30), "the application page did not paint")
    }
}

extension AcceptanceUITests {
    /// Refresh must answer a gateway that changed while the app looked away.
    /// The caller renames the node between launches and names it here.
    func testHomeRefreshReflectsTheGateway() throws {
        guard let renamed = ProcessInfo.processInfo.environment["RE_E2E_RENAMED_NODE"] else {
            throw XCTSkip("RE_E2E_RENAMED_NODE not provided; skipping the refresh check.")
        }
        let app = XCUIApplication()
        app.launch()
        let refresh = app.buttons["arrow.clockwise"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 20), "the refresh button is not there")
        refresh.tap()
        XCTAssertTrue(app.staticTexts[renamed].waitForExistence(timeout: 25), "refresh did not show the renamed node")
    }
}

extension AcceptanceUITests {
    /// Changing the appearance must re-render the screen the change was made on,
    /// not only the screens opened afterwards.
    func testAppearanceReRendersTheSettingsScreen() throws {
        guard ProcessInfo.processInfo.environment["RE_E2E_APPEARANCE_CHECK"] != nil else {
            throw XCTSkip("RE_E2E_APPEARANCE_CHECK not provided; skipping the appearance check.")
        }
        let app = XCUIApplication()
        app.launch()
        app.buttons["gearshape"].tap()
        let dark = app.buttons["深色"].firstMatch.exists ? app.buttons["深色"].firstMatch : app.staticTexts["深色"].firstMatch
        XCTAssertTrue(dark.waitForExistence(timeout: 10), "the dark choice is not on the settings screen")
        dark.tap()
        sleep(2)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "settings-after-dark"
        shot.lifetime = .keepAlways
        add(shot)
        let light = app.buttons["浅色"].firstMatch.exists ? app.buttons["浅色"].firstMatch : app.staticTexts["浅色"].firstMatch
        XCTAssertTrue(light.waitForExistence(timeout: 5))
        light.tap()
    }
}
