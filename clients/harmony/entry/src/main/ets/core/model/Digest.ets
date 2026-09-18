// Hashing and encoding, in the one place both are done.
//
// Everything in here is computed locally and treated as evidence: the fingerprint of
// the certificate this device was issued is recomputed rather than believed, the
// SPKI pin a LAN gateway handed out in its invitation is compared against the
// public key its certificate actually carries, and random material comes from the
// platform's cryptographic generator.

import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

const HEX_DIGITS = '0123456789abcdef';

/** A failure of the platform's cryptography. Never expected, and never ignored. */
export class DigestError extends Error {
  constructor(detail: string) {
    super(detail);
  }
}

export function sha256(data: Uint8Array): Uint8Array {
  try {
    const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
    md.updateSync({ data: data });
    return md.digestSync().data;
  } catch (error) {
    throw new DigestError('the platform could not hash a value');
  }
}

export function toHex(data: Uint8Array): string {
  let text: string = '';
  for (let index: number = 0; index < data.length; index += 1) {
    const value: number = data[index];
    text += HEX_DIGITS.charAt((value >> 4) & 0x0f);
    text += HEX_DIGITS.charAt(value & 0x0f);
  }
  return text;
}

export function sha256Hex(data: Uint8Array): string {
  return toHex(sha256(data));
}

/** The text's UTF-8 bytes. */
export function utf8(text: string): Uint8Array {
  try {
    return new util.TextEncoder().encodeInto(text);
  } catch (error) {
    throw new DigestError('a value could not be encoded');
  }
}

/** SHA-256 of the text's UTF-8 bytes — the fingerprint of a name, not of a secret. */
export function sha256HexOfText(text: string): string {
  return sha256Hex(utf8(text));
}

/** Lowercase hex of the text's UTF-8 bytes, for names that have to be filenames. */
export function utf8Hex(text: string): string {
  return toHex(utf8(text));
}

export function base64Encode(data: Uint8Array): string {
  try {
    return new util.Base64Helper().encodeToStringSync(data, util.Type.BASIC);
  } catch (error) {
    throw new DigestError('a value could not be encoded');
  }
}

export function base64Decode(text: string): Uint8Array {
  try {
    return new util.Base64Helper().decodeSync(text, util.Type.BASIC);
  } catch (error) {
    throw new DigestError('a value is not base64');
  }
}

export function base64UrlDecode(text: string): Uint8Array {
  try {
    return new util.Base64Helper().decodeSync(text, util.Type.BASIC_URL_SAFE);
  } catch (error) {
    throw new DigestError('a value is not base64url');
  }
}

/** Random bytes from the platform's cryptographic generator. */
export function randomBytes(length: number): Uint8Array {
  try {
    const generator: cryptoFramework.Random = cryptoFramework.createRandom();
    const blob: cryptoFramework.DataBlob | null = generator.generateRandomSync(length);
    if (blob === null) {
      throw new DigestError('the platform returned no random bytes');
    }
    return blob.data;
  } catch (error) {
    throw new DigestError('the platform could not provide random bytes');
  }
}

/** Fills a byte array with zeroes. Called the moment a secret is no longer needed. */
export function wipe(data: Uint8Array | null): void {
  if (data === null) {
    return;
  }
  data.fill(0);
}

export function sameBytes(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) {
    return false;
  }
  let difference: number = 0;
  for (let index: number = 0; index < left.length; index += 1) {
    difference |= left[index] ^ right[index];
  }
  return difference === 0;
}
