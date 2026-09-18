// The identity index: which gateways this device holds a credential for, and the
// one reference to each credential. The credential itself is never here — it is in
// platform secure storage, and `credentialRef` is what names it.
//
// The file is written whole, through one rename, and read strictly: a field this
// client does not know, or one that is missing, means the file is not this
// client's and its contents are not acted on.

import { JsonReader } from '../json/Strict';
import { Identity, ServerPin } from '../model/Models';
import { Sandbox } from './Sandbox';

const SCHEMA = 1;
const FILE = 'identity/index.json';
const FINGERPRINT = new RegExp('^[a-f0-9]{64}$');
const ORIGIN = new RegExp('^https://[^/?#]+$');
const PIN = new RegExp('^[A-Za-z0-9+/]{43}=$');

function decodePin(reader: JsonReader): ServerPin | null {
  const value: JsonReader | null = reader.optionalObject('server_pin');
  if (value === null) {
    return null;
  }
  value.rejectUnknown(['cert_fingerprint', 'public_key_pin']);
  const certFingerprint: string = value.pattern('cert_fingerprint', FINGERPRINT);
  const publicKeyPin: string = value.pattern('public_key_pin', PIN);
  return new ServerPin(certFingerprint, publicKeyPin);
}

function decodeIdentity(reader: JsonReader): Identity {
  reader.rejectUnknown(['origin', 'device_name', 'cert_fingerprint', 'credential_ref',
    'server_pin', 'created_at']);
  const origin: string = reader.pattern('origin', ORIGIN);
  const deviceName: string = reader.string('device_name');
  const certFingerprint: string = reader.pattern('cert_fingerprint', FINGERPRINT);
  const credentialRef: string = reader.string('credential_ref');
  const createdAt: number = reader.number('created_at');
  return new Identity(origin, deviceName, certFingerprint, credentialRef, decodePin(reader), createdAt);
}

export class IdentityStore {
  /** Every identity on record, in the order they were added. */
  read(): Identity[] {
    const text: string | null = Sandbox.readText(FILE);
    if (text === null) {
      return [];
    }
    let reader: JsonReader;
    try {
      reader = JsonReader.parse(text, FILE);
      reader.rejectUnknown(['schema', 'identities']);
      if (reader.number('schema') !== SCHEMA) {
        return [];
      }
      const identities: Identity[] = [];
      for (const entry of reader.array('identities')) {
        identities.push(decodeIdentity(JsonReader.of(entry, `${FILE}.identities[]`)));
      }
      return identities;
    } catch (error) {
      // A file this client cannot read is a file it does not act on. It is left
      // where it is rather than overwritten: what it holds may still be readable by
      // hand, and writing over it would destroy that.
      return [];
    }
  }

  write(identities: Identity[]): void {
    Sandbox.ensureDirectory('identity');
    const encoded: string[] = [];
    for (const identity of identities) {
      encoded.push(encodeIdentity(identity));
    }
    const document: string = `{"schema":${SCHEMA},"identities":[${encoded.join(',')}]}`;
    Sandbox.writeAtomic(FILE, document);
  }

  static has(identities: Identity[], origin: string): boolean {
    for (const identity of identities) {
      if (identity.origin === origin) {
        return true;
      }
    }
    return false;
  }

  static find(identities: Identity[], origin: string): Identity | null {
    for (const identity of identities) {
      if (identity.origin === origin) {
        return identity;
      }
    }
    return null;
  }
}

function encodePin(pin: ServerPin | null): string {
  if (pin === null) {
    return 'null';
  }
  return `{"cert_fingerprint":"${pin.certFingerprint}","public_key_pin":"${pin.publicKeyPin}"}`;
}

function encodeIdentity(identity: Identity): string {
  return `{"origin":${JSON.stringify(identity.origin)},` +
    `"device_name":${JSON.stringify(identity.deviceName)},` +
    `"cert_fingerprint":${JSON.stringify(identity.certFingerprint)},` +
    `"credential_ref":${JSON.stringify(identity.credentialRef)},` +
    `"server_pin":${encodePin(identity.serverPin)},` +
    `"created_at":${identity.createdAt}}`;
}
