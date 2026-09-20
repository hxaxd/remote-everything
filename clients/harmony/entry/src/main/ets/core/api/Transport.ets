// Talking to a gateway: RCP, one session per origin.
//
// RCP is used rather than `http` for two reasons the old clients paid for: a request
// can actually be cancelled (session.cancel) and it carries a client certificate with
// a pinning rule of its own. The session is per origin — which is also where the
// certificate belongs — so two gateways cannot share a connection pool or a key.
//
// The archive is opened into memory (HuksVault), handed to RCP as `content` (an ArrayBuffer, never a
// file path), and this client's copy of it is wiped immediately after the session
// holds it. The session is dropped when it is no longer being used — a forgotten
// gateway, a 401, a network change, the app going to the background — so the material
// does not sit in memory for longer than it is needed.
//
// What makes a session safe to open — the pin a LAN gateway's invitation carried, the
// platform's own verification for a gateway with a domain — lives beside this file in
// core/api/SessionSecurity, next to the pinning decision it builds on.

import { rcp } from '@kit.RemoteCommunicationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { ServerPin } from '../model/Models';
import { Cadence } from '../model/Cadence';
import { ClientError } from '../model/Errors';
import { anonymousSecurity, lastPinFailureReason, pinnedSecurity } from './SessionSecurity';
import { RcpPool } from './RcpPool';

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
        this.sessionConfiguration(this.requestConfiguration(Cadence.requestTimeoutMs,
          this.security(identity, host))));
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
    try {
      const response: rcp.Response = await session.fetch(rcpRequest);
      return this.replyOf(response);
    } catch (error) {
      throw this.translate(error);
    }
  }

  /** One request on a session of its own, for the request that arrives without a credential. */
  async sendAnonymous(origin: string, pin: ServerPin | null, request: ApiRequest,
    extraHeaders: Record<string, string> = {}): Promise<ApiReply> {
    const host: string = hostOf(origin);
    const sessionConfiguration: rcp.SessionConfiguration =
      this.sessionConfiguration(this.requestConfiguration(request.timeoutMs, anonymousSecurity(pin, host)));
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
      this.sessionConfiguration(this.requestConfiguration(timeoutMs, anonymousSecurity(noPin)));
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

  /** One origin's own security: the device certificate, and the pin when there is one. */
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
    const pinned: rcp.SecurityConfiguration = pinnedSecurity(identity.serverPin, host);
    pinned.certificate = certificate;
    return pinned;
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
      const reason: string | null = lastPinFailureReason();
      return ClientError.transport(reason !== null
        ? `the gateway certificate does not match: ${reason}`
        : 'the gateway did not present the certificate this device expects');
    }
    if (code !== undefined) {
      return ClientError.transport(`the request failed with ${code}`);
    }
    return ClientError.transport('the request failed');
  }
}

function hostOf(url: string): string {
  const scheme: number = url.indexOf('://');
  if (scheme < 0) {
    return '';
  }
  let authority: string = url.substring(scheme + 3);
  const stop: number = firstIndexOf(authority, ['/', '?', '#']);
  if (stop >= 0) {
    authority = authority.substring(0, stop);
  }
  if (authority.includes('@')) {
    authority = authority.substring(authority.indexOf('@') + 1);
  }
  if (authority.startsWith('[')) {
    const close: number = authority.indexOf(']');
    return close < 0 ? '' : authority.substring(0, close + 1);
  }
  const colon: number = authority.lastIndexOf(':');
  return colon < 0 ? authority : authority.substring(0, colon);
}

function firstIndexOf(text: string, needles: string[]): number {
  let found: number = -1;
  for (const needle of needles) {
    const at: number = text.indexOf(needle);
    if (at >= 0 && (found < 0 || at < found)) {
      found = at;
    }
  }
  return found;
}
