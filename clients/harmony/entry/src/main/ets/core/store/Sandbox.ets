// The app sandbox: where this client's own files live, and the one way they are
// written. Everything that is persisted goes through `writeAtomic` — a temporary
// file in the same directory, then a rename — so a file is either the old document
// or the new one and never half of either.
//
// Every platform call here can throw, and each one is handled where it happens: a
// document that cannot be read is absent, a write that cannot finish removes what it
// left behind and says so, and a file that cannot be removed is reported rather than
// ignored (a leftover is a bug, architecture.md §3.4).

import { fileIo as fs } from '@kit.CoreFileKit';
import { JsonError } from '../json/Strict';

/** A failure in this device's own storage. */
export class SandboxError extends Error {
  constructor(detail: string) {
    super(detail);
  }
}

function closeQuietly(file: fs.File | null): void {
  if (file === null) {
    return;
  }
  try {
    fs.closeSync(file);
  } catch (error) {
    // A descriptor that cannot be closed is one the system has already taken back.
  }
}

export class Sandbox {
  private static root: string = '';

  /** Called once, from the ability, with its files directory. */
  static init(filesDir: string): void {
    Sandbox.root = filesDir;
  }

  static get isReady(): boolean {
    return Sandbox.root !== '';
  }

  static path(relative: string): string {
    if (Sandbox.root === '') {
      throw new JsonError('the sandbox was used before it was initialised');
    }
    return `${Sandbox.root}/${relative}`;
  }

  static exists(relative: string): boolean {
    try {
      return fs.accessSync(Sandbox.path(relative));
    } catch (error) {
      return false;
    }
  }

  /** Makes sure a directory is there, and says so when it cannot be. */
  static ensureDirectory(relative: string): string {
    const full: string = Sandbox.path(relative);
    try {
      if (!fs.accessSync(full)) {
        fs.mkdirSync(full, true);
      }
      return full;
    } catch (error) {
      throw new SandboxError(`the directory ${relative} could not be created`);
    }
  }

  static readText(relative: string): string | null {
    if (!Sandbox.exists(relative)) {
      return null;
    }
    try {
      return fs.readTextSync(Sandbox.path(relative));
    } catch (error) {
      return null;
    }
  }

  static readBytes(relative: string): Uint8Array | null {
    const full: string = Sandbox.path(relative);
    if (!Sandbox.exists(relative)) {
      return null;
    }
    let file: fs.File | null = null;
    try {
      const size: number = fs.statSync(full).size;
      if (size <= 0) {
        return null;
      }
      file = fs.openSync(full, fs.OpenMode.READ_ONLY);
      const buffer: ArrayBuffer = new ArrayBuffer(size);
      if (fs.readSync(file.fd, buffer) !== size) {
        return null;
      }
      return new Uint8Array(buffer);
    } catch (error) {
      return null;
    } finally {
      closeQuietly(file);
    }
  }

  /** Writes the document whole: temp file, flush, rename. */
  static writeAtomic(relative: string, contents: string): void {
    Sandbox.write(relative, contents, false);
  }

  /** The same rename-or-nothing write, for material that is not text. */
  static writeBytesAtomic(relative: string, contents: Uint8Array): void {
    Sandbox.write(relative, contents, true);
  }

  private static write(relative: string, contents: string | Uint8Array, binary: boolean): void {
    const full: string = Sandbox.path(relative);
    const temporary: string = `${full}.tmp`;
    let file: fs.File | null = null;
    try {
      file = fs.openSync(temporary, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      if (binary) {
        fs.writeSync(file.fd, (contents as Uint8Array).buffer as ArrayBuffer);
      } else {
        fs.writeSync(file.fd, contents as string);
      }
      fs.fsyncSync(file.fd);
    } catch (error) {
      closeQuietly(file);
      Sandbox.removeWithTemporary(relative);
      throw new SandboxError(`the document ${relative} could not be written`);
    }
    closeQuietly(file);
    try {
      fs.renameSync(temporary, full);
    } catch (error) {
      Sandbox.removeWithTemporary(relative);
      throw new SandboxError(`the document ${relative} could not be replaced`);
    }
  }

  static remove(relative: string): void {
    if (!Sandbox.exists(relative)) {
      return;
    }
    try {
      fs.unlinkSync(Sandbox.path(relative));
    } catch (error) {
      // The file is either gone or beyond this app's reach; the caller verifies what
      // it needs by looking for it again.
    }
  }

  /** Removes a file and the temporary file an interrupted write may have left. */
  static removeWithTemporary(relative: string): void {
    Sandbox.remove(relative);
    Sandbox.remove(`${relative}.tmp`);
  }

  /**
   * A filename for one origin. An origin is not a filename — it carries `:`, `/` and
   * whatever the operator typed as a host — so it is written out as hex of its own
   * UTF-8 bytes: two different origins never collide, and the result is always a
   * plain ASCII name.
   */
  static originKey(origin: string): string {
    let text: string = '';
    for (let index: number = 0; index < origin.length; index += 1) {
      const code: number = origin.charCodeAt(index);
      text += '0123456789abcdef'.charAt((code >> 4) & 0x0f);
      text += '0123456789abcdef'.charAt(code & 0x0f);
    }
    return text;
  }
}
