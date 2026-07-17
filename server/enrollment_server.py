#!/usr/bin/env python3
import datetime as dt
import base64
import hashlib
import hmac
import json
import os
import secrets
import threading
import time
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.hashes import SHA256

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 58631
STATE_DIR = Path("/var/lib/kimi-enrollment/requests")
BOOTSTRAP_FINGERPRINT_FILE = Path("/etc/kimi-gateway/bootstrap-fingerprint")
MAX_BODY = 32 * 1024
CODE_ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
LOCK = threading.Lock()


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def iso(value: dt.datetime) -> str:
    return value.astimezone(dt.timezone.utc).replace(microsecond=0).isoformat()


def expected_bootstrap_fingerprint() -> str:
    return BOOTSTRAP_FINGERPRINT_FILE.read_text(encoding="utf-8").strip().lower()


def proof_message(device_name: str, nonce: bytes) -> bytes:
    return b"KIMI-REMOTE-ENROLL-V1\x00" + device_name.encode("utf-8") + b"\x00" + nonce


def validate_device_key(device_name: str, public_key_pem: str, nonce_b64: str, signature_b64: str) -> tuple[str, str]:
    if len(public_key_pem) > 8 * 1024:
        raise ValueError("public_key_too_large")
    try:
        public_key = serialization.load_pem_public_key(public_key_pem.encode("ascii"))
    except (ValueError, UnicodeEncodeError) as exc:
        raise ValueError("invalid_public_key") from exc

    if not isinstance(public_key, ec.EllipticCurvePublicKey) or not isinstance(public_key.curve, ec.SECP256R1):
        raise ValueError("unsupported_key")
    try:
        nonce = base64.b64decode(nonce_b64, validate=True)
        signature = base64.b64decode(signature_b64, validate=True)
    except (ValueError, TypeError) as exc:
        raise ValueError("invalid_proof_encoding") from exc
    if not 24 <= len(nonce) <= 64 or not 8 <= len(signature) <= 256:
        raise ValueError("invalid_proof_size")
    try:
        public_key.verify(signature, proof_message(device_name, nonce), ec.ECDSA(SHA256()))
    except InvalidSignature as exc:
        raise ValueError("invalid_key_proof") from exc

    der = public_key.public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    canonical_pem = public_key.public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo).decode("ascii")
    fingerprint = hashlib.sha256(der).hexdigest()
    return canonical_pem, fingerprint


def request_files() -> list[Path]:
    return sorted(STATE_DIR.glob("*.json"))


def read_request(path: Path) -> dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8"))


def write_request(path: Path, value: dict[str, object]) -> None:
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def is_expired(item: dict[str, object]) -> bool:
    try:
        return dt.datetime.fromisoformat(str(item.get("expires_at", ""))) <= utc_now()
    except ValueError:
        return True


def find_existing(fingerprint: str, credential_delivery: str) -> dict[str, object] | None:
    for path in request_files():
        try:
            item = read_request(path)
        except (OSError, json.JSONDecodeError):
            continue
        if (
            item.get("fingerprint") == fingerprint
            and item.get("credential_delivery", "certificate") == credential_delivery
            and item.get("status") in ("pending", "approved")
            and not (item.get("status") == "pending" and is_expired(item))
        ):
            return item
    return None


SWEEP_INTERVAL_SECONDS = 3600


def sweep_expired_requests() -> None:
    while True:
        time.sleep(SWEEP_INTERVAL_SECONDS)
        try:
            with LOCK:
                now = utc_now()
                for path in request_files():
                    try:
                        item = read_request(path)
                    except (OSError, json.JSONDecodeError):
                        continue
                    if item.get("status") != "pending":
                        continue
                    try:
                        expires_at = dt.datetime.fromisoformat(str(item.get("expires_at", "")))
                    except ValueError:
                        expires_at = None
                    if expires_at is None or expires_at <= now:
                        path.unlink(missing_ok=True)
        except OSError:
            continue


def public_state(item: dict[str, object]) -> dict[str, object]:
    result = {
        "ok": True,
        "status": item.get("status"),
        "request_id": item.get("request_id"),
        "registration_code": item.get("registration_code"),
        "fingerprint": item.get("fingerprint"),
        "device_name": item.get("device_name"),
    }
    if item.get("status") == "approved":
        result["certificate_pem"] = item.get("certificate_pem")
        result["certificate_fingerprint"] = item.get("certificate_fingerprint")
        if item.get("credential_delivery") == "pkcs12":
            result["credential_format"] = "pkcs12"
            result["credential_pkcs12"] = item.get("credential_pkcs12")
    return result


