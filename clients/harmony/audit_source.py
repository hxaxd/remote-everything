#!/usr/bin/env python3
"""Static guards for things the free DevEco SDK cannot catch in CI.

CI has no HarmonyOS SDK, so the ArkTS code is never compiled or executed here. This
audit only covers what that absent toolchain would otherwise miss silently: calls to
APIs the design forbids, security regressions, unfinished markers, manifest/project
wiring, the message keys the three clients share, and the behaviour fixtures the
HarmonyOS test asserts against. It deliberately does NOT assert implementation
details (method order, variable names, call sequences); behaviour belongs in the tests
under entry/src/ohosTest and in entry/src/test.
"""

from __future__ import annotations

import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parent
MODULE = ROOT / "entry" / "src" / "main"
SOURCE = MODULE / "ets"
TESTS = ROOT / "entry" / "src" / "ohosTest" / "ets"
BEHAVIOR = ROOT.parent / "behavior" / "fixtures"

forbidden = {
    # APIs that do not exist, or exist under another name.
    r"\bpinSet\b": "nonexistent Network Kit pinSet option",
    r"\bassetStore\.": "nonexistent Asset Store API",
    # Decisions the design makes once, for every client.
    r"MixedMode\.Compatibility": "insecure mixed-content compatibility mode",
    r"forceDarkAccess\s*\(\s*true": "the web content is never force-inverted (pitfalls §2.5)",
    r"clearClientAuthenticationCache": "clearing the client-auth cache before navigating "
                                       "times the challenge out (pitfalls §1.3)",
    r"setPreferredOrientation": "every screen follows the system (ui-contract §6)",
    r"WebCookieManager\.(setCookie|configCookie)": "the client never writes cookies: an "
                                                   "application's origin is its isolation (architecture §6.2)",
    r"WebCookieManager\.clearAllCookiesSync|WebStorage\.deleteAllData": "forgetting a gateway never wipes "
                                                                        "every gateway's web state (behavior README)",
    # Language escapes the ArkTS subset does not have.
    r"as\s+any\b": "ArkTS any escape",
    r"(?i)//\s*(stub|todo|placeholder)\b": "unfinished implementation marker",
}

failures: list[str] = []
for path in sorted(SOURCE.rglob("*.ets")):
    text = path.read_text(encoding="utf-8")
    for pattern, reason in forbidden.items():
        if re.search(pattern, text):
            failures.append(f"{path.relative_to(ROOT)}: {reason}")


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


# The manifest: the permissions the design requires, and the link scheme.
module_manifest = read("entry/src/main/module.json5")
if '"name": "ohos.permission.ACCESS_CERT_MANAGER"' not in module_manifest:
    failures.append("entry/src/main/module.json5: missing Web client-certificate permission")
if '"name": "ohos.permission.INTERNET"' not in module_manifest:
    failures.append("entry/src/main/module.json5: missing network permission")
if '"scheme": "remote-everything"' not in module_manifest:
    failures.append("entry/src/main/module.json5: an invitation link cannot open the app")
if re.search(r'"(storePassword|keyPassword|password)"\s*:', module_manifest):
    failures.append("entry/src/main/module.json5: a password is written into the manifest")

# No signing material, or any other secret, in the build files that are in git.
for relative in ("build-profile.json5", "oh-package.json5", "entry/oh-package.json5",
                 "entry/build-profile.json5"):
    if re.search(r"signingConfigs|storePassword|keyPassword|\.p12|\.cer\b|\.p7b", read(relative)):
        failures.append(f"{relative}: signing material belongs in the environment, not in git")

pages = json.loads(read("entry/src/main/resources/base/profile/main_pages.json"))["src"]
for expected in ("pages/AppRoot",):
    if expected not in pages:
        failures.append(f"main_pages.json: missing {expected}")

required_project_files = (
    "hvigor/hvigor-config.json5",
    "entry/src/ohosTest/ets/test/List.test.ets",
    "entry/src/ohosTest/ets/test/behavior/BehaviorFixturesTest.ets",
    "entry/src/ohosTest/ets/test/behavior/WireCasesTest.ets",
    "AppScope/resources/base/media/ic_launcher.svg",
    "AppScope/resources/base/element/string.json",
    "entry/src/main/resources/base/media/ic_launcher.svg",
    "entry/src/main/resources/base/element/string.json",
    "entry/src/main/resources/zh_CN/element/string.json",
)
for relative in required_project_files:
    if not (ROOT / relative).is_file():
        failures.append(f"missing project file: {relative}")

