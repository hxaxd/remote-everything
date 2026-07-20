#!/usr/bin/env python3
import argparse
import json
import os
import re
import tempfile
from datetime import datetime, timezone

HEX64 = re.compile(r"^[0-9a-f]{64}$")
COLLECTION_KEYS = {"components": "id", "dependencies": "id", "integrations": "id"}
ITEM_FIELDS = {
    "components": {"id", "managed", "executable", "sha256", "arguments", "working_directory", "log", "manager", "expected", "observed", "verification"},
    "dependencies": {"id", "managed", "version", "source", "path", "sha256"},
    "integrations": {"id", "managed", "type", "owner", "definition", "insertion", "restore", "verification"},
}


def fail(message):
    raise ValueError(message)


def absolute(value, field):
    if not isinstance(value, str) or not (os.path.isabs(value) or value.startswith("/") or re.match(r"^[A-Za-z]:[\\/]", value)):
        fail(f"{field} must be an absolute path")


def nonempty_string(value, field):
    if not isinstance(value, str) or not value:
        fail(f"{field} must be a non-empty string")


def string(value, field):
    if not isinstance(value, str):
        fail(f"{field} must be a string")


def object_value(value, field):
    if not isinstance(value, dict):
        fail(f"{field} must be an object")


def load_single(path):
    with open(path, encoding="utf-8") as source:
        decoder = json.JSONDecoder()
        text = source.read()
    value, end = decoder.raw_decode(text)
    if text[end:].strip():
        fail(f"{path} contains trailing JSON")
    return value


def validate(record):
    if not isinstance(record, dict) or set(record) != {
        "schema", "installation_id", "root", "platform", "mode", "release",
        "created_at", "updated_at", "components", "dependencies", "integrations", "verification",
    }:
        fail("runtime record fields do not match schema 1")
    if record["schema"] != 1 or not HEX64.fullmatch(record["installation_id"]):
        fail("schema or installation_id is invalid")
    absolute(record["root"], "root")
    if record["platform"] not in {"windows", "linux", "macos"} or record["mode"] not in {"lan", "public"}:
        fail("platform or mode is invalid")
    if not isinstance(record["release"], dict) or set(record["release"]) != {"tag", "source"}:
        fail("release must contain tag and source")
    string(record["release"]["tag"], "release.tag")
    string(record["release"]["source"], "release.source")
    for field in ("created_at", "updated_at"):
        string(record[field], field)
        timestamp = datetime.fromisoformat(record[field].replace("Z", "+00:00"))
        if timestamp.tzinfo is None:
            fail(f"{field} must include a timezone")
    for collection, key in COLLECTION_KEYS.items():
        values = record[collection]
        if not isinstance(values, list):
            fail(f"{collection} must be an array")
        seen = set()
        for index, value in enumerate(values):
            if not isinstance(value, dict) or set(value) != ITEM_FIELDS[collection]:
                fail(f"{collection}[{index}] fields do not match schema 1")
            if not isinstance(value.get(key), str) or not value[key]:
                fail(f"{collection}[{index}].{key} is invalid")
            if value[key] in seen:
                fail(f"duplicate {collection} id: {value[key]}")
            seen.add(value[key])
            if not isinstance(value.get("managed"), bool):
                fail(f"{collection}[{index}].managed is required")
            if collection == "components":
                for field in ("executable", "working_directory", "log"):
                    absolute(value.get(field), f"{collection}[{index}].{field}")
                if not HEX64.fullmatch(value.get("sha256", "")):
                    fail(f"{collection}[{index}].sha256 is invalid")
                if not isinstance(value.get("arguments"), list) or not all(isinstance(item, str) for item in value["arguments"]):
                    fail(f"{collection}[{index}].arguments is invalid")
                for field in ("manager", "expected", "observed", "verification"):
                    object_value(value[field], f"{collection}[{index}].{field}")
            elif collection == "dependencies":
                absolute(value.get("path"), f"{collection}[{index}].path")
                if not HEX64.fullmatch(value.get("sha256", "")):
                    fail(f"{collection}[{index}].sha256 is invalid")
                string(value["version"], f"{collection}[{index}].version")
                string(value["source"], f"{collection}[{index}].source")
            else:
                string(value["type"], f"{collection}[{index}].type")
                string(value["owner"], f"{collection}[{index}].owner")
                absolute(value["definition"], f"{collection}[{index}].definition")
                object_value(value["verification"], f"{collection}[{index}].verification")
    if not isinstance(record["verification"], dict):
        fail("verification must be an object")
    return record


def atomic_write(path, value):
    parent = os.path.dirname(os.path.abspath(path))
    os.makedirs(parent, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".runtime-", suffix=".json", dir=parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as output:
            json.dump(value, output, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def now():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def command_init(args):
    if os.path.exists(args.path):
        fail("runtime record already exists")
    absolute(args.root, "root")
    timestamp = now()
    record = {
        "schema": 1, "installation_id": args.installation_id, "root": os.path.normpath(args.root),
        "platform": args.platform, "mode": args.mode,
        "release": {"tag": args.release, "source": args.source},
        "created_at": timestamp, "updated_at": timestamp,
        "components": [], "dependencies": [], "integrations": [], "verification": {},
    }
    atomic_write(args.path, validate(record))


def command_put(args):
    record = validate(load_single(args.path))
    value = load_single(args.value)
    if not isinstance(value, dict):
        fail("update value must be an object")
    key = COLLECTION_KEYS[args.collection]
    identity = value.get(key)
    if not isinstance(identity, str) or not identity:
        fail(f"update value requires {key}")
    values = [item for item in record[args.collection] if item[key] != identity]
    values.append(value)
    record[args.collection] = sorted(values, key=lambda item: item[key])
    record["updated_at"] = now()
    atomic_write(args.path, validate(record))


def command_verify(args):
    record = validate(load_single(args.path))
    value = load_single(args.value)
    if not isinstance(value, dict):
        fail("verification value must be an object")
    record["verification"] = value
    record["updated_at"] = now()
    atomic_write(args.path, validate(record))


def main():
    parser = argparse.ArgumentParser()
    subcommands = parser.add_subparsers(dest="command", required=True)
    init = subcommands.add_parser("init")
    init.add_argument("path")
    init.add_argument("--root", required=True)
    init.add_argument("--installation-id", required=True)
    init.add_argument("--platform", choices=("windows", "linux", "macos"), required=True)
    init.add_argument("--mode", choices=("lan", "public"), required=True)
    init.add_argument("--release", required=True)
    init.add_argument("--source", required=True)
    init.set_defaults(run=command_init)
    put = subcommands.add_parser("put")
    put.add_argument("path")
    put.add_argument("collection", choices=tuple(COLLECTION_KEYS))
    put.add_argument("value")
    put.set_defaults(run=command_put)
    verify = subcommands.add_parser("verify")
    verify.add_argument("path")
    verify.add_argument("value")
    verify.set_defaults(run=command_verify)
    check = subcommands.add_parser("validate")
    check.add_argument("path")
    check.set_defaults(run=lambda args: validate(load_single(args.path)))
    args = parser.parse_args()
    try:
        args.run(args)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        parser.error(str(error))
    print(json.dumps({"ok": True, "path": os.path.abspath(args.path)}, separators=(",", ":")))


if __name__ == "__main__":
    main()
