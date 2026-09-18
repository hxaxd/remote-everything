// The protocol: eight endpoints, and the codes they answer with turned into typed
// errors. Nothing above this file knows what a path or a status line is.
//
// Every request goes to the origin an identity was paired with — checked here, so an
// answer cannot steer a later request somewhere else. `open` is the one endpoint that
// answers with a redirect instead of a document, and the redirect is read rather than
// followed: the client resolves it against the gateway origin and hands the result to
// the WebView, which is what keeps a substituted `Location` from moving this client's
// certificate to another host.

import { ServerPin } from '../model/Models';
import { Cadence } from '../model/Cadence';
import { CredentialMaterial, IdentityVault } from '../identity/IdentityVault';
import { CredentialError } from '../identity/CredentialError';
import { CatalogAnswer, ControlAnswer, decodeCatalog, decodeControl, decodeNodes, decodePairing, failureCode,
  NodesAnswer, PairingAnswer } from './Dto';
import { ClientError, ErrorCode } from './Errors';
import { ApiReply, ApiRequest, SessionIdentity, Transport } from './Transport';

const PAIR_PATH = '/__remote_everything_pair';
const ACTIVATE_PATH = '/__remote_everything_activate';
const NODES_PATH = '/__remote_everything/nodes';

/** What an activation answered: admitted, still waiting, or refused. */
export class Activation {
  readonly catalog: CatalogAnswer | null;
  readonly pending: boolean;
  readonly failure: ClientError | null;

  private constructor(catalog: CatalogAnswer | null, pending: boolean, failure: ClientError | null) {
    this.catalog = catalog;
    this.pending = pending;
    this.failure = failure;
  }

  static admitted(catalog: CatalogAnswer): Activation {
    return new Activation(catalog, false, null);
  }

  static waiting(): Activation {
    return new Activation(null, true, null);
  }

  static refused(error: ClientError): Activation {
    return new Activation(null, false, error);
  }
}

/** Which gateway and node a request is for: the identity names both. */
export class GatewayTarget {
  readonly origin: string;
  readonly nodeId: string;
  readonly serverPin: ServerPin | null;

  constructor(origin: string, nodeId: string, serverPin: ServerPin | null) {
    this.origin = origin;
    this.nodeId = nodeId;
    this.serverPin = serverPin;
  }
}

export class ProtocolClient {
  private readonly transport: Transport = new Transport();
  private readonly vault: IdentityVault;

  constructor(vault: IdentityVault) {
    this.vault = vault;
  }

  /** Opens (or refreshes) the session for one gateway. Sessions are not opened twice. */
  async connect(origin: string, serverPin: ServerPin | null): Promise<void> {
    if (this.transport.has(origin)) {
      return;
    }
    const material: CredentialMaterial = await this.vault.material(origin);
    try {
      const identity: SessionIdentity = new SessionIdentity(copyOf(material.archive), material.password, serverPin);
      this.transport.open(origin, identity);
    } finally {
      material.wipe();
    }
  }

  release(origin: string): void {
    this.transport.close(origin);
  }

  releaseAll(): void {
    this.transport.closeAll();
  }

  cancel(origin: string): void {
    this.transport.cancel(origin);
  }

  /** Redeems an invitation. The one request that carries no credential. */
  async pair(origin: string, invitation: string, deviceName: string, credentialPassword: string,
    serverPin: ServerPin | null): Promise<PairingAnswer> {
    const body: string = JSON.stringify({
      device_name: deviceName,
      credential_password: credentialPassword
    });
    // Pairing is the one request a gateway accepts without a credential: the
    // invitation is what it carries instead, in the header the server reads it from.
    const request: ApiRequest = new ApiRequest('POST', PAIR_PATH, null, body, Cadence.requestTimeoutMs);
    const reply: ApiReply = await this.transport.sendAnonymous(origin, serverPin, request,
      { 'authorization': `Invitation ${invitation}` });
    return this.answer(reply, 'the pairing answer', (text: string) => decodePairing(text));
  }

  /** Asks to be admitted for one node; being admitted answers with that node's catalog. */
  async activate(origin: string, nodeId: string): Promise<Activation> {
    const reply: ApiReply = await this.transport.send(origin,
      new ApiRequest('POST', ACTIVATE_PATH, nodeId, null, Cadence.requestTimeoutMs));
    if (reply.status === 202) {
      const code: ErrorCode | null = failureCode(reply.body);
      if (code === ErrorCode.ApprovalPending) {
        return Activation.waiting();
      }
      return Activation.refused(this.failure(reply, code));
    }
    return Activation.admitted(this.answer(reply, 'the activation answer', (text: string) => decodeCatalog(text)));
  }

  /**
   * Every node this device may reach through one gateway. Names no node, by design:
   * the answer is the whole list, and the same call is both the refresh and the probe,
   * so it is given the probe timeout rather than the ordinary one.
   */
  async nodes(origin: string, timeoutMs: number = Cadence.probeTimeoutMs): Promise<NodesAnswer> {
    const reply: ApiReply = await this.transport.send(origin, new ApiRequest('GET', NODES_PATH, null, null, timeoutMs));
    return this.answer(reply, 'the nodes answer', (text: string) => decodeNodes(text));
  }

