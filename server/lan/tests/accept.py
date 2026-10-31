#!/usr/bin/env python3
"""Exercise the no-domain LAN tunnel using real node, LAN gateway and FRP binaries.

Usage: python3 server/lan/tests/accept.py MATERIAL_DIRECTORY
The directory contains node, lan, frpc and frps. No system services, DNS records,
privileged ports or machine trust stores are changed.
"""
import base64
import http.client
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import tempfile
import time
from urllib.parse import parse_qs, urlsplit


REPO = Path(__file__).resolve().parents[3]
RENDER = REPO / "skills/remote-everything-install/scripts/render.py"
VALIDATE = RENDER.with_name("validate_deployment.py")


def run(*args):
    return subprocess.check_output([str(arg) for arg in args], text=True)


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def listening(port):
    with socket.socket() as sock:
        sock.settimeout(.2)
        return sock.connect_ex(("127.0.0.1", port)) == 0


def wait_port(port, opened=True):
    for _ in range(200):
        if listening(port) == opened:
            return
        time.sleep(.1)
    raise AssertionError(f"port {port} did not become {'open' if opened else 'closed'}")


def request(context, origin, method, path, headers=None, body=None):
    target = urlsplit(origin)
    connection = http.client.HTTPSConnection(target.hostname, target.port, context=context, timeout=10)
    try:
        connection.request(method, path, body=body, headers=headers or {})
        response = connection.getresponse()
        return response.status, dict(response.getheaders()), response.read()
    finally:
        connection.close()


def check_tls(port, context, allowed):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=3) as raw:
            with context.wrap_socket(raw, server_hostname="remote-everything-frps") as secure:
                if allowed:
                    return
                secure.sendall(b"not-an-frp-login")
                secure.recv(1)
    except (ssl.SSLError, ConnectionError):
        if not allowed:
            return
        raise
    raise AssertionError("FRPS admitted a TLS peer that should be refused")


