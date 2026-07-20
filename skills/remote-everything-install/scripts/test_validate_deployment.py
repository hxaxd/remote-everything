#!/usr/bin/env python3
import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("validate_deployment.py")
ASSETS = SCRIPT.parent.parent / "assets"
SPEC = importlib.util.spec_from_file_location("deployment_validator", SCRIPT)
validator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validator)


class DeploymentContractTests(unittest.TestCase):
    def test_rendered_frp_contract_and_inner_tls_rejection(self):
        client = (ASSETS / "frpc.toml.tmpl").read_text(encoding="utf-8")
        replacements = {
            "PUBLIC_HOST": "remote.example.com", "TUNNEL_CLIENT_CERT": "/client.pem",
            "TUNNEL_CLIENT_KEY": "/client.key", "FRPS_TOKEN_FILE": "/token", "FRPC_LOG": "/frpc.log",
            "INSTALLATION_ID": "a" * 64, "NODE_PORT": "5001", "NODE_TUNNEL_PORT": "5002",
        }
        for key, value in replacements.items(): client = client.replace("{{" + key + "}}", value)
        server = (ASSETS / "frps.toml.tmpl").read_text(encoding="utf-8").replace("{{FRPS_PORT}}", "5003").replace("{{FRPS_TOKEN_FILE}}", "/token").replace("{{FRPS_LOG}}", "/frps.log")
        validator.validate_frp_contract(client, server)
        with self.assertRaises(ValueError):
            validator.validate_frp_contract(client, server + "\ntransport.tls.force = true\n")
        with self.assertRaises(ValueError):
            validator.validate_frp_contract(client.replace("[[proxies]]", 'transport.tls.trustedCaFile = "/ca.pem"\n\n[[proxies]]'), server)

    def test_caddy_contract_requires_route_order(self):
        caddy = (ASSETS / "Caddyfile.tmpl").read_text(encoding="utf-8")
        caddy = caddy.replace("{{PUBLIC_HOST}}", "remote.example.com")
        validator.validate_caddy_contract(caddy)
        pair = caddy.index("@pair path")
        tunnel = caddy.index("@tunnel expression")
        device = caddy.index("\t@device expression")
        broken = caddy[:pair] + caddy[tunnel:device] + caddy[pair:tunnel] + caddy[device:]
        with self.assertRaises(ValueError):
            validator.validate_caddy_contract(broken)
        with self.assertRaises(ValueError):
            validator.validate_caddy_contract(caddy.replace("\tauto_https disable_redirects\n", ""))
        with self.assertRaises(ValueError):
            validator.validate_caddy_contract(caddy.replace("\t\t\tdisable_http_challenge\n", ""))


if __name__ == "__main__":
    unittest.main()
