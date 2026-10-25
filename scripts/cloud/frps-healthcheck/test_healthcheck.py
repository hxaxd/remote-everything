"""Real installer and runner isolation; systemctl is replaced in a temp PATH."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


HERE = Path(__file__).resolve().parent


class InstallationIsolation(unittest.TestCase):
    def test_two_gateways_keep_units_locks_logs_and_failure_counts(self):
        with tempfile.TemporaryDirectory(prefix="frps-health-") as directory:
            root = Path(directory)
            fakebin = root / "tools"
            fakebin.mkdir()
            # Execute both healthy and failing paths without touching services,
            # real network endpoints, or waiting for the backoff sleeps.
            for name, body in {
                "systemctl": 'printf "%s\\n" "$*" >> "$CALLS"\n',
                "sleep": 'exit 0\n',
                "timeout": 'exit 0\n',
                "curl": '[ "$HEALTHY" = 1 ]\n',
            }.items():
                path = fakebin / name
                path.write_text("#!/bin/sh\n" + body)
                path.chmod(0o755)
            env = dict(os.environ, PATH=str(fakebin) + os.pathsep + os.environ["PATH"],
                       CALLS=str(root / "calls"), HEALTHY="0")
            ids = ["a" * 64, "b" * 64]
            scripts = []
            installs = []
            for index, identity in enumerate(ids):
                command = ["bash", str(HERE / "install.sh"), "--installation-id", identity,
                    "--frps-listen", f"127.0.0.1:{34000+index}", "--tunnel-listen", f"127.0.0.1:{35000+index}",
                    "--target-dir", str(root / "bin"), "--unit-dir", str(root / "units"),
                    "--data-dir", str(root / "data"), "--lock-dir", str(root / "locks"), "--no-enable"]
                installs.append(command)
                result = subprocess.run(command, text=True, capture_output=True, env=env, timeout=15)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                base = "remote-everything-" + identity + "-frps-healthcheck"
                scripts.append(root / "bin" / (base + ".sh"))
                service = root / "units" / (base + ".service")
                timer = root / "units" / (base + ".timer")
                self.assertIn("ExecStart=" + str(scripts[-1]), service.read_text())
                self.assertIn("Unit=" + base + ".service", timer.read_text())
                self.assertNotIn("{{", service.read_text() + timer.read_text() + scripts[-1].read_text())
            a, b = (root / "data" / identity for identity in ids)
            for folder, count in ((a, 3), (b, 7)):
                folder.mkdir(parents=True)
                (folder / "state.json").write_text(json.dumps({"consecutive_failures": count}, separators=(",", ":")))
            def run(index, healthy):
                result = subprocess.run(["bash", str(scripts[index])], env=dict(env, HEALTHY=str(healthy)), capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stderr)
            # A recovers without clearing B's outstanding failures.
            run(0, 1)
            self.assertEqual(json.loads((a / "state.json").read_text())["consecutive_failures"], 0)
            self.assertEqual(json.loads((b / "state.json").read_text())["consecutive_failures"], 7)
            self.assertFalse((b / "health.log").exists())
            # B's failure restarts only B. Its log and lock are independent of A.
            run(1, 0)
            self.assertEqual((root / "calls").read_text().strip(), "restart remote-everything-" + ids[1] + "-frps")
            self.assertNotIn("ACTING", (a / "health.log").read_text())
            self.assertIn("ACTING", (b / "health.log").read_text())
            self.assertEqual(len(list((root / "locks").iterdir())), 2)
            self.assertEqual(len(list((root / "units").iterdir())), 4)
            # Reinstalling A is idempotent and does not overwrite B's definitions.
            before = {path: path.read_bytes() for path in (root / "units").iterdir() if ids[1] in path.name}
            result = subprocess.run(installs[0], text=True, capture_output=True, env=env, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            # A held lock does not block B's check.
            lock = root / "locks" / ("remote-everything-" + ids[0] + "-frps-healthcheck.lock")
            with lock.open("w") as held:
                import fcntl
                fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
                run(1, 1)
            for path, content in before.items():
                self.assertEqual(path.read_bytes(), content)


if __name__ == "__main__":
    unittest.main()
