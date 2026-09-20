// Setup URI parsing.
//
// The wire is `remote-everything://setup?node=…&node_name=…&origin=…&invitation=…`,
// with `fingerprint` and `public_key_pin` present exactly together when the gateway
// signs its own certificate. The rules below are the ones
// contracts/schemas/setup-uri.schema.json states, and they are stated strictly: an
// unknown parameter, a parameter given twice, a missing one, or a value that does
// not match its pattern is a refusal rather than something to be interpreted.

import { ServerPin } from '../model/Models';

export { ServerPin };

export enum SetupErrorReason {
  Malformed = 'malformed',
  UnsupportedScheme = 'unsupported_scheme',
  UnknownParameter = 'unknown_parameter',
  DuplicateParameter = 'duplicate_parameter',
  MissingParameter = 'missing_parameter',
  InvalidValue = 'invalid_value',
  PinPairIncomplete = 'pin_pair_incomplete'
}

export class SetupError extends Error {
  readonly reason: SetupErrorReason;
  readonly parameter: string;

  constructor(reason: SetupErrorReason, parameter: string, message: string) {
    super(message);
    this.reason = reason;
    this.parameter = parameter;
  }
}

/** One invitation, read: the node it opens, what that node is called, and where the gateway is. */
export class SetupUri {
  readonly node: string;
  readonly nodeName: string;
  readonly origin: string;
  readonly invitation: string;
  readonly serverPin: ServerPin | null;

  constructor(node: string, nodeName: string, origin: string, invitation: string, serverPin: ServerPin | null) {
    this.node = node;
    this.nodeName = nodeName;
    this.origin = origin;
    this.invitation = invitation;
    this.serverPin = serverPin;
  }
}

const SCHEME_PREFIX = 'remote-everything://';
const SETUP_HOST = 'setup';
const NODE_PATTERN = new RegExp('^[a-f0-9]{64}$');
const INVITATION_PATTERN = new RegExp('^[A-Za-z0-9_-]{43}$');
const FINGERPRINT_PATTERN = new RegExp('^[a-f0-9]{64}$');
const PUBLIC_KEY_PIN_PATTERN = new RegExp('^[A-Za-z0-9+/]{43}=$');
const ORIGIN_PATTERN = new RegExp('^https://[^/?#]+$');
const REQUIRED_PARAMETERS: string[] = ['node', 'node_name', 'origin', 'invitation'];
const KNOWN_PARAMETERS: string[] = ['node', 'node_name', 'origin', 'invitation', 'fingerprint', 'public_key_pin'];

function decodeComponent(value: string, parameter: string): string {
  try {
    return decodeURIComponent(value.replace(/\+/g, ' '));
  } catch (error) {
    throw new SetupError(SetupErrorReason.InvalidValue, parameter, `setup parameter ${parameter} is not decodable`);
  }
}

function parseQuery(query: string): Map<string, string> {
  const values: Map<string, string> = new Map<string, string>();
  if (query === '') {
    return values;
  }
  const pairs: string[] = query.split('&');
  for (const pair of pairs) {
    if (pair === '') {
      // An empty segment between ampersands is not a parameter; the strict side
      // of the contract refuses it rather than reading around it.
      throw new SetupError(SetupErrorReason.Malformed, '', 'setup query carries an empty segment');
    }
    const separator: number = pair.indexOf('=');
    if (separator <= 0) {
      throw new SetupError(SetupErrorReason.Malformed, pair, 'setup parameter has no value');
    }
    // The name is compared as it arrived: a percent-encoded parameter name is not
    // one of the known names, no matter what it decodes to.
    const name: string = pair.substring(0, separator);
    if (!KNOWN_PARAMETERS.includes(name)) {
      throw new SetupError(SetupErrorReason.UnknownParameter, name, `unknown setup parameter ${name}`);
    }
    if (values.has(name)) {
      throw new SetupError(SetupErrorReason.DuplicateParameter, name, `setup parameter ${name} was given twice`);
    }
    values.set(name, decodeComponent(pair.substring(separator + 1), name));
  }
  return values;
}

function codePointCount(value: string): number {
  let count: number = 0;
  for (const _ of value) {
    count += 1;
  }
  return count;
}

function hasControlCharacters(value: string): boolean {
  for (let index: number = 0; index < value.length; index += 1) {
    const code: number = value.charCodeAt(index);
    if (code < 32 || code === 127) {
      return true;
    }
  }
  return false;
}

function validNodeName(value: string): boolean {
  if (value.length === 0 || value.trim() !== value || codePointCount(value) > 80) {
    return false;
  }
  return !hasControlCharacters(value);
}

