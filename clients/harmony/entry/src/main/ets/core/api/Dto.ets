// The wire's documents, read strictly.
//
// Every answer a gateway gives is decoded here into classes the rest of the client
// uses, and every rule the schemas state is enforced: required fields must be there,
// unknown fields are refused, an unknown enum value is refused rather than defaulted,
// and the cross-field constraints the schemas describe — a catalog that says `ready`
// while `computer_connected` is false, an app whose `code` contradicts its
// `enabled`+`running` — are refused too. That is the trust boundary: a substituted
// gateway or a proxy rewriting answers is exactly what a lenient reader would let in.

import { JsonError, JsonReader, codePoints, hasNoControlCharacters, isBase64, isLaunchFragment, isRfc3339 } from
  '../json/Strict';
import { AppInfo, AppState } from '../model/Models';
import { ClientError, ErrorCode, parseErrorCode } from './Errors';

const ID_PATTERN = new RegExp('^[a-z0-9][a-z0-9._-]{0,63}$');
const NODE_ID_PATTERN = new RegExp('^[a-f0-9]{64}$');
const ACCENT_PATTERN = new RegExp('^#[0-9A-Fa-f]{6}$');
const FINGERPRINT_PATTERN = new RegExp('^[a-f0-9]{64}$');

export class NodeSummaryDto {
  readonly id: string;
  readonly name: string;

  constructor(id: string, name: string) {
    this.id = id;
    this.name = name;
  }
}

export type NodeSummary = NodeSummaryDto;
export const NodeSummary = NodeSummaryDto;

export class AppDto {
  readonly id: string;
  readonly name: string;
  readonly description: string;
  readonly icon: string;
  readonly accent: string;
  readonly launchFragment: string;
  readonly enabled: boolean;
  readonly running: boolean;
  readonly code: string;

  constructor(id: string, name: string, description: string, icon: string, accent: string, launchFragment: string,
    enabled: boolean, running: boolean, code: string) {
    this.id = id;
    this.name = name;
    this.description = description;
    this.icon = icon;
    this.accent = accent;
    this.launchFragment = launchFragment;
    this.enabled = enabled;
    this.running = running;
    this.code = code;
  }

  toAppInfo(): AppInfo {
    return new AppInfo(this.id, this.name, this.description, this.icon, this.accent, this.launchFragment,
      this.enabled, this.running, this.code as AppState);
  }
}

export class NodesResponse {
  readonly nodes: NodeSummaryDto[];

  constructor(nodes: NodeSummaryDto[]) {
    this.nodes = nodes;
  }
}

export type NodesAnswer = NodesResponse;
export const NodesAnswer = NodesResponse;

export class CatalogResponse {
  readonly ok: boolean;
  readonly computerConnected: boolean;
  readonly code: string;
  readonly apps: AppInfo[];

  constructor(ok: boolean, computerConnected: boolean, code: string, apps: AppInfo[]) {
    this.ok = ok;
    this.computerConnected = computerConnected;
    this.code = code;
    this.apps = apps;
  }
}

export type CatalogAnswer = CatalogResponse;
export const CatalogAnswer = CatalogResponse;

/** The status codes a control answer may carry, `computer_offline` included. */
export enum ControlCode {
  Ready = 'ready',
  Starting = 'starting',
  Stopping = 'stopping',
  Stopped = 'stopped',
  ComputerOffline = 'computer_offline',
  AppNotFound = 'app_not_found',
  StateUpdateFailed = 'state_update_failed'
}

export class ControlResponse {
  readonly ok: boolean;
  readonly action: string;
  readonly computerConnected: boolean;
  readonly enabled: boolean;
  readonly running: boolean;
  readonly code: ControlCode;
  readonly app: AppInfo | null;
  readonly errorCode: string | null;

  constructor(ok: boolean, action: string, computerConnected: boolean, enabled: boolean, running: boolean,
    code: ControlCode, app: AppInfo | null, errorCode: string | null) {
    this.ok = ok;
    this.action = action;
    this.computerConnected = computerConnected;
    this.enabled = enabled;
    this.running = running;
    this.code = code;
    this.app = app;
    this.errorCode = errorCode;
  }

  /** The app's own state, for the rows that show it. */
  get state(): AppState {
    return appStateOf(this.enabled, this.running);
  }

  get settled(): boolean {
    return this.code === ControlCode.Ready || this.code === ControlCode.Stopped;
  }
}

export type ControlAnswer = ControlResponse;
export const ControlAnswer = ControlResponse;

export class PairingResponse {
  readonly deviceName: string;
  readonly certificateFingerprint: string;
  readonly credentialPkcs12: string;
  readonly pendingExpiresAt: string;