# The resource split the design asks for: English by default, Chinese alongside, and
# every message key rendered in both. A key without a translation is a screen with a
# key on it.
base_strings = json.loads(read("entry/src/main/resources/base/element/string.json"))["string"]
zh_strings = json.loads(read("entry/src/main/resources/zh_CN/element/string.json"))["string"]
base_names = {entry["name"] for entry in base_strings}
zh_names = {entry["name"] for entry in zh_strings}

message_keys_source = read("entry/src/main/ets/core/model/MessageKeys.ets")
message_keys = re.findall(r"static readonly [A-Z_0-9]+: string = '([^']+)';", message_keys_source)
if len(message_keys) != len(set(message_keys)):
    failures.append("core/model/MessageKeys.ets: a message key is declared twice")
if not message_keys:
    failures.append("core/model/MessageKeys.ets: no message keys were found")
# The vocabulary itself is the contract: the set of keys this client declares is
# exactly the shared fixture, nothing more, nothing less.
if BEHAVIOR.is_dir() and (BEHAVIOR / "message-keys.json").is_file():
    fixture_keys = set(json.loads((BEHAVIOR / "message-keys.json").read_text(encoding="utf-8")))
    declared = set(message_keys)
    if fixture_keys != declared:
        missing = sorted(fixture_keys - declared)
        extra = sorted(declared - fixture_keys)
        if missing:
            failures.append(f"MessageKeys.ets is missing {missing}")
        if extra:
            failures.append(f"MessageKeys.ets declares keys the fixture does not: {extra}")
for key in message_keys:
    resource_name = key.replace(".", "_")
    if resource_name not in base_names:
        failures.append(f"resources/base: {key} has no English string")
    if resource_name not in zh_names:
        failures.append(f"resources/zh_CN: {key} has no Chinese string")

# The fixtures the behaviour test asserts against are the repository's own, byte for
# byte: a device is not needed to check that they are the same file.
if not BEHAVIOR.is_dir():
    failures.append(f"missing behaviour fixtures: {BEHAVIOR}")
else:
    shipped = ROOT / "entry" / "src" / "ohosTest" / "resources" / "rawfile" / "behavior"
    for fixture in sorted(BEHAVIOR.glob("*.json")):
        copy = shipped / fixture.name
        if not copy.is_file():
            failures.append(f"the behaviour test is missing {fixture.name}")
            continue
        if copy.read_bytes() != fixture.read_bytes():
            failures.append(f"{copy.relative_to(ROOT)} differs from {fixture.name}")

    # Every refusal the fixtures name is a key this client knows how to say.
    errors = json.loads((BEHAVIOR / "errors.json").read_text(encoding="utf-8"))["cases"]
    for case in errors:
        if f"'{case['key']}'" not in message_keys_source:
            failures.append(f"MessageKeys does not carry {case['key']} from errors.json")

# A resource the code asks for by name has to exist in both languages, or a screen
# shows a key where a sentence belongs. Message keys are asked for through
# MessageKeys and are checked above; this catches the literal lookups.
literal_lookups = set()
for path in sorted(SOURCE.rglob("*.ets")):
    text = path.read_text(encoding="utf-8")
    literal_lookups.update(re.findall(r"Strings\.(?:text|text1|text2|byName)\('([^']+)'\)", text))
    literal_lookups.update(re.findall(r"showToast\('([^']+)'\)", text))
for name in sorted(literal_lookups):
    resource_name = name.replace(".", "_")
    if resource_name not in base_names:
        failures.append(f"resources/base: {name} is asked for but not defined")
    if resource_name not in zh_names:
        failures.append(f"resources/zh_CN: {name} is asked for but not defined")

# The strings and the source files the test suite itself needs.
if not list(TESTS.rglob("*.test.ets")):
    failures.append("entry/src/ohosTest: no test sources")

if failures:
    raise SystemExit("\n".join(failures))
print("HarmonyOS source audit passed.")
