#!/usr/bin/env python3
"""Regenerate tls.json: the certificates the clients' pinning is asserted against.

Apple's trust evaluation rejects a TLS certificate whose validity spans more than
825 days ("certificate is not standards compliant"), so the "valid" certificate
must be issued for less than that. It therefore expires about two years after this
script runs; run it again when `valid.validUntil` is close.

Both certificates are self-signed P-256 leaves with subjectAltName, extendedKeyUsage
serverAuth, subjectKeyIdentifier and authorityKeyIdentifier — the same shape the
node issues for a gateway, and the shape Apple's trust evaluation accepts.

usage: python3 clients/behavior/fixtures/generate-tls.py
"""
import base64
import hashlib
import json
import pathlib
import subprocess
import tempfile
from datetime import datetime, timedelta, timezone

FIXTURE = pathlib.Path(__file__).resolve().parent / "tls.json"
HARMONY = FIXTURE.parents[2] / "harmony/entry/src/ohosTest/resources/rawfile/behavior/tls.json"

VALID_DAYS = 800
EXPIRED_FROM = datetime(2020, 1, 1, tzinfo=timezone.utc)
EXPIRED_TO = datetime(2021, 1, 1, tzinfo=timezone.utc)

CONFIG = """[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = gateway.example
[v3]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
subjectAltName = DNS:gateway.example, DNS:*.gateway.example, IP:127.0.0.1, IP:2001:db8::1
"""


def stamp(moment: datetime) -> str:
    return moment.strftime("%Y%m%d%H%M%SZ")


def issue(work: pathlib.Path, name: str, not_before: datetime, not_after: datetime) -> bytes:
    config = work / f"{name}.cnf"
    config.write_text(CONFIG, encoding="utf-8")
    key = work / f"{name}.key"
    pem = work / f"{name}.pem"
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
         "-keyout", str(key), "-out", str(pem), "-nodes", "-config", str(config),
         "-not_before", stamp(not_before), "-not_after", stamp(not_after)],
        check=True, capture_output=True,
    )
    der = work / f"{name}.der"
    subprocess.run(["openssl", "x509", "-in", str(pem), "-outform", "DER", "-out", str(der)], check=True, capture_output=True)
    return der.read_bytes()


def public_key_der(work: pathlib.Path, name: str) -> bytes:
    pub_pem = subprocess.run(
        ["openssl", "x509", "-in", str(work / f"{name}.pem"), "-pubkey", "-noout"],
        check=True, capture_output=True,
    ).stdout
    return subprocess.run(
        ["openssl", "pkey", "-pubin", "-outform", "DER"], input=pub_pem, check=True, capture_output=True,
    ).stdout


def main() -> None:
    now = datetime.now(timezone.utc).replace(microsecond=0)
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp)
        valid = issue(work, "valid", now, now + timedelta(days=VALID_DAYS))
        expired = issue(work, "expired", EXPIRED_FROM, EXPIRED_TO)
        valid_pub = public_key_der(work, "valid")

    fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))
    fixture["certificates"] = {
        "valid": base64.b64encode(valid).decode(),
        "expired": base64.b64encode(expired).decode(),
    }
    fixture["pin"] = {
        "fingerprint": hashlib.sha256(valid).hexdigest(),
        "publicKeyPin": base64.b64encode(hashlib.sha256(valid_pub).digest()).decode(),
    }
    fixture["validUntil"] = (now + timedelta(days=VALID_DAYS)).strftime("%Y-%m-%d")
    text = json.dumps(fixture, indent=2) + "\n"
    FIXTURE.write_text(text, encoding="utf-8")
    if HARMONY.exists():
        HARMONY.write_text(text, encoding="utf-8")
    print(f"wrote {FIXTURE} (valid until {fixture['validUntil']})")


if __name__ == "__main__":
    main()
