import XCTest

/// Node list, application control and path fallback against the live topology.
final class NodeAcceptanceUITests: XCTestCase {

    private var app: XCUIApplication!
    private var nodeName = "macbook-swipe"
    private var alternateName = "macbook-approval"

    override func setUpWithError() throws {
        continueAfterFailure = true
        let env = ProcessInfo.processInfo.environment
        guard env["RE_E2E_NODE_RUN"] != nil else {
            throw XCTSkip("RE_E2E_NODE_RUN not provided")
        }
        if let name = env["RE_E2E_NODE_NAME"] { nodeName = name }
        if let name = env["RE_E2E_ALT_NODE"] { alternateName = name }
        app = XCUIApplication()
    }

    func testStoppedApplicationCannotOpenAndStartRecovers() throws {
        openNode()
        let cell = row("Demo")
        XCTAssertTrue(cell.waitForExistence(timeout: 15), "Demo is not in the catalog")
        if cell.buttons["停止"].exists {
            cell.buttons["停止"].tap()
        }
        XCTAssertTrue(cell.staticTexts["已停止"].waitForExistence(timeout: 20), "Demo did not stop")
        let stoppedOpen = cell.buttons.matching(NSPredicate(format: "label CONTAINS 'Demo'")).firstMatch
        XCTAssertFalse(stoppedOpen.isEnabled, "a stopped application's row is still openable")
        XCTAssertFalse(app.staticTexts["DEMO-READY"].exists, "a stopped application was already open")
        _ = scrollToApp("Demo")
        row("Demo").buttons["启动"].tap()
        XCTAssertTrue(waitForState("Demo", "运行中", timeout: 40), "Demo did not start again")
        row("Demo").buttons.matching(NSPredicate(format: "label CONTAINS 'Demo'")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["DEMO-READY"].waitForExistence(timeout: 30), "the restarted application did not open")
        capture("n08-stopped-then-started")
    }

    func testTwoApplicationsStartAndStopIndependently() throws {
        openNode()
        let demo = row("Demo")
        let fixture = row("Fixture A")
        XCTAssertTrue(demo.waitForExistence(timeout: 15))
        XCTAssertTrue(fixture.waitForExistence(timeout: 15))
        _ = scrollToApp("Demo")
        if row("Demo").buttons["停止"].exists {
            row("Demo").buttons["停止"].tap()
            XCTAssertTrue(waitForState("Demo", "已停止", timeout: 25), "Demo did not stop")
        }
        _ = scrollToApp("Fixture A")
        if row("Fixture A").buttons["停止"].exists {
            row("Fixture A").buttons["停止"].tap()
            XCTAssertTrue(waitForState("Fixture A", "已停止", timeout: 25), "Fixture A did not stop")
        }
        _ = scrollToApp("Demo")
        row("Demo").buttons["启动"].tap()
        _ = scrollToApp("Fixture A")
        row("Fixture A").buttons["启动"].tap()
        XCTAssertTrue(waitForState("Demo", "运行中", timeout: 40), "Demo did not settle")
        XCTAssertTrue(waitForState("Fixture A", "运行中", timeout: 40), "Fixture A did not settle while Demo was also starting")
        capture("n06-two-controls")
    }

    func testRevokedNodeGrantDisappearsWithoutTakingTheOtherNode() throws {
        app.launch()
        let node = app.staticTexts[nodeName]
        XCTAssertTrue(node.waitForExistence(timeout: 20), "the remaining node is not on the home list")
        refreshHome()
        XCTAssertFalse(app.staticTexts["node-b"].waitForExistence(timeout: 3), "the revoked node is still on the home list")
        XCTAssertTrue(node.exists, "revoking node-b removed macbook-swipe too")
        node.tap()
        let entry = scrollToApp("Fixture A")
        XCTAssertTrue(entry.exists, "the remaining node lost its catalog")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Fixture A'")).firstMatch
        if row.exists { row.tap() } else { entry.tap() }
        XCTAssertTrue(app.staticTexts["FIXTURE-A-READY"].waitForExistence(timeout: 30), "the remaining node cannot open its application")
        capture("n11-revoked-node")
    }

    func testNodeRemainsReachableThroughTheOtherGateway() throws {
        app.launch()
        // Gateway A is stopped by the caller. The node is still advertised by
        // gateway B, so home must show it and its applications must open.
        let node = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", nodeName)).firstMatch
        let alternate = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", alternateName)).firstMatch
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline, !node.exists, !alternate.exists {
            app.buttons["arrow.clockwise"].tap()
            usleep(2_000_000)
        }
        let target = node.exists ? node : alternate
        XCTAssertTrue(target.exists, "the node disappeared when one gateway was unreachable")
        target.tap()
        let entry = scrollToApp("Fixture A")
        XCTAssertTrue(entry.exists, "the fallback path did not produce a catalog")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Fixture A'")).firstMatch
        if row.exists { row.tap() } else { entry.tap() }
        XCTAssertTrue(app.staticTexts["FIXTURE-A-READY"].waitForExistence(timeout: 40), "the node could not be opened through the other gateway")
        capture("n03-fallback")
    }


    func testOfflineNodeShowsRetry() throws {
        app.launch()
        let node = app.staticTexts["node-b"]
        XCTAssertTrue(node.waitForExistence(timeout: 20), "the offline node is not on the home list")
        node.tap()
        XCTAssertTrue(app.buttons["重试"].waitForExistence(timeout: 20), "an unreachable node did not offer a retry")
        capture("t06-offline-node")
        app.buttons["BackButton"].tap()
    }

    func testNodeRecoversAfterRestart() throws {
        app.launch()
        let node = app.staticTexts["node-b"]
        XCTAssertTrue(node.waitForExistence(timeout: 20))
        node.tap()
        let entry = scrollToApp("Fixture A")
        XCTAssertTrue(entry.exists, "the recovered node did not list its application")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Fixture A'")).firstMatch
        if row.exists { row.tap() } else { entry.tap() }
        XCTAssertTrue(app.staticTexts["FIXTURE-B-READY"].waitForExistence(timeout: 40), "the recovered node could not open its application")
        capture("t06-recovered-node")
    }

    // MARK: - Helpers

    private func openNode() {
        app.launch()
        let node = app.staticTexts[nodeName]
        XCTAssertTrue(node.waitForExistence(timeout: 20), "the node is not on the home list")
        node.tap()
    }

    private func row(_ name: String) -> XCUIElement {
        app.cells.containing(.staticText, identifier: name).firstMatch
    }

    private func waitForState(_ name: String, _ state: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if row(name).staticTexts[state].exists { return true }
            usleep(500_000)
        }
        return row(name).staticTexts[state].exists
    }

    private func refreshHome() {
        if app.buttons["arrow.clockwise"].exists {
            app.buttons["arrow.clockwise"].tap()
            usleep(2_000_000)
        }
    }

    private func scrollToApp(_ name: String) -> XCUIElement {
        for _ in 0..<3 { app.swipeDown(); usleep(200_000) }
        let element = app.staticTexts[name]
        for _ in 0..<12 where !element.exists {
            app.swipeUp()
            usleep(200_000)
        }
        return element
    }

    @discardableResult
    private func capture(_ name: String) -> XCUIScreenshot {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return shot
    }
}
