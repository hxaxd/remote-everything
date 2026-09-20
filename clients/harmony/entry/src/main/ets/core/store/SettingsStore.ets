// Local persistence in one home, the way the other two clients keep it: the two
// settings that outlive a session (language, appearance), and the identity index —
// which gateways this device holds a credential for, and the one reference to each
// credential. The credential itself is never here: it is in platform secure
// storage, and `credentialRef` is what names it.
//
// The two halves ride on the media this platform gives each: settings live in
// preferences and are read before the first frame; the identity index is one JSON
// document written whole through one rename, and read strictly — a field this
// client does not know, or one that is missing, means the file is not this
// client's and its contents are not acted on. An unreadable store is a store with
// the defaults in it, never a crash.

import { preferences } from '@kit.ArkData';
import { Appearance, Identity, Language, ServerPin } from '../model/Models';
import { JsonReader } from '../json/Strict';
import { AtomicFile } from './AtomicFile';
import { WebAppPrefs } from './WebAppPrefs';

const STORE_NAME = 'settings';
const KEY_LANGUAGE = 'language';
const KEY_APPEARANCE = 'appearance';
/** The node page that was open when the app last left, for a cold start to return to. */
const KEY_LAST_NODE = 'last_node_id';
/** One preferences entry per application, named by the application. */
const PREFIX_WEB_PREFS = 'web_prefs.';

const INDEX_FILE = 'identity/index.json';
const INDEX_SCHEMA = 1;
const FINGERPRINT = new RegExp('^[a-f0-9]{64}$');
const ORIGIN = new RegExp('^https://[^/?#]+$');
const PIN = new RegExp('^[A-Za-z0-9+/]{43}=$');

export class Settings {
  readonly language: Language;
  readonly appearance: Appearance;

  constructor(language: Language, appearance: Appearance) {
    this.language = language;
    this.appearance = appearance;
  }

  static defaults(): Settings {
    return new Settings(Language.System, Appearance.System);
  }

  withLanguage(language: Language): Settings {
    return new Settings(language, this.appearance);
  }

  withAppearance(appearance: Appearance): Settings {
    return new Settings(this.language, appearance);
  }
}

function readLanguage(value: string | null): Language {
  if (value === Language.Chinese) {
    return Language.Chinese;
  }
  if (value === Language.English) {
    return Language.English;
  }
  return Language.System;
}

function readAppearance(value: string | null): Appearance {
  if (value === Appearance.Light) {
    return Appearance.Light;
  }
  if (value === Appearance.Dark) {
    return Appearance.Dark;
  }
  return Appearance.System;
}

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

export class SettingsStore {
  private store: preferences.Preferences | null = null;

  constructor(store: preferences.Preferences | null = null) {
    this.store = store;
  }

  attach(store: preferences.Preferences): void {
    this.store = store;
  }

  // ---- Settings ----------------------------------------------------------------

  open(context: Context): Settings {
    try {
      this.store = preferences.getPreferencesSync(context, { name: STORE_NAME });
    } catch (error) {
      this.store = null;
      return Settings.defaults();
    }
    return this.read();
  }

  read(): Settings {
    const store: preferences.Preferences | null = this.store;
    if (store === null) {
      return Settings.defaults();
    }
    try {
      const language: string = store.getSync(KEY_LANGUAGE, '') as string;
      const appearance: string = store.getSync(KEY_APPEARANCE, '') as string;
      return new Settings(readLanguage(language), readAppearance(appearance));
    } catch (error) {
      // A store that cannot be read is a store with the defaults in it.
      return Settings.defaults();
    }
  }

  write(settings: Settings): void {
    if (this.store === null) {
      return;
    }
    try {
      this.store.putSync(KEY_LANGUAGE, settings.language);
      this.store.putSync(KEY_APPEARANCE, settings.appearance);
      this.store.flushSync();
    } catch (error) {
      // A setting that could not be written is a setting for this run only; the app
      // stays usable and the next change tries again.
    }
  }

  // ---- Where the app was when it last left -------------------------------------

  /** The node page that was open, or '' when the app last left the list. */
  readLastNode(): string {
    const store: preferences.Preferences | null = this.store;
    if (store === null) {
      return '';
    }
    try {
      return store.getSync(KEY_LAST_NODE, '') as string;
    } catch (error) {
      return '';
    }
  }

  writeLastNode(nodeId: string): void {
    const store: preferences.Preferences | null = this.store;
    if (store === null) {
      return;
    }
    try {
      store.putSync(KEY_LAST_NODE, nodeId);
      store.flushSync();
    } catch (error) {
      // A navigation that could not be remembered is a cold start on the list.
    }
  }

  // ---- What the web host remembers per application -----------------------------

  /**
   * One application's panel choices, as `nodeId/appId` names it. The defaults come
   * back for an application whose panel was never touched, and for a stored value
   * this client does not recognise.
   */
  readWebAppPrefs(appKey: string): WebAppPrefs {
    const store: preferences.Preferences | null = this.store;
    if (store === null) {
      return WebAppPrefs.defaults();
    }
    try {
      const value: string = store.getSync(PREFIX_WEB_PREFS + appKey, '') as string;
      if (value === '') {
        return WebAppPrefs.defaults();
      }
      return WebAppPrefs.decode(value);
    } catch (error) {
      return WebAppPrefs.defaults();
    }
  }

  writeWebAppPrefs(appKey: string, prefs: WebAppPrefs): void {
    const store: preferences.Preferences | null = this.store;
    if (store === null) {
      return;
    }
    try {
      store.putSync(PREFIX_WEB_PREFS + appKey, prefs.encode());
      store.flushSync();
    } catch (error) {
      // A choice that could not be written is a choice for this visit only; the
      // application stays usable and the next change tries again.
    }
  }

  // ---- The identity index ------------------------------------------------------

  /** Every identity on record, in the order they were added. */
  readIdentities(): Identity[] {
    const text: string | null = AtomicFile.readText(INDEX_FILE);
    if (text === null) {
      return [];
    }
    try {
      const reader: JsonReader = JsonReader.parse(text, INDEX_FILE);
      reader.rejectUnknown(['schema', 'identities']);
      if (reader.number('schema') !== INDEX_SCHEMA) {
        return [];
      }
      const identities: Identity[] = [];
      for (const entry of reader.array('identities')) {
        identities.push(decodeIdentity(JsonReader.of(entry, `${INDEX_FILE}.identities[]`)));
      }
      return identities;
    } catch (error) {
      // A file this client cannot read is a file it does not act on. It is left
      // where it is rather than overwritten: what it holds may still be readable by
      // hand, and writing over it would destroy that.
      return [];
    }
  }

  writeIdentities(identities: Identity[]): void {
    AtomicFile.ensureDirectory('identity');
    const encoded: string[] = [];
    for (const identity of identities) {
      encoded.push(encodeIdentity(identity));
    }
    const document: string = `{"schema":${INDEX_SCHEMA},"identities":[${encoded.join(',')}]}`;
    AtomicFile.writeAtomic(INDEX_FILE, document);
  }
}
