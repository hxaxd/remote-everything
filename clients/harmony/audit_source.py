#!/usr/bin/env python3
"""Static guards for things the free DevEco SDK cannot catch in CI.

CI has no HarmonyOS SDK, so the ArkTS code is never compiled or executed
here. This audit only covers what that absent toolchain would otherwise
miss silently: calls to APIs that do not exist, security regressions,
unfinished markers, and manifest/project wiring. It deliberately does
NOT assert implementation details (method order, variable names, call
sequences); behavior belongs in the unit tests under entry/src/test.
"""

from __future__ import annotations

import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "entry" / "src" / "main" / "ets"

forbidden = {
    r"\bpinSet\b": "nonexistent Network Kit pinSet option",
    r"\bassetStore\.": "nonexistent Asset Store API",
    r"MixedMode\.Compatibility": "insecure mixed-content compatibility mode",
    r"as\s+any\b": "ArkTS any escape",
    r"(?i)//\s*(stub|todo|placeholder)\b": "unfinished implementation marker",
}

failures: list[str] = []
for path in sorted(SOURCE.rglob("*.ets")):
    text = path.read_text(encoding="utf-8")
    for pattern, reason in forbidden.items():
        if re.search(pattern, text):
            failures.append(f"{path.relative_to(ROOT)}: {reason}")

module_manifest = (
    ROOT / "entry" / "src" / "main" / "module.json5"
).read_text(encoding="utf-8")
if '"name": "ohos.permission.ACCESS_CERT_MANAGER"' not in module_manifest:
    failures.append("entry/src/main/module.json5: missing Web client-certificate permission")

pages = json.loads(
    (ROOT / "entry" / "src" / "main" / "resources" / "base" / "profile" / "main_pages.json")
    .read_text(encoding="utf-8")
)["src"]
for expected in ("pages/AppRoot", "features/remote/RemoteWebPage"):
    if expected not in pages:
        failures.append(f"main_pages.json: missing {expected}")

required_project_files = (
    "hvigor/hvigor-config.json5",
    "entry/src/test/List.test.ets",
    "AppScope/resources/base/media/ic_launcher.svg",
    "AppScope/resources/base/element/string.json",
    "entry/src/main/resources/base/media/ic_launcher.svg",
)
for relative in required_project_files:
    if not (ROOT / relative).is_file():
        failures.append(f"missing project file: {relative}")

if failures:
    raise SystemExit("\n".join(failures))
print("HarmonyOS source audit passed.")
