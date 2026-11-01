import XCTest

/// Drives the gateway-hosted fixture pages through the app's WKWebView. The
/// topology (node "macbook-swipe", Fixture A/B and the slow/failure apps) is
/// the caller's; every test skips unless `RE_E2E_WEB_NODE` names the node.
final class WebAcceptanceUITests: XCTestCase {

    private var app: XCUIApplication!
    private var nodeName = ""

    override func setUpWithError() throws {
        continueAfterFailure = true
        let env = ProcessInfo.processInfo.environment
        guard let node = env["RE_E2E_WEB_NODE"], !node.isEmpty else {
            throw XCTSkip("RE_E2E_WEB_NODE not provided; skipping web acceptance.")
        }
        nodeName = node
        app = XCUIApplication()
    }

    // MARK: - W: loading mask and first paint

    func testW01W03DelayedPaintMask() throws {
        openFresh("Slow Paint", marker: "PAINT-A-DONE", wait: false)
        let early = capture("w01-mask-early")
        usleep(1_500_000)
        let mid = capture("w02-mask-2s")
        let midDone = app.staticTexts["PAINT-A-DONE"].exists
        sleep(4)
        let late = capture("w03-mask-6s")
        let lateDone = app.staticTexts["PAINT-A-DONE"].exists
        XCTAssertTrue(app.staticTexts["PAINT-A-DONE"].waitForExistence(timeout: 6), "the delayed content never painted")
        let content = capture("w03-content")
        print("W01 earlyBrightness=\(brightness(early)) midBrightness=\(brightness(mid)) lateBrightness=\(brightness(late)) contentBrightness=\(brightness(content)) midDone=\(midDone) lateDone=\(lateDone)")
        XCTAssertLessThan(brightness(early), 100, "the first frame was not the opaque loading surface")
        XCTAssertLessThan(brightness(mid), 100, "the empty document was revealed before its content")
        XCTAssertGreaterThan(brightness(content), 180, "the white content page was not painted")
    }

    func testSlowCssJsAndDocument() throws {
        for (name, marker) in [("Slow CSS", "SLOWCSS-A-READY"), ("Slow JS", "SLOWJS-A-READY"), ("Slow Doc", "SLOWDOC-A-READY")] {
            openFresh(name, marker: marker, wait: false)
            usleep(1_200_000)
            let masked = capture("w-\(name)-masked")
            XCTAssertTrue(app.staticTexts[marker].waitForExistence(timeout: 15), "\(name) never painted")
            let content = capture("w-\(name)-content")
            print("W_SLOW \(name) maskBrightness=\(brightness(masked)) contentBrightness=\(brightness(content))")
            XCTAssertLessThan(brightness(masked), 100, "\(name) exposed the empty document")
        }
    }

