// Talking to a gateway: RCP, one session per origin, cancellation that cancels.
//
// RCP is used rather than `http` for two reasons the old clients paid for: a request
// can actually be cancelled (`session.cancel`, error 1007900992) and it carries a
// client certificate with a pinning rule of its own. The session is per origin —
// which is also where the certificate belongs — so two gateways cannot share a
// connection pool or a key.
//
// The archive is opened into memory (HuksVault), handed to RCP as `content` (an ArrayBuffer, never a
// file path), and this client's copy of it is wiped immediately after the session
// holds it. The session is dropped when it is no longer being used — a forgotten
// gateway, a 401, a network change, the app going to the background — so the material
// does not sit in memory for longer than it is needed.
//
// Server certificates:
//   * a gateway that signs its own certificate (a LAN entrance) is verified against
//     the pin its invitation carried: the public key the platform pins, and this
//     client's own check of the public key or the certificate fingerprint. Nothing
//     else is accepted, and there is no way to continue past a mismatch.
//   * a gateway with a domain uses the platform's own verification, and carries no
//     pin: its certificate is renewed by whoever signs it, and pinning a CA is how a
//     client locks itself out.

import { rcp } from '@kit.RemoteCommunicationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { cert } from '@kit.DeviceCertificateKit';
import { ServerPin } from '../model/Models';
import { Cadence } from '../model/Cadence';
import { certificateMatchesPin } from '../identity/Pinning';
import { ClientError } from './Errors';

const CANCELED = 1007900992;
const SESSION_CLOSED = 1007900993;
const PIN_MISMATCH = 1007900090;

export class ApiRequest {
  readonly method: string;
  readonly path: string;
  readonly nodeId: string | null;
  readonly body: string | null;
  readonly timeoutMs: number;

  constructor(method: string, path: string, nodeId: string | null, body: string | null, timeoutMs: number) {
    this.method = method;
    this.path = path;
    this.nodeId = nodeId;
    this.body = body;
    this.timeoutMs = timeoutMs;
  }
}

export class ApiReply {
  readonly status: number;
  readonly body: string;
  readonly location: string | null;
  readonly retryAfterSeconds: number;

  constructor(status: number, body: string, location: string | null, retryAfterSeconds: number) {
    this.status = status;
    this.body = body;
    this.location = location;
    this.retryAfterSeconds = retryAfterSeconds;
  }

  get ok(): boolean {
    return this.status >= 200 && this.status < 300;
  }
}

/** The material one origin's session is built from. */
export class SessionIdentity {
  readonly certificate: ArrayBuffer;
  readonly password: string;
  readonly serverPin: ServerPin | null;

  constructor(certificate: ArrayBuffer, password: string, serverPin: ServerPin | null) {
    this.certificate = certificate;
    this.password = password;
    this.serverPin = serverPin;
  }
}

interface PinnedDecision {
  readonly accepted: boolean;
  readonly reason: string;
}

function pemToDer(pem: string): Uint8Array | null {
  const begin: number = pem.indexOf('-----BEGIN CERTIFICATE-----');
  const end: number = pem.indexOf('-----END CERTIFICATE-----');
  if (begin < 0 || end < 0 || end <= begin) {
    return null;
  }
  const body: string = pem.substring(begin + '-----BEGIN CERTIFICATE-----'.length, end).replace(/\s+/g, '');
  try {
    const helper: util.Base64Helper = new util.Base64Helper();
    return helper.decodeSync(body, util.Type.BASIC);
  } catch (error) {
    return null;
  }
}

/**
 * A pinned gateway's certificate, checked against what its invitation said. The
 * decision itself lives in core/identity/Pinning so the API plane and the WebView
 * cannot disagree about it.
 */
export function pinDecision(chainPem: string[], pin: ServerPin, host?: string): PinnedDecision {
  if (chainPem.length === 0) {
    return { accepted: false, reason: 'the gateway presented no certificate' };
  }
  const leaf: Uint8Array | null = pemToDer(chainPem[0]);
  if (leaf === null) {
    return { accepted: false, reason: 'the gateway certificate could not be read' };
  }
  if (certificateMatchesPin(leaf, pin, host)) {
    return { accepted: true, reason: 'the certificate this device was told to expect' };
  }
  return { accepted: false, reason: 'the gateway presents a certificate this device was not told to expect' };
}

/** The platform's own validity strings are `YYYYMMDDHHMMSSZ`, which sorts as text. */
function utcStampNow(): string {
  const now: Date = new Date();
  const pad = (value: number): string => value < 10 ? `0${value}` : `${value}`;
  return `${now.getUTCFullYear()}${pad(now.getUTCMonth() + 1)}${pad(now.getUTCDate())}` +
    `${pad(now.getUTCHours())}${pad(now.getUTCMinutes())}${pad(now.getUTCSeconds())}Z`;
}

function withinValidity(notBefore: string, notAfter: string): boolean {
  const now: string = utcStampNow();
  return now >= notBefore && now <= notAfter;
}

/**
 * Whether one self-signed gateway's certificate may be used: the key the invitation
 * named or the certificate it named, and — when the platform hands over a readable
 * validity window — that the certificate is current.
 */
