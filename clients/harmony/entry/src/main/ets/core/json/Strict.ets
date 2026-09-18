// Strict JSON reading, in one place.
//
// Every document this client reads — a gateway's answer, a file it wrote itself —
// is decoded through here, and the rules are the ones contracts/README.md states:
// a missing field, a field of the wrong type, an unknown field and a value outside
// its enum are all refusals. A lenient reader is the one place a substituted
// gateway or a stale file would slip through unnoticed, so there is no lenient
// path: this package depends on nothing and is used by everything.

export class JsonError extends Error {
  constructor(message: string) {
    super(message);
  }
}

export function isJsonObject(value: Object | undefined): boolean {
  return value !== undefined && value !== null && typeof value === 'object' && !Array.isArray(value);
}

/** A JSON object being read strictly. */
export class JsonReader {
  private readonly record: Record<string, Object>;
  private readonly what: string;

  private constructor(record: Record<string, Object>, what: string) {
    this.record = record;
    this.what = what;
  }

  static parse(text: string, what: string): JsonReader {
    let parsed: Object;
    try {
      parsed = JSON.parse(text) as Object;
    } catch (error) {
      throw new JsonError(`${what} is not JSON`);
    }
    if (!isJsonObject(parsed)) {
      throw new JsonError(`${what} is not a JSON object`);
    }
    return new JsonReader(parsed as Record<string, Object>, what);
  }

  static of(value: Object, what: string): JsonReader {
    if (!isJsonObject(value)) {
      throw new JsonError(`${what} is not a JSON object`);
    }
    return new JsonReader(value as Record<string, Object>, what);
  }

  context(): string {
    return this.what;
  }

  /** The object this reader holds, as text — for feeding a decoded body to a decoder. */
  json(): string {
    return JSON.stringify(this.record);
  }

  has(name: string): boolean {
    return this.record[name] !== undefined;
  }

  /** Refuses anything this reader was not told to expect. */
  rejectUnknown(allowed: string[]): void {
    const names: string[] = Object.keys(this.record);
    for (const name of names) {
      if (!allowed.includes(name)) {
        throw new JsonError(`${this.what} carries an unknown field ${name}`);
      }
    }
  }

  string(name: string): string {
    const value: Object | undefined = this.record[name];
    if (typeof value !== 'string') {
      throw new JsonError(`${this.what}.${name} is not a string`);
    }
    return value;
  }

  optionalString(name: string): string | null {
    const value: Object | undefined = this.record[name];
    if (value === undefined) {
      return null;
    }
    if (typeof value !== 'string') {
      throw new JsonError(`${this.what}.${name} is not a string`);
    }
    return value;
  }

  bool(name: string): boolean {
    const value: Object | undefined = this.record[name];
    if (typeof value !== 'boolean') {
      throw new JsonError(`${this.what}.${name} is not a boolean`);
    }
    return value;
  }

  optionalBool(name: string): boolean | null {
    const value: Object | undefined = this.record[name];
    if (value === undefined) {
      return null;
    }
    if (typeof value !== 'boolean') {
      throw new JsonError(`${this.what}.${name} is not a boolean`);
    }
    return value;
  }

  number(name: string): number {
    const value: Object | undefined = this.record[name];
    if (typeof value !== 'number' || !Number.isFinite(value)) {
      throw new JsonError(`${this.what}.${name} is not a number`);
    }
    return value;
  }

  optionalNumber(name: string): number | null {
    const value: Object | undefined = this.record[name];
    if (value === undefined) {
      return null;
    }
    if (typeof value !== 'number' || !Number.isFinite(value)) {
      throw new JsonError(`${this.what}.${name} is not a number`);
    }
    return value;
  }

  array(name: string): Object[] {
    const value: Object | undefined = this.record[name];
    if (!Array.isArray(value)) {
      throw new JsonError(`${this.what}.${name} is not an array`);
    }
    return value as Object[];
  }

  optionalArray(name: string): Object[] | null {
    const value: Object | undefined = this.record[name];
    if (value === undefined) {
      return null;
    }
    if (!Array.isArray(value)) {
      throw new JsonError(`${this.what}.${name} is not an array`);
    }
    return value as Object[];
  }

  object(name: string): JsonReader {
    const value: Object | undefined = this.record[name];
    if (!isJsonObject(value)) {
      throw new JsonError(`${this.what}.${name} is not an object`);
    }
    return JsonReader.of(value as Object, `${this.what}.${name}`);
  }

  optionalObject(name: string): JsonReader | null {
    const value: Object | undefined = this.record[name];
    if (value === undefined) {
      return null;
    }
    if (!isJsonObject(value)) {
      throw new JsonError(`${this.what}.${name} is not an object`);
    }
    return JsonReader.of(value as Object, `${this.what}.${name}`);
  }

  /** Reads a member of a closed set. An unknown value is a refusal, never a default. */
  enumValue(name: string, allowed: string[]): string {
    const value: string = this.string(name);
    if (!allowed.includes(value)) {
      throw new JsonError(`${this.what}.${name} has an unknown value`);
    }
    return value;
  }

  /** Reads a string and checks it against a pattern. */
  pattern(name: string, expression: RegExp): string {
    const value: string = this.string(name);
    if (!expression.test(value)) {
      throw new JsonError(`${this.what}.${name} is malformed`);
    }
    return value;
  }
}

/** Length in code points, the unit the contract counts names in. */
export function codePoints(value: string): number {
  let count: number = 0;
  for (let i = 0; i < value.length; i++) {
    const code: number = value.charCodeAt(i);
    if (code >= 0xd800 && code <= 0xdbff && i + 1 < value.length) {
      const next: number = value.charCodeAt(i + 1);
      if (next >= 0xdc00 && next <= 0xdfff) {
        i++;
      }
    }
    count++;
  }
  return count;
}

/** No C0 or DEL control characters; the wire refuses them in prose fields. */
export function hasNoControlCharacters(value: string): boolean {
  for (let i = 0; i < value.length; i++) {
    const code: number = value.charCodeAt(i);
    if (code < 0x20 || code === 0x7f) {
      return false;
    }
  }
  return true;
}

/** A credential is base64, because it has to be installed as bytes. */
export function isBase64(value: string): boolean {
  if (value.length === 0 || value.length % 4 !== 0) {
    return false;
  }
  return /^[A-Za-z0-9+/]*={0,2}$/.test(value);
}

/** An expiry is an RFC 3339 UTC instant, because the pending window is computed from it. */
export function isRfc3339(value: string): boolean {
  return !Number.isNaN(Date.parse(value));
}

/** A launch fragment is empty or starts with #, at most 2048 code points. */
export function isLaunchFragment(value: string): boolean {
  return value.length === 0 || (value.startsWith('#') && codePoints(value) <= 2048);
}

/** A release version name is three dot-separated numbers. */
export function isVersionName(value: string): boolean {
  const parts: string[] = value.split('.');
  if (parts.length !== 3) {
    return false;
  }
  for (const part of parts) {
    if (part.length === 0) {
      return false;
    }
    for (let i = 0; i < part.length; i++) {
      if (part.charCodeAt(i) < 0x30 || part.charCodeAt(i) > 0x39) {
        return false;
      }
    }
  }
  return true;
}
