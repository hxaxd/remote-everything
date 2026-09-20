// How often this client looks at things, and how long it waits.
//
// These are the numbers all three clients share — a node list refreshed every minute
// on one platform and every five on another is two products rather than one — and
// `clients/behavior/fixtures/cadence.json` is where they are written down: the
// behaviour test reads that fixture and asserts this object against it, so a cadence
// changed here alone does not pass. This file is a copy of the same table in the other
// two clients, constant for constant.
//
// A duration in this table is a promise to the person holding the phone, not a
// tuning knob: the refresh is how stale a screen may be, the poll ceiling is how
// often a busy row may cost a request, and the timeouts are when the client stops
// asking and says something.

export class Cadence {
  /** The node list while the app is in the foreground. */
  static readonly nodeRefreshMs: number = 60000;

  /** One node's applications while its screen is open. */
  static readonly catalogRefreshMs: number = 30000;

  /** After a start or a stop: from here, times this factor, up to the ceiling. */
  static readonly controlPollMs: number = 1000;
  static readonly controlPollFactor: number = 1.5;
  static readonly controlPollCeilingMs: number = 5000;

  /** How long a start or a stop is waited for before the screen stops asking. */
  static readonly controlPollTimeoutMs: number = 60000;

  /** A device that paired and is waiting for its operator. */
  static readonly approvalPollMs: number = 5000;
  static readonly approvalPollTimeoutMs: number = 600000;

  /** How long a path is given to answer while it is being probed. */
  static readonly probeTimeoutMs: number = 2000;

  /** Everything that is not a probe: a catalog, an action, an open. */
  static readonly requestTimeoutMs: number = 10000;
}