def create_request(
    device_name: str,
    public_key_pem: str,
    nonce_b64: str,
    signature_b64: str,
    credential_delivery: str,
    credential_password: str,
) -> dict[str, object]:
    device_name = device_name.strip()
    if not device_name or len(device_name) > 80 or any(ord(char) < 32 for char in device_name):
        raise ValueError("invalid_device_name")
    canonical_public_key, fingerprint = validate_device_key(device_name, public_key_pem, nonce_b64, signature_b64)
    if credential_delivery not in ("certificate", "pkcs12"):
        raise ValueError("invalid_credential_delivery")
    if credential_delivery == "pkcs12" and re.fullmatch(r"[A-Za-z0-9_-]{20,32}", credential_password) is None:
        raise ValueError("invalid_credential_password")

    with LOCK:
        existing = find_existing(fingerprint, credential_delivery)
        if existing is not None:
            return public_state(existing)

        request_id = secrets.token_urlsafe(24)
        registration_code = "".join(secrets.choice(CODE_ALPHABET) for _ in range(8))
        now = utc_now()
        item: dict[str, object] = {
            "request_id": request_id,
            "registration_code": registration_code,
            "device_name": device_name,
            "fingerprint": fingerprint,
            "public_key_pem": canonical_public_key,
            "credential_delivery": credential_delivery,
            "status": "pending",
            "created_at": iso(now),
            "expires_at": iso(now + dt.timedelta(hours=24)),
        }
        if credential_delivery == "pkcs12":
            item["credential_password"] = credential_password
        write_request(STATE_DIR / f"{request_id}.json", item)
        return public_state(item)


def lookup_request(request_id: str) -> dict[str, object] | None:
    if not request_id or any(char not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_" for char in request_id):
        return None
    path = STATE_DIR / f"{request_id}.json"
    if not path.is_file():
        return None
    try:
        return read_request(path)
    except (OSError, json.JSONDecodeError):
        return None


class Handler(BaseHTTPRequestHandler):
    server_version = ""
    sys_version = ""

    def bootstrap_authorized(self) -> bool:
        supplied = self.headers.get("X-Kimi-Bootstrap-Fingerprint", "").strip().lower()
        return hmac.compare_digest(supplied, expected_bootstrap_fingerprint())

    def write_json(self, status: int, value: dict[str, object]) -> None:
        body = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:
        if self.path != "/__kimi_enroll/request":
            self.write_json(404, {"ok": False, "code": "not_found"})
            return
        if not self.bootstrap_authorized():
            self.write_json(403, {"ok": False, "code": "bootstrap_forbidden"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_BODY:
            self.write_json(400, {"ok": False, "code": "invalid_body"})
            return
        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
            result = create_request(
                str(payload.get("device_name", "")),
                str(payload.get("public_key_pem", "")),
                str(payload.get("proof_nonce", "")),
                str(payload.get("proof_signature", "")),
                str(payload.get("credential_delivery", "certificate")),
                str(payload.get("credential_password", "")),
            )
        except (UnicodeDecodeError, json.JSONDecodeError, AttributeError):
            self.write_json(400, {"ok": False, "code": "invalid_json"})
            return
        except ValueError as exc:
            self.write_json(400, {"ok": False, "code": str(exc)})
            return
        self.write_json(200, result)

    def do_GET(self) -> None:
        if not self.bootstrap_authorized():
            self.write_json(403, {"ok": False, "code": "bootstrap_forbidden"})
            return
        split = urlsplit(self.path)
        if split.path != "/__kimi_enroll/status":
            self.write_json(404, {"ok": False, "code": "not_found"})
            return
        request_id = parse_qs(split.query).get("id", [""])[0]
        item = lookup_request(request_id)
        if item is None:
            self.write_json(404, {"ok": False, "code": "request_not_found"})
            return
        self.write_json(200, public_state(item))

    def log_message(self, fmt: str, *args: object) -> None:
        return


if __name__ == "__main__":
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    threading.Thread(target=sweep_expired_requests, daemon=True).start()
    ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler).serve_forever()
