// Why one connection is not answering.
//
// "Offline" is one word for three different situations: this device has no
// network, the gateway cannot be reached from where it stands, or the gateway is
// answering and refusing. Only the last one is about the deployment; the first is
// the device's own business. Keeping the failure — not just a count of failures —
// is what lets a screen and a report say which one it is.
//
// What the person does with this is copy it: an installation that cannot be
// reached is a question for whoever runs the gateway, and the answer has to
// travel. So the report carries what a reader needs and the device happened to
// see, in that order: what this client is, what it was talking to, what went
// wrong, and what it knows about the network in between.
//
// The words are not here: every line is built from a message key through `say`,
// so the report comes out in the language the app is in. The keys are declared in
// core/model/MessageKeys.ets and the sentences live in the resource files.

import { ClientError, FailureSide, NetworkError, WireProtocolError } from '../model/Errors';
import { MessageKeys } from '../model/MessageKeys';

/** The five ways a connection can fail to answer. */
export enum TroubleKind {
  NoNetwork = 'no_network',
  Unreachable = 'unreachable',
  Refused = 'refused',
  BadAnswer = 'bad_answer',
  Unknown = 'unknown'
}

/** Why one connection is not answering, as of its last probe. */
export class LinkTrouble {
  readonly kind: TroubleKind;
  /** When the last failed probe ran. */
  readonly at: number;
  /** When the failures started: the difference between a blip and a state. */
  readonly since: number;
  readonly attempts: number;
  readonly code: string | null;
  readonly httpStatus: number | null;
  readonly detail: string | null;
  readonly lastGoodAt: number | null;

  constructor(kind: TroubleKind, at: number, since: number, attempts: number, code: string | null = null,
              httpStatus: number | null = null, detail: string | null = null,
              lastGoodAt: number | null = null) {
    this.kind = kind;
    this.at = at;
    this.since = since;
    this.attempts = attempts;
    this.code = code;
    this.httpStatus = httpStatus;
    this.detail = detail;
    this.lastGoodAt = lastGoodAt;
  }
}

/** One failed probe, kept so a report can show a run rather than a moment. */
export class LinkAttempt {
  readonly at: number;
  readonly kind: TroubleKind;

  constructor(at: number, kind: TroubleKind) {
    this.at = at;
    this.kind = kind;
  }
}

/** A classified failure: what it was, and whatever the wire said about it. */
export class LinkFailure {
  readonly kind: TroubleKind;
  readonly code: string | null;
  readonly httpStatus: number | null;
  readonly detail: string | null;

  constructor(kind: TroubleKind, code: string | null = null, httpStatus: number | null = null,
              detail: string | null = null) {
    this.kind = kind;
    this.code = code;
    this.httpStatus = httpStatus;
    this.detail = detail;
  }
}

/**
 * Everything a report says, gathered where the platform can answer it: the
 * version lines come from the build, the system line from the platform's device
 * information, the network line from the platform's own idea of the network, and
 * the rest from what this client remembers about the connection.
 */
export class LinkReportInput {
  readonly appName: string;
  readonly client: string;
  readonly protocol: string;
  readonly system: string;
  readonly origin: string;
  readonly deviceName: string;
  readonly network: string;
  readonly machines: string[];
  readonly trouble: LinkTrouble;
  readonly attempts: LinkAttempt[];
  readonly time: (at: number) => string;

  constructor(appName: string, client: string, protocol: string, system: string, origin: string,
              deviceName: string, network: string, machines: string[], trouble: LinkTrouble,
              attempts: LinkAttempt[], time: (at: number) => string) {
    this.appName = appName;
    this.client = client;
    this.protocol = protocol;
    this.system = system;
    this.origin = origin;
    this.deviceName = deviceName;
    this.network = network;
    this.machines = machines;
    this.trouble = trouble;
    this.attempts = attempts;
    this.time = time;
  }
}

/** How many failed probes a report keeps: enough to show a pattern, not a log. */
export const LINK_ATTEMPTS_KEPT: number = 4;

/** Longest detail a report carries; the rest is noise about noise. */
const DETAIL_CHARS: number = 200;

/**
 * Classifies one failure. `offline` is the platform's answer to "is there any
 * network this device could be using at all": with nothing to send on, every
 * connection fails the same way, and that is worth saying before anything else.
 */
export function classifyFailure(failure: ClientError | NetworkError | WireProtocolError | Error,
                               offline: boolean): LinkFailure {
  if (offline) {
    return new LinkFailure(TroubleKind.NoNetwork, null, null, describe(failure));
  }
  if (failure instanceof ClientError) {
    if (failure.code !== null) {
      // The code is the wire's own word for the refusal (Errors.ets), so it travels as it is.
      return new LinkFailure(TroubleKind.Refused, failure.code, failure.httpStatus, describe(failure));
    }
    if (failure.side === FailureSide.Client) {
      // Something came back and this client could not read it: protocol drift, not a network.
      return new LinkFailure(TroubleKind.BadAnswer, null, null, describe(failure));
    }
    return new LinkFailure(TroubleKind.Unreachable, null, null, describe(failure));
  }
  if (failure instanceof WireProtocolError) {
    return new LinkFailure(TroubleKind.BadAnswer, null, null, describe(failure));
  }
  if (failure instanceof NetworkError) {
    return new LinkFailure(TroubleKind.Unreachable, null, null, describe(failure));
  }
  return new LinkFailure(TroubleKind.Unknown, null, null, describe(failure));
}

