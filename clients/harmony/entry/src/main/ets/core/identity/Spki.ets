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
