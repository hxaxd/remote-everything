// Every refusal the wire can carry, plus the one failure that has no code on the
// wire: a request that never got an answer. The list is
// contracts/schemas/errors.schema.json enumerated, with `stop_command_failed` and
// `state_update_failed` from control.schema.json, and `network` standing for the
// row ui-contract §3 keeps for transport failures.
//
// The code decides what a client does and what it says; the prose the gateway sends
// is never read. A code maps to a resource key, and the resource file is where the
// words live — an error object carries no user-facing text.

export enum ErrorCode {
  Network = 'network',
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
  InternalError = 'internal_error',
  StopCommandFailed = 'stop_command_failed',
  StateUpdateFailed = 'state_update_failed'
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
  'internal_error',
  'stop_command_failed',
  'state_update_failed'
];

/** Reads a code strictly: an unknown one is not a code this client knows. */
export function parseErrorCode(value: string): ErrorCode | null {
  if (!WIRE_CODES.includes(value)) {
    return null;
  }
  return value as ErrorCode;
}

/**
 * A refusal or a failure, typed. `httpStatus` is 0 when no answer arrived at all,
 * and `retryAfterMs` is set only where the gateway said when to come back.
 */
export class ClientError extends Error {
  readonly code: ErrorCode;
  readonly httpStatus: number;
  readonly retryAfterMs: number;

  constructor(code: ErrorCode, httpStatus: number, detail: string, retryAfterMs: number = 0) {
    super(detail);
    this.code = code;
    this.httpStatus = httpStatus;
    this.retryAfterMs = retryAfterMs;
  }

  static transport(detail: string): ClientError {
    return new ClientError(ErrorCode.Network, 0, detail);
  }

  /** A failure in this client rather than in the gateway or the network. */
  static client(detail: string): ClientError {
    return new ClientError(ErrorCode.InvalidBody, 0, detail);
  }

  get isTransport(): boolean {
    return this.code === ErrorCode.Network;
  }

  get isApprovalPending(): boolean {
    return this.code === ErrorCode.ApprovalPending;
  }
}
