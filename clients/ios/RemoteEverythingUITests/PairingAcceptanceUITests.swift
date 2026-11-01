import XCTest

/// Pairing and pending-approval behaviour against the live acceptance gateways.
/// Every invitation is one-shot and minted by the caller; keys arrive as
/// `RE_E2E_P_<NAME>` environment variables. Tests skip without them.
final class PairingAcceptanceUITests: XCTestCase {

    private var app: XCUIApplication!
    private var springboard: XCUIApplication!
    private let nodeName = "macbook-swipe"

    override func setUpWithError() throws {
        continueAfterFailure = true
        springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "Local network permission") { alert in
            for title in ["允许", "Allow"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }
    }

    // MARK: - P02/P03: what the form refuses

    func testInvalidInvitationsDoNotCreateAnything() throws {
        let bad = ["not_a_uri", "missing_node", "non_https"]
        for key in bad {
            let uri = try invitation(key)
            openPair()
            paste(uri)
            XCTAssertTrue(app.staticTexts["这不是有效的邀请链接"].waitForExistence(timeout: 8), "\(key) was not refused")
            XCTAssertFalse(app.buttons["pair.join"].exists, "\(key) produced a join button")
            capture("p02-\(key)")
            closeSheet()
        }
        XCTAssertTrue(app.staticTexts[nodeName].waitForExistence(timeout: 10), "the existing connection disappeared")
        XCTAssertEqual(try connectionCount(), 2, "an invalid invitation changed the saved connections")
    }

    func testExpiredAndConsumedInvitationsKeepTheForm() throws {
        openPair()
        paste(try invitation("expired"))
        app.buttons["pair.join"].tap()
        pokeLocalNetwork()
        let expired = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '邀请无效'")).firstMatch
        if expired.waitForExistence(timeout: 15) {
            capture("p02-expired")
        } else {
            capture("p02-expired-unexpected")
            XCTFail("the expired invitation did not show an expiry error:\n\(app.debugDescription)")
        }
        XCTAssertTrue(app.buttons["pair.join"].exists, "the expired invitation left the form")
        closeSheet()

        // Redeem once: it becomes pending, which consumes it. Cancel, then
        // submit the same invitation again; the gateway must refuse it.
        openPair()
        paste(try invitation("consumed"))
        app.buttons["pair.join"].tap()
        pokeLocalNetwork()
        XCTAssertTrue(app.staticTexts["正在等待操作者批准这台设备"].waitForExistence(timeout: 30), "the first redeem did not reach pending")
        closeSheet() // toolbar cancel: ends the pending attempt
        XCTAssertTrue(app.staticTexts[nodeName].waitForExistence(timeout: 10))

        openPair()
        paste(try invitation("consumed"))
        app.buttons["pair.join"].tap()
        pokeLocalNetwork()
        let consumed = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '邀请'")).firstMatch
        XCTAssertTrue(consumed.waitForExistence(timeout: 15), "the consumed invitation was accepted again")
        usleep(1_500_000)
        XCTAssertFalse(app.staticTexts["正在等待操作者批准这台设备"].exists, "the consumed invitation reached pending again")
        capture("p02-consumed")
        closeSheet()
    }

