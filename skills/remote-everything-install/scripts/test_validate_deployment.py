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
            "INSTALLATION_ID": "a" * 64, "NODE_HOST": "192.168.1.10", "NODE_PORT": "5001", "NODE_TUNNEL_PORT": "5002",
        }
        for key, value in replacements.items(): client = client.replace("{{" + key + "}}", value)
        server = (ASSETS / "frps.toml.tmpl").read_text(encoding="utf-8").replace("{{FRPS_PORT}}", "5003").replace("{{FRPS_TOKEN_FILE}}", "/token").replace("{{FRPS_LOG}}", "/frps.log")
        validator.validate_frp_contract(client, server)
        with self.assertRaises(ValueError):
            validator.validate_frp_contract(client.replace("transport.poolCount = 32", "transport.poolCount = 15"), server)
        with self.assertRaises(ValueError):
            validator.validate_frp_contract(client.replace('localIP = "192.168.1.10"', 'localIP = "0.0.0.0"'), server)
        with self.assertRaises(ValueError):
            validator.validate_frp_contract(client, server.replace("transport.maxPoolCount = 32", "transport.maxPoolCount = 15"))
        with self.assertRaises(ValueError):
            validator.validate_frp_contract(client, server.replace('proxyBindAddr = "127.0.0.1"', 'proxyBindAddr = "0.0.0.0"'))
        with self.assertRaises(ValueError):
            validator.validate_frp_contract(client, server + "\ntransport.tls.force = true\n")
        with self.assertRaises(ValueError):
            validator.validate_frp_contract(client.replace("[[proxies]]", 'transport.tls.trustedCaFile = "/ca.pem"\n\n[[proxies]]'), server)

    def test_caddy_contract_requires_route_order(self):
        caddy = (ASSETS / "Caddyfile.tmpl").read_text(encoding="utf-8")
        render_values = {
            "PUBLIC_HOST": "remote.example.com", "ACME_PROFILE": "", "DEFAULT_SNI": "", "STRICT_SNI_HOST": "",
            "DEVICE_CA_FILE": "/state/device-ca.pem", "TUNNEL_CA_FILE": "/state/tunnel-ca.pem",
            "PAIRING_UPSTREAM": "127.0.0.1:5001", "FRPS_UPSTREAM": "127.0.0.1:5002", "STATUS_UPSTREAM": "127.0.0.1:5003",
            "TUNNEL_ISSUER_DN": "CN=Tunnel", "DEVICE_ISSUER_DN": "CN=Device",
        }
        for key, value in render_values.items():
            caddy = caddy.replace("{{" + key + "}}", value)
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
        with self.assertRaises(ValueError):
            validator.validate_caddy_contract(caddy.replace("\t" + 'encode @compressible zstd gzip\n', ""))
        with self.assertRaises(ValueError):
            validator.validate_caddy_contract(caddy.replace("\t\t\theader_up X-Remote-Everything-Client-Fingerprint", "\t\t\theader_up -X-Remote-Everything-Client-Fingerprint\n\t\t\theader_up X-Remote-Everything-Client-Fingerprint"))
        # An application's host is `<application>.<node prefix>.<domain>`: a single
        # wildcard covers one label and would leave every application without a site
        # that serves it, so the two it takes are part of the contract.
        with self.assertRaises(ValueError):
            validator.validate_caddy_contract(caddy.replace("https://*.*.", "https://*."))
        with self.assertRaises(ValueError):
            validator.validate_caddy_contract(caddy.replace("\t\ton_demand\n", ""))
        with self.assertRaises(ValueError):
            validator.validate_caddy_contract(caddy.replace("\t\task http://127.0.0.1:5003/__remote_everything_tls_ask\n", ""))
        # The permission is asked on loopback: the entrance stands on the gateway's
        # own machine, and an ask endpoint anywhere else is one a stranger can answer.
        with self.assertRaises(ValueError):
            validator.validate_caddy_contract(caddy.replace("ask http://127.0.0.1:5003/", "ask http://192.0.2.5:5003/"))
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
