import XCTest
@testable import RemoteEverything

@MainActor
final class OneShotCompletionTests: XCTestCase {
    func testResolvesExactlyOnce() {
        var values: [Bool] = []
        let completion = OneShotCompletion<Bool> { values.append($0) }

        XCTAssertTrue(completion.resolve(true))
        XCTAssertFalse(completion.resolve(false))
        XCTAssertTrue(completion.isResolved)
        XCTAssertEqual(values, [true])
    }
}
