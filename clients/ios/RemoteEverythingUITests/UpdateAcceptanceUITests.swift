import XCTest

/// Update-check states, driven by the debug manifest override. The caller runs
/// a manifest server on 127.0.0.1:59030; each case names one path on it.
final class UpdateAcceptanceUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        guard ProcessInfo.processInfo.environment["RE_E2E_UPDATE_RUN"] != nil else {
            throw XCTSkip("RE_E2E_UPDATE_RUN not provided")
        }
        app = XCUIApplication()
    }

    func testUpToDate() throws {
        try check(path: "uptodate.json", expected: "已是最新", name: "u02-uptodate")
    }

    func testAvailable() throws {
        try check(path: "available.json", expected: "有新版本 3.6.0 (29)", name: "u02-available")
        XCTAssertTrue(app.staticTexts["从应用商店安装新版本"].waitForExistence(timeout: 5), "the store hint is missing")
    }

    func testProtocolChange() throws {
        try check(path: "protocol.json", expected: "新版本改变了连接方式", name: "u02-protocol")
        XCTAssertTrue(app.staticTexts["3.5.0 (28)"].exists, "the current version was replaced instead of kept")
    }

    func testInvalidJson() throws {
        try check(path: "invalid.json", expected: "无法检查更新", name: "u03-invalid")
    }

    func testHTTPError() throws {
        try check(path: "http500", expected: "无法检查更新", name: "u03-http500")
    }

    func testUnreachable() throws {
        try check(path: "missing.json", expected: "无法检查更新", name: "u03-404")
    }

    func testCheckingDoesNotStack() throws {
        app.launchEnvironment["RE_UPDATE_MANIFEST_URL"] = "http://127.0.0.1:59030/slow.json"
        app.launch()
        openSettings()
        let version = scrollToVersion()
        XCTAssertTrue(version.exists)
        version.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '检查中'")).firstMatch.waitForExistence(timeout: 3), "the checking state did not appear")
        for _ in 0..<5 { version.tap() }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '已是最新'")).firstMatch.waitForExistence(timeout: 8), "the check did not finish")
        capture("u01-one-check")
    }


    func testRecoveryAfterTemporaryFailure() throws {
        app.launchEnvironment["RE_UPDATE_MANIFEST_URL"] = "http://127.0.0.1:59030/flip.json"
        app.launch()
        openSettings()
        let version = scrollToVersion()
        version.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '无法检查更新'")).firstMatch.waitForExistence(timeout: 15), "the first check did not fail")
        capture("u04-failed")
        sleep(30)
        version.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '已是最新'")).firstMatch.waitForExistence(timeout: 15), "the retry after recovery did not succeed")
        capture("u04-recovered")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '无法检查更新'")).firstMatch.exists, "the old failure detail stayed")
    }

    func testCopyFieldsAndForgetCancel() throws {
        app.launch()
        openSettings()
        let origin = app.buttons.matching(NSPredicate(format: "label MATCHES '^[0-9.]+:[0-9]+$'")).firstMatch
        for _ in 0..<6 where !origin.exists {
            app.swipeUp()
            usleep(300_000)
        }
        XCTAssertTrue(origin.exists, "the connection address is not in settings")
        origin.tap()
        XCTAssertTrue(app.staticTexts["已复制"].waitForExistence(timeout: 4), "the copied feedback is missing")
        capture("u05-after-tap")
        capture("u05-copied")
        let forget = app.buttons["忘记此连接"].firstMatch
        XCTAssertTrue(forget.exists)
        forget.tap()
        let cancel = app.alerts.buttons["取消"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "the forget confirmation did not appear")
        cancel.tap()
        XCTAssertTrue(origin.exists, "cancelling the confirmation removed the connection")
    }

    // MARK: - Helpers

    private func check(path: String, expected: String, name: String) throws {
        app.launchEnvironment["RE_UPDATE_MANIFEST_URL"] = "http://127.0.0.1:59030/\(path)"
        app.launch()
        openSettings()
        let version = scrollToVersion()
        XCTAssertTrue(version.exists, "the version row is not there")
        version.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", expected)).firstMatch.waitForExistence(timeout: 15), "\(path) did not reach the expected state:\n\(app.debugDescription)")
        capture(name)
    }

    private func scrollToVersion() -> XCUIElement {
        let element = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '3.5.0'")).firstMatch
        for _ in 0..<5 where !element.exists {
            app.swipeUp()
            usleep(300_000)
        }
        return element
    }

    private func openSettings() {
        let gear = app.buttons["gearshape"]
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "settings are not reachable")
        gear.tap()
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
