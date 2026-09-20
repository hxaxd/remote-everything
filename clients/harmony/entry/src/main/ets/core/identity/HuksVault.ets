// Sealing the API plane's credential at rest.
//
// The WebView's traffic needs no key material at all: the certificate manager holds
// the private key locked in HUKS and only ever signs with it. RCP is different — it
// takes a PKCS#12 archive and its password on every request, so the archive has to
// exist somewhere this process can read it, and the only safe place for it is
// sealed under a key that never leaves HUKS:
//
//   * one HUKS AES-256-GCM key per gateway, generated in HUKS and unexportable;
//   * the archive and its password, concatenated, sealed as one blob;
//   * on disk only that blob — never a PEM, never a bare PKCS#12, never a password.
//
// A request therefore decrypts what it needs into memory, hands it to RCP, and wipes
// it. What is left on disk is ciphertext that only this device's HUKS can open, so
// the residual risk is a debugger attached to a running process, not a file waiting
// to be picked up.

import { util } from '@kit.ArkTS';
import { huks } from '@kit.UniversalKeystoreKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { randomBytes, wipe } from '../model/Digest';
import { CredentialError } from '../model/Errors';

const NONCE_BYTES = 12;
const PASSWORD_LENGTH_BYTES = 2;
const BLOB_VERSION = 1;
const TAG_BYTES = 16;

function uintProperty(tag: huks.HuksTag, value: number): huks.HuksParam {
  return { tag: tag, value: value };
}

function bytesProperty(tag: huks.HuksTag, value: Uint8Array): huks.HuksParam {
  return { tag: tag, value: value };
}

function keyProperties(): huks.HuksParam[] {
  return [
    uintProperty(huks.HuksTag.HUKS_TAG_ALGORITHM, huks.HuksKeyAlg.HUKS_ALG_AES),
    uintProperty(huks.HuksTag.HUKS_TAG_KEY_SIZE, huks.HuksKeySize.HUKS_AES_KEY_SIZE_256),
    uintProperty(huks.HuksTag.HUKS_TAG_PURPOSE,
      huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT),
    uintProperty(huks.HuksTag.HUKS_TAG_PADDING, huks.HuksKeyPadding.HUKS_PADDING_NONE),
    uintProperty(huks.HuksTag.HUKS_TAG_BLOCK_MODE, huks.HuksCipherMode.HUKS_MODE_GCM)
  ];
}

function cipherProperties(purpose: number, nonce: Uint8Array, associatedData: Uint8Array,
  tag?: Uint8Array): huks.HuksParam[] {
  const props: huks.HuksParam[] = [
    uintProperty(huks.HuksTag.HUKS_TAG_ALGORITHM, huks.HuksKeyAlg.HUKS_ALG_AES),
    // Decrypt refuses a session that does not restate the key's size — encrypt
    // tolerates its absence, decrypt answers 401 "the parameter does not exist".
    uintProperty(huks.HuksTag.HUKS_TAG_KEY_SIZE, huks.HuksKeySize.HUKS_AES_KEY_SIZE_256),
    // A session moves one direction only: the purpose is single here, even though
    // the key carries both — the platform answers a combined one with "invalid".
    uintProperty(huks.HuksTag.HUKS_TAG_PURPOSE, purpose),
    uintProperty(huks.HuksTag.HUKS_TAG_PADDING, huks.HuksKeyPadding.HUKS_PADDING_NONE),
    uintProperty(huks.HuksTag.HUKS_TAG_BLOCK_MODE, huks.HuksCipherMode.HUKS_MODE_GCM),
    bytesProperty(huks.HuksTag.HUKS_TAG_NONCE, nonce),
    bytesProperty(huks.HuksTag.HUKS_TAG_ASSOCIATED_DATA, associatedData)
  ];
  if (tag !== undefined && tag.length > 0) {
    props.push(bytesProperty(huks.HuksTag.HUKS_TAG_AE_TAG, tag));
  }
  return props;
}

/** Two byte lengths followed by the password, then the archive. */
function pack(password: string, archive: Uint8Array): Uint8Array {
  let passwordBytes: Uint8Array = new Uint8Array(0);
  try {
    passwordBytes = new Uint8Array(new util.TextEncoder().encodeInto(password));
  } catch (error) {
    throw new CredentialError('a credential password could not be encoded');
  }
  if (passwordBytes.length > 0xffff) {
    throw new CredentialError('a credential password is implausibly long');
  }
  const packed: Uint8Array = new Uint8Array(PASSWORD_LENGTH_BYTES + passwordBytes.length + archive.length);
  packed[0] = (passwordBytes.length >> 8) & 0xff;
  packed[1] = passwordBytes.length & 0xff;
  packed.set(passwordBytes, PASSWORD_LENGTH_BYTES);
  packed.set(archive, PASSWORD_LENGTH_BYTES + passwordBytes.length);
  wipe(passwordBytes);
  return packed;
}