    func testRefreshRemasksThePage() throws {
        openFresh("Slow Doc", marker: "SLOWDOC-A-READY")
        openPanel()
        let refresh = app.buttons["刷新"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 5), "the panel did not offer refresh")
        refresh.tap()
        usleep(300_000)
        let reMasked = capture("w04-refresh-mask")
        XCTAssertTrue(app.staticTexts["SLOWDOC-A-READY"].waitForExistence(timeout: 15), "the refreshed page never painted")
        let content = capture("w04-refresh-content")
        print("W04 maskBrightness=\(brightness(reMasked)) contentBrightness=\(brightness(content))")
        XCTAssertLessThan(brightness(reMasked), 100, "refresh did not re-mount the loading surface")
        XCTAssertGreaterThan(brightness(content), 180, "the refreshed page stayed covered")
    }

    func testRedirectChainAndWhitePage() throws {
        openFresh("Redirect", marker: "REDIRECT-A-DONE")
        capture("w09-redirect-done")
        exitWeb()
        openFromNode("Blank Page", marker: "WHITE-READY")
        let white = capture("w14-white-page")
        print("W14 whiteBrightness=\(brightness(white))")
        XCTAssertGreaterThan(brightness(white), 180, "the app tinted a page that did not ask for it")
    }

    func testMainDocumentFailureAndSubresourceFailure() throws {
        // A 500 with a body is still a main document. The question is whether
        // the client treats it as a failed page (retry) or as content.
        openFresh("Main Fail", marker: "MAIN-FAIL", wait: false)
        sleep(3)
        capture("w10-main-500")
        print("W10_500\n\(app.debugDescription)")
        let retry = app.buttons["重试"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5), "a 500 main document was rendered as if it were the page; no retry was offered")

        exitWeb()
        openFromNode("Sub Fail", marker: "SUBFAIL-A-OK")
        capture("w10-subresource-failure")
    }

    func testHangingMainDocumentHasATimeout() throws {
        guard ProcessInfo.processInfo.environment["RE_E2E_WEB_HANG"] != nil else {
            throw XCTSkip("RE_E2E_WEB_HANG not provided.")
        }
        openFresh("Broken", marker: "retry", wait: false)
        sleep(22)
        capture("w10-hang-22s")
        print("HANG_TREE\n\(app.debugDescription)")
        let retry = app.buttons["重试"]
        XCTAssertTrue(retry.waitForExistence(timeout: 30), "a main document that never answers kept the loading mask past 30s")
    }

    func testPopupHasItsOwnMaskAndClosesBack() throws {
        openFresh("Fixture A", marker: "FIXTURE-A-READY")
        tapLink("弹窗")
        XCTAssertTrue(app.staticTexts["POPUP-PARENT-A"].waitForExistence(timeout: 10), "the popup parent did not paint")
        tapWebButton("打开慢弹窗")
        usleep(500_000)
        let childMask = capture("w07-popup-mask")
        XCTAssertTrue(app.staticTexts["POPUP-CHILD-A-DONE"].waitForExistence(timeout: 10), "the popup child never painted")
        capture("w07-popup-content")
        print("W07 popupMaskBrightness=\(brightness(childMask))")
        closePopup()
        XCTAssertTrue(app.staticTexts["POPUP-PARENT-A"].waitForExistence(timeout: 5), "closing the popup broke the parent")
    }

    func testExitBeforeThePageFinishes() throws {
        openFresh("Slow Doc", marker: "SLOWDOC-A-READY", wait: false)
        usleep(400_000)
        openPanel()
        let exit = app.buttons["退出"]
        XCTAssertTrue(exit.waitForExistence(timeout: 5), "the panel did not open during loading")
        exit.tap()
        XCTAssertTrue(app.buttons["BackButton"].waitForExistence(timeout: 10), "leaving the loading page did not return")
        openFromNode("Fixture B", marker: "FIXTURE-B-READY")
        capture("w12-other-app-after-early-exit")
    }

    func testDesktopUserAgentReloadsWithAMask() throws {
        openFresh("Fixture A", marker: "FIXTURE-A-READY")
        tapLink("UA 标识")
        XCTAssertTrue(app.staticTexts["UA-A-READY"].waitForExistence(timeout: 10))
        let mobile = readLabel(prefix: "UA:")
        print("W06 mobile=\(mobile)")
        openPanel()
        let desktop = app.staticTexts["桌面"]
        XCTAssertTrue(desktop.waitForExistence(timeout: 5), "the panel did not offer the desktop choice")
        desktop.tap()
        usleep(400_000)
        let switched = capture("w06-ua-switch")
        dismissPanel()
        XCTAssertTrue(app.staticTexts["UA-A-READY"].waitForExistence(timeout: 15), "the page did not reload after the UA switch")
        let desktopLabel = readLabel(prefix: "UA:")
        capture("w06-ua-switch-done")
        print("W06 switchedBrightness=\(brightness(switched)) desktop=\(desktopLabel)")
        XCTAssertTrue(desktopLabel.contains("Macintosh") || !desktopLabel.contains("iPhone"), "the user agent did not change")
    }

    func testInPageHistoryBackDoesNotTrapTheMask() throws {
        openFresh("Fixture A", marker: "FIXTURE-A-READY")
        tapLink("返回导航")
        XCTAssertTrue(app.staticTexts["NAV-A-READY"].waitForExistence(timeout: 10))
        tapLink("下一屏")
        XCTAssertTrue(app.staticTexts["PAINT-A-DONE"].waitForExistence(timeout: 10))
        tapWebButton("返回上一页")
        XCTAssertTrue(app.staticTexts["NAV-A-READY"].waitForExistence(timeout: 10), "the history back did not return")
        sleep(1)
        capture("w08-history-back")
    }

    // MARK: - S: storage, persistence, lifecycle

    func testStorageIsolationBetweenApplications() throws {
        openFresh("Fixture A", marker: "FIXTURE-A-READY")
        openStorage("A")
        writeStorage()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'ls=A'")).firstMatch.waitForExistence(timeout: 10))
        exitWeb()

        openFromNode("Fixture B", marker: "FIXTURE-B-READY")
        openStorage("B")
        writeStorage()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'ls=B'")).firstMatch.waitForExistence(timeout: 10))
        exitWeb()

        openFromNode("Fixture A", marker: "FIXTURE-A-READY")
        openStorage("A")
        let aAgain = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'ls=A'")).firstMatch
        XCTAssertTrue(aAgain.waitForExistence(timeout: 10), "Fixture A lost its own storage")
        capture("s01-storage-a-again")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'ls=B'")).firstMatch.exists, "Fixture B leaked into Fixture A")
    }

    func testStoragePersistsAcrossColdStart() throws {
        openFresh("Fixture A", marker: "FIXTURE-A-READY")
        openStorage("A")
        writeStorage()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'ls=A'")).firstMatch.waitForExistence(timeout: 10))
        app.terminate()
        app.launch()
        openFromHome("Fixture A", marker: "FIXTURE-A-READY")
        openStorage("A")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'ls=A'")).firstMatch.waitForExistence(timeout: 10), "storage did not survive a cold start")
        capture("s03-storage-after-relaunch")
    }

    func testSameApplicationOnTwoNodesIsIsolated() throws {
        openFresh("Fixture A", marker: "FIXTURE-A-READY")
        openStorage("A")
        writeStorage()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'ls=A'")).firstMatch.waitForExistence(timeout: 10))
        exitWeb()
        goHome()
        openNode("node-b")
        openFromNode("Fixture A", marker: "FIXTURE-B-READY")
        openStorage("B")
        writeStorage()
        let b = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'ls=B'")).firstMatch
        XCTAssertTrue(b.waitForExistence(timeout: 10), "the node-B copy did not keep its own storage")
        capture("s02-node-b-storage")
        exitWeb()
        goHome()
        openNode(nodeName)
        openFromNode("Fixture A", marker: "FIXTURE-A-READY")
        openStorage("A")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'ls=A'")).firstMatch.waitForExistence(timeout: 10), "node A's storage was overwritten by node B")
    }

    func testBackgroundingKeepsTheForm() throws {
        openFresh("Fixture A", marker: "FIXTURE-A-READY")
        tapLink("键盘输入")
        XCTAssertTrue(app.staticTexts["KEYBOARD-READY"].waitForExistence(timeout: 10))
        let field = app.textFields["type here"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("hello")
        XCTAssertTrue(app.staticTexts["KEYBOARD:hello"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        sleep(1)
        app.activate()
        sleep(1)
        capture("s07-after-background")
        XCTAssertTrue(app.staticTexts["KEYBOARD:hello"].exists, "the page lost its input across backgrounding")
    }

    // MARK: - C: capabilities

    func testVideoPlaysAndReturnsFromFullscreen() throws {
        openFresh("Fixture A", marker: "FIXTURE-A-READY")
        tapLink("视频")
        XCTAssertTrue(app.staticTexts["VIDEO-READY"].waitForExistence(timeout: 10))
        tapWebButton("播放视频")
        XCTAssertTrue(app.staticTexts["VIDEO-PLAYING"].waitForExistence(timeout: 8), "the video did not start")
        capture("c08-video-playing")
        tapWebButton("网页全屏")
        sleep(2)
        let done = app.buttons["完成"].exists ? app.buttons["完成"] : app.buttons["Done"]
        if done.exists {
            capture("c08-video-fullscreen")
            done.tap()
        } else {
            capture("c08-video-fullscreen-missing-done")
        }
        XCTAssertTrue(app.staticTexts["VIDEO-READY"].waitForExistence(timeout: 10), "the page did not survive the video")
    }

    func testExternalSchemesLeaveThePageIntact() throws {
        openFresh("Fixture A", marker: "FIXTURE-A-READY")
        tapLink("tel/mailto")
        XCTAssertTrue(app.staticTexts["EXTERNAL-READY"].waitForExistence(timeout: 10))
        tapLink("tel")
        sleep(1)
        dismissSystemAlert()
        app.activate()
        sleep(1)
        capture("c09-tel")
        XCTAssertTrue(app.staticTexts["EXTERNAL-READY"].exists, "tel: destroyed the page")
        tapLink("mailto")
        sleep(1)
        dismissSystemAlert()
        app.activate()
        sleep(1)
        capture("c09-mailto")
        XCTAssertTrue(app.staticTexts["EXTERNAL-READY"].exists, "mailto: destroyed the page")
    }

    func testKeyboardSurvivesRotation() throws {
        openFresh("Fixture A", marker: "FIXTURE-A-READY")
        tapLink("键盘输入")
        XCTAssertTrue(app.staticTexts["KEYBOARD-READY"].waitForExistence(timeout: 10))
        let field = app.textFields["type here"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("rotate")
        XCTAssertTrue(app.staticTexts["KEYBOARD:rotate"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(1)
        capture("c10-landscape")
        XCTAssertTrue(app.staticTexts["KEYBOARD:rotate"].exists, "rotation reloaded the page and lost the input")
        XCUIDevice.shared.orientation = .portrait
        sleep(1)
        XCTAssertTrue(app.staticTexts["KEYBOARD:rotate"].exists)
    }


    func testDshProbe() throws {
        guard ProcessInfo.processInfo.environment["RE_E2E_DSH_RUN"] != nil else {
            throw XCTSkip("RE_E2E_DSH_RUN not provided")
        }
        openFresh("DSH Acceptance", marker: "DSH", wait: false)
        sleep(8)
        capture("d01-dsh-first-open")
        print("DSH_TREE\n\(app.debugDescription)")
        openPanel()
        if app.buttons["刷新"].waitForExistence(timeout: 5) {
            app.buttons["刷新"].tap()
        }
        sleep(8)
        capture("d01-dsh-refreshed")
        print("DSH_REFRESH_TREE\n\(app.debugDescription)")
    }


    func testDshAfterRestartAndContinue() throws {
        guard ProcessInfo.processInfo.environment["RE_E2E_DSH_RUN"] != nil else {
            throw XCTSkip("RE_E2E_DSH_RUN not provided")
        }
        openFresh("DSH Acceptance", marker: "DSH", wait: false)
        sleep(8)
        capture("d02-dsh-after-restart")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'authentication required'")).firstMatch.exists, "DSH asked for authentication after a restart")
        let go = app.buttons["继续"]
        if go.waitForExistence(timeout: 5) {
            go.tap()
            sleep(5)
            capture("d05-dsh-main")
            print("DSH_MAIN\n\(app.debugDescription)")
        } else {
            capture("d05-dsh-no-continue")
        }
    }


    func testHTTPDownloadSavesFile() throws {
        openFresh("Fixture A", marker: "FIXTURE-A-READY")
        tapLink("下载")
        sleep(4)
        capture("c04-download")
        let saved = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'fixture' OR label CONTAINS '已保存' OR label CONTAINS '保存到'")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10), "the download did not present its saved file")
        for label in ["取消", "关闭", "Close", "Cancel"] {
            let button = app.buttons[label]
            if button.exists { button.tap(); break }
        }
        sleep(1)
    }


    func testBinaryDownloadSavesFile() throws {
        openFresh("Fixture A", marker: "FIXTURE-A-READY")
        tapLink("二进制下载")
        sleep(4)
        capture("c04-binary-download")
        let saved = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'fixture' OR label CONTAINS '已保存' OR label CONTAINS '保存到'")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10), "the binary download did not report a saved file")
        for label in ["取消", "关闭", "Close", "Cancel"] {
            let button = app.buttons[label]
            if button.exists { button.tap(); break }
        }
    }


    func testUserAgentSwitchRemasksASlowPage() throws {
        openFresh("Slow Doc", marker: "SLOWDOC-A-READY")
        // The choice is remembered per application. Make this run start from the
        // mobile identity so switching to desktop is always a change.
        openPanel()
        if app.staticTexts["移动"].exists {
            app.staticTexts["移动"].tap()
            dismissPanel()
            XCTAssertTrue(app.staticTexts["SLOWDOC-A-READY"].waitForExistence(timeout: 20), "the mobile identity did not reload")
        } else {
            dismissPanel()
        }
        openPanel()
        let desktop = app.staticTexts["桌面"]
        XCTAssertTrue(desktop.waitForExistence(timeout: 5), "the panel did not offer the desktop choice")
        desktop.tap()
        usleep(80_000)
        let masked = capture("w06-slow-ua-mask")
        XCTAssertLessThan(brightness(masked), 100, "switching the user agent did not re-mount the loading surface")
        // The panel is still open; dismiss it and wait for the slow document.
        dismissPanel()
        XCTAssertTrue(app.staticTexts["SLOWDOC-A-READY"].waitForExistence(timeout: 20), "the slow page did not reload under the new identity")
        capture("w06-slow-ua-content")
    }

    // MARK: - Helpers

    private func openFresh(_ name: String, marker: String, wait: Bool = true) {
        app.launch()
        openFromHome(name, marker: marker, wait: wait)
    }

    private func openFromHome(_ name: String, marker: String, wait: Bool = true) {
        let node = app.staticTexts[nodeName]
        XCTAssertTrue(node.waitForExistence(timeout: 20), "the node is not on the home list")
        node.tap()
        openFromNode(name, marker: marker, wait: wait)
    }

    private func openFromNode(_ name: String, marker: String, wait: Bool = true) {
        let entry = scrollToApp(name)
        XCTAssertTrue(entry.exists, "the catalog did not list \(name)")
        usleep(400_000)
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        if row.exists {
            row.tap()
        } else {
            entry.tap()
        }
        if wait {
            XCTAssertTrue(app.staticTexts[marker].waitForExistence(timeout: 30), "\(name) did not paint \(marker)")
        }
    }

    private func scrollToApp(_ name: String) -> XCUIElement {
        // The list may be scrolled far down; a status-bar tap is not reliable
        // once the page has hidden and restored the bar, so go to the top first.
        for _ in 0..<3 { app.swipeDown(); usleep(200_000) }
        let element = app.staticTexts[name]
        for _ in 0..<12 where !element.exists {
            app.swipeUp()
            usleep(200_000)
        }
        return element
    }

    private func goHome() {
        let back = app.buttons["BackButton"]
        if back.exists { back.tap() }
    }

    private func openNode(_ name: String) {
        let node = app.staticTexts[name]
        XCTAssertTrue(node.waitForExistence(timeout: 10), "the node \(name) is not on the home list")
        node.tap()
    }

    private func openStorage(_ label: String) {
        tapLink("存储读写")
        XCTAssertTrue(app.staticTexts["STORAGE-\(label)"].waitForExistence(timeout: 10), "the storage page did not paint")
    }

    private func writeStorage() {
        let write = app.buttons["写入"]
        XCTAssertTrue(write.waitForExistence(timeout: 5), "the storage page has no write button")
        write.tap()
    }

    private func tapLink(_ label: String) {
        let link = app.links[label]
        if link.waitForExistence(timeout: 5) { link.tap(); return }
        let text = app.staticTexts[label]
        if text.waitForExistence(timeout: 2) { text.tap(); return }
        let button = app.buttons[label]
        if button.exists { button.tap(); return }
        XCTFail("link \(label) is not reachable; page is:\n\(app.debugDescription)")
    }

    private func tapWebButton(_ label: String) {
        let button = app.buttons[label]
        if button.waitForExistence(timeout: 5) { button.tap(); return }
        XCTFail("web button \(label) is not reachable; page is:\n\(app.debugDescription)")
    }

    private func openPanel() {
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        let across = app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: across)
    }

    private func dismissPanel() {
        let outside = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        outside.tap()
    }

    private func exitWeb() {
        openPanel()
        let exit = app.buttons["退出"]
        XCTAssertTrue(exit.waitForExistence(timeout: 5), "the panel did not open")
        exit.tap()
        XCTAssertTrue(app.buttons["BackButton"].waitForExistence(timeout: 10), "leaving the page did not return to the node")
    }

    private func closePopup() {
        for label in ["关闭", "Close"] {
            let button = app.buttons[label]
            if button.exists { button.tap(); return }
        }
        let corner = app.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.08))
        corner.tap()
    }

    private func dismissSystemAlert() {
        for label in ["取消", "Cancel", "不允许", "Don't Allow", "好", "OK"] {
            let button = app.buttons[label]
            if button.exists { button.tap(); return }
            let spring = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons[label]
            if spring.exists { spring.tap(); return }
        }
    }

    private func readLabel(prefix: String) -> String {
        let element = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        return element.exists ? element.label : ""
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
        guard let cg = shot.image.cgImage, let provider = cg.dataProvider, let data = provider.data else {
            return -1
        }
        let width = cg.width
        let height = cg.height
        let rect = CGRect(x: width / 2 - 20, y: height / 4 - 20, width: 40, height: 40)
        guard let crop = cg.cropping(to: rect), let cropData = crop.dataProvider?.data else { return -1 }
        let bytes = cropData as Data
        let bpp = crop.bitsPerPixel / 8
        var sum = 0.0
        var count = 0.0
        bytes.withUnsafeBytes { raw in
            let pixels = raw.bindMemory(to: UInt8.self)
            for y in 0..<crop.height {
                for x in 0..<crop.width {
                    let offset = y * crop.bytesPerRow + x * bpp
                    guard offset + 2 < bytes.count else { continue }
                    let r = Double(pixels[offset])
                    let g = Double(pixels[offset + 1])
                    let b = Double(pixels[offset + 2])
                    sum += 0.2126 * r + 0.7152 * g + 0.0722 * b
                    count += 1
                }
            }
        }
        return count > 0 ? sum / count : -1
    }

    func testWebProbe() throws {
        guard ProcessInfo.processInfo.environment["RE_E2E_WEB_PROBE"] != nil else {
            throw XCTSkip("RE_E2E_WEB_PROBE not provided.")
        }
        openFresh("Fixture A", marker: "FIXTURE-A-READY")
        print("WEB_INDEX\n\(app.debugDescription)")
        capture("web-probe")
        exitWeb()
    }
}