function pinnedAccepted(chainPem: string[], chain: cert.X509Cert[], pin: ServerPin, host?: string): boolean {
  if (!pinDecision(chainPem, pin, host).accepted) {
    return false;
  }
  if (chain.length === 0) {
    return true;
  }
  try {
    return withinValidity(chain[0].getNotBeforeTime(), chain[0].getNotAfterTime());
  } catch (error) {
    // The window could not be read; the pin still stands.
    return true;
  }
}

import { RcpPool } from './RcpPool';

export class Transport {
  private readonly pool: RcpPool = new RcpPool();

  /** Whether this origin already has a session. */
  has(origin: string): boolean {
    return this.pool.has(origin);
  }

  /**
   * Opens a session for one origin. The identity material is copied into the session,
   * and the caller wipes what it handed over.
   */
  open(origin: string, identity: SessionIdentity): void {
    try {
      const host: string = hostOf(origin);
      const session: rcp.Session = rcp.createSession(
        this.sessionConfiguration(this.requestConfiguration(Cadence.requestTimeoutMs, this.security(identity, host))));
      this.pool.set(origin, session);
    } catch (error) {
      throw ClientError.client('the transport refused to open a session');
    }
  }

  /** Drops a session, and with it the key material RCP was handed. */
  close(origin: string): void {
    this.pool.close(origin);
  }

  closeAll(): void {
    this.pool.closeAll();
  }

  /** Cancels whatever is in flight for one origin. The call itself returns at once. */
  cancel(origin: string): void {
    this.pool.cancelInflight(origin);
  }

  async send(origin: string, request: ApiRequest): Promise<ApiReply> {
    const session: rcp.Session | undefined = this.pool.get(origin);
    if (session === undefined) {
      throw ClientError.transport('this gateway has no open session');
    }
    const url: string = `${origin}${request.path}`;
    if (!url.startsWith(`${origin}/`)) {
      throw ClientError.client('a request was built for another origin');
    }
    const headers: Record<string, string> = this.headersFor(request);
    const rcpRequest: rcp.Request = new rcp.Request(url, request.method, headers,
      request.body === null ? undefined : request.body);
    const configuration: rcp.Configuration = {
      // No redirect is followed here either; the session's own security configuration
      // still applies to this request.
      transfer: { autoRedirect: false, timeout: { connectMs: request.timeoutMs, transferMs: request.timeoutMs } }
    };
    rcpRequest.configuration = configuration;
    this.pool.setInflight(origin, rcpRequest);
    try {
      const response: rcp.Response = await session.fetch(rcpRequest);
      return this.replyOf(response);
    } catch (error) {
      throw this.translate(error);
    } finally {
      this.pool.clearInflight(origin);
    }
  }

  /** One request on a session of its own, for the request that arrives without a credential. */
  async sendAnonymous(origin: string, pin: ServerPin | null, request: ApiRequest,
    extraHeaders: Record<string, string> = {}): Promise<ApiReply> {
    const host: string = hostOf(origin);
    const sessionConfiguration: rcp.SessionConfiguration =
      this.sessionConfiguration(this.requestConfiguration(request.timeoutMs, this.anonymousSecurity(pin, host)));
    let probe: rcp.Session;
    try {
      probe = rcp.createSession(sessionConfiguration);
    } catch (error) {
      throw ClientError.client('the transport refused to open a session');
    }
    try {
      const url: string = `${origin}${request.path}`;
      if (!url.startsWith(`${origin}/`)) {
        throw ClientError.client('a request was built for another origin');
      }
      const headers: Record<string, string> = this.headersFor(request);
      const extra: string[] = Object.keys(extraHeaders);
      for (let i = 0; i < extra.length; i++) {
        headers[extra[i]] = extraHeaders[extra[i]];
      }
      const rcpRequest: rcp.Request = new rcp.Request(url, request.method, headers,
        request.body === null ? undefined : request.body);
      const response: rcp.Response = await probe.fetch(rcpRequest);
      return this.replyOf(response);
    } catch (error) {
      throw this.translate(error);
    } finally {
      try {
        probe.close();
      } catch (error) {
        // Nothing to release.
      }
    }
  }

