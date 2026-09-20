// Extracting SubjectPublicKeyInfo from a certificate, by hand.
//
// The pin a LAN gateway hands out in its invitation is the SHA-256 of that
// certificate's SubjectPublicKeyInfo, and that is the pin that survives a renewal
// which keeps the key. Verifying it from inside the
// app needs the SPKI bytes of a peer certificate, and the platform offers no API
// that returns them: `X509Cert.getPublicKey()` hands back a key object whose DER
// encoding is a raw ECC point rather than the SPKI structure, so it is not the same
// bytes the pin was computed over.
//
// So the structure is read here instead. DER is a TLV encoding with a handful of
// rules, and only two paths are needed:
//
//   Certificate    ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
//   TBSCertificate ::= SEQUENCE {
//                        [0] version, serialNumber, signature, issuer, validity,
//                        subject, subjectPublicKeyInfo, ... }
//
// Everything is bounds-checked and anything unexpected is a refusal: this decides
// whether a TLS connection to a self-signed gateway is allowed to continue, and a
// parser that guesses is worse than one that says no.

export class DerError extends Error {
  constructor(message: string) {
    super(message);
  }
}

class Element {
  readonly tag: number;
  readonly start: number;
  readonly contentStart: number;
  readonly end: number;

  constructor(tag: number, start: number, contentStart: number, end: number) {
    this.tag = tag;
    this.start = start;
    this.contentStart = contentStart;
    this.end = end;
  }
}

function readElement(data: Uint8Array, offset: number): Element {
  if (offset + 2 > data.length) {
    throw new DerError('a DER element is truncated');
  }
  const tag: number = data[offset];
  let cursor: number = offset + 1;
  const first: number = data[cursor];
  cursor += 1;
  let length: number = 0;
  if ((first & 0x80) === 0) {
    length = first;
  } else {
    const count: number = first & 0x7f;
    if (count === 0 || count > 4 || cursor + count > data.length) {
      throw new DerError('a DER length is not readable');
    }
    for (let index: number = 0; index < count; index += 1) {
      length = length * 256 + data[cursor + index];
    }
    cursor += count;
  }
  const end: number = cursor + length;
  if (length < 0 || end > data.length) {
    throw new DerError('a DER element runs past the end of the document');
  }
  return new Element(tag, offset, cursor, end);
}

function children(data: Uint8Array, parent: Element): Element[] {
  const found: Element[] = [];
  let cursor: number = parent.contentStart;
  while (cursor < parent.end) {
    const element: Element = readElement(data, cursor);
    found.push(element);
    cursor = element.end;
  }
  if (cursor !== parent.end) {
    throw new DerError('a DER element is not aligned with its parent');
  }
  return found;
}

/**
 * The SubjectPublicKeyInfo of a DER certificate, encoded as the DER element itself
 * — which is what the gateway hashed to produce `public_key_pin`.
 */
export function subjectPublicKeyInfo(certificate: Uint8Array): Uint8Array {
  const outer: Element = readElement(certificate, 0);
  if (outer.tag !== 0x30 || outer.end !== certificate.length) {
    throw new DerError('a certificate is a SEQUENCE and nothing else');
  }
  const parts: Element[] = children(certificate, outer);
  if (parts.length < 3 || parts[0].tag !== 0x30) {
    throw new DerError('a certificate does not start with its tbsCertificate');
  }
  const tbs: Element[] = children(certificate, parts[0]);
  let index: number = 0;
  if (tbs.length > 0 && tbs[0].tag === 0xa0) {
    // An explicit version tag is optional: version 1 omits it.
    index = 1;
  }
  // serialNumber, signature, issuer, validity and subject come before the key.
  const skipped: number = 5;
  if (tbs.length < index + skipped + 1) {
    throw new DerError('a certificate names no public key');
  }
  const spki: Element = tbs[index + skipped];
  if (spki.tag !== 0x30) {
    throw new DerError('a certificate public key is not a SEQUENCE');
  }
  return certificate.subarray(spki.start, spki.end);
}

