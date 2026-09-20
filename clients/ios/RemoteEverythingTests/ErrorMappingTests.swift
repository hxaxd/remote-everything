import XCTest
@testable import RemoteEverything

/// The code → copy mapping of ui-contract §3, and the pieces around it: every
/// code has a place to be said, and nothing is matched by its prose.
final class ErrorMappingTests: XCTestCase {

    func testEveryCodeHasCopy() {
        for code in ErrorCode.allCases {
            let key = ErrorText.key(for: code)
            XCTAssertFalse(key.isEmpty, "\(code.rawValue) has no copy key")
            XCTAssertTrue(key.hasPrefix("error.") || key.hasPrefix("node.") || key.hasPrefix("pair."), "Unexpected key format for \(code.rawValue): \(key)")
            XCTAssertFalse(ErrorText.text(for: code).isEmpty)
        }
        XCTAssertEqual(ErrorCode.allCases.count, 19)
    }

    func testTheContractRowsShareTheirCopy() {
        XCTAssertEqual(ErrorText.key(for: .unauthorized), ErrorText.key(for: .nodeNotFound))
        XCTAssertEqual(ErrorText.key(for: .nodeNotFound), ErrorText.key(for: .nodeRequired))
        XCTAssertEqual(ErrorText.key(for: .rateLimited), ErrorText.key(for: .serverBusy))
        XCTAssertEqual(ErrorText.key(for: .pairingFailed), ErrorText.key(for: .activationFailed))
        XCTAssertEqual(ErrorText.key(for: .activationFailed), ErrorText.key(for: .internalError))
        XCTAssertEqual(ErrorText.key(for: .invalidBody), ErrorText.key(for: .invalidJson))
        XCTAssertEqual(ErrorText.key(for: .invalidJson), ErrorText.key(for: .invalidDeviceName))
    }

    func testCodesThatMustNotBeConfusedAreDifferent() {
        XCTAssertNotEqual(ErrorText.key(for: .computerOffline), ErrorText.key(for: .unauthorized))
        XCTAssertNotEqual(ErrorText.key(for: .approvalPending), ErrorText.key(for: .unauthorized))
        XCTAssertNotEqual(ErrorText.key(for: .invitationDenied), ErrorText.key(for: .invitationExpired))
        XCTAssertNotEqual(ErrorText.key(for: .appNotFound), ErrorText.key(for: .nodeNotFound))
    }

    func testPairingFailuresReachTheirCopy() {
        XCTAssertEqual(
            ErrorText.text(for: .refusal(ClientError(.invitationDenied))),
            ErrorText.text(for: .invitationDenied)
        )
        XCTAssertEqual(ErrorText.text(for: .network), ErrorText.network)
        XCTAssertEqual(ErrorText.text(for: .client), ErrorText.text(for: .invalidBody))
    }

    func testOnlyFailuresWorthColorAreColored() {
        XCTAssertFalse(NoticeText.usesErrorColor(.busy))
        XCTAssertFalse(NoticeText.usesErrorColor(.appGone))
        XCTAssertFalse(NoticeText.usesErrorColor(.network))
        XCTAssertTrue(NoticeText.usesErrorColor(.stopFailed))
        XCTAssertTrue(NoticeText.usesErrorColor(.credentialLost("https://gw.example.com")))
    }

    func testClientErrorsCarryTheirStatus() {
        let error = ClientError(.unauthorized, httpStatus: 401)
        XCTAssertEqual(error.code, .unauthorized)
        XCTAssertEqual(error.httpStatus, 401)
    }

    func testStatusFallbackOnlyFillsGaps() {
        XCTAssertEqual(GatewayClient.code(forStatus: 401), .unauthorized)
        XCTAssertEqual(GatewayClient.code(forStatus: 429), .rateLimited)
        XCTAssertEqual(GatewayClient.code(forStatus: 503), .serverBusy)
        XCTAssertEqual(GatewayClient.code(forStatus: 500), .internalError)
    }
}
