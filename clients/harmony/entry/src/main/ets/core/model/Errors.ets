// Every refusal the wire can carry, matching contracts/schemas/errors.schema.json
// exactly: nineteen codes, none added, none dropped.
//
// The code decides what a client does and what it says; the prose the gateway sends
// is never read. A code maps to a resource key, and the resource file is where the
// words live — an error object carries no user-facing text.

export enum ErrorCode {
  NodeRequired = 'node_required',
  Unauthorized = 'unauthorized',
  InvitationDenied = 'invitation_denied',
  InvitationExpired = 'invitation_expired',
  ApprovalPending = 'approval_pending',
  NodeNotFound = 'node_not_found',
  AppNotFound = 'app_not_found',
  NotFound = 'not_found',
  Forbidden = 'forbidden',
  ComputerOffline = 'computer_offline',
  ActivationFailed = 'activation_failed',
  InvalidDeviceName = 'invalid_device_name',
  InvalidCredentialPassword = 'invalid_credential_password',
  InvalidBody = 'invalid_body',
  InvalidJson = 'invalid_json',
  RateLimited = 'rate_limited',
  ServerBusy = 'server_busy',
  PairingFailed = 'pairing_failed',
  InternalError = 'internal_error'
}

const WIRE_CODES: string[] = [
  'node_required',
  'unauthorized',
  'invitation_denied',
  'invitation_expired',
  'approval_pending',
  'node_not_found',
  'app_not_found',
  'not_found',
  'forbidden',
  'computer_offline',
  'activation_failed',
  'invalid_device_name',
  'invalid_credential_password',
  'invalid_body',
  'invalid_json',
  'rate_limited',
  'server_busy',
  'pairing_failed',
  'internal_error'
];

/** Reads a code strictly: an unknown one is not a code this client knows. */
export function parseErrorCode(value: string): ErrorCode | null {
  if (!WIRE_CODES.includes(value)) {
    return null;
  }
  return value as ErrorCode;
}

/**
 * A refusal below the protocol: DNS, TLS, timeout, unreachable host.
 */
export class NetworkError extends Error {
  constructor(detail: string) {
    super(detail);
    this.name = 'NetworkError';
  }
}

/**
 * A failure in this client decoding or validating the wire format.
 */
export class WireProtocolError extends Error {
  constructor(detail: string) {
    super(detail);
    this.name = 'WireProtocolError';
  }
}

/**
 * A failure in this client's own credential handling: opening, installing or
 * reading the certificate a pairing left behind. It carries no user-facing text —
 * the app layer maps a failure to a resource key, the same way it does for the
 * wire's codes.
 */
export class CredentialError extends Error {
  readonly detail: string;

  constructor(detail: string) {
    super(detail);
    this.detail = detail;
  }
}

/**
 * Which side of the request failed: the wire, which answered nothing, or this
 * client, which could not make sense of what came back. Neither side leaves a
 * code or a status behind, so the two look alike in the error itself — and the
 * difference is what a person reading a report acts on, because one of them is
 * the deployment and the other is this build.
 */
export enum FailureSide {
  Wire = 'wire',
  Client = 'client'
}

/**
 * A refusal from the wire: the code drives presentation, never prose.
 * Matches contracts/schemas/errors.schema.json.
 */
export class ClientError extends Error {
  readonly code: ErrorCode | null;
  readonly httpStatus: number;
  readonly retryAfterMs: number;
  readonly side: FailureSide;

  constructor(code: ErrorCode | null, httpStatus: number, detail: string, retryAfterMs: number = 0,
              side: FailureSide = FailureSide.Wire) {
    super(detail);
    this.name = 'ClientError';
    this.code = code;
    this.httpStatus = httpStatus;
    this.retryAfterMs = retryAfterMs;
    this.side = side;
  }

  /** A transport failure below HTTP or at connection time. */
  static transport(detail: string): ClientError {
    return new ClientError(null, 0, detail);
  }

  /** A refusal strictly parsed from the wire body. */
  static refusal(code: ErrorCode, httpStatus: number, detail: string = '', retryAfterMs: number = 0): ClientError {
    return new ClientError(code, httpStatus, detail || `refused: ${code}`, retryAfterMs);
  }

  /** A client-side decoding failure. Does not forge ErrorCode.InvalidBody. */
  static client(detail: string): ClientError {
    return new ClientError(null, 0, detail, 0, FailureSide.Client);
  }

  get isTransport(): boolean {
    return this.code === null;
  }

  get isApprovalPending(): boolean {
    return this.code === ErrorCode.ApprovalPending;
  }
}
