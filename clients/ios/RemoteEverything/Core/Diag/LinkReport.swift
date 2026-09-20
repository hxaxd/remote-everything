import Foundation

/// Why one connection is not answering.
///
/// "Offline" is one word for three different situations: this phone has no
/// network, the gateway cannot be reached from where the phone stands, or the
/// gateway is answering and refusing. Only the last one is about the deployment;
/// the first is the phone's own business. Keeping the failure — not just a count
/// of failures — is what lets a screen and a report say which one it is.
///
/// What the person does with this is copy it: an installation that cannot be
/// reached is a question for whoever runs the gateway, and the answer has to
/// travel. So the report carries what a reader needs and the phone happened to
/// see, in that order: what this client is, what it was talking to, what went
/// wrong, and what it knows about the network in between.
struct LinkTrouble: Equatable {
    enum Kind: String, Equatable, CaseIterable {
        case noNetwork = "no_network"
        case unreachable = "unreachable"
        case refused = "refused"
        case badAnswer = "bad_answer"
        case unknown = "unknown"
    }

    let kind: Kind
    let at: Date
    let since: Date
    let attempts: Int
    let code: String?
    let httpStatus: Int?
    let detail: String?
    let lastGoodAt: Date?

    init(
        kind: Kind,
        at: Date,
        since: Date,
        attempts: Int,
        code: String? = nil,
        httpStatus: Int? = nil,
        detail: String? = nil,
        lastGoodAt: Date? = nil
    ) {
        self.kind = kind
        self.at = at
        self.since = since
        self.attempts = attempts
        self.code = code
        self.httpStatus = httpStatus
        self.detail = detail
        self.lastGoodAt = lastGoodAt
    }

    init(
        kind: Kind,
        atMs: Int64,
        sinceMs: Int64,
        attempts: Int,
        code: String? = nil,
        httpStatus: Int? = nil,
        detail: String? = nil,
        lastGoodAtMs: Int64? = nil
    ) {
        self.init(
            kind: kind,
            at: Date(timeIntervalSince1970: Double(atMs) / 1000.0),
            since: Date(timeIntervalSince1970: Double(sinceMs) / 1000.0),
            attempts: attempts,
            code: code,
            httpStatus: httpStatus,
            detail: detail,
            lastGoodAt: lastGoodAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000.0) }
        )
    }
}

/// One failed probe, kept so a report can show a run rather than a moment.
struct LinkAttempt: Equatable {
    let at: Date
    let kind: LinkTrouble.Kind

    init(at: Date, kind: LinkTrouble.Kind) {
        self.at = at
        self.kind = kind
    }

    init(atMs: Int64, kind: LinkTrouble.Kind) {
        self.init(at: Date(timeIntervalSince1970: Double(atMs) / 1000.0), kind: kind)
    }
}

/// A classified failure: what it was, and whatever the wire said about it.
struct LinkFailure: Equatable {
    let kind: LinkTrouble.Kind
    let code: String?
    let httpStatus: Int?
    let detail: String?

    init(
        kind: LinkTrouble.Kind,
        code: String? = nil,
        httpStatus: Int? = nil,
        detail: String? = nil
    ) {
        self.kind = kind
        self.code = code
        self.httpStatus = httpStatus
        self.detail = detail
    }
}

/// Everything a report says, gathered where the platform can answer it: the
/// version lines come from the build, the system line from the OS, the network
/// line from the platform's own idea of the network, and the rest from what the
/// client remembers about this connection.
struct LinkReportInput {
    let appName: String
    let client: String
    let protocolVersion: String
    let system: String
    let origin: String
    let deviceName: String
    let network: String
    let machines: [String]
    let trouble: LinkTrouble
    let attempts: [LinkAttempt]
    let time: (Date) -> String
}

/// How many failed probes a report keeps: enough to show a pattern, not a log.
let LinkAttemptsKept = 4

/// Longest exception message a report carries; the rest is noise about noise.
private let DetailChars = 200

/// Classifies one failure. `offline` is the platform's answer to "is there any
/// network this phone could be using at all": with nothing to send on, every
/// connection fails the same way, and that is worth saying before anything else.
func classifyFailure(_ failure: Error, offline: Bool) -> LinkFailure {
    if offline {
        return LinkFailure(kind: .noNetwork, detail: describe(failure))
    }
    if let clientError = failure as? ClientError {
        return LinkFailure(
            kind: .refused,
            code: clientError.code.rawValue.lowercased(),
            httpStatus: clientError.httpStatus,
            detail: describe(clientError)
        )
    }
    if let unreadable = failure as? UnreadableAnswer {
        return LinkFailure(kind: .badAnswer, detail: describe(unreadable))
    }
    if let netFailure = failure as? NetworkFailure {
        let deepest = netFailure.underlying ?? netFailure
        return LinkFailure(kind: .unreachable, detail: describe(deepest))
    }
    if failure is URLError {
        return LinkFailure(kind: .unreachable, detail: describe(failure))
    }
    return LinkFailure(kind: .unknown, detail: describe(failure))
}

