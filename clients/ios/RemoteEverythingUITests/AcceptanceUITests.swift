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
