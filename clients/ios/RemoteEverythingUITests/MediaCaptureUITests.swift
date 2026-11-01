import XCTest

/// Asks the application's WKWebView to call the system's camera, microphone and
/// location APIs, and records what the page was told. The gateway, node and
/// camera-test application are the caller's fixtures; the tests skip unless
/// `RE_E2E_MEDIA_NODE` and `RE_E2E_MEDIA_APP` name them.
final class MediaCaptureUITests: XCTestCase {

    private var app: XCUIApplication!
    private var springboard: XCUIApplication!
    private var nodeName = ""
    private var appName = ""

    override func setUpWithError() throws {
        continueAfterFailure = true
        springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let env = ProcessInfo.processInfo.environment
        guard let node = env["RE_E2E_MEDIA_NODE"], !node.isEmpty,
              let application = env["RE_E2E_MEDIA_APP"], !application.isEmpty else {
            throw XCTSkip("RE_E2E_MEDIA_NODE/RE_E2E_MEDIA_APP not provided; skipping media capture.")
        }
        nodeName = node
        appName = application
        app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "System permission") { alert in
            for title in ["允许", "Allow", "允许一次", "Allow Once", "使用App时允许", "Allow While Using App"]
            where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }
    }

    func testGrantedMediaStreamsAndRecords() throws {
        openTestPage()
        tapButton("请求相机和麦克风")
        grantSystemPrompts(rounds: 3)
        line("AV", waitForStatus(prefix: "STATUS:av:", timeout: 25))
        sleep(2)
        line("AVDETAIL", detailText())

        tapButton("请求麦克风")
        grantSystemPrompts(rounds: 1)
        line("MIC", waitForStatus(prefix: "STATUS:microphone:", timeout: 20))
        sleep(2)
        line("MICDETAIL", detailText())

        tapButton("录一秒")
        grantSystemPrompts(rounds: 1)
        line("RECORD", waitForStatus(prefix: "STATUS:record:OK", timeout: 15))

        tapButton("请求定位")
        grantSystemPrompts(rounds: 2)
        line("GEO", waitForStatus(prefix: "STATUS:geo:", timeout: 25))

        tapButton("停止所有")
        line("STOP", waitForStatus(prefix: "STATUS:stopped", timeout: 10))
    }

    func testDeniedMediaIsReportedWithoutReprompting() throws {
        openTestPage()
        tapButton("请求相机和麦克风")
        denySystemPrompts(rounds: 3)
        line("DENIED", waitForStatus(prefix: "STATUS:av:ERR", timeout: 20))

        // A system-level denial is remembered: asking again must fail without
        // another system question.
        tapButton("请求相机和麦克风")
        usleep(2_000_000)
        let again = waitForStatus(prefix: "STATUS:av:ERR", timeout: 10)
        line("DENIED_AGAIN", again)
        XCTAssertFalse(again.isEmpty)
        XCTAssertFalse(springboard.buttons["允许"].exists, "a denied permission asked again")
    }

    func testDeniedLocationIsReported() throws {
        openTestPage()
        tapButton("请求定位")
        denySystemPrompts(rounds: 2)
        line("GEO_DENIED", waitForStatus(prefix: "STATUS:geo:ERR", timeout: 20))
    }

    func testLeavingThePageStopsMedia() throws {
        openTestPage()
        tapButton("请求相机和麦克风")
        grantSystemPrompts(rounds: 3)
        line("LIVE", waitForStatus(prefix: "STATUS:av:OK", timeout: 25))
        attachScreenshot(named: "c07-live")

        // Backgrounding the app must not leave the capture running.
        XCUIDevice.shared.press(.home)
        sleep(2)
        attachScreenScreenshot(named: "c07-backgrounded")
        app.activate()
        sleep(1)

        // The way out of S4 is the edge-swipe panel, not a navigation bar.
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        let across = app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: across)
        let exit = app.buttons["退出"]
        XCTAssertTrue(exit.waitForExistence(timeout: 5), "the back-gesture panel did not open")
        exit.tap()

        let node = app.staticTexts[nodeName]
        XCTAssertTrue(node.waitForExistence(timeout: 10), "leaving the page did not return to the node")
        sleep(2)
        attachScreenshot(named: "c07-after-exit")
    }

    // MARK: - Fixtures

    private func openTestPage() {
        app.launch()
        let node = app.staticTexts[nodeName]
        XCTAssertTrue(node.waitForExistence(timeout: 20), "the paired node is not on the home list")
        node.tap()

        let application = app.staticTexts[appName]
        XCTAssertTrue(application.waitForExistence(timeout: 25), "the catalog did not list the test application")
        application.tap()

        let ready = app.staticTexts["CAMTEST-READY"]
        XCTAssertTrue(ready.waitForExistence(timeout: 30), "the test page did not paint")
    }

    private func tapButton(_ label: String) {
        let button = app.buttons[label]
        if button.waitForExistence(timeout: 5) {
            button.tap()
        } else {
            XCTFail("the web button \(label) is not reachable; page is:\n\(app.debugDescription)")
        }
    }

    private func grantSystemPrompts(rounds: Int) {
        for _ in 0..<rounds {
            var tapped = false
            for title in ["允许", "Allow", "允许一次", "Allow Once", "使用App时允许", "Allow While Using App"] {
                let button = springboard.buttons[title]
                if button.waitForExistence(timeout: 2) {
                    attachScreenshot(named: "media-alert-\(title)")
                    button.tap()
                    tapped = true
                    break
                }
            }
            if !tapped {
                for title in ["允许", "Allow"] {
                    let button = app.buttons[title]
                    if button.exists {
                        button.tap()
                        tapped = true
                        break
                    }
                }
            }
            if !tapped { usleep(1_000_000) }
            usleep(500_000)
        }
    }

    private func denySystemPrompts(rounds: Int) {
        for _ in 0..<rounds {
            var tapped = false
            for title in ["不允许", "Don't Allow", "不允许一次"] {
                let button = springboard.buttons[title]
                if button.waitForExistence(timeout: 2) {
                    attachScreenshot(named: "media-deny-\(title)")
                    button.tap()
                    tapped = true
                    break
                }
            }
            if !tapped { usleep(1_000_000) }
            usleep(500_000)
        }
    }

    private func waitForStatus(prefix: String, timeout: TimeInterval) -> String {
        let predicate = NSPredicate(format: "label BEGINSWITH %@", prefix)
        let element = app.staticTexts.matching(predicate).firstMatch
        if element.waitForExistence(timeout: timeout) {
            return element.label
        }
        let any = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'STATUS:'")).allElementsBoundByIndex
        return "MISSING \(prefix) :: " + any.map(\.label).joined(separator: " || ")
    }

    private func detailText() -> String {
        let element = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'DETAIL:'")).firstMatch
        return element.exists ? element.label : "DETAIL:MISSING"
    }

    private func line(_ tag: String, _ text: String) {
        print("E2E_\(tag)=\(text)")
        attachScreenshot(named: "media-\(tag.lowercased())")
    }

    private func attachScreenshot(named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func attachScreenScreenshot(named name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
