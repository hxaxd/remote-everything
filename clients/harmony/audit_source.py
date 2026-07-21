#!/usr/bin/env python3
"""Fail CI on known non-functional HarmonyOS scaffolding and project drift."""

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

required_snippets = {
    "core/security/CredentialStore.ets": (
        "cert.parsePkcs12",
        "asset.add",
        "CredentialStore.filesDir",
    ),
    "features/setup/SetupTransaction.ets": (
        "certificatePinning",
        "clientCert",
        "config.isGatewayUrl(url)",
    ),
    "features/remote/RemoteWebPage.ets": (
        ".onShowFileSelector",
        ".onClientAuthenticationRequest",
        ".onSslErrorEventReceive",
        ".onPermissionRequest",
        ".onDownloadStart",
    ),
    "core/storage/ProfileStore.ets": (
        "preferences.getPreferencesSync",
        "store.flush()",
    ),
}
for relative, snippets in required_snippets.items():
    text = (SOURCE / relative).read_text(encoding="utf-8")
    for snippet in snippets:
        if snippet not in text:
            failures.append(f"{relative}: missing {snippet}")

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
