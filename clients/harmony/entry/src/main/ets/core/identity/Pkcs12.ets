// The PKCS#12 archive a pairing hands out, handled in memory and never on disk in
// the form it arrived in.
//
// What happens here, in order, and why each step exists:
//
//  1. The archive is opened with the one-time credential password. That password
//     exists for this call only: it is the client's own random string, it was never
//     shown to anyone, and it is dropped the moment this returns.
//  2. The certificate's fingerprint is recomputed locally and compared with the
//     one the pairing response claimed. A fingerprint that is merely believed is
//     not evidence of anything.
//  3. The archive is re-encoded under a password this device generates and keeps,
//     which is what makes the API plane possible at all: RCP needs a certificate
//     and a password on every request, and this device's own password — not the
//     pairing one — is what may be stored. Re-encoding also validates the pair: the
//     platform refuses to write an archive whose private key does not match its
//     certificate, which is the check that catches a corrupt credential.
//  4. The result is measured, because the certificate manager refuses a credential
//     larger than 20 KiB and finding that out at install time is finding out late.

import { cert } from '@kit.DeviceCertificateKit';
import { base64Decode, base64Encode, randomBytes, sha256Hex, wipe } from '../model/Digest';
import { CredentialError } from '../model/Errors';

/** The certificate manager's documented ceiling for one credential, in bytes. */
export const MAX_CREDENTIAL_BYTES = 20480;

/** The device's own password: 24 random bytes in base64, which is 32 characters. */
const DEVICE_PASSWORD_BYTES = 24;

export class OpenedCredential {
  /** The archive as it arrived, to be offered to the certificate manager first. */
  readonly original: Uint8Array;
  /** The password that opens `original`, held only for that first attempt. */
  readonly originalPassword: string;
  /** The archive re-encoded under the device's own password. */
  readonly reencoded: Uint8Array;
  /** The password the device keeps, wrapped by HUKS before it is written. */
  readonly devicePassword: string;
  /** SHA-256 of the issued certificate, recomputed here. */
  readonly fingerprint: string;

  constructor(original: Uint8Array, originalPassword: string, reencoded: Uint8Array, devicePassword: string,
    fingerprint: string) {
    this.original = original;
    this.originalPassword = originalPassword;
    this.reencoded = reencoded;
    this.devicePassword = devicePassword;
    this.fingerprint = fingerprint;
  }

  /** Zeroes the archive as it arrived. The re-encoded form is what is kept. */
  wipeOriginal(): void {
    wipe(this.original);
  }
}

export function newDevicePassword(): string {
  return base64Encode(randomBytes(DEVICE_PASSWORD_BYTES));
}

function decodeArchive(encoded: string, what: string): Uint8Array {
  try {
    return base64Decode(encoded.trim());
  } catch (error) {
    throw new CredentialError(`${what} is not base64`);
  }
}

/**
 * Opens a pairing credential and prepares the form this device keeps.
 *
 * `expectedFingerprint` is the pairing response's `certificate_fingerprint`: the
 * locally recomputed one has to match it.
 */
export async function openCredential(base64Pkcs12: string, credentialPassword: string,
  expectedFingerprint: string): Promise<OpenedCredential> {
  const original: Uint8Array = decodeArchive(base64Pkcs12, 'the pairing credential');
  let parsed: cert.Pkcs12Data;
  try {
    parsed = cert.parsePkcs12(original, { password: credentialPassword, needsPrivateKey: true });
  } catch (error) {
    throw new CredentialError('the pairing credential could not be opened');
  }
  const certificate: cert.X509Cert | undefined = parsed.cert;
  if (certificate === undefined || parsed.privateKey === undefined) {
    throw new CredentialError('the pairing credential carries no certificate and key');
  }
  let fingerprint: string;
  try {
    // The certificate's own bytes, hashed here rather than taken on trust.
    const encoded: cert.EncodingBlob = await certificate.getEncoded();
    fingerprint = sha256Hex(encoded.data);
  } catch (error) {
    throw new CredentialError('the issued certificate could not be read');
  }
  if (fingerprint !== expectedFingerprint.toLowerCase()) {
    throw new CredentialError('the issued certificate is not the one the gateway named');
  }

  const devicePassword: string = newDevicePassword();
  let reencoded: Uint8Array;
  try {
    reencoded = cert.createPkcs12Sync(parsed, {
      password: devicePassword,
      encryptCert: true,
      macSaltLen: 16,
      macIterations: 2048
    });
  } catch (error) {
    throw new CredentialError('the credential could not be re-encoded for this device');
  }
  if (reencoded.length > MAX_CREDENTIAL_BYTES) {
    throw new CredentialError('the credential is larger than the certificate manager accepts');
  }
  return new OpenedCredential(original, credentialPassword, reencoded, devicePassword, fingerprint);
}

/** Re-encodes an archive this device kept, under a fresh device password. */
export function repack(p12: Uint8Array, password: string): Uint8Array {
  let parsed: cert.Pkcs12Data;
  try {
    parsed = cert.parsePkcs12(p12, { password: password, needsPrivateKey: true });
  } catch (error) {
    throw new CredentialError('a stored credential could not be opened');
  }
  let reencoded: Uint8Array;
  try {
    reencoded = cert.createPkcs12Sync(parsed, {
      password: password,
      encryptCert: true,
      macSaltLen: 16,
      macIterations: 2048
    });
  } catch (error) {
    throw new CredentialError('a stored credential could not be re-encoded');
  }
  if (reencoded.length > MAX_CREDENTIAL_BYTES) {
    throw new CredentialError('a stored credential is larger than the certificate manager accepts');
  }
  return reencoded;
}
