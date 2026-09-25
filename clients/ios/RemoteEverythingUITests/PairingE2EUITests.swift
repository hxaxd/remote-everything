import XCTest

/// Drives a real pairing against a live gateway: invitation into the field,
/// join tapped, page expected to close itself with the node on the home list.
/// The setup URI comes from the environment (`RE_E2E_SETUP_URI`) because it is
/// minted per gateway, names a node, and expires — without it there is nothing
/// to join and the test skips.
final class PairingE2EUITests: XCTestCase {

    func testJoinNodeAgainstLiveGateway() throws {
        guard let uri = ProcessInfo.processInfo.environment["RE_E2E_SETUP_URI"], !uri.isEmpty else {
            throw XCTSkip("RE_E2E_SETUP_URI not provided; skipping live gateway pairing test.")
        }
        let app = XCUIApplication()
        app.launch()

        let add = app.buttons["home.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 15), "the add-node button is not there")
        add.tap()

        // The invitation field may surface as a text view (it grows with the
        // invitation); the identifier finds whichever it is.
        let field = app.descendants(matching: .any)["pair.invitation"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the invitation field is not there")
        field.tap()
        field.typeText(uri)

        let join = app.buttons["pair.join"]
        XCTAssertTrue(join.waitForExistence(timeout: 5), "the confirm card did not appear for the invitation")
        join.tap()

        // Success closes the page and puts the node on the home list; anything
        // else leaves the page with a failure line. Wait, then say which.
        let deadline = Date().addingTimeInterval(20)
        var tree = ""
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            if !app.buttons["pair.join"].exists {
                break
            }
        }
        let home = app.navigationBars.firstMatch.exists
        let nodeRow = app.staticTexts["macbook"]
        if home && !app.buttons["pair.join"].exists && nodeRow.waitForExistence(timeout: 2) {
            return
        }
        tree = app.debugDescription
        XCTFail("pairing did not finish approved; the page is:\n\(tree)")
    }
}
