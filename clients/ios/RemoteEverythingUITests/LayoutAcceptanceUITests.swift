import XCTest

/// Layout, language, appearance, large text and landscape evidence. The caller
/// has already paired the simulator; these tests only need the home screen.
final class LayoutAcceptanceUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        guard ProcessInfo.processInfo.environment["RE_E2E_LAYOUT_RUN"] != nil else {
            throw XCTSkip("RE_E2E_LAYOUT_RUN not provided")
        }
        app = XCUIApplication()
    }

    func testLanguageAndAppearanceSwitchInPlace() throws {
        app.launch()
        openSettings()
        capture("l06-settings-zh-dark")

        let english = app.buttons["English"]
        XCTAssertTrue(english.waitForExistence(timeout: 8), "the English option is not there")
        english.tap()
        XCTAssertTrue(app.buttons["Light"].waitForExistence(timeout: 5), "the settings screen did not switch to English")
        capture("l09-settings-en-dark")
        XCTAssertTrue(app.navigationBars["Settings"].exists, "the settings title did not change")

        app.buttons["Light"].tap()
        sleep(1)
        let light = capture("l10-settings-en-light")
        XCTAssertGreaterThan(brightness(light), 150, "the light appearance did not take effect")
        app.buttons["Done"].tap()

        XCTAssertTrue(app.staticTexts["Remote Everything"].waitForExistence(timeout: 5), "the home title did not switch to English")
        let homeLight = capture("l09-home-en-light")
        XCTAssertGreaterThan(brightness(homeLight), 150)

        // Leave the client in its original Chinese, dark state.
        openSettings()
        app.buttons["中文"].tap()
        XCTAssertTrue(app.buttons["深色"].waitForExistence(timeout: 5), "the Chinese appearance options did not return")
        app.buttons["深色"].tap()
        sleep(1)
        app.buttons["完成"].tap()
        XCTAssertTrue(app.staticTexts["远程万物"].waitForExistence(timeout: 5), "the home title did not return to Chinese")
    }

    func testLargeTextScreens() throws {
        app.launch()
        capture("l12-home-large-text")
        openSettings()
        capture("l12-settings-large-text")
        app.buttons["完成"].tap()
        app.buttons["home.add"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["pair.invitation"].waitForExistence(timeout: 8))
        capture("l12-pair-large-text")
        app.navigationBars.buttons["取消"].tap()
    }

    func testLandscapeWebPanel() throws {
        app.launch()
        let node = app.staticTexts["macbook-swipe"]
        XCTAssertTrue(node.waitForExistence(timeout: 20))
        node.tap()
        let entry = scrollToApp("Fixture A")
        XCTAssertTrue(entry.exists)
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Fixture A'")).firstMatch
        if row.exists { row.tap() } else { entry.tap() }
        XCTAssertTrue(app.staticTexts["FIXTURE-A-READY"].waitForExistence(timeout: 30))

        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(1)
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        let across = app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: across)
        XCTAssertTrue(app.buttons["退出"].waitForExistence(timeout: 5), "the panel did not fit in landscape")
        capture("l13-panel-landscape")
        XCTAssertTrue(app.buttons["刷新"].exists)
        app.buttons["退出"].tap()
        XCUIDevice.shared.orientation = .portrait
        sleep(1)
    }


    func testIPadWideLayout() throws {
        guard ProcessInfo.processInfo.environment["RE_E2E_IPAD"] != nil else {
            throw XCTSkip("RE_E2E_IPAD not provided")
        }
        app.launch()
        capture("l02-ipad-home-portrait")
        let node = app.staticTexts["macbook-swipe"].firstMatch
        XCTAssertTrue(node.waitForExistence(timeout: 20), "the node is not in the wide list")
        node.tap()
        XCTAssertTrue(app.staticTexts["Fixture A"].waitForExistence(timeout: 25), "the right column did not load the catalog")
        capture("l02-ipad-node-portrait")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Fixture A'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.staticTexts["FIXTURE-A-READY"].waitForExistence(timeout: 30), "the application did not open on iPad")
        capture("l04-ipad-web-fullscreen")
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        let across = app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: across)
        XCTAssertTrue(app.buttons["退出"].waitForExistence(timeout: 5))
        app.buttons["退出"].tap()
        XCTAssertTrue(app.staticTexts["Fixture A"].waitForExistence(timeout: 15), "the node selection was lost after leaving the page")
        capture("l04-ipad-back-to-node")
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(1)
        capture("l02-ipad-landscape")
        XCUIDevice.shared.orientation = .portrait
    }


    func testIPadWideSelectionRefreshAndWebReturn() throws {
        guard ProcessInfo.processInfo.environment["RE_E2E_IPAD_WIDE"] != nil else {
            throw XCTSkip("RE_E2E_IPAD_WIDE not provided")
        }
        app.launch()
        XCTAssertTrue(app.staticTexts["选择一个节点"].waitForExistence(timeout: 15), "the detail column did not start with the select hint")
        capture("wide-initial")

        let nodeA = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'macbook-swipe'")).firstMatch
        XCTAssertTrue(nodeA.waitForExistence(timeout: 15), "the sidebar did not list node A")
        nodeA.tap()
        XCTAssertTrue(app.staticTexts["Blank Page"].waitForExistence(timeout: 25), "node A did not fill the detail column")
        XCTAssertTrue(app.staticTexts["当前为本地连接"].exists, "node A's path is not in the detail title")
        capture("wide-node-a")

        let nodeB = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'node-b'")).firstMatch
        XCTAssertTrue(nodeB.waitForExistence(timeout: 15), "the sidebar did not list node B")
        nodeB.tap()
        XCTAssertTrue(app.staticTexts["Fixture A"].waitForExistence(timeout: 25), "node B did not fill the detail column")
        XCTAssertFalse(app.staticTexts["Blank Page"].exists, "node A's catalog stayed in node B's detail")
        capture("wide-node-b")

        nodeA.tap()
        XCTAssertTrue(app.staticTexts["Blank Page"].waitForExistence(timeout: 25), "switching back to node A did not restore its catalog")
        let row = app.staticTexts["Fixture A"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let before = row.frame
        app.buttons["arrow.clockwise"].tap()
        sleep(2)
        XCTAssertTrue(app.staticTexts["当前为本地连接"].exists, "the detail title disappeared during a sidebar refresh")
        let after = app.staticTexts["Fixture A"].firstMatch.frame
        XCTAssertEqual(before.minY, after.minY, accuracy: 2, "the sidebar refresh moved the detail column")
        capture("wide-after-sidebar-refresh")

        let sidebarBefore = nodeA.frame
        app.swipeDown()
        sleep(2)
        XCTAssertEqual(nodeA.frame.minY, sidebarBefore.minY, accuracy: 2, "the detail refresh moved the sidebar")
        XCTAssertTrue(app.staticTexts["Blank Page"].exists, "the detail refresh lost the catalog")
        capture("wide-after-detail-refresh")

        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Fixture A'")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["FIXTURE-A-READY"].waitForExistence(timeout: 30), "the application did not open from the detail")
        capture("wide-web-fullscreen")
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        let across = app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: across)
        XCTAssertTrue(app.buttons["退出"].waitForExistence(timeout: 5))
        app.buttons["退出"].tap()
        XCTAssertTrue(app.staticTexts["Blank Page"].waitForExistence(timeout: 15), "leaving the application did not restore the detail")
        XCTAssertTrue(app.staticTexts["当前为本地连接"].exists, "the selected node was lost after leaving the application")
        capture("wide-back-to-node")

        XCUIDevice.shared.orientation = .landscapeRight
        sleep(2)
        XCTAssertTrue(app.staticTexts["Blank Page"].exists, "rotation lost the selected node's catalog")
        capture("wide-landscape")
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        XCTAssertTrue(app.staticTexts["Blank Page"].exists, "rotation back lost the selected node's catalog")

        app.buttons["gearshape"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 8), "settings did not open over the wide layout")
        app.buttons["完成"].tap()
        XCTAssertTrue(app.staticTexts["Blank Page"].waitForExistence(timeout: 10), "closing settings lost the detail selection")
        capture("wide-after-settings")
    }

    func testOrientationLockReleasesOnExit() throws {
        guard ProcessInfo.processInfo.environment["RE_E2E_ORIENTATION"] != nil else {
            throw XCTSkip("RE_E2E_ORIENTATION not provided")
        }
        app.launch()
        let node = app.staticTexts["macbook-swipe"]
        XCTAssertTrue(node.waitForExistence(timeout: 20))
        node.tap()
        let entry = scrollToApp("Fixture A")
        XCTAssertTrue(entry.exists)
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Fixture A'")).firstMatch
        if row.exists { row.tap() } else { entry.tap() }
        XCTAssertTrue(app.staticTexts["FIXTURE-A-READY"].waitForExistence(timeout: 30))
        openPanel()
        let landscape = app.staticTexts["横屏"]
        XCTAssertTrue(landscape.waitForExistence(timeout: 5), "the orientation choice is not in the panel")
        landscape.tap()
        let outside = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        outside.tap()
        sleep(2)
        sleep(2)
        capture("orientation-locked")
        XCTAssertGreaterThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height, "the landscape choice did not rotate the page")
        openPanel()
        XCTAssertTrue(app.buttons["退出"].waitForExistence(timeout: 5))
        app.buttons["退出"].tap()
        sleep(3)
        capture("orientation-released")
        XCTAssertGreaterThan(app.windows.firstMatch.frame.height, app.windows.firstMatch.frame.width, "leaving the application left the list in landscape")
    }


    func testIPadWideOfflineDetailRecoversBySelectingAnotherNode() throws {
        guard ProcessInfo.processInfo.environment["RE_E2E_IPAD_OFFLINE"] != nil else {
            throw XCTSkip("RE_E2E_IPAD_OFFLINE not provided")
        }
        app.launch()
        let nodeB = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'node-b'")).firstMatch
        XCTAssertTrue(nodeB.waitForExistence(timeout: 15), "the sidebar lost node B")
        nodeB.tap()
        XCTAssertTrue(app.buttons["重试"].waitForExistence(timeout: 25), "the offline node did not show a retry page in the detail")
        capture("wide-node-b-offline")
        let nodeA = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'macbook-swipe'")).firstMatch
        XCTAssertTrue(nodeA.exists, "the offline detail took the whole sidebar with it")
        nodeA.tap()
        XCTAssertTrue(app.staticTexts["Blank Page"].waitForExistence(timeout: 25), "selecting the healthy node did not replace the error")
        XCTAssertFalse(app.buttons["重试"].exists, "the old error page stayed after selecting another node")
        capture("wide-error-recovered-by-selection")
    }


    func testEmptyHomeHasNoIllustrationAndACompactAction() throws {
        guard ProcessInfo.processInfo.environment["RE_E2E_EMPTY"] != nil else {
            throw XCTSkip("RE_E2E_EMPTY not provided")
        }
        app.launch()
        let title = app.staticTexts.matching(NSPredicate(format: "label == '还没有节点' OR label == 'No nodes yet'")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15), "the empty state did not appear")
        XCTAssertFalse(app.staticTexts["📦"].exists, "the empty state still has an illustration")
        let action = app.buttons.matching(NSPredicate(format: "label == '添加节点' OR label == 'Add node'")).firstMatch
        XCTAssertTrue(action.exists, "the empty state has no add action")
        XCTAssertLessThan(action.frame.width, app.windows.firstMatch.frame.width - 80, "the empty-state action is a full-width bar")
        capture("empty-state-fixed")
    }

    // MARK: - Helpers

    private func openPanel() {
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        let across = app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: across)
    }

    private func openSettings() {
        let gear = app.buttons["gearshape"]
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "the settings button is not there")
        gear.tap()
    }

    private func scrollToApp(_ name: String) -> XCUIElement {
        if app.statusBars.firstMatch.exists { app.statusBars.firstMatch.tap() }
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

    private func brightness(_ shot: XCUIScreenshot) -> Double {
        guard let cg = shot.image.cgImage, let crop = cg.cropping(to: CGRect(x: cg.width / 2 - 20, y: cg.height / 4 - 20, width: 40, height: 40)),
              let data = crop.dataProvider?.data else { return -1 }
        let bytes = data as Data
        let bpp = crop.bitsPerPixel / 8
        var sum = 0.0
        var count = 0.0
        bytes.withUnsafeBytes { raw in
            let pixels = raw.bindMemory(to: UInt8.self)
            for y in 0..<crop.height {
                for x in 0..<crop.width {
                    let offset = y * crop.bytesPerRow + x * bpp
                    guard offset + 2 < bytes.count else { continue }
                    sum += 0.2126 * Double(pixels[offset]) + 0.7152 * Double(pixels[offset + 1]) + 0.0722 * Double(pixels[offset + 2])
                    count += 1
                }
            }
        }
        return count > 0 ? sum / count : -1
    }
}