/**
 * Checks an origin the way the gateway records it: HTTPS, an authority and nothing
 * else, a valid port when one is given, and no user information.
 */
function normalizeOrigin(value: string): string {
  if (!ORIGIN_PATTERN.test(value) || value.includes('@')) {
    throw new SetupError(SetupErrorReason.InvalidValue, 'origin', 'setup origin must be an HTTPS origin');
  }
  const authority: string = value.substring('https://'.length);
  if (authority.length === 0) {
    throw new SetupError(SetupErrorReason.InvalidValue, 'origin', 'setup origin has no host');
  }
  const colon: number = authority.lastIndexOf(':');
  if (colon >= 0 && authority.indexOf(']') < colon) {
    const port: string = authority.substring(colon + 1);
    const parsed: number = Number.parseInt(port, 10);
    if (!new RegExp('^[0-9]+$').test(port) || Number.isNaN(parsed) || parsed < 1 || parsed > 65535) {
      throw new SetupError(SetupErrorReason.InvalidValue, 'origin', 'setup origin must use a valid port');
    }
  }
  return value;
}

function required(values: Map<string, string>, name: string): string {
  const value: string | undefined = values.get(name);
  if (value === undefined) {
    throw new SetupError(SetupErrorReason.MissingParameter, name, `setup parameter ${name} is missing`);
  }
  return value;
}

function checked(value: string, expression: RegExp, name: string): string {
  if (!expression.test(value)) {
    throw new SetupError(SetupErrorReason.InvalidValue, name, `setup parameter ${name} is malformed`);
  }
  return value;
}

/**
 * Reads an invitation link. Surrounding whitespace is accepted: a link arrives by
 * paste, and what it says is what matters. Everything else is exact.
 */
export function parseSetupUri(raw: string): SetupUri {
  const trimmed: string = raw.trim();
  // A URI is ASCII, and a specific ASCII at that: a bare space, a control
  // character, or a non-ASCII character (a Chinese name not percent-encoded, for
  // example) is not a link this client reads — the same refusal the platform URI
  // parser gives on the other clients.
  if (/[^A-Za-z0-9\-._~!$&'()*+,;=:@/?%#\[\]]/.test(trimmed)) {
    throw new SetupError(SetupErrorReason.Malformed, '', 'a setup link carries a character a URI cannot');
  }
  if (!trimmed.toLowerCase().startsWith(SCHEME_PREFIX)) {
    throw new SetupError(SetupErrorReason.UnsupportedScheme, '', 'not a remote-everything setup link');
  }
  let remainder: string = trimmed.substring(SCHEME_PREFIX.length);
  const fragment: number = remainder.indexOf('#');
  if (fragment >= 0) {
    throw new SetupError(SetupErrorReason.Malformed, '', 'a setup link carries no fragment');
  }
  let query: string = '';
  const question: number = remainder.indexOf('?');
  if (question >= 0) {
    query = remainder.substring(question + 1);
    remainder = remainder.substring(0, question);
  }
  const host: string = remainder.endsWith('/') ? remainder.substring(0, remainder.length - 1) : remainder;
  if (host.toLowerCase() !== SETUP_HOST) {
    throw new SetupError(SetupErrorReason.UnsupportedScheme, '', 'not a remote-everything setup link');
  }

  const values: Map<string, string> = parseQuery(query);
  for (const name of REQUIRED_PARAMETERS) {
    required(values, name);
  }

  const node: string = checked(required(values, 'node'), NODE_PATTERN, 'node');
  const nodeName: string = required(values, 'node_name');
  if (!validNodeName(nodeName)) {
    throw new SetupError(SetupErrorReason.InvalidValue, 'node_name', 'setup parameter node_name is malformed');
  }
  const origin: string = normalizeOrigin(required(values, 'origin'));
  const invitation: string = checked(required(values, 'invitation'), INVITATION_PATTERN, 'invitation');

  const fingerprint: string | undefined = values.get('fingerprint');
  const publicKeyPin: string | undefined = values.get('public_key_pin');
  if (fingerprint === undefined && publicKeyPin === undefined) {
    return new SetupUri(node, nodeName, origin, invitation, null);
  }
  if (fingerprint === undefined || publicKeyPin === undefined) {
    const missing: string = fingerprint === undefined ? 'fingerprint' : 'public_key_pin';
    throw new SetupError(SetupErrorReason.PinPairIncomplete, missing, 'a setup link pins both halves or neither');
  }
  checked(fingerprint, FINGERPRINT_PATTERN, 'fingerprint');
  checked(publicKeyPin, PUBLIC_KEY_PIN_PATTERN, 'public_key_pin');
  return new SetupUri(node, nodeName, origin, invitation, new ServerPin(fingerprint, publicKeyPin));
}