function parseAsn1Time(data: Uint8Array, element: Element): number {
  let text: string = '';
  for (let index: number = element.contentStart; index < element.end; index += 1) {
    text += String.fromCharCode(data[index]);
  }
  let year: number = 0;
  let month: number = 0;
  let day: number = 0;
  let hour: number = 0;
  let min: number = 0;
  let sec: number = 0;

  if (element.tag === 0x17) {
    if (text.length < 10) {
      throw new DerError('UTCTime is truncated');
    }
    const yy: number = Number.parseInt(text.substring(0, 2), 10);
    year = yy >= 50 ? 1900 + yy : 2000 + yy;
    month = Number.parseInt(text.substring(2, 4), 10);
    day = Number.parseInt(text.substring(4, 6), 10);
    hour = Number.parseInt(text.substring(6, 8), 10);
    min = Number.parseInt(text.substring(8, 10), 10);
    if (text.length >= 12 && text.charAt(10) !== 'Z' && text.charAt(10) !== '+' && text.charAt(10) !== '-') {
      sec = Number.parseInt(text.substring(10, 12), 10);
    }
  } else if (element.tag === 0x18) {
    if (text.length < 12) {
      throw new DerError('GeneralizedTime is truncated');
    }
    year = Number.parseInt(text.substring(0, 4), 10);
    month = Number.parseInt(text.substring(4, 6), 10);
    day = Number.parseInt(text.substring(6, 8), 10);
    hour = Number.parseInt(text.substring(8, 10), 10);
    min = Number.parseInt(text.substring(10, 12), 10);
    if (text.length >= 14 && text.charAt(12) !== 'Z' && text.charAt(12) !== '.') {
      sec = Number.parseInt(text.substring(12, 14), 10);
    }
  } else {
    throw new DerError('unsupported ASN.1 time tag in certificate');
  }

  if (Number.isNaN(year) || Number.isNaN(month) || Number.isNaN(day) ||
      Number.isNaN(hour) || Number.isNaN(min) || Number.isNaN(sec)) {
    throw new DerError('failed to parse date components');
  }

  return Date.UTC(year, month - 1, day, hour, min, sec);
}

export class CertValidity {
  readonly notBefore: number;
  readonly notAfter: number;

  constructor(notBefore: number, notAfter: number) {
    this.notBefore = notBefore;
    this.notAfter = notAfter;
  }
}

/**
 * Parses notBefore and notAfter (epoch ms) from a DER certificate.
 */
export function certificateValidity(certificate: Uint8Array): CertValidity {
  const outer: Element = readElement(certificate, 0);
  if (outer.tag !== 0x30 || outer.end !== certificate.length) {
    throw new DerError('a certificate is a SEQUENCE and nothing else');
  }
  const parts: Element[] = children(certificate, outer);
  if (parts.length < 3 || parts[0].tag !== 0x30) {
    throw new DerError('a certificate does not start with its tbsCertificate');
  }
  const tbs: Element[] = children(certificate, parts[0]);
  let index: number = 0;
  if (tbs.length > 0 && tbs[0].tag === 0xa0) {
    index = 1;
  }
  if (tbs.length < index + 4) {
    throw new DerError('a certificate has no validity field');
  }
  const validity: Element = tbs[index + 3];
  if (validity.tag !== 0x30) {
    throw new DerError('a certificate validity is not a SEQUENCE');
  }
  const times: Element[] = children(certificate, validity);
  if (times.length < 2) {
    throw new DerError('validity does not contain notBefore and notAfter');
  }
  const notBefore: number = parseAsn1Time(certificate, times[0]);
  const notAfter: number = parseAsn1Time(certificate, times[1]);
  return new CertValidity(notBefore, notAfter);
}

/**
 * Checks if the certificate is currently within its valid date range.
 */
export function isCertificateValid(certificate: Uint8Array, nowMs: number = Date.now()): boolean {
  try {
    const v: CertValidity = certificateValidity(certificate);
    return nowMs >= v.notBefore && nowMs <= v.notAfter;
  } catch (error) {
    return false;
  }
}

function dnsNameMatches(pattern: string, host: string): boolean {
  const p = pattern.toLowerCase();
  const h = host.toLowerCase();
  if (!p.startsWith('*.')) {
    return p === h;
  }
  const suffix = p.substring(2);
  if (!h.endsWith('.' + suffix)) {
    return false;
  }
  const prefix = h.substring(0, h.length - suffix.length - 1);
  return !prefix.includes('.');
}

/** The 16 bytes of an iPAddress SAN, as the eight groups an IPv6 text is compared as. */
function ipv6FromBytes(bytes: Uint8Array, start: number): string {
  const groups: string[] = [];
  for (let i = 0; i < 8; i++) {
    const hi = bytes[start + i * 2];
    const lo = bytes[start + i * 2 + 1];
    groups.push(((hi << 8) | lo).toString(16).padStart(4, '0'));
  }
  return groups.join(':');
}

/** An IPv6 address as its full eight groups, or null when it is not one. */
function ipv6Expanded(text: string): string | null {
  const t: string = text.toLowerCase();
  if (t.includes('.')) {
    return null; // IPv4-embedded forms are not matched here
  }
  let parts: string[];
  const doubleColon: number = t.indexOf('::');
  if (doubleColon >= 0) {
    const left: string[] = t.substring(0, doubleColon).split(':').filter(s => s.length > 0);
    const right: string[] = t.substring(doubleColon + 2).split(':').filter(s => s.length > 0);
    if (left.length + right.length > 7) {
      return null;
    }
    const missing: number = 8 - left.length - right.length;
    parts = [...left, ...new Array<string>(missing).fill('0'), ...right];
  } else {
    parts = t.split(':');
    if (parts.length !== 8) {
      return null;
    }
  }
  if (parts.some(p => !/^[0-9a-f]{1,4}$/.test(p))) {
    return null;
  }
  return parts.map(p => p.padStart(4, '0')).join(':');
}

