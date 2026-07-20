#!/usr/bin/env python3
import argparse
import json
import os
import re
import subprocess
import tomllib


def read_rendered(path):
    with open(path, encoding="utf-8") as source:
        text = source.read()
    if re.search(r"\{\{[A-Z0-9_]+\}\}", text):
        raise ValueError(f"unrendered placeholder in {path}")
    return text


def run(command):
    result = subprocess.run(command, capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise ValueError((result.stderr or result.stdout or "validation failed").strip())
    return result.stdout


def nested(value, *path):
    for key in path:
        if not isinstance(value, dict) or key not in value:
            raise ValueError("missing config field " + ".".join(path))
        value = value[key]
    return value


def validate_frp_contract(client_text, server_text):
    client = tomllib.loads(client_text)
    server = tomllib.loads(server_text)
    if client.get("serverPort") != 443 or nested(client, "transport", "protocol") != "wss" or nested(client, "transport", "wireProtocol") != "v2":
        raise ValueError("frpc transport must be WSS v2 on 443")
    tls = nested(client, "transport", "tls")
    for key in ("certFile", "keyFile", "serverName"):
        if not isinstance(tls.get(key), str) or not tls[key]:
            raise ValueError(f"frpc TLS field {key} is required")
    if "trustedCaFile" in tls:
        raise ValueError("frpc public server trust must use the operating-system trust store")
    if tls.get("enable") is not True:
        raise ValueError("frpc TLS must be enabled")
    if nested(client, "auth", "method") != "token" or nested(client, "auth", "tokenSource", "type") != "file" or not nested(client, "auth", "tokenSource", "file", "path"):
        raise ValueError("frpc must use a file token")
    proxies = client.get("proxies")
    if not isinstance(proxies, list) or len(proxies) != 1:
        raise ValueError("frpc must define exactly one node proxy")
    proxy = proxies[0]
    if proxy.get("type") != "tcp" or proxy.get("localIP") != "127.0.0.1" or not isinstance(proxy.get("localPort"), int) or not isinstance(proxy.get("remotePort"), int):
        raise ValueError("frpc node proxy contract is invalid")
    if server.get("bindAddr") != "127.0.0.1" or not isinstance(server.get("bindPort"), int):
        raise ValueError("frps must bind a dynamic loopback port")
    if "tls" in server.get("transport", {}):
        raise ValueError("frps behind the TLS-terminating reverse proxy must not require inner TLS")
    if nested(server, "auth", "method") != "token" or nested(server, "auth", "tokenSource", "type") != "file" or not nested(server, "auth", "tokenSource", "file", "path"):
        raise ValueError("frps must use a file token")


def validate_caddy_contract(text):
    active = "\n".join(line.split("#", 1)[0] for line in text.splitlines())
    markers = ["@pair path /__remote_everything_pair", "@tunnel expression", "@device expression"]
    positions = [active.find(marker) for marker in markers]
    if any(position < 0 for position in positions) or positions != sorted(positions):
        raise ValueError("Caddy routes must be ordered pairing, tunnel, device")
    for required in ("auto_https disable_redirects", "disable_http_challenge", "path('/~!frp')", "{tls_client_fingerprint}", "header_up -X-Remote-Everything-Client-Fingerprint", "mode verify_if_given"):
        if required not in active:
            raise ValueError(f"Caddy config missing {required}")


def main():
    parser = argparse.ArgumentParser()
    for name in ("frpc", "frpc-config", "frps", "frps-config", "caddy", "caddy-config"):
        parser.add_argument("--" + name)
    args = parser.parse_args()
    try:
        if args.frpc or args.frpc_config or args.frps or args.frps_config:
            if not all((args.frpc, args.frpc_config, args.frps, args.frps_config)):
                raise ValueError("FRP validation requires both binaries and both configs")
            client = read_rendered(args.frpc_config)
            server = read_rendered(args.frps_config)
            validate_frp_contract(client, server)
            run([os.path.abspath(args.frpc), "verify", "-c", os.path.abspath(args.frpc_config)])
            run([os.path.abspath(args.frps), "verify", "-c", os.path.abspath(args.frps_config)])
        if args.caddy or args.caddy_config:
            if not args.caddy or not args.caddy_config:
                raise ValueError("Caddy validation requires binary and config")
            caddy = read_rendered(args.caddy_config)
            validate_caddy_contract(caddy)
            adapted = run([os.path.abspath(args.caddy), "adapt", "--config", os.path.abspath(args.caddy_config)])
            json.loads(adapted)
            run([os.path.abspath(args.caddy), "validate", "--config", os.path.abspath(args.caddy_config)])
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        parser.error(str(error))
    print(json.dumps({"ok": True}, separators=(",", ":")))


if __name__ == "__main__":
    main()
