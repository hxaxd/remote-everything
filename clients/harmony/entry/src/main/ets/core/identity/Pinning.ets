// Whether a self-signed gateway's certificate is the one this device was told to
// expect.
//
// The pin arrives in the invitation as two halves: the SHA-256 of the certificate's
// SubjectPublicKeyInfo, which survives a renewal that keeps the key, and the
// certificate's own fingerprint, which does not but is exact. Both are checked, and
// either one matching is enough — that is what makes a gateway which renewed its
// certificate without changing its key keep working, while a substituted certificate
// fails. There is no way to continue past a mismatch.
//
// Two callers use this and they arrive with different material: the API plane has PEM
// text from the transport's validation callback, and the WebView has the DER chain the
// kernel hands over. The decision itself lives here so the two cannot drift.

import { ServerPin } from '../model/Models';
import { base64Encode, sha256, toHex } from '../model/Digest';
import { certificateCoversHost, isCertificateValid, subjectPublicKeyInfo } from './Spki';

export enum PinVerdict {
  /** The certificate is the one this device holds. */
  Trusted = 'trusted',
  /** It is not, or it could not be read. */
  Refused = 'refused'
}

/** The fingerprint half of the pin: SHA-256 over the certificate itself. */
export function certificateFingerprint(certificateDer: Uint8Array): string {
  return toHex(sha256(certificateDer));
}

/** The key half of the pin: SHA-256 over the certificate's SubjectPublicKeyInfo, base64. */
export function publicKeyPin(certificateDer: Uint8Array): string | null {
  try {
    return base64Encode(sha256(subjectPublicKeyInfo(certificateDer)));
  } catch (error) {
    return null;
  }
}

/** Whether one certificate may be used for one pinned gateway. */
export function certificateMatchesPin(certificateDer: Uint8Array, pin: ServerPin, host?: string): boolean {
  if (!isCertificateValid(certificateDer)) {
    return false;
  }
  if (host && !certificateCoversHost(certificateDer, host)) {
    return false;
  }
  if (certificateFingerprint(certificateDer) === pin.certFingerprint) {
    return true;
  }
  const key: string | null = publicKeyPin(certificateDer);
  return key !== null && key === pin.publicKeyPin;
}

/** Whether a chain's leaf certificate may be used for one pinned gateway. */
export function chainMatchesPin(chain: Uint8Array[], pin: ServerPin, host?: string): PinVerdict {
  if (chain.length === 0) {
    return PinVerdict.Refused;
  }
  return certificateMatchesPin(chain[0], pin, host) ? PinVerdict.Trusted : PinVerdict.Refused;
}
