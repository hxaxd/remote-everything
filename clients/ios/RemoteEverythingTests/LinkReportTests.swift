import XCTest
@testable import RemoteEverything

/// What a connection that will not answer is reported to be failing at, and what
/// the report says about it. Asserted across all platforms against the same rules.
final class LinkReportTests: XCTestCase {

    private let say: (String, String?) -> String = { key, arg in
        if let arg { return "\(key)=\(arg)" } else { return key }
    }

    private func input(
        _ trouble: LinkTrouble,
        _ attempts: [LinkAttempt] = [],
        appName: String = "远程万物",
        machines: [String] = ["Windows-PC 本地 ✗ 隧道 ✗"]
    ) -> LinkReportInput {
        LinkReportInput(
            appName: appName,
            client: "3.5.0 (28)",
            protocolVersion: "1",
            system: "Android 16 (API 36) · OPPO PLG110",
            origin: "https://47-97-117-46.nip.io",
            deviceName: "PLG110",
            network: "wifi · internet ✓ · vpn ✗",
            machines: machines,
            trouble: trouble,
            attempts: attempts,
            time: { at in "T\(Int(at.timeIntervalSince1970 * 1000))" }
        )
    }

    // MARK: - Classification

    func testARefusalFromTheWireKeepsItsCodeAndStatus() {
        let failure = classifyFailure(ClientError(.unauthorized, httpStatus: 401), offline: false)
        XCTAssertEqual(failure.kind, .refused)
        XCTAssertEqual(failure.code, "unauthorized")
        XCTAssertEqual(failure.httpStatus, 401)
    }

    func testAPhoneWithNothingToSendOnSaysSoBeforeNamingAnException() {
        let error = NSError(domain: "UnknownHostException", code: 0, userInfo: [NSLocalizedDescriptionKey: "gw.example.com"])
        let failure = classifyFailure(NetworkFailure(error), offline: true)
        XCTAssertEqual(failure.kind, .noNetwork)
    }

    func testAnUnreachableGatewayIsNamedByItsDeepestCause() {
        let error = NSError(domain: "SocketTimeoutException", code: 0, userInfo: [NSLocalizedDescriptionKey: "timeout"])
        let failure = classifyFailure(NetworkFailure(error), offline: false)
        XCTAssertEqual(failure.kind, .unreachable)
        XCTAssertTrue(failure.detail?.hasPrefix("SocketTimeoutException") == true)
    }

    func testTheWrapperIsNotWhatIsReportedTheCauseUnderneathItIs() {
        let underlying = NSError(domain: "UnknownHostException", code: 0, userInfo: [NSLocalizedDescriptionKey: "no such host"])
        let wrapper = NSError(domain: "IOException", code: 0, userInfo: [
            NSLocalizedDescriptionKey: "outer",
            NSUnderlyingErrorKey: underlying
        ])
        let failure = classifyFailure(NetworkFailure(wrapper), offline: false)
        XCTAssertTrue(failure.detail?.hasPrefix("UnknownHostException") == true)
        XCTAssertTrue(failure.detail?.contains("no such host") == true)
    }

    func testAnAnswerThatCannotBeReadIsItsOwnKind() {
        let failure = classifyFailure(UnreadableAnswer("HTTP 502 without a refusal this client can read"), offline: false)
        XCTAssertEqual(failure.kind, .badAnswer)
    }

    // MARK: - The Report

    func testTheReportCarriesTheConnectionTheCauseAndTheRunOfFailures() {
        let trouble = LinkTrouble(
            kind: .unreachable,
            atMs: 500,
            sinceMs: 100,
            attempts: 4,
            detail: "SocketTimeoutException: timeout",
            lastGoodAtMs: 50
        )
        let report = buildLinkReport(
            input: input(
                trouble,
                [LinkAttempt(atMs: 500, kind: trouble.kind), LinkAttempt(atMs: 400, kind: trouble.kind)]
            ),
            say: say
        )
        let lines = report.components(separatedBy: "\n")
        let expected = [
            "远程万物 · \(MessageKeys.DIAG_TITLE)",
            "\(MessageKeys.DIAG_CLIENT) 3.5.0 (28) · \(MessageKeys.SETTINGS_PROTOCOL_VERSION) 1",
            "\(MessageKeys.DIAG_SYSTEM) Android 16 (API 36) · OPPO PLG110",
            "\(MessageKeys.DIAG_CONNECTION) https://47-97-117-46.nip.io · \(MessageKeys.DIAG_DEVICE_NAME) PLG110",
            "\(MessageKeys.DIAG_STATE) \(MessageKeys.DIAG_CAUSE_UNREACHABLE) · " +
                "\(MessageKeys.DIAG_FAILURES)=4 · \(MessageKeys.DIAG_SINCE)=T100 · \(MessageKeys.DIAG_LAST_ANSWER)=T50",
            "\(MessageKeys.DIAG_CAUSE) SocketTimeoutException: timeout",
            "\(MessageKeys.DIAG_NETWORK) wifi · internet ✓ · vpn ✗",
            "\(MessageKeys.DIAG_MACHINES) Windows-PC 本地 ✗ 隧道 ✗",
            "\(MessageKeys.DIAG_ATTEMPTS) T500 \(MessageKeys.DIAG_CAUSE_UNREACHABLE)；T400 \(MessageKeys.DIAG_CAUSE_UNREACHABLE)",
        ]
        XCTAssertEqual(lines, expected)
    }

    func testARefusalReportsTheCodeAndTheStatusItCameWith() {
        let trouble = LinkTrouble(
            kind: .refused,
            atMs: 1,
            sinceMs: 1,
            attempts: 1,
            code: "unauthorized",
            httpStatus: 401,
            detail: "ClientError: refused: UNAUTHORIZED"
        )
        let report = buildLinkReport(input: input(trouble), say: say)
        XCTAssertTrue(report.contains("\(MessageKeys.DIAG_CAUSE) ClientError: refused: UNAUTHORIZED · HTTP 401 · unauthorized"))
    }

    func testAConnectionThatNeverAnsweredHasNoLastAnswerClause() {
        let trouble = LinkTrouble(kind: .noNetwork, atMs: 1, sinceMs: 1, attempts: 2, detail: "offline")
        let report = buildLinkReport(input: input(trouble), say: say)
        XCTAssertTrue(report.contains(MessageKeys.DIAG_CAUSE_NO_NETWORK))
        XCTAssertFalse(report.contains(MessageKeys.DIAG_LAST_ANSWER))
        XCTAssertFalse(report.contains(MessageKeys.DIAG_ATTEMPTS))
    }

    func testAnEnglishReportUsesWesternSemicolonsForLists() {
        let trouble = LinkTrouble(kind: .unreachable, atMs: 200, sinceMs: 100, attempts: 2)
        let enInput = input(
            trouble,
            [LinkAttempt(atMs: 200, kind: trouble.kind), LinkAttempt(atMs: 100, kind: trouble.kind)],
            appName: "Remote Everything",
            machines: ["Machine A LAN ✓", "Machine B LAN ✗"]
        )
        let report = buildLinkReport(input: enInput, say: say)
        XCTAssertTrue(report.contains("\(MessageKeys.DIAG_MACHINES) Machine A LAN ✓; Machine B LAN ✗"))
        XCTAssertTrue(report.contains("\(MessageKeys.DIAG_ATTEMPTS) T200 \(MessageKeys.DIAG_CAUSE_UNREACHABLE); T100 \(MessageKeys.DIAG_CAUSE_UNREACHABLE)"))
    }
}
