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
    def test_lan_tunnel_contract_rejects_missing_mutual_tls_and_wrong_mode(self):
        def rendered(name, replacements):
            text = (ASSETS / name).read_text(encoding="utf-8")
            for key, value in replacements.items():
                text = text.replace("{{" + key + "}}", value)
            return text
        client = rendered("frpc-lan.toml.tmpl", {
            "SERVER_HOST":"192.0.2.10", "SERVER_PORT":"51001", "TUNNEL_SERVER_NAME":"remote-everything-frps",
            "TUNNEL_CA_FILE":"/agent/ca.pem", "TUNNEL_CLIENT_CERT":"/agent/client.pem", "TUNNEL_CLIENT_KEY":"/agent/client.key",
            "FRPS_TOKEN_FILE":"/agent/token", "FRPC_LOG":"/logs/frpc.log", "NODE_ID":"a"*64,
            "NODE_HOST":"127.0.0.1", "NODE_PORT":"51002", "NODE_TUNNEL_PORT":"51003"})
        server = rendered("frps-lan.toml.tmpl", {
            "BIND_HOST":"0.0.0.0", "FRPS_PORT":"51001", "TUNNEL_SERVER_CERT":"/state/server.pem",
            "TUNNEL_SERVER_KEY":"/state/server.key", "TUNNEL_CA_FILE":"/state/ca.pem",
            "FRPS_TOKEN_FILE":"/state/token", "FRPS_LOG":"/logs/frps.log"})
        validator.validate_frp_contract(client, server, "lan")
        for bad_client, bad_server, mode in (
            (client, server, "public"),
            (client.replace('transport.tls.trustedCaFile = "/agent/ca.pem"', ''), server, "lan"),
            (client, server.replace('transport.tls.force = true', 'transport.tls.force = false'), "lan"),
            (client, server.replace('transport.tls.trustedCaFile = "/state/ca.pem"', ''), "lan"),
            (client, server.replace('proxyBindAddr = "127.0.0.1"', 'proxyBindAddr = "0.0.0.0"'), "lan"),
            (client.replace('serverPort = 51001', 'serverPort = 51009'), server, "lan"),
        ):
            with self.subTest(mode=mode, client=bad_client[:60]):
                with self.assertRaises(ValueError):
                    validator.validate_frp_contract(bad_client, bad_server, mode)

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
        with self.assertRaises(ValueError):
            validator.validate_caddy_contract(caddy.replace("header_up -X-Remote-Everything-Client-Fingerprint", ""))
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
        # The ask path is one name: the template has to ask where the gateway
        # answers, and the validator reads that name from the gateway itself.
        with self.assertRaises(ValueError):
            validator.validate_caddy_contract(caddy.replace("/__remote_everything_tls_ask", "/__remote_everything_ask"))
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