  /**
   * One document from somewhere that is not a gateway — the release manifest, which is
   * read by devices that have never paired and therefore carries no credential.
   */
  async fetchDocument(url: string, timeoutMs: number): Promise<string> {
    const noPin: ServerPin | null = null;
    const sessionConfiguration: rcp.SessionConfiguration =
      this.sessionConfiguration(this.requestConfiguration(timeoutMs, this.anonymousSecurity(noPin)));
    let session: rcp.Session;
    try {
      session = rcp.createSession(sessionConfiguration);
    } catch (error) {
      throw ClientError.client('the transport refused to open a session');
    }
    try {
      const headers: Record<string, string> = { 'accept': 'application/json' };
      const request: rcp.Request = new rcp.Request(url, 'GET', headers);
      const response: rcp.Response = await session.fetch(request);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ClientError.transport('the release channel answered no document');
      }
      return this.readBody(response.body);
    } catch (error) {
      if (error instanceof ClientError) {
        throw error;
      }
      throw this.translate(error);
    } finally {
      try {
        session.close();
      } catch (error) {
        // Nothing to release.
      }
    }
  }

  private headersFor(request: ApiRequest): Record<string, string> {
    const headers: Record<string, string> = { 'accept': 'application/json' };
    if (request.nodeId !== null) {
      headers['X-Remote-Everything-Node'] = request.nodeId;
    }
    if (request.body !== null) {
      headers['content-type'] = 'application/json';
    }
    return headers;
  }

  private replyOf(response: rcp.Response): ApiReply {
    return new ApiReply(response.statusCode, this.readBody(response.body), this.header(response, 'location'),
      this.retryAfterSeconds(response));
  }

  private sessionConfiguration(requestConfiguration: rcp.Configuration): rcp.SessionConfiguration {
    const connections: rcp.ConnectionConfiguration = { maxConnectionsPerHost: 4, maxTotalConnections: 8 };
    const configuration: rcp.SessionConfiguration = {
      requestConfiguration: requestConfiguration,
      connectionConfiguration: connections
    };
    return configuration;
  }

  private anonymousSecurity(pin: ServerPin | null, host?: string): rcp.SecurityConfiguration {
    if (pin === null) {
      const plain: rcp.SecurityConfiguration = { remoteValidation: 'system' };
      return plain;
    }
    return this.pinnedSecurity(pin, host);
  }

  private security(identity: SessionIdentity, host?: string): rcp.SecurityConfiguration {
    const certificate: rcp.ClientCertificate = {
      content: identity.certificate,
      type: 'P12',
      keyPassword: identity.password
    };
    if (identity.serverPin === null) {
      // A gateway with a domain: the platform's own verification, and no pin — its
      // certificate is renewed by whoever signs it.
      const verified: rcp.SecurityConfiguration = { remoteValidation: 'system', certificate: certificate };
      return verified;
    }
    const pinned: rcp.SecurityConfiguration = this.pinnedSecurity(identity.serverPin, host);
    pinned.certificate = certificate;
    return pinned;
  }

  /**
   * A self-signed gateway's security: the platform pins the public key the invitation
   * named, and this client's own validation accepts that key or the certificate's
   * fingerprint. The system's trust store has never heard of this gateway, so the CA
   * chain is not what decides here.
   */
  private pinnedSecurity(pin: ServerPin, host?: string): rcp.SecurityConfiguration {
    const pinning: rcp.CertificatePinning[] = [
      { kind: 'public-key', publicKeyHash: pin.publicKeyPin, hashAlgorithm: 'SHA-256' }
    ];
    const validate: rcp.ValidationCallback = (context: rcp.ValidationContext): boolean =>
      pinnedAccepted(context.pemCerts, context.x509Certs, pin, host);
    const security: rcp.SecurityConfiguration = {
      remoteValidation: validate,
      certificatePinning: pinning
    };
    return security;
  }

  /**
   * How the transport treats an answer: refusals arrive as bodies this client reads
   * itself, and no redirect is ever followed (pitfalls §4). The security configuration
   * is per session, so the certificate and the pin travel with it.
   */
  private requestConfiguration(timeoutMs: number, security: rcp.SecurityConfiguration): rcp.Configuration {
    const validate: rcp.ResponseValidationCallback = (): boolean => true;
    const processing: rcp.ProcessingConfiguration = { validateResponse: validate };
    const configuration: rcp.Configuration = {
      processing: processing,
      security: security,
      transfer: { autoRedirect: false, timeout: { connectMs: timeoutMs, transferMs: timeoutMs } }
    };
    return configuration;
  }

  private readBody(body: ArrayBuffer | undefined): string {
    if (body === undefined || body.byteLength === 0) {
      return '';
    }
    try {
      return new util.TextDecoder().decodeToString(new Uint8Array(body));
    } catch (error) {
      return '';
    }
  }

  private header(response: rcp.Response, name: string): string | null {
    const value: string | string[] | undefined = response.headers[name];
    if (value === undefined) {
      return null;
    }
    if (typeof value === 'string') {
      return value;
    }
    return value.length > 0 ? value[0] : null;
  }

  private retryAfterSeconds(response: rcp.Response): number {
    const value: string | null = this.header(response, 'retry-after');
    if (value === null) {
      return 0;
    }
    const parsed: number = Number.parseInt(value.trim(), 10);
    if (Number.isNaN(parsed) || parsed < 0) {
      return 0;
    }
    return parsed;
  }

  /** A transport failure is typed like everything else: no caller reads a message. */
  private translate(error: Object): ClientError {
    const business: BusinessError = error as BusinessError;
    const code: number | undefined = business.code;
    if (code === CANCELED || code === SESSION_CLOSED) {
      return ClientError.transport('the request was cancelled');
    }
    if (code === PIN_MISMATCH) {
      return ClientError.transport('the gateway did not present the certificate this device expects');
    }
    if (code !== undefined) {
      return ClientError.transport(`the request failed with ${code}`);
    }
    return ClientError.transport('the request failed');
  }
}