class Unpacked {
  readonly password: string;
  readonly archive: Uint8Array;

  constructor(password: string, archive: Uint8Array) {
    this.password = password;
    this.archive = archive;
  }
}

function unpack(packed: Uint8Array): Unpacked {
  if (packed.length < PASSWORD_LENGTH_BYTES) {
    throw new CredentialError('a sealed credential is truncated');
  }
  const passwordLength: number = (packed[0] << 8) | packed[1];
  if (PASSWORD_LENGTH_BYTES + passwordLength > packed.length) {
    throw new CredentialError('a sealed credential is truncated');
  }
  const passwordBytes: Uint8Array = packed.subarray(PASSWORD_LENGTH_BYTES, PASSWORD_LENGTH_BYTES + passwordLength);
  let password: string;
  try {
    password = new util.TextDecoder().decodeToString(passwordBytes);
  } catch (error) {
    throw new CredentialError('a sealed credential holds no readable password');
  }
  const archive: Uint8Array = packed.subarray(PASSWORD_LENGTH_BYTES + passwordLength);
  return new Unpacked(password, archive);
}

export class SealedCredential {
  readonly password: string;
  readonly archive: Uint8Array;

  constructor(password: string, archive: Uint8Array) {
    this.password = password;
    this.archive = archive;
  }

  wipe(): void {
    wipe(this.archive);
  }
}

export class HuksVault {
  /** Generates the gateway's sealing key if it is not there yet. */
  private async ensureKey(alias: string): Promise<void> {
    const options: huks.HuksOptions = { properties: keyProperties() };
    let exists: boolean;
    try {
      exists = await huks.isKeyItemExist(alias, options);
    } catch (error) {
      const business: BusinessError = error as BusinessError;
      if (business.code === 12000011) {
        // The platform answers "no such key" by throwing 12000011, not by
        // returning false — the first pairing on a device always comes this way.
        exists = false;
      } else {
        const detail: string = `${business.code ?? ''} ${business.message ?? ''}`.trim();
        hilog.error(0x0000, 'RemoteEverything', `sealing key unavailable for ${alias}: ${detail}`);
        throw new CredentialError(detail === '' ? 'the sealing key is not available' :
          `the sealing key is not available (${detail})`);
      }
    }
    if (exists) {
      return;
    }
    try {
      await huks.generateKeyItem(alias, options);
    } catch (error) {
      const business: BusinessError = error as BusinessError;
      const detail: string = `${business.code ?? ''} ${business.message ?? ''}`.trim();
      hilog.error(0x0000, 'RemoteEverything', `sealing key generation failed for ${alias}: ${detail}`);
      throw new CredentialError(detail === '' ? 'the sealing key could not be generated' :
        `the sealing key could not be generated (${detail})`);
    }
  }

  /** Seals one credential: `nonce || ciphertext`, with the gateway's name as tag. */
  async seal(alias: string, associatedData: Uint8Array, password: string, archive: Uint8Array): Promise<Uint8Array> {
    await this.ensureKey(alias);
    const nonce: Uint8Array = new Uint8Array(NONCE_BYTES);
    nonce.set(randomBytes(NONCE_BYTES));
    const packed: Uint8Array = pack(password, archive);
    let handle: number = -1;
    try {
      const session: huks.HuksSessionHandle = await huks.initSession(alias, {
        properties: cipherProperties(huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT, nonce, associatedData)
      });
      handle = session.handle;
      const finished: huks.HuksReturnResult = await huks.finishSession(handle, {
        properties: [],
        inData: packed
      });
      handle = -1;
      let ciphertext: Uint8Array | undefined = finished.outData;
      if (ciphertext === undefined || ciphertext.length === 0) {
        throw new CredentialError('the platform returned no sealed credential');
      }
      if (ciphertext.length === packed.length && finished.properties !== undefined) {
        for (const p of finished.properties) {
          if (p.tag === huks.HuksTag.HUKS_TAG_AE_TAG && p.value instanceof Uint8Array) {
            const combined: Uint8Array = new Uint8Array(ciphertext.length + p.value.length);
            combined.set(ciphertext, 0);
            combined.set(p.value, ciphertext.length);
            ciphertext = combined;
            break;
          }
        }
      }
      const blob: Uint8Array = new Uint8Array(1 + NONCE_BYTES + ciphertext.length);
      blob[0] = BLOB_VERSION;
      blob.set(nonce, 1);
      blob.set(ciphertext, 1 + NONCE_BYTES);
      return blob;
    } catch (error) {
      if (handle >= 0) {
        await this.abort(handle, alias);
      }
      if (error instanceof CredentialError) {
        throw error;
      }
      const business: BusinessError = error as BusinessError;
      const detail: string = `${business.code ?? ''} ${business.message ?? ''}`.trim();
      hilog.error(0x0000, 'RemoteEverything', `seal failed for ${alias}: ${detail}`);
      throw new CredentialError(detail === '' ? 'the credential could not be sealed' :
        `the credential could not be sealed (${detail})`);
    } finally {
      wipe(packed);
    }
  }