  constructor(deviceName: string, certificateFingerprint: string, credentialPkcs12: string,
    pendingExpiresAt: string) {
    this.deviceName = deviceName;
    this.certificateFingerprint = certificateFingerprint;
    this.credentialPkcs12 = credentialPkcs12;
    this.pendingExpiresAt = pendingExpiresAt;
  }
}

export type PairingAnswer = PairingResponse;
export const PairingAnswer = PairingResponse;

/** The state code an app's enabled/running pair has to agree with. */
function appStateOf(enabled: boolean, running: boolean): AppState {
  if (enabled) {
    return running ? AppState.Ready : AppState.Starting;
  }
  return running ? AppState.Stopping : AppState.Stopped;
}

export function decodeAppDto(reader: JsonReader): AppDto {
  reader.rejectUnknown(['id', 'name', 'description', 'icon', 'accent', 'launch_fragment', 'computer_connected',
    'enabled', 'running', 'code']);
  const id: string = reader.pattern('id', ID_PATTERN);
  const name: string = reader.string('name');
  if (name.length === 0 || codePoints(name) > 80 || !hasNoControlCharacters(name)) {
    throw new JsonError(`${reader.context()}.name is out of bounds`);
  }
  const description: string = reader.string('description');
  if (codePoints(description) > 240 || !hasNoControlCharacters(description)) {
    throw new JsonError(`${reader.context()}.description is out of bounds`);
  }
  const icon: string = reader.string('icon');
  if (codePoints(icon) > 4) {
    throw new JsonError(`${reader.context()}.icon is out of bounds`);
  }
  if (!hasNoControlCharacters(icon)) {
    throw new JsonError(`${reader.context()}.icon carries control characters`);
  }
  const accent: string = reader.pattern('accent', ACCENT_PATTERN);
  const launchFragment: string = reader.string('launch_fragment');
  if (!isLaunchFragment(launchFragment)) {
    throw new JsonError(`${reader.context()}.launch_fragment is not a fragment`);
  }
  if (!reader.bool('computer_connected')) {
    throw new JsonError(`${reader.context()}.computer_connected is false for an application`);
  }
  const enabled: boolean = reader.bool('enabled');
  const running: boolean = reader.bool('running');
  const code: string = reader.enumValue('code', ['ready', 'starting', 'stopping', 'stopped']);
  const expected: AppState = appStateOf(enabled, running);
  if (code !== expected) {
    throw new JsonError(`${reader.context()}.code contradicts enabled and running`);
  }
  return new AppDto(id, name, description, icon, accent, launchFragment, enabled, running, code);
}

function decodeApp(reader: JsonReader): AppInfo {
  return decodeAppDto(reader).toAppInfo();
}

function readCode(text: string, what: string): JsonReader {
  try {
    return JsonReader.parse(text, what);
  } catch (error) {
    throw ClientError.client(`${what} is not the JSON this client reads`);
  }
}

/** `{ok: true, nodes: [...]}` — which nodes this device may reach. */
export function decodeNodes(text: string): NodesAnswer {
  const reader: JsonReader = readCode(text, 'the nodes answer');
  try {
    reader.rejectUnknown(['ok', 'nodes']);
    if (!reader.bool('ok')) {
      throw new JsonError('the nodes answer is not ok');
    }
    const nodes: NodeSummary[] = [];
    for (const entry of reader.array('nodes')) {
      const node: JsonReader = JsonReader.of(entry, 'the nodes answer');
      node.rejectUnknown(['id', 'name']);
      const name: string = node.string('name');
      if (name.length === 0) {
        throw new JsonError('the nodes answer names a node with an empty name');
      }
      nodes.push(new NodeSummary(node.pattern('id', NODE_ID_PATTERN), name));
    }
    return new NodesAnswer(nodes);
  } catch (error) {
    throw ClientError.client(`the nodes answer is not one this client reads: ${(error as Error).message}`);
  }
}

/** `{ok: true, computer_connected, code, apps: [...]}` — what one node runs. */
export function decodeCatalog(text: string): CatalogAnswer {
  const reader: JsonReader = readCode(text, 'the catalog answer');
  try {
    reader.rejectUnknown(['ok', 'computer_connected', 'code', 'apps']);
    if (!reader.bool('ok')) {
      throw new JsonError('the catalog answer is not ok');
    }
    const connected: boolean = reader.bool('computer_connected');
    const code: string = reader.enumValue('code', ['ready', 'computer_offline']);
    if (connected !== (code === 'ready')) {
      throw new JsonError('the catalog code contradicts computer_connected');
    }
    const apps: AppInfo[] = [];
    const seen: Set<string> = new Set<string>();
    for (const entry of reader.array('apps')) {
      const app: AppInfo = decodeApp(JsonReader.of(entry, 'the catalog answer'));
      if (seen.has(app.id)) {
        throw new JsonError(`the catalog answer lists the application ${app.id} twice`);
      }
      seen.add(app.id);
      apps.push(app);
    }
    if (!connected && apps.length > 0) {
      throw new JsonError('an offline catalog still lists applications');
    }
    return new CatalogAnswer(true, connected, code, apps);
  } catch (error) {
    throw ClientError.client(`the catalog answer is not one this client reads: ${(error as Error).message}`);
  }
}

