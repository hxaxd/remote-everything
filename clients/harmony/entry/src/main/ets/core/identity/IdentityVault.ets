// The credential library: one identity per gateway origin, and the only place the
// key material behind one is handled.
//
// Three things are kept for each gateway, and none of them is a bare key:
//
//   * the certificate manager's entry — signing for the WebView, private key locked
//     in HUKS, referenced by `credentialRef`;
//   * a sealed archive under `identity/<hex of origin>.sealed`, which is what the API
//     plane opens in memory per request (see HuksVault);
//   * the identity record in the store, which names both.
//
// The pairing credential password is used once, inside `adopt`, and never written
// anywhere: what this device keeps is an archive re-encoded under a password this
// device generated itself.

import { util } from '@kit.ArkTS';
import { ServerPin } from '../model/Models';
import { Sandbox } from '../store/Sandbox';
import { CertificateVault } from './CertificateVault';
import { CredentialError, CredentialPresence } from './CredentialError';
import { utf8Hex, wipe } from './Digest';
import { HuksVault, SealedCredential } from './HuksVault';
import { openCredential, OpenedCredential } from './Pkcs12';

/** What a completed import leaves behind: the certificate reference, and its fingerprint. */
export class StoredCredential {
  readonly keyUri: string;
  readonly fingerprint: string;

  constructor(keyUri: string, fingerprint: string) {
    this.keyUri = keyUri;
    this.fingerprint = fingerprint;
  }
}

/** An archive and the password that opens it, in memory, for as long as one request. */
export class CredentialMaterial {
  readonly archive: Uint8Array;
  readonly password: string;

  constructor(archive: Uint8Array, password: string) {
    this.archive = archive;
    this.password = password;
  }

  wipe(): void {
    wipe(this.archive);
  }
}

/** The identity the WebView presents: a reference the certificate manager can sign with. */
export class WebGatewayIdentity {
  readonly keyUri: string;
  readonly serverPin: ServerPin | null;

  constructor(keyUri: string, serverPin: ServerPin | null) {
    this.keyUri = keyUri;
    this.serverPin = serverPin;
  }
}

export class IdentityVault {
  private readonly huks: HuksVault = new HuksVault();
  private readonly certificates: CertificateVault = new CertificateVault();

  private static sealAlias(origin: string): string {
    return `remote_everything_credential_${utf8Hex(origin).substring(0, 32)}`;
  }

  private static sealedFile(origin: string): string {
    return `identity/${Sandbox.originKey(origin)}.sealed`;
  }

  /** The name this gateway's credential is installed under in the certificate manager. */
  static certificateAlias(origin: string): string {
    return CertificateVault.aliasFor(origin);
  }

  /**
   * Takes in a pairing credential: opens it, verifies it, installs it for the
   * WebView, and seals the archive this device keeps for the API plane. What the
   * certificate manager is offered first is the archive exactly as the gateway
   * issued it; a gateway whose encoding the manager will not take is served by the
   * re-encoded form, which is kept either way.
   */
  async adopt(origin: string, base64Pkcs12: string, credentialPassword: string,
    expectedFingerprint: string): Promise<StoredCredential> {
    let opened: OpenedCredential | null = null;
    try {
      opened = await openCredential(base64Pkcs12, credentialPassword, expectedFingerprint);
      const alias: string = IdentityVault.certificateAlias(origin);
      let keyUri: string;
      try {
        keyUri = await this.certificates.install(alias, opened.original, opened.originalPassword);
      } catch (directError) {
        keyUri = await this.certificates.install(alias, opened.reencoded, opened.devicePassword);
      }
      const sealed: Uint8Array = await this.huks.seal(IdentityVault.sealAlias(origin),
        this.associatedData(origin), opened.devicePassword, opened.reencoded);
      Sandbox.ensureDirectory('identity');
      Sandbox.writeBytesAtomic(IdentityVault.sealedFile(origin), sealed);
      return new StoredCredential(keyUri, opened.fingerprint);
    } finally {
      if (opened !== null) {
        // The archive as it arrived is not kept, in any form.
        opened.wipeOriginal();
      }
    }
  }

  /** The reference the WebView signs with, installed if that had to be redone. */
  async webIdentity(origin: string): Promise<string> {
    const alias: string = IdentityVault.certificateAlias(origin);
    const existing: string | null = await this.certificates.find(alias);
    if (existing !== null && await this.certificates.alive(existing)) {
      return existing;
    }
    // The entry is gone or no longer resolves — a system cleanup, a restore, or a
    // manager that dropped it. The sealed archive is still evidence that this device
    // was paired, so the entry is made again from it rather than making the user pair
    // a second time.
    const material: CredentialMaterial = await this.material(origin);
    try {
      return await this.certificates.install(alias, material.archive, material.password);
    } finally {
      material.wipe();
    }
  }

  /** The archive and password for an API request. The caller wipes what it gets. */
  async material(origin: string): Promise<CredentialMaterial> {
    const file: string = IdentityVault.sealedFile(origin);
    const sealed: Uint8Array | null = Sandbox.readBytes(file);
    if (sealed === null) {
      throw new CredentialError('this gateway has no credential on this device');
    }
    const unwrapped: SealedCredential = await this.huks.unseal(IdentityVault.sealAlias(origin),
      this.associatedData(origin), sealed);
    return new CredentialMaterial(unwrapped.archive, unwrapped.password);
  }

  /** Whether this gateway's credential can still be read at all. */
  async presence(origin: string): Promise<CredentialPresence> {
    try {
      const material: CredentialMaterial = await this.material(origin);
      material.wipe();
      return CredentialPresence.Present;
    } catch (error) {
      return CredentialPresence.Missing;
    }
  }

  /**
   * Removes everything this device holds for one gateway: the certificate manager's
   * entry, the sealing key, and the sealed archive. It is the first half of
   * forgetting an identity, and it leaves nothing behind on its own side.
   */
  async forget(origin: string): Promise<void> {
    await this.certificates.uninstallAlias(IdentityVault.certificateAlias(origin));
    await this.huks.destroy(IdentityVault.sealAlias(origin));
    Sandbox.removeWithTemporary(IdentityVault.sealedFile(origin));
  }

  /** A gateway's name, bound into every sealing operation so a file cannot be moved between them. */
  private associatedData(origin: string): Uint8Array {
    return new util.TextEncoder().encodeInto(`remote-everything:${origin}`);
  }
}