/**
 * The failure, named. "the request failed" says nothing a reader can use; "the
 * gateway did not present the certificate this device expects" says which hop
 * stopped answering, which is the difference between a guess and a report. ArkTS
 * has no cause chain to walk: this client's errors are built where they happen,
 * with the detail already in hand.
 */
export function describe(failure: ClientError | NetworkError | WireProtocolError | Error): string {
  let name: string = 'Error';
  let message: string = '';
  try {
    const given: string = failure.name !== undefined ? `${failure.name}` : '';
    name = given.length > 0 ? given : 'Error';
    message = failure.message !== undefined ? `${failure.message}`.trim() : '';
  } catch (error) {
    // A thrown value that is not an Error has no name and no message to read.
    return 'unknown failure';
  }
  if (message.length === 0) {
    return name;
  }
  const detail: string = message.length > DETAIL_CHARS ? `${message.substring(0, DETAIL_CHARS)}…` : message;
  return `${name}: ${detail}`;
}

/** What this kind of failure is called, as a message key. */
export function linkKindKey(kind: TroubleKind): string {
  if (kind === TroubleKind.NoNetwork) {
    return MessageKeys.DIAG_CAUSE_NO_NETWORK;
  }
  if (kind === TroubleKind.Unreachable) {
    return MessageKeys.DIAG_CAUSE_UNREACHABLE;
  }
  if (kind === TroubleKind.Refused) {
    return MessageKeys.DIAG_CAUSE_REFUSED;
  }
  if (kind === TroubleKind.BadAnswer) {
    return MessageKeys.DIAG_CAUSE_BAD_ANSWER;
  }
  return MessageKeys.DIAG_CAUSE_UNKNOWN;
}

/**
 * The report itself: one line per fact, each starting with a word for what the
 * line is — a screen reader's shape, and the shape a person pastes into a message
 * without editing it first. `say` resolves a message key, with an argument when
 * the key takes one.
 */
export function buildLinkReport(input: LinkReportInput, say: (key: string, arg: string | null) => string): string {
  const trouble: LinkTrouble = input.trouble;
  const title: string = say(MessageKeys.DIAG_TITLE, null);
  const lines: string[] = [];

  lines.push(`${input.appName} · ${title}`);
  lines.push(`${say(MessageKeys.DIAG_CLIENT, null)} ${input.client} · ` +
    `${say(MessageKeys.SETTINGS_PROTOCOL_VERSION, null)} ${input.protocol}`);
  lines.push(`${say(MessageKeys.DIAG_SYSTEM, null)} ${input.system}`);
  lines.push(`${say(MessageKeys.DIAG_CONNECTION, null)} ${input.origin} · ` +
    `${say(MessageKeys.DIAG_DEVICE_NAME, null)} ${input.deviceName}`);

  // What is wrong, how long it has been wrong, and when it was last right: three
  // facts that together say whether this is new or a state of affairs.
  const state: string[] = [];
  state.push(say(linkKindKey(trouble.kind), null));
  state.push(say(MessageKeys.DIAG_FAILURES, `${trouble.attempts}`));
  state.push(say(MessageKeys.DIAG_SINCE, input.time(trouble.since)));
  if (trouble.lastGoodAt !== null) {
    state.push(say(MessageKeys.DIAG_LAST_ANSWER, input.time(trouble.lastGoodAt)));
  }
  lines.push(`${say(MessageKeys.DIAG_STATE, null)} ${state.join(' · ')}`);

  // The wire's own words, when there were any: a status and a code are what a
  // gateway-side reader can look up, and the detail names the hop that failed.
  const cause: string[] = [];
  if (trouble.detail !== null) {
    cause.push(trouble.detail);
  }
  if (trouble.httpStatus !== null) {
    cause.push(`HTTP ${trouble.httpStatus}`);
  }
  if (trouble.code !== null) {
    cause.push(trouble.code);
  }
  lines.push(`${say(MessageKeys.DIAG_CAUSE, null)} ${cause.length === 0 ? '—' : cause.join(' · ')}`);

  lines.push(`${say(MessageKeys.DIAG_NETWORK, null)} ${input.network}`);
  const separator: string = isChinese(`${input.appName}${title}`) ? '；' : '; ';
  if (input.machines.length > 0) {
    lines.push(`${say(MessageKeys.DIAG_MACHINES, null)} ${input.machines.join(separator)}`);
  }
  if (input.attempts.length > 0) {
    const attempts: string[] = input.attempts.map((attempt: LinkAttempt) =>
    `${input.time(attempt.at)} ${say(linkKindKey(attempt.kind), null)}`);
    lines.push(`${say(MessageKeys.DIAG_ATTEMPTS, null)} ${attempts.join(separator)}`);
  }
  return lines.join('\n');
}

/** Whether this text is written in Chinese, which decides the line separator. */
function isChinese(text: string): boolean {
  for (let index: number = 0; index < text.length; index += 1) {
    const code: number = text.charCodeAt(index);
    if (code >= 0x4e00 && code <= 0x9fff) {
      return true;
    }
  }
  return false;
}
