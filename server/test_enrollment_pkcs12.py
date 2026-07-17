#!/usr/bin/env python3
import base64
import json
import os
import ssl
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.serialization import pkcs12


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


device_name = "protocol-self-test"
public_host = os.environ.get("PUBLIC_HOST")
if not public_host:
    raise SystemExit("set PUBLIC_HOST to the gateway IP or DNS name")
proof_key = ec.generate_private_key(ec.SECP256R1())
public_key_pem = proof_key.public_key().public_bytes(
    serialization.Encoding.PEM,
    serialization.PublicFormat.SubjectPublicKeyInfo,
).decode("ascii")
nonce = os.urandom(32)
message = b"KIMI-REMOTE-ENROLL-V1\x00" + device_name.encode("utf-8") + b"\x00" + nonce
signature = proof_key.sign(message, ec.ECDSA(hashes.SHA256()))
credential_password = base64.urlsafe_b64encode(os.urandom(18)).decode("ascii").rstrip("=")
payload = json.dumps({
    "device_name": device_name,
    "public_key_pem": public_key_pem,
    "proof_nonce": base64.b64encode(nonce).decode("ascii"),
    "proof_signature": base64.b64encode(signature).decode("ascii"),
    "credential_delivery": "pkcs12",
    "credential_password": credential_password,
}).encode("utf-8")
bootstrap_fingerprint = open("/etc/kimi-gateway/bootstrap-fingerprint", encoding="utf-8").read().strip()
headers = {
    "Content-Type": "application/json",
    "X-Kimi-Bootstrap-Fingerprint": bootstrap_fingerprint,
}
request = urllib.request.Request(
    "http://127.0.0.1:58631/__kimi_enroll/request",
    data=payload,
    method="POST",
    headers=headers,
)
with urllib.request.urlopen(request, timeout=5) as response:
    created = json.loads(response.read())

enroll_cli = "/usr/local/sbin/agent-remote-enroll"
if not os.path.isfile(enroll_cli):
    enroll_cli = "/usr/local/sbin/kimi-enroll"
subprocess.run([enroll_cli, "approve", created["registration_code"]], check=True, stdout=subprocess.DEVNULL)
state_file = f"/var/lib/kimi-enrollment/requests/{created['request_id']}.json"
state = json.loads(open(state_file, encoding="utf-8").read())
if "credential_password" in state:
    raise SystemExit("credential password retained after approval")
status_request = urllib.request.Request(
    f"http://127.0.0.1:58631/__kimi_enroll/status?id={created['request_id']}",
    headers=headers,
)
with urllib.request.urlopen(status_request, timeout=5) as response:
    approved = json.loads(response.read())

credential = base64.b64decode(approved["credential_pkcs12"], validate=True)
private_key, certificate, chain = pkcs12.load_key_and_certificates(
    credential,
    credential_password.encode("ascii"),
)
if private_key is None or certificate is None or not chain:
    raise SystemExit("pkcs12 contents missing")
if private_key.public_key().public_numbers() != certificate.public_key().public_numbers():
    raise SystemExit("pkcs12 key does not match certificate")
if certificate.fingerprint(hashes.SHA256()).hex() != approved["certificate_fingerprint"]:
    raise SystemExit("certificate fingerprint mismatch")

with tempfile.TemporaryDirectory() as directory:
    certificate_path = os.path.join(directory, "client.crt.pem")
    key_path = os.path.join(directory, "client.key.pem")
    open(certificate_path, "wb").write(certificate.public_bytes(serialization.Encoding.PEM))
    open(key_path, "wb").write(private_key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ))
    context = ssl.create_default_context()
    context.load_cert_chain(certificate_path, key_path)
    token = open("/etc/kimi-gateway/control-token", encoding="utf-8").read().strip()
    public_request = urllib.request.Request(
        f"https://{public_host}/__kimi_remote/status",
        headers={"Authorization": f"Bearer {token}"},
    )
    with urllib.request.urlopen(public_request, context=context, timeout=10) as response:
        public_state = json.loads(response.read())
    apps_request = urllib.request.Request(
        f"https://{public_host}/__agent_remote/apps",
        headers={"Authorization": f"Bearer {token}"},
    )
    with urllib.request.urlopen(apps_request, context=context, timeout=10) as response:
        public_apps = json.loads(response.read())
    open_request = urllib.request.Request(f"https://{public_host}/__agent_remote/open/kimi")
    opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=context), NoRedirect())
    try:
        opener.open(open_request, timeout=10)
        raise SystemExit("application route did not redirect")
    except urllib.error.HTTPError as redirect:
        if redirect.code != 302 or redirect.headers.get("Location") != "/" or "AgentRemoteApp=kimi" not in redirect.headers.get("Set-Cookie", ""):
            raise
    routed_request = urllib.request.Request(
        f"https://{public_host}/",
        headers={"Cookie": "AgentRemoteApp=kimi"},
    )
    with urllib.request.urlopen(routed_request, context=context, timeout=10) as response:
        routed_status = response.status
    stop_request = urllib.request.Request(
        f"https://{public_host}/__agent_remote/apps/kimi/stop",
        method="POST",
        headers={"Authorization": f"Bearer {token}"},
    )
    with urllib.request.urlopen(stop_request, context=context, timeout=10) as response:
        stopped = json.loads(response.read())
    start_request = urllib.request.Request(
        f"https://{public_host}/__agent_remote/apps/kimi/start",
        method="POST",
        headers={"Authorization": f"Bearer {token}"},
    )
    with urllib.request.urlopen(start_request, context=context, timeout=10) as response:
        started = json.loads(response.read())
    restored = ""
    for _ in range(12):
        time.sleep(1)
        status_request = urllib.request.Request(
            f"https://{public_host}/__agent_remote/apps/kimi/status",
            headers={"Authorization": f"Bearer {token}"},
        )
        with urllib.request.urlopen(status_request, context=context, timeout=10) as response:
            restored = json.loads(response.read()).get("code", "")
        if restored == "ready":
            break
    if restored != "ready":
        raise SystemExit("application did not restart")

subprocess.run([
    enroll_cli,
    "revoke",
    approved["certificate_fingerprint"],
], check=True, stdout=subprocess.DEVNULL)
print(json.dumps({
    "ok": True,
    "credential_format": approved["credential_format"],
    "public_status": public_state.get("code"),
    "applications": [app.get("id") for app in public_apps.get("apps", [])],
    "open_redirect": 302,
    "routed_http": routed_status,
    "stop": stopped.get("code"),
    "start": started.get("code"),
    "restored": restored,
    "revoked": approved["certificate_fingerprint"],
}, ensure_ascii=False))