/**
 * Whether a certificate covers a given host via SubjectAlternativeName (DNS / IP)
 * or Subject CommonName fallback.
 */
export function certificateCoversHost(certificate: Uint8Array, host: string): boolean {
  if (!host || host.trim() === '') {
    return true;
  }
  const wanted: string = host.trim().toLowerCase();
  // The host a transport reports for an IPv6 origin keeps its brackets; a SAN
  // never does. The plain form is what an address is matched as.
  const wantedPlain: string = wanted.startsWith('[') && wanted.endsWith(']')
    ? wanted.substring(1, wanted.length - 1) : wanted;
  try {
    const outer: Element = readElement(certificate, 0);
    if (outer.tag !== 0x30) return false;
    const parts: Element[] = children(certificate, outer);
    if (parts.length < 1 || parts[0].tag !== 0x30) return false;
    const tbs: Element[] = children(certificate, parts[0]);
    let index: number = 0;
    if (tbs.length > 0 && tbs[0].tag === 0xa0) {
      index = 1;
    }
    const names: string[] = [];
    let hasSan = false;

    // Search extensions for SAN (OID 2.5.29.17: 0x55, 0x1d, 0x11)
    for (let i = index + 6; i < tbs.length; i++) {
      if (tbs[i].tag === 0xa3) {
        const extWrapper = children(certificate, tbs[i]);
        if (extWrapper.length > 0 && extWrapper[0].tag === 0x30) {
          const extensions = children(certificate, extWrapper[0]);
          for (const ext of extensions) {
            const extParts = children(certificate, ext);
            if (extParts.length >= 2 && extParts[0].tag === 0x06) {
              const oid = certificate.subarray(extParts[0].contentStart, extParts[0].end);
              if (oid.length === 3 && oid[0] === 0x55 && oid[1] === 0x1d && oid[2] === 0x11) {
                const octet = extParts[extParts.length - 1];
                if (octet.tag === 0x04) {
                  const sanSeq = readElement(certificate, octet.contentStart);
                  if (sanSeq.tag === 0x30) {
                    const generalNames = children(certificate, sanSeq);
                    for (const gn of generalNames) {
                      if (gn.tag === 0x82) { // dNSName [2]
                        hasSan = true;
                        let name = '';
                        for (let b = gn.contentStart; b < gn.end; b++) {
                          name += String.fromCharCode(certificate[b]);
                        }
                        names.push(name.trim().toLowerCase());
                      } else if (gn.tag === 0x87) { // iPAddress [7]
                        hasSan = true;
                        const ipLen = gn.end - gn.contentStart;
                        if (ipLen === 4) {
                          const ip = `${certificate[gn.contentStart]}.${certificate[gn.contentStart + 1]}.${certificate[gn.contentStart + 2]}.${certificate[gn.contentStart + 3]}`;
                          names.push(ip);
                        } else if (ipLen === 16) {
                          names.push(ipv6FromBytes(certificate, gn.contentStart));
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }

    if (hasSan) {
      const expandedWanted: string | null = wantedPlain.includes(':') ? ipv6Expanded(wantedPlain) : null;
      return names.some((n: string) => dnsNameMatches(n, wantedPlain) || n === wantedPlain ||
        (expandedWanted !== null && n.includes(':') && ipv6Expanded(n) === expandedWanted));
    }

    // Fallback: CommonName in Subject (tbs[index + 4])
    if (tbs.length > index + 4 && tbs[index + 4].tag === 0x30) {
      const subject = tbs[index + 4];
      const rdnSeq = children(certificate, subject);
      for (const rdn of rdnSeq) {
        if (rdn.tag === 0x31) {
          const attrs = children(certificate, rdn);
          for (const attr of attrs) {
            if (attr.tag === 0x30) {
              const attrParts = children(certificate, attr);
              if (attrParts.length >= 2 && attrParts[0].tag === 0x06) {
                const oid = certificate.subarray(attrParts[0].contentStart, attrParts[0].end);
                // OID 2.5.4.3 (id-at-commonName: 0x55, 0x04, 0x03)
                if (oid.length === 3 && oid[0] === 0x55 && oid[1] === 0x04 && oid[2] === 0x03) {
                  let cn = '';
                  for (let b = attrParts[1].contentStart; b < attrParts[1].end; b++) {
                    cn += String.fromCharCode(certificate[b]);
                  }
                  return dnsNameMatches(cn.trim().toLowerCase(), wanted);
                }
              }
            }
          }
        }
      }
    }
    return false;
  } catch (error) {
    return false;
  }
}