  /** Opens a sealed credential. Any failure here means the credential is gone. */
  async unseal(alias: string, associatedData: Uint8Array, blob: Uint8Array): Promise<SealedCredential> {
    if (blob.length <= 1 + NONCE_BYTES + TAG_BYTES || blob[0] !== BLOB_VERSION) {
      throw new CredentialError('a sealed credential is not readable');
    }
    const nonce: Uint8Array = blob.subarray(1, 1 + NONCE_BYTES);
    const ciphertextWithTag: Uint8Array = blob.subarray(1 + NONCE_BYTES);
    const tag: Uint8Array = ciphertextWithTag.subarray(ciphertextWithTag.length - TAG_BYTES);
    const ciphertextOnly: Uint8Array = ciphertextWithTag.subarray(0, ciphertextWithTag.length - TAG_BYTES);
    const properties: huks.HuksParam[] =
      cipherProperties(huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT, nonce, associatedData, tag);
    let handle: number = -1;
    try {
      const session: huks.HuksSessionHandle = await huks.initSession(alias, {
        properties: properties
      });
      handle = session.handle;
      hilog.info(0x0000, 'RemoteEverything', `unseal init ok for ${alias}`);
      const finished: huks.HuksReturnResult = await huks.finishSession(handle, {
        properties: properties,
        inData: ciphertextOnly
      });
      handle = -1;
      const packed: Uint8Array | undefined = finished.outData;
      if (packed === undefined) {
        throw new CredentialError('a sealed credential could not be opened');
      }
      const unpacked: Unpacked = unpack(packed);
      const password: string = unpacked.password;
      const archive: Uint8Array = new Uint8Array(unpacked.archive.length);
      archive.set(unpacked.archive);
      wipe(packed);
      return new SealedCredential(password, archive);
    } catch (error) {
      if (handle >= 0) {
        await this.abort(handle, alias);
      }
      if (error instanceof CredentialError) {
        throw error;
      }
      const business: BusinessError = error as BusinessError;
      const detail: string = `${business.code ?? ''} ${business.message ?? ''}`.trim();
      hilog.error(0x0000, 'RemoteEverything',
        `unseal failed for ${alias} (blob ${blob.length} bytes): ${detail}`);
      throw new CredentialError(detail === '' ? 'a sealed credential could not be opened' :
        `a sealed credential could not be opened (${detail})`);
    }
  }

  /** Diagnostic self-test verifying encryption and decryption round-trip on this platform. */
  async selfTest(): Promise<boolean> {
    const alias: string = 'remote_everything_selftest';
    const aad: Uint8Array = new Uint8Array([1, 2, 3, 4]);
    const pwd: string = 'selftest-pwd';
    const testData: Uint8Array = new Uint8Array([10, 20, 30, 40, 50, 60, 70, 80]);
    try {
      const sealed: Uint8Array = await this.seal(alias, aad, pwd, testData);
      const unsealed: SealedCredential = await this.unseal(alias, aad, sealed);
      const matches: boolean = unsealed.password === pwd && unsealed.archive.length === testData.length &&
        unsealed.archive[0] === testData[0] && unsealed.archive[7] === testData[7];
      unsealed.wipe();
      hilog.info(0x0000, 'RemoteEverything', `HuksVault selfTest result: ${matches ? 'PASS' : 'FAIL'}`);
      return matches;
    } catch (error) {
      const business: BusinessError = error as BusinessError;
      hilog.error(0x0000, 'RemoteEverything', `HuksVault selfTest threw error: ${business.message ?? error}`);
      return false;
    } finally {
      await this.destroy(alias);
    }
  }

  /** Removes the sealing key, and with it every credential sealed under it. */
  async destroy(alias: string): Promise<void> {
    try {
      await huks.deleteKeyItem(alias, { properties: keyProperties() });
    } catch (error) {
      // A key that is not there is the state this call wanted.
    }
  }

  private async abort(handle: number, alias: string): Promise<void> {
    try {
      await huks.abortSession(handle, { properties: keyProperties() });
    } catch (error) {
      // The session is gone either way.
    }
  }
}
