import Foundation

/// How often this client looks at things, and how long it waits. These are the
/// numbers all three clients share — a node list refreshed every minute on one
/// platform and every five on another is two products rather than one — and
/// `clients/behavior/fixtures/cadence.json` is where they are written down: a test
/// asserts this table against it, so a cadence changed here alone does not pass.
///
/// The table is written in milliseconds, the unit the fixture and the other two
/// clients use. The properties below it are the same numbers in the units
/// Foundation asks for — seconds for a deadline or a request timeout, nanoseconds
/// for `Task.sleep` — derived here so a duration is written down once and the
/// app asks for it by name.
enum Cadence {

    /// The node list while the app is in the foreground. The `/nodes` call is also
    /// the path probe, so this is how often each path is probed as well.
    static let nodeRefreshMs: Int = 60_000

    /// One node's applications while its screen is open.
    static let catalogRefreshMs: Int = 30_000

    /// After a start or a stop: from here, times this factor, up to the ceiling.
    static let controlPollMs: Int = 1_000
    static let controlPollFactor: Double = 1.5
    static let controlPollCeilingMs: Int = 5_000

    /// How long a start or a stop is waited for before the screen stops asking.
    static let controlPollTimeoutMs: Int = 60_000

    /// A device that paired and is waiting for its operator.
    static let approvalPollMs: Int = 5_000
    static let approvalPollTimeoutMs: Int = 600_000

    /// How long a staged pairing is treated as alive when the gateway's own expiry
    /// could not be read: the invitation lifetime it hands out by default.
    static let pendingFallbackMs: Int = 600_000

    /// How long a path is given to answer while it is being probed.
    static let probeTimeoutMs: Int = 2_000

    /// Everything that is not a probe: a catalog, an action, an open.
    static let requestTimeoutMs: Int = 10_000

    // MARK: - The same table in the units Foundation asks in

    static var controlPoll: TimeInterval { seconds(controlPollMs) }
    static var controlPollCeiling: TimeInterval { seconds(controlPollCeilingMs) }
    static var controlPollTimeout: TimeInterval { seconds(controlPollTimeoutMs) }
    static var approvalPollTimeout: TimeInterval { seconds(approvalPollTimeoutMs) }
    static var pendingFallback: TimeInterval { seconds(pendingFallbackMs) }
    static var probeTimeout: TimeInterval { seconds(probeTimeoutMs) }
    static var requestTimeout: TimeInterval { seconds(requestTimeoutMs) }

    static var nodeRefreshNanos: UInt64 { nanoseconds(nodeRefreshMs) }
    static var catalogRefreshNanos: UInt64 { nanoseconds(catalogRefreshMs) }
    static var approvalPollNanos: UInt64 { nanoseconds(approvalPollMs) }

    /// Milliseconds as the seconds a deadline or a request timeout is written in.
    static func seconds(_ milliseconds: Int) -> TimeInterval { TimeInterval(milliseconds) / 1_000 }

    /// Milliseconds as the nanoseconds `Task.sleep` takes.
    static func nanoseconds(_ milliseconds: Int) -> UInt64 { UInt64(milliseconds) * 1_000_000 }

    /// Seconds as the nanoseconds `Task.sleep` takes, for an interval — like the
    /// control poll's — that grows while it is being waited out.
    static func nanoseconds(seconds: TimeInterval) -> UInt64 { UInt64(seconds * 1_000_000_000) }
}