    func testDeviceNameIsRequired() throws {
        openPair()
        paste(try invitation("valid_name"))
        let name = app.textFields["设备名"]
        XCTAssertTrue(name.waitForExistence(timeout: 8), "the device-name field is not there")
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40))
        XCTAssertTrue(app.staticTexts["请填写设备名"].waitForExistence(timeout: 5), "an empty name was not called out")
        XCTAssertFalse(app.buttons["pair.join"].isEnabled, "join stayed enabled with an empty name")
        capture("p03-empty-name")
        name.typeText("My Phone")
        XCTAssertTrue(app.buttons["pair.join"].isEnabled, "join stayed disabled with a valid name")
        capture("p03-name-filled")
        closeSheet()
        XCTAssertEqual(try connectionCount(), 2)
    }

    // MARK: - P04/P09: leave and cancel

    func testBackLeavesPendingAndCancelEndsIt() throws {
        openPair()
        try submitPending(try invitation("pending_back"))
        app.buttons["返回"].tap()
        let badge = app.staticTexts["待批准"]
        XCTAssertTrue(badge.waitForExistence(timeout: 10), "returning from pending lost the pending row")
        capture("p09-home-pending")
        let cancel = app.buttons["取消"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "the pending row has no cancel")
        cancel.tap()
        XCTAssertTrue(waitForDisappearance(of: badge, timeout: 10), "cancelling the pending row did not end it")
        capture("p09-after-cancel")
        XCTAssertEqual(try connectionCount(), 2, "cancelling a new attempt changed the saved connections")
    }

    // MARK: - P20: cold start

    func testPendingSurvivesColdStartAndCancelDoesNot() throws {
        openPair()
        try submitPending(try invitation("pending_cold"))
        app.terminate()
        app.launch()
        let waiting = app.staticTexts["正在等待操作者批准这台设备"]
        if waiting.waitForExistence(timeout: 8) {
            app.buttons["返回"].tap()
        }
        let badge = app.staticTexts["待批准"]
        XCTAssertTrue(badge.waitForExistence(timeout: 10), "the pending attempt did not survive a cold start")
        capture("p20-after-relaunch")
        app.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(waitForDisappearance(of: badge, timeout: 10), "cancel did not clear the restored pending row")
        app.terminate()
        app.launch()
        XCTAssertFalse(app.staticTexts["待批准"].waitForExistence(timeout: 5), "a cancelled pending attempt came back after relaunch")
        XCTAssertEqual(try connectionCount(), 2)
    }

    // MARK: - P05/P07: a new attempt never damages what is there

    func testCancellingNewAttemptsKeepsBothConnections() throws {
        for (key, expected) in [("cancel_nodeb", "node-b"), ("cancel_same", "macbook-approval")] {
            openPair()
            try submitPending(try invitation(key))
            app.buttons["返回"].tap()
            let badge = app.staticTexts["待批准"]
            XCTAssertTrue(badge.waitForExistence(timeout: 10), "\(key) did not leave a pending row")
            XCTAssertTrue(app.staticTexts[expected].exists, "\(key) did not show its node name")
            app.buttons["取消"].firstMatch.tap()
            XCTAssertTrue(waitForDisappearance(of: badge, timeout: 10))
            XCTAssertEqual(try connectionCount(), 2, "\(key) changed the saved connections")
            openFixtureA()
        }
    }

    func testDoubleTapJoinLeavesOnePending() throws {
        openPair()
        paste(try invitation("double_tap"))
        let join = app.buttons["pair.join"]
        XCTAssertTrue(join.waitForExistence(timeout: 8))
        join.tap()
        if join.exists { join.tap() }
        pokeLocalNetwork()
        XCTAssertTrue(app.staticTexts["正在等待操作者批准这台设备"].waitForExistence(timeout: 30), "the first tap did not reach pending")
        app.buttons["返回"].tap()
        let badges = app.staticTexts.matching(NSPredicate(format: "label == '待批准'")).allElementsBoundByIndex
        XCTAssertEqual(badges.count, 1, "double tap left more than one pending request")
        capture("p23-one-pending")
        app.buttons["取消"].firstMatch.tap()
    }


    func testWrongPinIsRejected() throws {
        let uri = try invitation("bad_pin")
        openPair()
        paste(uri)
        let join = app.buttons["pair.join"]
        XCTAssertTrue(join.waitForExistence(timeout: 8), "the tampered invitation did not parse")
        join.tap()
        pokeLocalNetwork()
        sleep(15)
        XCTAssertFalse(app.staticTexts["正在等待操作者批准这台设备"].exists, "a wrong certificate pin still reached pending")
        XCTAssertTrue(app.buttons["pair.join"].exists || app.navigationBars.buttons["取消"].exists, "the form disappeared after the pin failure")
        capture("t02-wrong-pin")
        closeSheet()
        XCTAssertEqual(try connectionCount(), 2, "a wrong pin changed the saved connections")
    }


    func testForgetConfirmationCancelKeepsTheConnection() throws {
        app.launch()
        app.buttons["gearshape"].tap()
        let origin = app.buttons.matching(NSPredicate(format: "label MATCHES '^[0-9.]+:[0-9]+$'")).firstMatch
        for _ in 0..<6 where !origin.exists {
            app.swipeUp()
            usleep(300_000)
        }
        XCTAssertTrue(origin.exists, "the connection row is not in settings")
        let before = app.buttons.matching(NSPredicate(format: "label == '忘记此连接'")).count
        app.buttons["忘记此连接"].firstMatch.tap()
        let cancel = app.alerts.buttons["取消"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "the forget confirmation did not appear")
        cancel.tap()
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == '忘记此连接'")).count, before, "cancelling the confirmation removed a connection")
        app.buttons["完成"].tap()
    }

    // MARK: - Helpers

    private func invitation(_ key: String) throws -> String {
        let name = "RE_E2E_P_" + key.uppercased()
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            throw XCTSkip("\(name) is not provided")
        }
        return value
    }

    private func openPair() {
        app.launch()
        let add = app.buttons["home.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 15), "the add button is not on the home screen")
        add.tap()
        XCTAssertTrue(app.descendants(matching: .any)["pair.invitation"].waitForExistence(timeout: 8), "the invitation field did not open")
    }

    private func paste(_ uri: String) {
        let field = app.descendants(matching: .any)["pair.invitation"]
        field.tap()
        field.typeText(uri)
    }

    private func submitPending(_ uri: String) throws {
        paste(uri)
        let join = app.buttons["pair.join"]
        XCTAssertTrue(join.waitForExistence(timeout: 8), "the invitation did not produce a join button")
        join.tap()
        pokeLocalNetwork()
        XCTAssertTrue(app.staticTexts["正在等待操作者批准这台设备"].waitForExistence(timeout: 30), "the invitation never reached pending")
    }

    private func pokeLocalNetwork() {
        app.tap()
        for title in ["允许", "Allow"] {
            let button = springboard.buttons[title]
            if button.waitForExistence(timeout: 2) { button.tap(); return }
        }
    }

    private func closeSheet() {
        let cancel = app.navigationBars.buttons["取消"]
        if cancel.exists {
            cancel.tap()
        } else {
            let button = app.buttons["取消"].firstMatch
            if button.exists { button.tap() }
        }
        usleep(500_000)
    }

    private func connectionCountAfterClose() throws -> Int {
        if app.buttons["pair.join"].exists { closeSheet() }
        return try connectionCount()
    }

    private func connectionCount() throws -> Int {
        let gear = app.buttons["gearshape"]
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "settings are not reachable")
        gear.tap()
        let forgets = app.buttons.matching(NSPredicate(format: "label == '忘记此连接'"))
        let count = forgets.count
        app.buttons["完成"].tap()
        return count
    }

    private func openFixtureA() {
        if app.buttons["BackButton"].exists {
            app.buttons["BackButton"].tap()
        }
        let node = app.staticTexts[nodeName]
        XCTAssertTrue(node.waitForExistence(timeout: 10))
        node.tap()
        let entry = scrollToApp("Fixture A")
        XCTAssertTrue(entry.exists, "the node no longer lists Fixture A")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Fixture A'")).firstMatch
        if row.exists { row.tap() } else { entry.tap() }
        XCTAssertTrue(app.staticTexts["FIXTURE-A-READY"].waitForExistence(timeout: 30), "the existing connection stopped working")
        // Leave the page so the next half starts from the node list.
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        let across = app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: across)
        XCTAssertTrue(app.buttons["退出"].waitForExistence(timeout: 5))
        app.buttons["退出"].tap()
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

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            usleep(300_000)
        }
        return !element.exists
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