  /** What one node runs. */
  async apps(origin: string, nodeId: string): Promise<CatalogAnswer> {
    const reply: ApiReply = await this.transport.send(origin,
      new ApiRequest('GET', `/__remote_everything/apps`, nodeId, null, Cadence.requestTimeoutMs));
    return this.answer(reply, 'the catalog answer', (text: string) => decodeCatalog(text));
  }

  async status(origin: string, nodeId: string, appId: string): Promise<ControlAnswer> {
    return this.control(origin, nodeId, appId, 'status');
  }

  async start(origin: string, nodeId: string, appId: string): Promise<ControlAnswer> {
    return this.control(origin, nodeId, appId, 'start');
  }

  async stop(origin: string, nodeId: string, appId: string): Promise<ControlAnswer> {
    return this.control(origin, nodeId, appId, 'stop');
  }

  /**
   * Where one application actually lives. The gateway answers a redirect to the
   * application's own origin, and that origin is what makes its browser storage
   * private to it; the client resolves the answer against the gateway origin and
   * refuses anything that does not lead back into this gateway.
   */
  async open(origin: string, nodeId: string, appId: string): Promise<string> {
    const reply: ApiReply = await this.transport.send(origin,
      new ApiRequest('GET', `/__remote_everything/open/${appId}`, nodeId, null, Cadence.requestTimeoutMs));
    if (reply.status !== 302) {
      const code: ErrorCode | null = failureCode(reply.body);
      throw this.failure(reply, code);
    }
    const location: string | null = reply.location;
    if (location === null || location === '') {
      throw ClientError.client('the gateway answered no location for an application');
    }
    const absolute: string = this.resolve(origin, location);
    if (!belongsToGateway(origin, absolute)) {
      throw ClientError.client('the gateway pointed at an origin that is not its own');
    }
    return absolute;
  }

  private async control(origin: string, nodeId: string, appId: string, action: string): Promise<ControlAnswer> {
    const method: string = action === 'status' ? 'GET' : 'POST';
    const reply: ApiReply = await this.transport.send(origin,
      new ApiRequest(method, `/__remote_everything/apps/${appId}/${action}`, nodeId, null, Cadence.requestTimeoutMs));
    return this.answer(reply, 'the control answer', (text: string) => decodeControl(text));
  }

  /**
   * One document from outside every gateway: the release manifest, which has to be
   * readable by a device that has never paired (ui-contract §5).
   */
  async fetchRelease(url: string, timeoutMs: number): Promise<string> {
    return await this.transport.fetchDocument(url, timeoutMs);
  }

  private resolve(origin: string, location: string): string {
    if (location.startsWith('https://')) {
      return location;
    }
    if (location.startsWith('/')) {
      return `${origin}${location}`;
    }
    return `${origin}/${location}`;
  }

  /** Any answer that is not a success is turned into a code, status and all. */
  private answer<T>(reply: ApiReply, what: string, decode: (text: string) => T): T {
    if (reply.ok) {
      try {
        return decode(reply.body);
      } catch (error) {
        if (error instanceof ClientError) {
          throw error;
        }
        throw ClientError.client(`${what} could not be read`);
      }
    }
    throw this.failure(reply, failureCode(reply.body));
  }

  private failure(reply: ApiReply, code: ErrorCode | null): ClientError {
    const resolved: ErrorCode = code === null ? ErrorCode.Network : code;
    const retryAfter: number = reply.retryAfterSeconds > 0 ? reply.retryAfterSeconds * 1000 : 0;
    return new ClientError(resolved, reply.status, 'the gateway refused the request', retryAfter);
  }
}

function copyOf(data: Uint8Array): ArrayBuffer {
  const copy: Uint8Array = new Uint8Array(data.length);
  copy.set(data);
  return copy.buffer as ArrayBuffer;
}

/**
 * Whether an address is this gateway's: the same host (a different port on it is
 * still this gateway, which is how a LAN gateway serves each application), or a host
 * in the gateway's own domain, which is how a gateway with a domain serves each
 * application.
 */
export function belongsToGateway(origin: string, url: string): boolean {
  const gatewayHost: string = hostOf(origin);
  const targetHost: string = hostOf(url);
  if (gatewayHost === '' || targetHost === '') {
    return false;
  }
  if (targetHost === gatewayHost) {
    return true;
  }
  if (gatewayHost.includes(':')) {
    // An address, not a domain: only the host itself can belong to it.
    return false;
  }
  return targetHost.endsWith(`.${gatewayHost}`);
}

export function hostOf(url: string): string {
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

/** Turns a credential failure into the same typed error the wire's refusals use. */
export function credentialFailure(error: Object): ClientError {
  if (error instanceof CredentialError) {
    return ClientError.client(error.detail);
  }
  return ClientError.client('the credential could not be used');
}