/** `{ok, action, computer_connected, enabled, running, code, app?, error_code?}`. */
export function decodeControl(text: string): ControlAnswer {
  const reader: JsonReader = readCode(text, 'the control answer');
  try {
    reader.rejectUnknown(['ok', 'action', 'computer_connected', 'enabled', 'running', 'code', 'app', 'error_code']);
    const ok: boolean = reader.bool('ok');
    const action: string = reader.enumValue('action', ['status', 'start', 'stop']);
    const connected: boolean = reader.bool('computer_connected');
    const enabled: boolean = reader.bool('enabled');
    const running: boolean = reader.bool('running');
    const code: string = reader.enumValue('code',
      ['ready', 'starting', 'stopping', 'stopped', 'computer_offline', 'app_not_found', 'state_update_failed']);
    const appReader: JsonReader | null = reader.optionalObject('app');
    const app: AppInfo | null = appReader === null ? null : decodeApp(appReader);
    const errorCode: string | null = reader.optionalString('error_code');
    if (errorCode !== null && errorCode !== 'stop_command_failed') {
      throw new JsonError('the control answer names an error this client does not know');
    }
    if (code === 'ready' || code === 'starting' || code === 'stopping' || code === 'stopped') {
      if (code !== appStateOf(enabled, running)) {
        throw new JsonError('the control code contradicts enabled and running');
      }
    }
    return new ControlAnswer(ok, action, connected, enabled, running, code as ControlCode, app, errorCode);
  } catch (error) {
    throw ClientError.client(`the control answer is not one this client reads: ${(error as Error).message}`);
  }
}

/** The credential a redeemed invitation is answered with. */
export function decodePairing(text: string): PairingAnswer {
  const reader: JsonReader = readCode(text, 'the pairing answer');
  try {
    reader.rejectUnknown(['ok', 'device_name', 'certificate_fingerprint', 'credential_format', 'credential_pkcs12',
      'pending_expires_at']);
    if (!reader.bool('ok')) {
      throw new JsonError('the pairing answer is not ok');
    }
    const deviceName: string = reader.string('device_name');
    const fingerprint: string = reader.pattern('certificate_fingerprint', FINGERPRINT_PATTERN);
    const format: string = reader.string('credential_format');
    if (format !== 'pkcs12') {
      throw new JsonError('the pairing answer offers a credential this client cannot read');
    }
    const pkcs12: string = reader.string('credential_pkcs12');
    if (!isBase64(pkcs12)) {
      throw new JsonError('the pairing answer offers a credential that is not base64');
    }
    const expires: string = reader.string('pending_expires_at');
    if (!isRfc3339(expires)) {
      throw new JsonError('the pairing answer carries an expiry that is not an instant');
    }
    return new PairingAnswer(deviceName, fingerprint, pkcs12, expires);
  } catch (error) {
    throw ClientError.client(`the pairing answer is not one this client reads: ${(error as Error).message}`);
  }
}

/**
 * The code of a refusal, or null when the body is not a refusal this client knows.
 * The HTTP status is never consulted here and the prose is never read: the code is
 * the decision (ui-contract §3).
 */
export function failureCode(text: string): ErrorCode | null {
  let reader: JsonReader;
  try {
    reader = JsonReader.parse(text, 'the refusal');
  } catch (error) {
    return null;
  }
  try {
    reader.rejectUnknown(['ok', 'code']);
    const ok: boolean = reader.bool('ok');
    const code: string = reader.string('code');
    if (ok) {
      return null;
    }
    return parseErrorCode(code);
  } catch (error) {
    return null;
  }
}

/**
 * `{ok: false, code}` read strictly: a refusal that says it is ok, or names a code
 * this client does not know, is refused here rather than guessed at. This is the
 * strict counterpart of `failureCode`, for the places a body has to be a refusal.
 */
export function decodeError(text: string): ErrorCode {
  const reader: JsonReader = readCode(text, 'the refusal');
  reader.rejectUnknown(['ok', 'code']);
  if (reader.bool('ok')) {
    throw new JsonError('a refusal says it is ok');
  }
  const parsed: ErrorCode | null = parseErrorCode(reader.string('code'));
  if (parsed === null) {
    throw new JsonError('the refusal names a code this client does not know');
  }
  return parsed;
}
