// The certificate manager: where the private key lives that the WebView signs with.
//
// The key installed here never leaves HUKS — the manager signs with it and offers no
// way to export it, which is the same guarantee AndroidKeyStore gives and the reason
// web traffic is the safe half of this client's two-plane key story.
//
// Two documented limits shape what this file does: an alias is letters, digits and
// underscores only and at most 32 bytes, and one credential may not exceed 20 KiB.
// The alias is therefore the first 32 hex characters of the origin's SHA-256, which
// is derivable from the origin alone and names exactly one gateway.
//
// Nothing here reads an error code. Every operation is followed by a check of the
// state it was supposed to produce, because the codes this API answers with are
// neither complete nor stable.

import { certificateManager } from '@kit.DeviceCertificateKit';
import { sha256HexOfText } from '../model/Digest';
import { CredentialError } from './CredentialError';

export class CertificateVault {
  /** The alias one gateway's credential is installed under. */
  static aliasFor(origin: string): string {
    return sha256HexOfText(origin).substring(0, 32);
  }

  /** The installed credential for an alias, or null. */
  async find(alias: string): Promise<string | null> {
    try {
      const result: certificateManager.CMResult = await certificateManager.getPrivateCertificates();
      const list: certificateManager.CredentialAbstract[] | undefined = result.credentialList;
      if (list === undefined) {
        return null;
      }
      for (const credential of list) {
        if (credential.alias === alias && credential.keyUri !== undefined && credential.keyUri !== '') {
          return credential.keyUri;
        }
      }
      return null;
    } catch (error) {
      return null;
    }
  }

  /** Whether a key reference still resolves to a usable credential. */
  async alive(keyUri: string): Promise<boolean> {
    if (keyUri === '') {
      return false;
    }
    try {
      const result: certificateManager.CMResult = await certificateManager.getPrivateCertificate(keyUri);
      const list: certificateManager.CertAbstract[] | undefined = result.certList;
      return list !== undefined && list.length > 0;
    } catch (error) {
      return false;
    }
  }

  /**
   * Installs one credential under one alias and returns the reference the WebView
   * will use. An alias that is already taken is cleared and the install is retried
   * exactly once: the platform does not document an error for that case, and a
   * second guess at a name that two writers disagree about is worse than a report.
   */
  async install(alias: string, archive: Uint8Array, password: string): Promise<string> {
    const first: string | null = await this.attempt(alias, archive, password);
    if (first !== null) {
      return first;
    }
    const existing: string | null = await this.find(alias);
    if (existing !== null) {
      await this.uninstall(existing);
    }
    const second: string | null = await this.attempt(alias, archive, password);
    if (second !== null) {
      return second;
    }
    throw new CredentialError('the certificate could not be installed');
  }

  /** Installs, then looks the alias up again: the install call is not believed. */
  private async attempt(alias: string, archive: Uint8Array, password: string): Promise<string | null> {
    try {
      await certificateManager.installPrivateCertificate(archive, password, alias);
    } catch (error) {
      // Whether this was a name collision, a password rule or a size limit is not
      // reported by the platform in any way a client may rely on.
    }
    return await this.find(alias);
  }

  /** Removes one credential. A credential that is not there is the state wanted. */
  async uninstall(keyUri: string): Promise<void> {
    try {
      await certificateManager.uninstallPrivateCertificate(keyUri);
    } catch (error) {
      // Nothing to do: the check that follows a removal is what decides.
    }
  }

  /** Removes every credential this app installed. Used only when forgetting a gateway. */
  async uninstallAlias(alias: string): Promise<void> {
    const keyUri: string | null = await this.find(alias);
    if (keyUri !== null) {
      await this.uninstall(keyUri);
    }
  }
}
