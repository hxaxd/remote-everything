#!/usr/bin/env python3
"""Deployment acceptance for device trust, not a unit test: it pairs against a
real, deployed gateway, pulls the client certificate out of the issued PKCS#12
with openssl, checks the fingerprint, and then speaks mTLS with that
certificate. CI only syntax-checks this file; running it needs a deployment
(PUBLIC_ORIGIN, SERVER_STATE_ROOT, GATEWAY_BIN).

Pairing and device records belong to internal/devicecore, so this script sits
beside them rather than under any one entrypoint.
"""
import base64
import hashlib
import json
import os
import shutil
import ssl
import subprocess
import tempfile
import urllib.error
import urllib.request

public_origin = os.environ.get("PUBLIC_ORIGIN", "").rstrip("/")
if not public_origin.startswith("https://"):
    raise SystemExit("set PUBLIC_ORIGIN to the deployed HTTPS origin")
if shutil.which("openssl") is None:
    raise SystemExit("openssl is required")

server_state_root = os.environ.get("SERVER_STATE_ROOT", "/var/lib/remote-everything-server")
gateway_binary = os.environ.get("GATEWAY_BIN", "/usr/local/bin/remote-everything-gateway")
with open(os.path.join(server_state_root, "server.json"), encoding="utf-8") as source:
    server_state = json.load(source)
pairing_listen = server_state.get("pairing_listen", "")
if not pairing_listen.startswith("127.0.0.1:"):
    raise SystemExit("server.json has an invalid pairing_listen")
credential_password = base64.urlsafe_b64encode(os.urandom(24)).decode("ascii").rstrip("=")
invitation_result = subprocess.run(
    [gateway_binary, "device", "--state", server_state_root, "invite",
     "--name", "Protocol self-test", "--origin", public_origin, "--ttl", "5m"],
    check=True,
    capture_output=True,
    text=True,
)
invitation = json.loads(invitation_result.stdout)["invitation"]
payload = json.dumps({
    "device_name": "protocol-self-test",
    "credential_password": credential_password,
}).encode("utf-8")
pair_request = urllib.request.Request(
    f"http://{pairing_listen}/__remote_everything_pair",
    data=payload,
    method="POST",
    headers={
        "Content-Type": "application/json",
        "Authorization": f"Invitation {invitation}",
    },
)
with urllib.request.urlopen(pair_request, timeout=5) as response:
    paired = json.loads(response.read())

credential = base64.b64decode(paired["credential_pkcs12"], validate=True)
with tempfile.TemporaryDirectory() as directory:
    credential_path = os.path.join(directory, "client.p12")
    certificate_path = os.path.join(directory, "client.crt.pem")
    key_path = os.path.join(directory, "client.key.pem")
    chain_path = os.path.join(directory, "chain.crt.pem")
    with open(credential_path, "wb") as file:
        file.write(credential)
    password_input = (credential_password + "\n").encode("ascii")
    for arguments in (
        ["-clcerts", "-nokeys", "-out", certificate_path],
        ["-nocerts", "-nodes", "-out", key_path],
        ["-cacerts", "-nokeys", "-out", chain_path],
    ):
        subprocess.run(
            ["openssl", "pkcs12", "-in", credential_path, "-passin", "stdin", *arguments],
            input=password_input, check=True, stdout=subprocess.DEVNULL,
        )
    if not all(os.path.getsize(path) for path in (certificate_path, key_path, chain_path)):
        raise SystemExit("pkcs12 contents missing")
    key_public = subprocess.run(
        ["openssl", "pkey", "-in", key_path, "-pubout"], check=True, capture_output=True,
    ).stdout
    certificate_public = subprocess.run(
        ["openssl", "x509", "-in", certificate_path, "-pubkey", "-noout"], check=True, capture_output=True,
    ).stdout
    if key_public != certificate_public:
        raise SystemExit("pkcs12 key does not match certificate")
    with open(certificate_path, encoding="ascii") as file:
        certificate_pem = file.read()
    certificate_pem = certificate_pem[certificate_pem.index("-----BEGIN CERTIFICATE-----"):]
    certificate_der = ssl.PEM_cert_to_DER_cert(certificate_pem)
    fingerprint = hashlib.sha256(certificate_der).hexdigest()
    if fingerprint != paired["certificate_fingerprint"]:
        raise SystemExit("certificate fingerprint mismatch")

    context = ssl.create_default_context()
    context.load_cert_chain(certificate_path, key_path)
    activate_request = urllib.request.Request(
        f"{public_origin}/__remote_everything_activate",
        data=b"{}",
        method="POST",
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(activate_request, context=context, timeout=10) as response:
        approval_pending = json.loads(response.read())
        if response.status != 202 or approval_pending.get("code") != "approval_pending":
            raise SystemExit("unapproved device activated")
    subprocess.run(
        [gateway_binary, "device", "--state", server_state_root, "approve", fingerprint],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    with urllib.request.urlopen(activate_request, context=context, timeout=10) as response:
        public_apps = json.loads(response.read())
    if public_apps.get("ok") is not True or public_apps.get("computer_connected") is not True:
        raise SystemExit("activation did not validate the node chain")

    apps_request = urllib.request.Request(f"{public_origin}/__remote_everything/apps")
    with urllib.request.urlopen(apps_request, context=context, timeout=10) as response:
        public_apps = json.loads(response.read())
    if public_apps.get("ok") is not True or not isinstance(public_apps.get("apps"), list):
        raise SystemExit("application directory response invalid")
    with urllib.request.urlopen(f"{public_origin}/", context=context, timeout=10) as response:
        root_status = response.status

    subprocess.run(
        [gateway_binary, "device", "--state", server_state_root, "revoke", fingerprint],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    try:
        urllib.request.urlopen(apps_request, context=context, timeout=10)
    except urllib.error.HTTPError as error:
        if error.code not in (401, 403):
            raise
    else:
        raise SystemExit("revoked device still has access")

print(json.dumps({
    "ok": True,
    "credential_format": paired["credential_format"],
    "applications": [app.get("id") for app in public_apps.get("apps", [])],
    "root_http": root_status,
    "revoked": fingerprint,
}, ensure_ascii=False))
