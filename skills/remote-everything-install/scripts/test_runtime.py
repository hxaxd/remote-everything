#!/usr/bin/env python3
import copy
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("runtime.py")
ASSETS = SCRIPT.parent.parent / "assets"
SPEC = importlib.util.spec_from_file_location("runtime_script", SCRIPT)
runtime = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runtime)


class RuntimeValidationTests(unittest.TestCase):
    def load(self, name):
        return json.loads((ASSETS / name).read_text(encoding="utf-8"))

    def test_examples_are_strictly_valid(self):
        runtime.validate(self.load("runtime.minimal.json"))
        runtime.validate(self.load("runtime.full.json"))

    def test_unknown_nested_fields_and_wrong_types_are_rejected(self):
        record = self.load("runtime.full.json")
        unknown = copy.deepcopy(record)
        unknown["components"][0]["obsolete"] = True
        with self.assertRaises(ValueError):
            runtime.validate(unknown)
        wrong = copy.deepcopy(record)
        wrong["dependencies"][0]["version"] = 2
        with self.assertRaises(ValueError):
            runtime.validate(wrong)
        naive = copy.deepcopy(record)
        naive["updated_at"] = "2026-01-01T00:00:00"
        with self.assertRaises(ValueError):
            runtime.validate(naive)

    def test_cli_rejects_trailing_json(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "runtime.json"
            path.write_text((ASSETS / "runtime.minimal.json").read_text(encoding="utf-8") + "{}", encoding="utf-8")
            with self.assertRaises(ValueError):
                runtime.validate(runtime.load_single(path))


if __name__ == "__main__":
    unittest.main()
