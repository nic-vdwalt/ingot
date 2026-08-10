#!/usr/bin/env python3

import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = json.loads((ROOT / "scripts/gate-manifest.json").read_text(encoding="utf-8"))
MAX_GATE_RECORDS = 64


class GateManifestTest(unittest.TestCase):
    def test_manifest_is_bounded_and_unique(self):
        for key, records in MANIFEST.items():
            self.assertLessEqual(len(records), MAX_GATE_RECORDS, key)
            normalized = [tuple(record) if isinstance(record, list) else record for record in records]
            self.assertEqual(len(normalized), len(set(normalized)), key)

    def test_packages_and_examples_exist(self):
        keys = ["test_packages", "check_packages", "binding_packages", "compile_packages"]
        for key in keys:
            for package in MANIFEST[key]:
                self.assertTrue((ROOT / package).is_dir(), package)
        for example in MANIFEST["examples"]:
            self.assertTrue((ROOT / "examples" / example).is_dir(), example)

    def test_test_packages_receive_a_compile_gate(self):
        checked = set(MANIFEST["check_packages"])
        bindings = set(MANIFEST["binding_packages"])
        for package in MANIFEST["test_packages"]:
            self.assertIn(package, checked | bindings, package)

    def test_launchers_consume_shared_manifest(self):
        shell = (ROOT / "scripts/check.sh").read_text(encoding="utf-8")
        powershell = (ROOT / "scripts/check.ps1").read_text(encoding="utf-8")
        self.assertIn("gate-manifest.json", shell)
        self.assertIn("gate-manifest.json", powershell)


if __name__ == "__main__":
    unittest.main()
