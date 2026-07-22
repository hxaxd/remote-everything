import assert from "node:assert/strict";
import test from "node:test";
import { patchIndexHtml, piSessionKey, upstreamSessionKey } from "./compat.mjs";

test("session keys preserve Unix behavior and repair Windows paths", () => {
  assert.equal(upstreamSessionKey("/srv/project"), "--srv-project--");
  assert.equal(piSessionKey("/srv/project"), "--srv-project--");
  assert.equal(upstreamSessionKey("C:\\Users\\alice"), "--C:\\Users\\alice--");
  assert.equal(piSessionKey("C:\\Users\\alice"), "--C--Users-alice--");
});

test("index patch changes exactly the stale selector", () => {
  const source = '<script>document.getElementById("mode-pi").classList.add("active");</script>';
  assert.equal(
    patchIndexHtml(source),
    '<script>document.getElementById("mode-pi")?.classList.add("active");</script>',
  );
  assert.throws(() => patchIndexHtml("<script></script>"), /found 0/);
  assert.throws(() => patchIndexHtml(source + source), /found 2/);
});