/// The deepest cause, named. "network failure" says nothing a reader can use;
/// "SocketTimeoutException: timeout" says which hop stopped answering, and that
/// is the difference between a guess and a report.
func describe(_ failure: Error) -> String {
    var deepest = failure
    while true {
        if let netFail = deepest as? NetworkFailure, let under = netFail.underlying {
            deepest = under
            continue
        }
        let ns = deepest as NSError
        if let under = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            deepest = under
            continue
        }
        break
    }

    let ns = deepest as NSError
    let typeName: String
    if ns.domain != NSCocoaErrorDomain && ns.domain != NSURLErrorDomain && ns.domain.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) == nil && !ns.domain.isEmpty {
        typeName = ns.domain
    } else {
        typeName = String(describing: type(of: deepest))
    }

    let message: String
    if let clientError = deepest as? ClientError {
        message = "refused: \(clientError.code.rawValue.uppercased())"
    } else if let unreadable = deepest as? UnreadableAnswer {
        message = unreadable.message
    } else {
        let trimmed = deepest.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        message = trimmed
    }

    let truncated = String(message.prefix(DetailChars)).trimmingCharacters(in: .whitespacesAndNewlines)
    if truncated.isEmpty {
        return typeName
    }
    if truncated == typeName || truncated.starts(with: "\(typeName):") {
        return truncated
    }
    return "\(typeName): \(truncated)"
}

extension LinkTrouble.Kind {
    var messageKey: String {
        switch self {
        case .noNetwork: return MessageKeys.DIAG_CAUSE_NO_NETWORK
        case .unreachable: return MessageKeys.DIAG_CAUSE_UNREACHABLE
        case .refused: return MessageKeys.DIAG_CAUSE_REFUSED
        case .badAnswer: return MessageKeys.DIAG_CAUSE_BAD_ANSWER
        case .unknown: return MessageKeys.DIAG_CAUSE_UNKNOWN
        }
    }

    /// What this kind of failure is called, in the language the app is in.
    func phrase(say: (String, String?) -> String) -> String {
        say(messageKey, nil)
    }
}

/// The report itself: one line per fact, each starting with a word for what the
/// line is — a screen-reader's shape, and the shape a person pastes into a
/// message without editing it first. `say` resolves a message key, with an
/// argument when the key takes one.
func buildLinkReport(input: LinkReportInput, say: (String, String?) -> String) -> String {
    let trouble = input.trouble
    var lines: [String] = []

    lines.append("\(input.appName) · \(say(MessageKeys.DIAG_TITLE, nil))")
    lines.append("\(say(MessageKeys.DIAG_CLIENT, nil)) \(input.client) · \(say(MessageKeys.SETTINGS_PROTOCOL_VERSION, nil)) \(input.protocolVersion)")
    lines.append("\(say(MessageKeys.DIAG_SYSTEM, nil)) \(input.system)")
    lines.append("\(say(MessageKeys.DIAG_CONNECTION, nil)) \(input.origin) · \(say(MessageKeys.DIAG_DEVICE_NAME, nil)) \(input.deviceName)")

    // What is wrong, how long it has been wrong, and when it was last right:
    // three facts that together say whether this is new or a state of affairs.
    var state: [String] = []
    state.append(trouble.kind.phrase(say: say))
    state.append(say(MessageKeys.DIAG_FAILURES, "\(trouble.attempts)"))
    state.append(say(MessageKeys.DIAG_SINCE, input.time(trouble.since)))
    if let lastGoodAt = trouble.lastGoodAt {
        state.append(say(MessageKeys.DIAG_LAST_ANSWER, input.time(lastGoodAt)))
    }
    lines.append("\(say(MessageKeys.DIAG_STATE, nil)) \(state.joined(separator: " · "))")

    // The wire's own words, when there were any: a code and a status are what a
    // gateway-side reader can look up, and the exception names the hop that failed.
    var cause: [String] = []
    if let detail = trouble.detail, !detail.isEmpty {
        cause.append(detail)
    }
    if let status = trouble.httpStatus {
        cause.append("HTTP \(status)")
    }
    if let code = trouble.code, !code.isEmpty {
        cause.append(code)
    }
    let causeStr = cause.isEmpty ? "—" : cause.joined(separator: " · ")
    lines.append("\(say(MessageKeys.DIAG_CAUSE, nil)) \(causeStr)")

    lines.append("\(say(MessageKeys.DIAG_NETWORK, nil)) \(input.network)")

    let hasCJK = input.appName.unicodeScalars.contains { $0.value >= 0x4e00 && $0.value <= 0x9fff }
        || say(MessageKeys.DIAG_TITLE, nil).unicodeScalars.contains { $0.value >= 0x4e00 && $0.value <= 0x9fff }
    let separator = hasCJK ? "；" : "; "

    if !input.machines.isEmpty {
        lines.append("\(say(MessageKeys.DIAG_MACHINES, nil)) \(input.machines.joined(separator: separator))")
    }

    if !input.attempts.isEmpty {
        let attemptsStr = input.attempts.map { "\(input.time($0.at)) \($0.kind.phrase(say: say))" }.joined(separator: separator)
        lines.append("\(say(MessageKeys.DIAG_ATTEMPTS, nil)) \(attemptsStr)")
    }

    return lines.joined(separator: "\n")
}
