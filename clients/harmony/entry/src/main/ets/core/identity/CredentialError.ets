// The one error type this package raises. It carries no user-facing text: the app
// layer maps a failure to a resource key, the same way it does for the wire's codes.

export class CredentialError extends Error {
  readonly detail: string;

  constructor(detail: string) {
    super(detail);
    this.detail = detail;
  }
}

/** What state one gateway's credential is in, as far as this device can tell. */
export enum CredentialPresence {
  /** Both halves are there and the certificate is installed. */
  Present = 'present',
  /** A credential was recorded but cannot be read: pairing is needed again. */
  Missing = 'missing'
}
