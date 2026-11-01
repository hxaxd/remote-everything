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

extension AcceptanceUITests {
    /// A capture of the pairing sheet for review; the layout it shows is the
    /// subject, so it asserts only that the sheet opened.
    func testCapturePairingSheet() throws {
        guard ProcessInfo.processInfo.environment["RE_E2E_CAPTURE_PAIR"] != nil else {
            throw XCTSkip("RE_E2E_CAPTURE_PAIR not provided; skipping the capture.")
        }
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["home.add"].waitForExistence(timeout: 15), "the add button never appeared")
        app.buttons["home.add"].tap()
        sleep(3)
        attach(app, "after-add")
        XCTAssertTrue(app.descendants(matching: .any)["pair.invitation"].waitForExistence(timeout: 10), "the invitation field is not there: \(app.debugDescription)")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "pairing-sheet"
        shot.lifetime = .keepAlways
        add(shot)
    }
}

extension AcceptanceUITests {
    /// A pull past the short threshold must run the refresh, exactly like the
    /// toolbar button does.
    func testPullToRefreshReflectsTheGateway() throws {
        guard let renamed = ProcessInfo.processInfo.environment["RE_E2E_SWIPED_NODE"] else {
            throw XCTSkip("RE_E2E_SWIPED_NODE not provided; skipping the pull check.")
        }
        let app = XCUIApplication()
        app.launch()
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(app.staticTexts[renamed].waitForExistence(timeout: 25), "the pull did not refresh")
    }
}

extension AcceptanceUITests {
    /// The pending device can be left on the home list and keeps being checked:
    /// an operator approves it while the app sits there, and the row turns into
    /// the node without anyone touching the app.
    func testPendingApprovalLeavesAndCompletesInBackground() throws {
        let env = ProcessInfo.processInfo.environment
        guard let uri = env["RE_E2E_PENDING_URI"], let nodeName = env["RE_E2E_PENDING_NODE"] else {
            throw XCTSkip("RE_E2E_PENDING_URI/RE_E2E_PENDING_NODE not provided.")
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
        let add = app.buttons["home.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 20), "the add button never appeared")
        add.tap()

        let field = app.descendants(matching: .any)["pair.invitation"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the invitation field is not there")
        field.tap()
        field.typeText(uri)
        let join = app.buttons["pair.join"]
        XCTAssertTrue(join.waitForExistence(timeout: 5), "the confirm card did not appear")
        join.tap()
        // The first request to a private address raises the system permission
        // alert above the app; answer it before waiting for the page.
        app.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for title in ["允许", "Allow"] {
            let button = springboard.buttons[title]
            if button.waitForExistence(timeout: 3) { button.tap(); break }
        }

        let waiting = app.staticTexts["正在等待操作者批准这台设备"]
        XCTAssertTrue(waiting.waitForExistence(timeout: 30), "the pending page did not appear")
        attach(app, "pending-page")

        let back = app.buttons["返回"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()

        let badge = app.staticTexts["待批准"]
        XCTAssertTrue(badge.waitForExistence(timeout: 15), "the home list lost the pending row")
        XCTAssertTrue(app.staticTexts[nodeName].waitForExistence(timeout: 5))
        attach(app, "home-pending")

        // The operator approves from the gateway; the poll must finish it here.
        let approved = NSPredicate(format: "exists == false")
        expectation(for: approved, evaluatedWith: badge)
        waitForExpectations(timeout: 120)
        XCTAssertTrue(app.staticTexts[nodeName].waitForExistence(timeout: 10))
        attach(app, "home-approved")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

extension AcceptanceUITests {
    /// Starting a new attempt ends the pending one: at most one pending at a time.
    func testANewAttemptEndsThePendingOne() throws {
        let env = ProcessInfo.processInfo.environment
        guard let uri = env["RE_E2E_PENDING_URI2"] else {
            throw XCTSkip("RE_E2E_PENDING_URI2 not provided.")
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
        XCTAssertTrue(app.buttons["home.add"].waitForExistence(timeout: 20))
        app.buttons["home.add"].tap()
        let field = app.descendants(matching: .any)["pair.invitation"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(uri)
        let join = app.buttons["pair.join"]
        XCTAssertTrue(join.waitForExistence(timeout: 5))
        join.tap()
        app.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for title in ["允许", "Allow"] {
            let button = springboard.buttons[title]
            if button.waitForExistence(timeout: 3) { button.tap(); break }
        }
        XCTAssertTrue(app.staticTexts["正在等待操作者批准这台设备"].waitForExistence(timeout: 30))
        app.buttons["返回"].tap()

        let badge = app.staticTexts["待批准"]
        XCTAssertTrue(badge.waitForExistence(timeout: 15), "the pending row did not appear")

        // A new attempt replaces it; closing that attempt must leave nothing behind.
        app.buttons["home.add"].tap()
        let cancel = app.buttons["取消"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.tap()

        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: badge)
        waitForExpectations(timeout: 10)
    }
}

extension AcceptanceUITests {
    /// Prints the home tree and the tree after an explicit refresh. This is the
    /// observation half of the topology checks: what the merged list really is,
    /// not what the fixtures say it should be.
    func testHomeProbe() throws {
        guard ProcessInfo.processInfo.environment["RE_E2E_PROBE_HOME"] != nil else {
            throw XCTSkip("RE_E2E_PROBE_HOME not provided; skipping the home probe.")
        }
        let app = XCUIApplication()
        app.launch()
        sleep(2)
        print("HOME_BEFORE\n\(app.debugDescription)")
        let refresh = app.buttons["arrow.clockwise"]
        if refresh.waitForExistence(timeout: 10) {
            refresh.tap()
        }
        sleep(4)
        print("HOME_AFTER\n\(app.debugDescription)")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "home-probe"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
