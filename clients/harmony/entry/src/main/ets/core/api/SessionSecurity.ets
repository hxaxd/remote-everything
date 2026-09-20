// The security half of a session, split out of the transport so the connection
// mechanics and the trust decision do not share one file: what makes a connection
// to one gateway safe to speak to, and the reading of the certificate that decision
// needs.
//
// Server certificates:
//   * a gateway that signs its own certificate (a LAN entrance) is verified against
//     the pin its invitation carried: the public key the platform pins, and this
//     client's own check of the public key or the certificate fingerprint. Nothing
//     else is accepted, and there is no way to continue past a mismatch.
//   * a gateway with a domain uses the platform's own verification, and carries no
//     pin: its certificate is renewed by whoever signs it, and pinning a CA is how a
//     client locks itself out.

import { rcp } from '@kit.RemoteCommunicationKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { cert } from '@kit.DeviceCertificateKit';
import { ServerPin } from '../model/Models';
import { certificateMatchesPin } from './Pinning';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'RemoteEverything';

/** The reason of the most recent refused pin, so a diagnostic report can say why. */
let lastPinReason: string | null = null;

/** The reason a pin was last refused, or null when none has been this run. */
export function lastPinFailureReason(): string | null {
  return lastPinReason;
}

interface PinnedDecision {
  readonly accepted: boolean;
  readonly reason: string;
}

function pemToDer(pem: string): Uint8Array | null {
  const begin: number = pem.indexOf('-----BEGIN CERTIFICATE-----');
  const end: number = pem.indexOf('-----END CERTIFICATE-----');
  if (begin < 0 || end < 0 || end <= begin) {
    return null;
  }
  const body: string = pem.substring(begin + '-----BEGIN CERTIFICATE-----'.length, end).replace(/\s+/g, '');
  try {
    const helper: util.Base64Helper = new util.Base64Helper();
    return helper.decodeSync(body, util.Type.BASIC);
  } catch (error) {
    return null;
  }
}

/**
 * A pinned gateway's certificate, checked against what its invitation said. The
 * decision itself lives in core/api/Pinning so the API plane and the WebView
 * cannot disagree about it.
 */
function pinDecision(chainPem: string[], pin: ServerPin, host?: string): PinnedDecision {
  if (chainPem.length === 0) {
    return { accepted: false, reason: 'the gateway presented no certificate' };
  }
  const leaf: Uint8Array | null = pemToDer(chainPem[0]);
  if (leaf === null) {
    return { accepted: false, reason: 'the gateway certificate could not be read' };
  }
  if (certificateMatchesPin(leaf, pin, host)) {
    return { accepted: true, reason: 'the certificate this device was told to expect' };
  }
  return { accepted: false, reason: 'the gateway presents a certificate this device was not told to expect' };
}

/** The platform's own validity strings are UTC stamps, but the width is not a given:
 * some builds say `YYYYMMDDHHMMSSZ`, others `YYMMDDHHMMSSZ`. What sorts correctly in
 * both cases is the digits alone, with a two-digit year grown to four. */
function stampDigits(value: string): string {
  let digits: string = '';
  for (let index: number = 0; index < value.length; index += 1) {
    const character: string = value.charAt(index);
    if (character >= '0' && character <= '9') {
      digits += character;
    }
  }
  if (digits.length === 12) {
    digits = `20${digits}`;
  }
  return digits;
}

function utcStampNow(): string {
  const now: Date = new Date();
  const pad = (value: number): string => value < 10 ? `0${value}` : `${value}`;
  return `${now.getUTCFullYear()}${pad(now.getUTCMonth() + 1)}${pad(now.getUTCDate())}` +
    `${pad(now.getUTCHours())}${pad(now.getUTCMinutes())}${pad(now.getUTCSeconds())}`;
}

function withinValidity(notBefore: string, notAfter: string): boolean {
  const from: string = stampDigits(notBefore);
  const to: string = stampDigits(notAfter);
  if (from.length === 0 || to.length === 0) {
    // The platform's answer was unreadable; the pin is the security decision and it stands.
    return true;
  }
  const now: string = stampDigits(utcStampNow());
  return now >= from && now <= to;
}

/** The security of a request that arrives with no credential: the release manifest, or a pairing. */
export function anonymousSecurity(pin: ServerPin | null, host?: string): rcp.SecurityConfiguration {
  if (pin === null) {
    const plain: rcp.SecurityConfiguration = { remoteValidation: 'system' };
    return plain;
  }
  return pinnedSecurity(pin, host);
}

/**
 * A self-signed gateway's security: one gate, this client's own validation, which
 * accepts the key the invitation named or the certificate's fingerprint. The
 * platform's own public-key pinning is deliberately not stacked on top of it — rcp
 * applies its pins inside the handshake, before any callback, and a self-signed
 * chain dies there with "peer certificate not OK" (rcp 1007900060) instead of ever
 * reaching the decision this client was asked to make.
 */
export function pinnedSecurity(pin: ServerPin, host?: string): rcp.SecurityConfiguration {
  const validate: rcp.ValidationCallback = (context: rcp.ValidationContext): boolean => {
    if (!pinDecision(context.pemCerts, pin, host).accepted) {
      // The refusal is only as good as its reason: a pairing that fails says "no"
      // without saying why, to the log and to nobody else. The reason is kept so
      // the next thing a person reads — the diagnostic report — can say it.
      const reason: string = pinDecision(context.pemCerts, pin, host).reason;
      lastPinReason = reason;
      hilog.error(LOG_DOMAIN, LOG_TAG,
        `pinned validation refused: ${reason}; pem=${context.pemCerts.length} x509=${context.x509Certs.length} host=${host ?? ''}`);
      return false;
    }
    if (context.x509Certs.length === 0) {
      return true;
    }
    let notBefore: string = '';
    let notAfter: string = '';
    let within: boolean = true;
    try {
      notBefore = context.x509Certs[0].getNotBeforeTime();
      notAfter = context.x509Certs[0].getNotAfterTime();
      within = withinValidity(notBefore, notAfter);
    } catch (error) {
      // The window could not be read; the pin still stands.
      within = true;
    }
    if (!within) {
      lastPinReason = 'the gateway certificate is outside its validity window';
      hilog.error(LOG_DOMAIN, LOG_TAG,
        `pinned validation refused: certificate outside its validity window; notBefore=${notBefore} notAfter=${notAfter}`);
    }
    return within;
  };
  const security: rcp.SecurityConfiguration = {
    remoteValidation: validate
  };
  return security;
}
