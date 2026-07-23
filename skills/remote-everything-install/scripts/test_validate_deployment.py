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
            validator.validate_frp_contract(client.replace("transport.poolCount = 32", "transport.poolCount = 15"), server)
        with self.assertRaises(ValueError):
            validator.validate_frp_contract(client, server.replace("transport.maxPoolCount = 32", "transport.maxPoolCount = 15"))
        with self.assertRaises(ValueError):
            validator.validate_frp_contract(client, server + "\ntransport.tls.force = true\n")
        with self.assertRaises(ValueError):
            validator.validate_frp_contract(client.replace("[[proxies]]", 'transport.tls.trustedCaFile = "/ca.pem"\n\n[[proxies]]'), server)

    def test_caddy_contract_requires_route_order(self):
        caddy = (ASSETS / "Caddyfile.tmpl").read_text(encoding="utf-8")
        caddy = caddy.replace("{{PUBLIC_HOST}}", "remote.example.com").replace("{{ACME_PROFILE}}", "").replace("{{DEFAULT_SNI}}", "").replace("{{STRICT_SNI_HOST}}", "")
        validator.validate_caddy_contract(caddy)
        pair = caddy.index("@pair path")
        tunnel = caddy.index("@tunnel expression")
        device_control = caddy.index("\t@device_control {")
        device = caddy.index("\t@device expression")
        broken = caddy[:pair] + caddy[tunnel:device_control] + caddy[pair:tunnel] + caddy[device_control:]
        with self.assertRaises(ValueError):
            validator.validate_caddy_contract(broken)
        with self.assertRaises(ValueError):
            validator.validate_caddy_contract(caddy.replace("\tauto_https disable_redirects\n", ""))
        with self.assertRaises(ValueError):
            validator.validate_caddy_contract(caddy.replace("\t\t\tdisable_http_challenge\n", ""))
        with self.assertRaises(ValueError):
            validator.validate_caddy_contract(caddy.replace("\t" + 'encode @compressible zstd gzip\n', ""))
        with self.assertRaises(ValueError):
            validator.validate_caddy_contract(caddy.replace("\t\t\theader_up X-Remote-Everything-Client-Fingerprint", "\t\t\theader_up -X-Remote-Everything-Client-Fingerprint\n\t\t\theader_up X-Remote-Everything-Client-Fingerprint"))
        ip_caddy = caddy.replace("remote.example.com", "192.0.2.1")
        with self.assertRaises(ValueError):
            validator.validate_caddy_contract(ip_caddy)
        with self.assertRaises(ValueError):
            validator.validate_caddy_contract(ip_caddy.replace("disable_http_challenge", "disable_http_challenge\n\t\t\tprofile shortlived"))
        with self.assertRaises(ValueError):
            validator.validate_caddy_contract(ip_caddy.replace("auto_https disable_redirects", "auto_https disable_redirects\n\tdefault_sni 192.0.2.1").replace("disable_http_challenge", "disable_http_challenge\n\t\t\tprofile shortlived"))
        validator.validate_caddy_contract(ip_caddy.replace("auto_https disable_redirects", "auto_https disable_redirects\n\tdefault_sni 192.0.2.1\n\tservers {\n\t\tstrict_sni_host insecure_off\n\t}").replace("disable_http_challenge", "disable_http_challenge\n\t\t\tprofile shortlived"))


if __name__ == "__main__":
    unittest.main()
