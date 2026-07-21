#!/usr/bin/env python3
"""Validate contract schemas, release metadata, and positive/negative fixtures."""

from __future__ import annotations

import json
import sys
from datetime import datetime
from pathlib import Path
from urllib.parse import parse_qsl, urlsplit

from jsonschema import Draft202012Validator, FormatChecker


ROOT = Path(__file__).resolve().parent
SCHEMAS = ROOT / "schemas"
FIXTURES = ROOT / "fixtures"


def load_json(path: Path) -> object:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def validator(name: str) -> Draft202012Validator:
    schema = load_json(SCHEMAS / f"{name}.schema.json")
    Draft202012Validator.check_schema(schema)
    return Draft202012Validator(schema, format_checker=FormatChecker())


VALIDATORS = {
    name: validator(name)
    for name in ("setup-uri", "catalog", "pairing", "activation", "control", "release")
}


def validate_setup_uri(value: str) -> None:
    parsed = urlsplit(value)
    if parsed.scheme != "remote-everything" or parsed.netloc != "setup":
        raise ValueError("invalid setup endpoint")
    if parsed.path not in ("", "/") or parsed.fragment:
        raise ValueError("invalid setup path")
    pairs = parse_qsl(parsed.query, keep_blank_values=True, strict_parsing=True)
    if len({key for key, _ in pairs}) != len(pairs):
        raise ValueError("duplicate setup parameter")
    values = dict(pairs)
    VALIDATORS["setup-uri"].validate(values)

    origin = urlsplit(values["origin"])
    if (
        origin.scheme != "https"
        or not origin.hostname
        or origin.username is not None
        or origin.password is not None
        or origin.path
        or origin.query
        or origin.fragment
    ):
        raise ValueError("invalid gateway origin")
    try:
        if origin.port is not None and not 1 <= origin.port <= 65535:
            raise ValueError("invalid gateway port")
    except ValueError as error:
        raise ValueError("invalid gateway port") from error

    name = values["name"]
    if len(name) > 80 or any(ord(character) < 32 or ord(character) == 127 for character in name):
        raise ValueError("invalid setup name")


def expected_app_code(enabled: bool, running: bool) -> str:
    return {
        (True, True): "ready",
        (True, False): "starting",
        (False, True): "stopping",
        (False, False): "stopped",
    }[(enabled, running)]


def validate_app(app: dict[str, object]) -> None:
    if app["code"] != expected_app_code(bool(app["enabled"]), bool(app["running"])):
        raise ValueError("inconsistent app state")
    for field, maximum in (("name", 80), ("description", 240), ("icon", 4)):
        value = str(app[field])
        if len(value) > maximum or any(ord(character) < 32 or ord(character) == 127 for character in value):
            raise ValueError(f"invalid app {field}")
    fragment = str(app["launch_fragment"])
    if len(fragment) > 2048 or (fragment and not fragment.startswith("#")):
        raise ValueError("invalid launch fragment")


def validate_catalog(payload: dict[str, object]) -> None:
    VALIDATORS["catalog"].validate(payload)
    connected = bool(payload["computer_connected"])
    if payload["code"] != ("ready" if connected else "computer_offline"):
        raise ValueError("inconsistent catalog state")
    apps = payload["apps"]
    if not isinstance(apps, list):
        raise ValueError("invalid app list")
    if not connected and apps:
        raise ValueError("offline catalog contains apps")
    ids: set[str] = set()
    for app in apps:
        if not isinstance(app, dict):
            raise ValueError("invalid app")
        validate_app(app)
        app_id = str(app["id"])
        if app_id in ids:
            raise ValueError("duplicate app id")
        ids.add(app_id)


def validate_pairing(payload: dict[str, object]) -> None:
    VALIDATORS["pairing"].validate(payload)
    name = str(payload["device_name"])
    if len(name) > 80 or any(ord(character) < 32 or ord(character) == 127 for character in name):
        raise ValueError("invalid device name")
    expiration = str(payload["pending_expires_at"])
    if not expiration.endswith("Z"):
        raise ValueError("pairing expiration is not a UTC instant")
    try:
        parsed = datetime.fromisoformat(expiration[:-1] + "+00:00")
    except ValueError as error:
        raise ValueError("pairing expiration is invalid") from error
    if parsed.tzinfo is None:
        raise ValueError("pairing expiration lacks a timezone")


def validate_activation(payload: dict[str, object]) -> None:
    VALIDATORS["activation"].validate(payload)
    code = payload["code"]
    if code == "ready":
        validate_catalog(payload)
    elif code == "approval_pending":
        if payload["ok"] is not False or payload["computer_connected"] is not True:
            raise ValueError("invalid approval state")
    else:
        raise ValueError("activation did not reach an accepted state")


def validate_control(payload: dict[str, object]) -> None:
    VALIDATORS["control"].validate(payload)
    connected = bool(payload["computer_connected"])
    if connected:
        app = payload.get("app")
        if not isinstance(app, dict):
            raise ValueError("connected control response lacks app")
        validate_app(app)
        for field in ("computer_connected", "enabled", "running", "code"):
            if payload[field] != app[field]:
                raise ValueError("inconsistent control state")


def fixture_kind(path: Path) -> str:
    name = path.name
    for prefix in ("setup-uri", "catalog", "pairing", "activation", "control"):
        if name.startswith(prefix):
            return prefix
    raise ValueError(f"unknown fixture kind: {path}")


def validate_fixture(path: Path) -> None:
    fixture = load_json(path)
    if not isinstance(fixture, dict) or not isinstance(fixture.get("description"), str):
        raise ValueError("fixture lacks description")
    kind = fixture_kind(path)
    if kind == "setup-uri":
        validate_setup_uri(str(fixture["uri"]))
        return
    payload = fixture.get("payload")
    if not isinstance(payload, dict):
        raise ValueError("fixture lacks payload")
    {
        "catalog": validate_catalog,
        "pairing": validate_pairing,
        "activation": validate_activation,
        "control": validate_control,
    }[kind](payload)


def main() -> int:
    release = load_json(ROOT.parent / "release.json")
    VALIDATORS["release"].validate(release)

    failures: list[str] = []
    for path in sorted((FIXTURES / "valid").glob("*.json")):
        try:
            validate_fixture(path)
        except Exception as error:  # noqa: BLE001 - aggregate fixture failures
            failures.append(f"valid fixture rejected: {path.name}: {error}")

    for path in sorted((FIXTURES / "invalid").glob("*.json")):
        try:
            validate_fixture(path)
        except Exception:
            continue
        failures.append(f"invalid fixture accepted: {path.name}")

    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print("Contract schemas, release metadata, and fixtures are consistent.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
