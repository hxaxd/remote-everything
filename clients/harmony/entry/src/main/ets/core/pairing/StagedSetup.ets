import { JsonReader } from '../json/Strict';
import { ServerPin } from '../model/Models';
import { CredentialPresence, IdentityVault } from '../identity/IdentityVault';
import { AtomicFile } from '../store/AtomicFile';

const FILE = 'pairing/staged.json';
const FINGERPRINT = new RegExp('^[a-f0-9]{64}$');

export class StagedSetup {
  readonly origin: string;
  readonly node: string;
  readonly nodeName: string;
  readonly deviceName: string;
  readonly certificateFingerprint: string;
  readonly credentialRef: string;
  readonly pendingExpiresAtMs: number;
  readonly serverPin: ServerPin | null;

  constructor(origin: string, node: string, nodeName: string, deviceName: string,
    certificateFingerprint: string, credentialRef: string, pendingExpiresAtMs: number,
    serverPin: ServerPin | null = null) {
    this.origin = origin; this.node = node; this.nodeName = nodeName; this.deviceName = deviceName;
    this.certificateFingerprint = certificateFingerprint; this.credentialRef = credentialRef;
    this.pendingExpiresAtMs = pendingExpiresAtMs; this.serverPin = serverPin;
  }
  get expired(): boolean { return this.pendingExpiresAtMs <= Date.now(); }
}

/** One durable record per gateway, committed together in one atomic document. */
export class StagedSetupStore {
  private readonly vault: IdentityVault;
  constructor(vault: IdentityVault) { this.vault = vault; }

  stage(staged: StagedSetup): void {
    const records: StagedSetup[] = this.readAll();
    const index: number = records.findIndex((record: StagedSetup) => record.origin === staged.origin);
    if (index < 0) { records.push(staged); } else { records[index] = staged; }
    this.writeAll(records);
  }

  read(origin?: string): StagedSetup | null {
    return this.readAll().find((record: StagedSetup) => origin === undefined || record.origin === origin) ?? null;
  }

  readAll(): StagedSetup[] {
    const text: string | null = AtomicFile.readText(FILE);
    if (text === null) { return []; }
    try {
      const reader: JsonReader = JsonReader.parse(text, FILE);
      reader.rejectUnknown(['schema', 'stages']);
      if (reader.number('schema') !== 1) { return []; }
      const records: StagedSetup[] = [];
      for (const value of reader.array('stages')) {
        const row: JsonReader = JsonReader.of(value, 'stages[]');
        row.rejectUnknown(['origin', 'node', 'node_name', 'device_name', 'certificate_fingerprint',
          'credential_ref', 'pending_expires_at', 'server_pin']);
        let pin: ServerPin | null = null;
        if (row.has('server_pin')) {
          const p: JsonReader = row.object('server_pin');
          p.rejectUnknown(['cert_fingerprint', 'public_key_pin']);
          pin = new ServerPin(p.string('cert_fingerprint'), p.string('public_key_pin'));
        }
        const origin: string = row.string('origin');
        if (records.some((record: StagedSetup) => record.origin === origin)) { return []; }
        records.push(new StagedSetup(origin, row.pattern('node', FINGERPRINT), row.string('node_name'),
          row.string('device_name'), row.pattern('certificate_fingerprint', FINGERPRINT), row.string('credential_ref'),
          row.number('pending_expires_at'), pin));
      }
      return records;
    } catch (error) { return []; }
  }

  clear(origin?: string): void {
    if (origin === undefined) { AtomicFile.removeWithTemporary(FILE); return; }
    this.writeAll(this.readAll().filter((record: StagedSetup) => record.origin !== origin));
  }

  private writeAll(records: StagedSetup[]): void {
    if (records.length === 0) { AtomicFile.removeWithTemporary(FILE); return; }
    AtomicFile.ensureDirectory('pairing');
    const rows: string[] = records.map((record: StagedSetup) => {
      const pin: string = record.serverPin === null ? '' : `,"server_pin":${JSON.stringify({
        cert_fingerprint: record.serverPin.certFingerprint, public_key_pin: record.serverPin.publicKeyPin })}`;
      return `{"origin":${JSON.stringify(record.origin)},"node":${JSON.stringify(record.node)},` +
        `"node_name":${JSON.stringify(record.nodeName)},"device_name":${JSON.stringify(record.deviceName)},` +
        `"certificate_fingerprint":${JSON.stringify(record.certificateFingerprint)},"credential_ref":${JSON.stringify(record.credentialRef)},` +
        `"pending_expires_at":${record.pendingExpiresAtMs}${pin}}`;
    });
    AtomicFile.writeAtomic(FILE, `{"schema":1,"stages":[${rows.join(',')}]}`);
  }

  async discard(origin: string): Promise<boolean> {
    if (this.read(origin) === null) { return false; }
    this.clear(origin);
    await this.vault.forget(origin);
    return true;
  }

  async reconcile(): Promise<StagedSetup[]> {
    const valid: StagedSetup[] = [];
    for (const staged of this.readAll()) {
      const present: CredentialPresence = await this.vault.presence(staged.origin);
      if (this.read(staged.origin)?.certificateFingerprint !== staged.certificateFingerprint) { continue; }
      if (staged.expired || present !== CredentialPresence.Present) {
        await this.discard(staged.origin);
      } else if (this.read(staged.origin)?.certificateFingerprint === staged.certificateFingerprint) {
        valid.push(staged);
      }
    }
    return valid;
  }
}
