#!/usr/bin/env python3
"""Check that every client consumes the shared release manifest consistently."""

from __future__ import annotations

import json
import plistlib
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parent
RELEASE = json.loads((ROOT / "release.json").read_text(encoding="utf-8"))
VERSION = RELEASE["versionName"]
BUILD = RELEASE["buildNumber"]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def api_level(value: str) -> int:
    match = re.fullmatch(r"\d+\.\d+\.\d+\((\d+)\)", value)
    require(match is not None, f"invalid HarmonyOS SDK version: {value}")
    return int(match.group(1))


android = (ROOT / "android" / "app" / "build.gradle.kts").read_text(encoding="utf-8")
for expected in (
    'file("../../release.json")',
    "versionCode = releaseBuildNumber",
    "versionName = releaseVersionName",
    "minSdk = releaseMinSdk",
):
    require(expected in android, f"Android build is not driven by release.json: {expected}")

with (ROOT / "ios" / "RemoteEverything" / "Resources" / "Info.plist").open("rb") as handle:
    ios_info = plistlib.load(handle)
require(ios_info["CFBundleShortVersionString"] == VERSION, "iOS version differs from release.json")
require(ios_info["CFBundleVersion"] == str(BUILD), "iOS build differs from release.json")

ios_project = (ROOT / "ios" / "project.yml").read_text(encoding="utf-8")
require(f'MARKETING_VERSION: "{VERSION}"' in ios_project, "iOS project version differs")
require(f'CURRENT_PROJECT_VERSION: "{BUILD}"' in ios_project, "iOS project build differs")
ios_package = (ROOT / "ios" / "Package.swift").read_text(encoding="utf-8")
minimum_ios = RELEASE["minimumPlatforms"]["ios"].split(".", maxsplit=1)[0]
require(f".iOS(.v{minimum_ios})" in ios_package, "iOS deployment target differs")

harmony_app = json.loads((ROOT / "harmony" / "AppScope" / "app.json5").read_text(encoding="utf-8"))
require(harmony_app["app"]["versionName"] == VERSION, "HarmonyOS version differs")
require(harmony_app["app"]["versionCode"] == BUILD, "HarmonyOS build differs")
for package_path in (ROOT / "harmony" / "oh-package.json5", ROOT / "harmony" / "entry" / "oh-package.json5"):
    package = json.loads(package_path.read_text(encoding="utf-8"))
    require(package["version"] == VERSION, f"{package_path.name} version differs")

harmony_build = json.loads((ROOT / "harmony" / "build-profile.json5").read_text(encoding="utf-8"))
product = harmony_build["app"]["products"][0]
minimum_harmony = int(RELEASE["minimumPlatforms"]["harmonyApi"])
require(api_level(product["compatibleSdkVersion"]) == minimum_harmony, "HarmonyOS minimum API differs")
require(api_level(product["compileSdkVersion"]) >= minimum_harmony, "HarmonyOS compile API is too old")
require(api_level(product["targetSdkVersion"]) >= minimum_harmony, "HarmonyOS target API is too old")

# The protocol version is the one thing not in the bundle; HarmonyOS keeps it in
# BuildInfo.ets, and it must move with the manifest like every other number.
build_info = (ROOT / "harmony" / "entry" / "src" / "main" / "ets" / "app" / "BuildInfo.ets").read_text(encoding="utf-8")
expected_protocol = RELEASE["protocolVersion"]
match = re.search(r"PROTOCOL_VERSION\s*:\s*number\s*=\s*(\d+)", build_info)
require(match is not None, "HarmonyOS BuildInfo.ets does not declare PROTOCOL_VERSION")
require(int(match.group(1)) == expected_protocol,
    f"HarmonyOS protocol version {match.group(1)} differs from release.json ({expected_protocol})")

print(f"All client versions match {VERSION} ({BUILD}); protocol {RELEASE['protocolVersion']}.")
