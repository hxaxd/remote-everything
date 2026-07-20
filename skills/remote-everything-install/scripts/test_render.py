#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as etree
from pathlib import Path


SCRIPT = Path(__file__).with_name("render.py")
INSTALLATION_ID = "a" * 64


class RenderTests(unittest.TestCase):
    def render(self, kind, values, *, launcher=False):
        root = Path(tempfile.mkdtemp())
        source = root / "values.json"
        output = root / "output"
        source.write_text(json.dumps(values), encoding="utf-8")
        command = [sys.executable, str(SCRIPT), kind, "--input", str(source), "--output", str(output)]
        launcher_path = root / "launcher.vbs"
        if launcher:
            command += ["--launcher-output", str(launcher_path)]
        result = subprocess.run(command, capture_output=True, text=True)
        return result, output, launcher_path

    def test_service_renderers_escape_arguments_and_produce_parseable_xml(self):
        common = {"installation_id": INSTALLATION_ID, "component_id": "node", "working_directory": "/opt/remote everything", "executable": "/opt/remote everything/control", "arguments": ["serve", "--state", "/tmp/a b", "$VALUE"]}
        result, output, _ = self.render("systemd", {**common, "user": "remote_everything", "log_file": "/opt/remote everything/node.log"})
        self.assertEqual(result.returncode, 0, result.stderr)
        rendered = output.read_text(encoding="utf-8")
        self.assertIn('"/tmp/a b"', rendered)
        self.assertIn('"$$VALUE"', rendered)
        self.assertIn("WorkingDirectory=/opt/remote\\x20everything", rendered)
        self.assertNotIn("ProtectSystem", rendered)
        self.assertIn("User=remote_everything", rendered)
        self.assertIn("WantedBy=multi-user.target", rendered)
        result, output, _ = self.render("systemd-user", {**common, "log_file": "/opt/remote everything/node.log"})
        self.assertEqual(result.returncode, 0, result.stderr)
        rendered = output.read_text(encoding="utf-8")
        self.assertNotIn("User=", rendered)
        self.assertNotIn("network-online.target", rendered)
        self.assertIn("WantedBy=default.target", rendered)
        result, output, _ = self.render("launchd", {**common, "log_file": "/tmp/a&b.log"})
        self.assertEqual(result.returncode, 0, result.stderr)
        etree.parse(output)

    def test_caddy_systemd_grants_only_bind_capability_and_persists_state(self):
        values = {
            "installation_id": INSTALLATION_ID, "user": "remote_everything",
            "working_directory": "/opt/remote everything/.runtime", "executable": "/opt/remote everything/.runtime/bin/caddy",
            "arguments": ["run", "--config", "/opt/remote everything/.runtime/config/Caddyfile"],
            "data_directory": "/opt/remote everything/.runtime/caddy-data", "config_directory": "/opt/remote everything/.runtime/caddy-config",
            "config_file": "/opt/remote everything/.runtime/config/Caddyfile", "log_file": "/opt/remote everything/.runtime/logs/caddy.log",
        }
        result, output, _ = self.render("caddy-systemd", values)
        self.assertEqual(result.returncode, 0, result.stderr)
        rendered = output.read_text(encoding="utf-8")
        self.assertIn("AmbientCapabilities=CAP_NET_BIND_SERVICE", rendered)
        self.assertIn('Environment="XDG_DATA_HOME=/opt/remote everything/.runtime/caddy-data"', rendered)
        self.assertNotIn("User=root", rendered)

    def test_windows_renderer_creates_utf16_task_and_launcher(self):
        values = {
            "installation_id": INSTALLATION_ID, "component_id": "frpc", "user_sid": "S-1-5-21-1-2-3-1001",
            "working_directory": r"C:\Remote Everything", "wscript": r"C:\Windows\System32\wscript.exe",
            "executable": r"C:\Remote Everything\frpc.exe", "arguments": ["-c", r"C:\Remote Everything\frpc.toml"],
        }
        result, output, launcher = self.render("windows", values, launcher=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        etree.parse(output)
        task = output.read_text(encoding="utf-16")
        launcher_text = launcher.read_text(encoding="utf-16")
        self.assertIn("<Count>999</Count>", task)
        self.assertIn("frpc.exe", launcher_text)
        self.assertIn("WScript.Quit", launcher_text)
        self.assertTrue(launcher_text.rstrip().endswith(", 0, True)"))

    @unittest.skipUnless(os.name == "nt", "Windows Script Host is required")
    def test_windows_launcher_waits_and_propagates_exit_code(self):
        windows = os.environ["WINDIR"]
        values = {
            "installation_id": INSTALLATION_ID, "component_id": "probe", "user_sid": "S-1-5-18",
            "working_directory": windows, "wscript": str(Path(windows) / "System32" / "wscript.exe"),
            "executable": str(Path(windows) / "System32" / "cmd.exe"), "arguments": ["/d", "/c", "exit", "7"],
        }
        result, _, launcher = self.render("windows", values, launcher=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        executed = subprocess.run([str(Path(windows) / "System32" / "cscript.exe"), "//nologo", str(launcher)], capture_output=True, text=True)
        self.assertEqual(executed.returncode, 7, executed.stderr)

    def test_frp_and_caddy_renderers_reject_unknown_keys(self):
        frps = {"frps_port": 58630, "frps_token_file": "/state/frps-token", "frps_log": "/state/frps.log"}
        result, output, _ = self.render("frps", frps)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("transport.tls.", output.read_text(encoding="utf-8"))
        result, _, _ = self.render("frps", {**frps, "unknown": True})
        self.assertNotEqual(result.returncode, 0)
        result, _, _ = self.render("frps", {**frps, "frps_token_file": "relative-token"})
        self.assertNotEqual(result.returncode, 0)
        caddy = {
            "public_host": "remote.example.com", "device_ca_file": "/state/device ca.pem", "tunnel_ca_file": "/state/tunnel ca.pem",
            "pairing_upstream": "127.0.0.1:5001", "frps_upstream": "127.0.0.1:5002", "status_upstream": "127.0.0.1:5003",
            "tunnel_issuer_dn": "CN=Tunnel", "device_issuer_dn": "CN=Device",
        }
        result, output, _ = self.render("caddy", caddy)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("{{", output.read_text(encoding="utf-8"))
        for invalid in (
            {**caddy, "device_ca_file": "relative.pem"},
            {**caddy, "status_upstream": "192.0.2.1:5003"},
            {**caddy, "device_issuer_dn": "CN={env.BAD}"},
        ):
            result, _, _ = self.render("caddy", invalid)
            self.assertNotEqual(result.returncode, 0)

    def test_frpc_requires_dns_host_and_absolute_runtime_paths(self):
        frpc = {
            "public_host": "remote.example.com",
            "tunnel_client_cert": "/state/client.pem", "tunnel_client_key": "/state/client-key.pem",
            "frps_token_file": "/state/frps-token", "frpc_log": "/state/frpc.log",
            "installation_id": INSTALLATION_ID, "node_port": 58627, "node_tunnel_port": 58628,
        }
        result, _, _ = self.render("frpc", frpc)
        self.assertEqual(result.returncode, 0, result.stderr)
        result, _, _ = self.render("frpc", {**frpc, "public_host": "https://remote.example.com"})
        self.assertNotEqual(result.returncode, 0)
        result, _, _ = self.render("frpc", {**frpc, "tunnel_client_key": "client-key.pem"})
        self.assertNotEqual(result.returncode, 0)

    def test_renderer_accepts_agent_values_on_standard_input(self):
        values = {"frps_port": 58630, "frps_token_file": "/state/frps-token", "frps_log": "/state/frps.log"}
        output = Path(tempfile.mkdtemp()) / "frps.toml"
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "frps", "--input", "-", "--output", str(output)],
            input=json.dumps(values), capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("bindPort = 58630", output.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
