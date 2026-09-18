package com.remoteeverything.core.model

/**
 * How often this client looks at things, and how long it waits. These are the
 * numbers all three clients share — a node list refreshed every minute on one
 * platform and every five on another is two products rather than one — and
 * `clients/behavior/fixtures/cadence.json` is where they are written down: a test
 * asserts this object against it, so a cadence changed here alone does not pass.
 */
object Cadence {
    /** The node list while the app is in the foreground. */
    const val nodeRefreshMs = 60_000L

    /** One node's applications while its screen is open. */
    const val catalogRefreshMs = 30_000L

    /** After a start or a stop: from here, times this factor, up to the ceiling. */
    const val controlPollMs = 1_000L
    const val controlPollFactor = 1.5
    const val controlPollCeilingMs = 5_000L

    /** How long a start or a stop is waited for before the screen stops asking. */
    const val controlPollTimeoutMs = 60_000L

    /** A device that paired and is waiting for its operator. */
    const val approvalPollMs = 5_000L
    const val approvalPollTimeoutMs = 600_000L

    /**
     * How long a staged pairing is treated as alive when the gateway's own expiry
     * could not be read: the invitation lifetime it hands out by default.
     */
    const val pendingFallbackMs = 600_000L

    /** How long a path is given to answer while it is being probed. */
    const val probeTimeoutMs = 2_000L

    /** Everything that is not a probe: a catalog, an action, an open. */
    const val requestTimeoutMs = 10_000L
}
