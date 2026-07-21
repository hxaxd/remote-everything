/**
 * Decoded pairing credential from the server. Mirrors Android's `PairingCredential`.
 */
export class PairingCredential {
  readonly encoded: string;
  readonly fingerprint: string;
  readonly pendingExpiresAt: string;

  constructor(encoded: string, fingerprint: string, pendingExpiresAt: string) {
    this.encoded = encoded;
    this.fingerprint = fingerprint;
    this.pendingExpiresAt = pendingExpiresAt;
  }
}
