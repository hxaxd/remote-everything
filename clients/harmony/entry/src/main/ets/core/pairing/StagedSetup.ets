// The pairing transaction: stage, activate, promote.
//
// Pairing and activation are two round trips, and the invitation that starts them is
// single-use — being killed in between must not mean asking the operator for another
// one. So the moment a credential exists it is put in one place, together with
// everything needed to finish the job, and that place is one file written with one
// rename:
//
//   { origin, node, node_name, device_name, certificate_fingerprint,
//     credential_ref, pending_expires_at, staged_at }
//
// The credential itself is where it always is — sealed under HUKS (IdentityVault) and
// installed in the certificate manager — and `credential_ref` names it. The one-time
// credential password is *not* here, or anywhere else: it was used to open the archive
// once, and what was staged is the archive this device re-encoded under its own
// password. The invitation is not here either: it was spent on the first round trip,
// and a single-use secret has no business on disk.
//
// `reconcile` reads it back at startup: a stage whose credential is gone, or whose
// pending window has passed, is discarded whole, and one that is still good is carried
// on with. Half a transaction is never resumed.

import { JsonReader } from '../json/Strict';
import { Cadence } from '../model/Cadence';
import { ServerPin } from '../model/Models';
import { CredentialPresence } from '../identity/CredentialError';
import { IdentityVault } from '../identity/IdentityVault';
import { Sandbox } from '../store/Sandbox';

const SCHEMA = 1;
const FILE = 'pairing/staged.json';
const FINGERPRINT = new RegExp('^[a-f0-9]{64}$');
const NODE_ID = new RegExp('^[a-f0-9]{64}$');

export class StagedPairing {
  readonly origin: string;
  readonly node: string;
  readonly nodeName: string;
  readonly deviceName: string;
  readonly certificateFingerprint: string;
  readonly credentialRef: string;
  readonly pendingExpiresAt: string;
  readonly stagedAt: number;
  readonly serverPin: ServerPin | null;

  constructor(origin: string, node: string, nodeName: string, deviceName: string,
    certificateFingerprint: string, credentialRef: string, pendingExpiresAt: string, stagedAt: number,
    serverPin: ServerPin | null = null) {
    this.origin = origin;
    this.node = node;
    this.nodeName = nodeName;
    this.deviceName = deviceName;
    this.certificateFingerprint = certificateFingerprint;
    this.credentialRef = credentialRef;
    this.pendingExpiresAt = pendingExpiresAt;
    this.stagedAt = stagedAt;
    this.serverPin = serverPin;
  }

  /** Whether the window this device may still be activated in has closed. */
  get expired(): boolean {
    const at: number = Date.parse(this.pendingExpiresAt);
    if (Number.isNaN(at)) {
      // A window this client cannot read is not one it trusts: fall back to the
      // cadence promise, ten minutes from when the pairing was staged.
      return this.stagedAt + Cadence.pendingFallbackMs <= Date.now();
    }
    return at <= Date.now();
  }
}

export class StagedSetupStore {
  private readonly vault: IdentityVault;

  constructor(vault: IdentityVault) {
    this.vault = vault;
  }

  /** Stages one pairing: one file, one rename, nothing to half-write. */
  stage(staged: StagedPairing): void {
    Sandbox.ensureDirectory('pairing');
    const pinPart = staged.serverPin === null ? '' :
      `,"server_pin":{"public_key_pin":${JSON.stringify(staged.serverPin.publicKeyPin)},"cert_fingerprint":${JSON.stringify(staged.serverPin.certFingerprint)}}`;
    const document: string = `{"schema":${SCHEMA},` +
      `"origin":${JSON.stringify(staged.origin)},` +
      `"node":${JSON.stringify(staged.node)},` +
      `"node_name":${JSON.stringify(staged.nodeName)},` +
      `"device_name":${JSON.stringify(staged.deviceName)},` +
      `"certificate_fingerprint":${JSON.stringify(staged.certificateFingerprint)},` +
      `"credential_ref":${JSON.stringify(staged.credentialRef)},` +
      `"pending_expires_at":${JSON.stringify(staged.pendingExpiresAt)},` +
      `"staged_at":${staged.stagedAt}${pinPart}}`;
    Sandbox.writeAtomic(FILE, document);
  }

  /** What is staged, if anything that can still be carried on with is. */
  read(): StagedPairing | null {
    const text: string | null = Sandbox.readText(FILE);
    if (text === null) {
      return null;
    }
    try {
      const reader: JsonReader = JsonReader.parse(text, FILE);
      reader.rejectUnknown(['schema', 'origin', 'node', 'node_name', 'device_name',
        'certificate_fingerprint', 'credential_ref', 'pending_expires_at', 'staged_at', 'server_pin']);
      if (reader.number('schema') !== SCHEMA) {
        return null;
      }
      let serverPin: ServerPin | null = null;
      if (reader.has('server_pin')) {
        const pinReader = reader.object('server_pin');
        pinReader.rejectUnknown(['public_key_pin', 'cert_fingerprint']);
        serverPin = new ServerPin(
          pinReader.string('public_key_pin'),
          pinReader.string('cert_fingerprint')
        );
      }
      return new StagedPairing(
        reader.string('origin'),
        reader.pattern('node', NODE_ID),
        reader.string('node_name'),
        reader.string('device_name'),
        reader.pattern('certificate_fingerprint', FINGERPRINT),
        reader.string('credential_ref'),
        reader.string('pending_expires_at'),
        reader.number('staged_at'),
        serverPin
      );
    } catch (error) {
      // A staged file this client cannot read is one it does not act on; it is
      // discarded with the credential it named, because a staged pairing whose
      // details are gone is not a pairing that can be finished.
      return null;
    }
  }

  /** Promotion: the identity is written and the stage is no longer needed. */
  clear(): void {
    Sandbox.removeWithTemporary(FILE);
  }

  /**
   * Discards a stage and the credential it named, in that order: nothing was
   * promoted, so nothing about it may be left behind — the sealed archive, the
   * certificate manager's entry, and the file itself go together.
   */
  async discard(origin: string): Promise<void> {
    Sandbox.removeWithTemporary(FILE);
    await this.vault.forget(origin);
  }

  /**
   * What to do with what is left from an interrupted pairing: keep it (an activation
   * can still be asked for), drop it (its credential or its window is gone), or
   * nothing at all.
   */
  async reconcile(): Promise<StagedPairing | null> {
    const staged: StagedPairing | null = this.read();
    if (staged === null) {
      Sandbox.removeWithTemporary(FILE);
      return null;
    }
    if (staged.expired) {
      await this.discard(staged.origin);
      return null;
    }
    const presence: CredentialPresence = await this.vault.presence(staged.origin);
    if (presence !== CredentialPresence.Present) {
      // The invitation is spent and the credential is gone: this pairing cannot be
      // finished, and pretending otherwise would leave a promise this device cannot
      // keep.
      await this.discard(staged.origin);
      return null;
    }
    return staged;
  }
}

export type PairingTransaction = StagedSetupStore;
export const PairingTransaction = StagedSetupStore;
export type StagedSetup = StagedPairing;
export const StagedSetup = StagedPairing;
