import { createRequire, syncBuiltinESMExports } from "node:module";
import { existsSync, readFileSync, realpathSync } from "node:fs";
import nodePath from "node:path";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { patchIndexHtml, piSessionKey, upstreamSessionKey } from "./compat.mjs";

const [serverScript, portText, workdir, home, piBinary] = process.argv.slice(2);

function fail(message) {
  console.error(`Pi launcher: ${message}`);
  process.exit(64);
}

if (!serverScript || !portText || !workdir || !home || !piBinary) {
  fail("expected server script, port, workdir, home, and Pi binary");
}

const port = Number(portText);
if (!Number.isInteger(port) || port < 1 || port > 65535 || String(port) !== portText) {
  fail("port must be an integer from 1 to 65535");
}

for (const [label, path] of [
  ["server script", serverScript],
  ["workdir", workdir],
  ["home", home],
  ["Pi binary", piBinary],
]) {
  if (!isAbsolute(path)) fail(`${label} must be absolute`);
  if (!existsSync(path)) fail(`${label} does not exist`);
}

process.env.WGPI_PORT = portText;
process.env.WGPI_HOST = "127.0.0.1";
process.env.WGPI_CWD = workdir;
process.env.WGPI_PI_BIN = piBinary;
process.env.HOME = home;

const serverRoot = dirname(serverScript);
const packageMetadata = JSON.parse(readFileSync(join(serverRoot, "package.json"), "utf8"));
if (packageMetadata.name !== "wgnr-pi" || packageMetadata.version !== "1.5.2") {
  fail("expected wgnr-pi 1.5.2");
}

// wgnr-pi 1.5.2 only encodes POSIX separators when locating sessions. Redirect
// that one broken Windows path component to the encoding used by Pi itself.
const brokenSessionKey = upstreamSessionKey(workdir);
const correctSessionKey = piSessionKey(workdir);
if (brokenSessionKey !== correctSessionKey) {
  const originalJoin = nodePath.join;
  nodePath.join = (...parts) => originalJoin(...parts.map((part) => part === brokenSessionKey ? correctSessionKey : part));
  syncBuiltinESMExports();
}

const indexPath = realpathSync(join(serverRoot, "public", "index.html"));
let patchedIndexHtml;
try {
  patchedIndexHtml = patchIndexHtml(readFileSync(indexPath, "utf8"));
} catch (error) {
  fail(`unsupported wgnr-pi page: ${error.message}`);
}

// Express' sendFile ignores absolute paths containing the managed `.runtime`
// directory on Windows. Keep the compatibility behavior process-local and
// constrain it to files shipped inside the pinned wgnr-pi package.
const requireFromServer = createRequire(pathToFileURL(serverScript));
const express = requireFromServer("express");
const originalSendFile = express.response.sendFile;
const realServerRoot = realpathSync(serverRoot);
express.response.sendFile = function sendManagedFile(filePath, ...args) {
  const absolutePath = realpathSync(resolve(filePath));
  const relativePath = relative(realServerRoot, absolutePath);
  const insideServer = relativePath === "" || (!relativePath.startsWith("..") && !isAbsolute(relativePath));
  if (!insideServer) return originalSendFile.call(this, filePath, ...args);
  this.type(absolutePath);
  if (absolutePath === indexPath) return this.send(patchedIndexHtml);
  return this.send(readFileSync(absolutePath));
};

await import(pathToFileURL(serverScript).href);
