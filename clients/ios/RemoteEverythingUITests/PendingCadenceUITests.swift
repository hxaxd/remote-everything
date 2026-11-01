import XCTest

/// Waiting-for-approval cadence. The invitations are one-shot and arrive as
/// `RE_E2E_Q_<NAME>`; the gateway is the approval-required one.
final class PendingCadenceUITests: XCTestCase {

    private var app: XCUIApplication!
    private var springboard: XCUIApplication!

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

    func testCheckFeedbackLastsAtLeast1500ms() throws {
        let uri = try invitation("q_feedback")
        try submitPending(uri)
        let retry = pendingRetry()
        XCTAssertTrue(retry.waitForExistence(timeout: 8), "the pending page has no retry")
        capture("q01-pending")

        var disabled: [TimeInterval] = []
        var last = retry.isEnabled
        var since = Date()
        let end = Date().addingTimeInterval(9)
        while Date() < end {
            usleep(100_000)
            let now = Date()
            let enabled = retry.isEnabled
            if enabled != last {
                if !last { disabled.append(now.timeIntervalSince(since)) }
                last = enabled
                since = now
            }
        }
        print("Q03 disabledIntervals=\(disabled)")
        XCTAssertFalse(disabled.isEmpty, "the page never showed a check in progress")
        XCTAssertTrue(disabled.contains { $0 >= 1.4 }, "a check's feedback was shorter than 1500ms: \(disabled)")
        closeSheet()
    }

    func testRepeatedRetryAndBackgroundChurnKeepOneChain() throws {
        let uri = try invitation("q_churn")
        try submitPending(uri)
        let retry = pendingRetry()
        XCTAssertTrue(retry.waitForExistence(timeout: 8))
        for _ in 0..<6 {
            if retry.isEnabled { retry.tap() }
            usleep(250_000)
        }
        for _ in 0..<5 {
            XCUIDevice.shared.press(.home)
            usleep(800_000)
            app.activate()
            usleep(500_000)
        }
        let waiting = app.staticTexts["正在等待操作者批准这台设备"]
        XCTAssertTrue(waiting.exists || app.staticTexts["待批准"].exists, "the pending attempt was lost during background churn")
        if app.buttons["返回"].exists { app.buttons["返回"].tap() }
        let badges = app.staticTexts.matching(NSPredicate(format: "label == '待批准'")).allElementsBoundByIndex
        XCTAssertEqual(badges.count, 1, "background churn left more than one pending row")
        capture("q05-q10-one-pending")
        app.buttons["取消"].firstMatch.tap()
    }

    // MARK: - Helpers

    private func invitation(_ key: String) throws -> String {
        let name = "RE_E2E_Q_" + key.uppercased()
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            throw XCTSkip("\(name) is not provided")
        }
        return value
    }

    private func submitPending(_ uri: String) throws {
        app.launch()
        let add = app.buttons["home.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 15), "the add button is not there")
        add.tap()
        let field = app.descendants(matching: .any)["pair.invitation"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        field.typeText(uri)
        let join = app.buttons["pair.join"]
        XCTAssertTrue(join.waitForExistence(timeout: 8))
        join.tap()
        app.tap()
        for title in ["允许", "Allow"] {
            let button = springboard.buttons[title]
            if button.waitForExistence(timeout: 2) { button.tap(); break }
        }
        XCTAssertTrue(app.staticTexts["正在等待操作者批准这台设备"].waitForExistence(timeout: 30), "the invitation never reached pending")
    }

    private func pendingRetry() -> XCUIElement {
        let all = app.buttons.matching(NSPredicate(format: "label == '重试'")).allElementsBoundByIndex
        return all.last ?? app.buttons["重试"]
    }

    private func closeSheet() {
        let cancel = app.navigationBars.buttons["取消"]
        if cancel.exists { cancel.tap() } else {
            let button = app.buttons["取消"].firstMatch
            if button.exists { button.tap() }
        }
        usleep(500_000)
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