def main(materials):
    binaries = {name: materials / name for name in ("node", "lan", "frpc", "frps")}
    for path in binaries.values():
        assert path.is_file(), f"missing binary: {path}"
    processes = []
    handles = []
    app_port = free_port()
    with tempfile.TemporaryDirectory(prefix="remote-lan-tunnel-") as directory:
        root = Path(directory)
        os.chmod(root, 0o700)
        try:
            def cli(name, *args):
                return json.loads(run(binaries[name], *args))

            def launch(name, *args):
                output = (root / (name + ".process.log")).open("ab")
                handles.append(output)
                process = subprocess.Popen([str(binaries[name]), *map(str, args)], stdout=output, stderr=output)
                processes.append(process)
                return process

            def render(kind, values):
                source, destination = root / (kind + ".json"), root / (kind + ".toml")
                source.write_text(json.dumps(values))
                run(sys.executable, RENDER, kind, "--input", source, "--output", destination)
                return destination

            node_root, lan_root, bundle = root / "node", root / "lan", root / "bundle"
            node = cli("node", "init", "--state", node_root)
            gateway = cli("lan", "init", "--state", lan_root, "--host", "127.0.0.1", "--tunnel", "--require-approval")
            added = cli("lan", "node", "add", "--state", lan_root, "--name", "Desk",
                        "--node-id", node["node_id"], "--node-bootstrap", bundle)
            cli("node", "binding", "add", "--state", node_root, "--bootstrap", bundle)
            fixture = root / "fixture.json"
            fixture.write_text(json.dumps(dict(id="editor", name="Editor", description="", icon="E", accent="#2563eb",
                proxy_url=f"http://127.0.0.1:{app_port}", command=sys.executable,
                arguments=[str(REPO / "internal/node/nodecore/testharness/fixture_server.py"), str(app_port)],
                stop_command="", stop_arguments=[], workdir=str(root))))
            cli("node", "app", "set", "--state", node_root, "--file", fixture)
            frps_host, frps_port = gateway["frps_listen"].rsplit(":", 1)
            node_host, node_port = node["listen_address"].rsplit(":", 1)
            remote_port = int(added["node_address"].rsplit(":", 1)[1])
            agent_root = Path(added["tunnel_material_directory"])
            server_config = render("frps-lan", dict(bind_host=frps_host, frps_port=int(frps_port),
                frps_token_file=gateway["frps_token_file"], frps_log=str(root / "frps.log"),
                tunnel_server_cert=gateway["tunnel_server_certificate_file"],
                tunnel_server_key=gateway["tunnel_server_key_file"], tunnel_ca_file=gateway["tunnel_ca_file"]))
            client_config = render("frpc-lan", dict(server_host="127.0.0.1", server_port=int(frps_port),
                tunnel_server_name=gateway["tunnel_server_name"], tunnel_ca_file=str(agent_root / "tunnel-ca.crt.pem"),
                tunnel_client_cert=str(agent_root / "tunnel-client.crt.pem"),
                tunnel_client_key=str(agent_root / "tunnel-client.key.pem"), frps_token_file=str(agent_root / "frps-token"),
                frpc_log=str(root / "frpc.log"), node_id=node["node_id"], node_host=node_host,
                node_port=int(node_port), node_tunnel_port=remote_port))
            run(sys.executable, VALIDATE, "--frp-mode", "lan", "--frpc", binaries["frpc"], "--frpc-config", client_config,
                "--frps", binaries["frps"], "--frps-config", server_config)
            launch("node", "serve", "--state", node_root)
            wait_port(int(node_port))
            frps = launch("frps", "-c", server_config)
            wait_port(int(frps_port))
            tunnel_context = ssl.create_default_context(cafile=gateway["tunnel_ca_file"])
            check_tls(int(frps_port), tunnel_context, False)
            tunnel_context.load_cert_chain(str(agent_root / "tunnel-client.crt.pem"), str(agent_root / "tunnel-client.key.pem"))
            check_tls(int(frps_port), tunnel_context, True)
            frpc = launch("frpc", "-c", client_config)
            wait_port(remote_port)
            launch("lan", "serve", "--state", lan_root)
            wait_port(urlsplit(gateway["origin"]).port)
            state = json.loads((lan_root / "lan.json").read_text())
            server_cert = lan_root / state["lan"]["certificate_file"]
            anonymous = ssl.create_default_context(cafile=str(server_cert))
            for path in ("/__remote_everything/apps", "/web/", "/__remote_everything_web_pair"):
                assert request(anonymous, gateway["origin"], "GET", path)[0] == 401, path
            invitation = cli("lan", "device", "--state", lan_root, "invite", "--name", "Acceptance", "--node", node["node_id"])
            token = parse_qs(urlsplit(invitation["setup_uri"]).query)["invitation"][0]
            password = "acceptance-credential-password"
            status, _, body = request(anonymous, gateway["origin"], "POST", "/__remote_everything_pair",
                {"Authorization": "Invitation " + token, "Content-Type": "application/json"},
                json.dumps(dict(device_name="Acceptance", credential_password=password)))
            assert status == 200, f"pairing HTTP {status}"
            paired = json.loads(body)
            p12, password_file = root / "device.p12", root / "password"
            p12.write_bytes(base64.b64decode(paired["credential_pkcs12"]))
            password_file.write_text(password)
            os.chmod(p12, 0o600)
            os.chmod(password_file, 0o600)
            cert, key = root / "device.crt.pem", root / "device.key.pem"
            run("openssl", "pkcs12", "-in", p12, "-passin", "file:" + str(password_file), "-clcerts", "-nokeys", "-out", cert)
            run("openssl", "pkcs12", "-in", p12, "-passin", "file:" + str(password_file), "-nocerts", "-nodes", "-out", key)
            os.chmod(key, 0o600)
            device = ssl.create_default_context(cafile=str(server_cert))
            device.load_cert_chain(str(cert), str(key))
            wrong_role = ssl.create_default_context(cafile=gateway["tunnel_ca_file"])
            wrong_role.load_cert_chain(str(cert), str(key))
            check_tls(int(frps_port), wrong_role, False)
            wrong_server = ssl.create_default_context(cafile=str(server_cert))
            wrong_server.load_cert_chain(str(agent_root / "tunnel-client.crt.pem"), str(agent_root / "tunnel-client.key.pem"))
            check_tls(int(frps_port), wrong_server, False)
            header = {"X-Remote-Everything-Node": node["node_id"]}
            assert request(device, gateway["origin"], "GET", "/__remote_everything/apps", header)[0] == 401
            assert request(device, gateway["origin"], "POST", "/__remote_everything_activate", header)[0] == 202
            cli("lan", "device", "--state", lan_root, "approve", paired["certificate_fingerprint"])
            status, _, body = request(device, gateway["origin"], "POST", "/__remote_everything_activate", header)
            assert status == 200 and json.loads(body)["computer_connected"]
            status, _, body = request(device, gateway["origin"], "GET", "/__remote_everything/nodes")
            assert status == 200 and json.loads(body)["nodes"][0]["id"] == node["node_id"]
            status, _, _ = request(device, gateway["origin"], "POST", "/__remote_everything/apps/editor/start", header)
            assert status == 200
            wait_port(app_port)
            status, headers, _ = request(device, gateway["origin"], "GET", "/__remote_everything/open/editor", header)
            assert status == 302
            application = headers["Location"]
            status, _, body = request(device, application, "GET", "/deep?q=1", {"Cookie":"KeepMe=yes"})
            assert status == 200 and json.loads(body) == {"path":"/deep?q=1", "cookie":"KeepMe=yes"}
            assert request(anonymous, application, "GET", "/")[0] == 401
            frpc.terminate()
            frpc.wait(timeout=10)
            wait_port(remote_port, False)
            renewed = cli("lan", "tunnel", "renew", "--state", lan_root, "--node-bootstrap", bundle)
            assert renewed["tunnel_client_fingerprint"] != added["tunnel_client_fingerprint"]
            launch("frpc", "-c", client_config)
            wait_port(remote_port)
            assert request(device, application, "GET", "/")[0] == 200
            frps.terminate()
            frps.wait(timeout=10)
            wait_port(remote_port, False)
            cli("lan", "tunnel", "server", "renew", "--state", lan_root)
            launch("frps", "-c", server_config)
            wait_port(remote_port)
            assert request(device, application, "GET", "/")[0] == 200
            cli("lan", "device", "--state", lan_root, "revoke", paired["certificate_fingerprint"])
            assert request(device, application, "GET", "/")[0] == 401
            print(json.dumps({"ok":True, "suite":"lan-tunnel-deployment", "transport":"mutual-tls-tcp", "browser":False}))
        finally:
            for process in reversed(processes):
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=10)
            wait_port(app_port, False)
            for handle in handles:
                handle.close()


if __name__ == "__main__":
    main(Path(sys.argv[1]).resolve())
