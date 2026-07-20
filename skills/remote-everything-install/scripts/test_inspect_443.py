#!/usr/bin/env python3
import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("inspect_443.py")
SPEC = importlib.util.spec_from_file_location("inspect_443", SCRIPT)
inspect_443 = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(inspect_443)


class Inspect443Tests(unittest.TestCase):
    def test_parses_every_listener_pid_without_name_guessing(self):
        sockets = 'LISTEN 0 4096 *:443 *:* users:(("nginx",pid=120,fd=7),("nginx",pid=121,fd=7))\n'
        self.assertEqual(inspect_443.parse_processes(sockets), [("nginx", 120), ("nginx", 121)])

    def test_reads_exact_systemd_unit_from_cgroup(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "42"
            path.mkdir()
            (path / "cgroup").write_text("0::/system.slice/caddy.service\n", encoding="utf-8")
            self.assertEqual(inspect_443.process_unit(42, directory), "caddy.service")
            (path / "cgroup").write_text("0::/user.slice/session-1.scope\n", encoding="utf-8")
            self.assertEqual(inspect_443.process_unit(42, directory), "")


if __name__ == "__main__":
    unittest.main()
