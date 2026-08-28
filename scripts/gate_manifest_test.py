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
        for example in MANIFEST["examples"] + MANIFEST["test_examples"]:
            self.assertTrue((ROOT / "examples" / example).is_dir(), example)
        for package in MANIFEST["hot_reload_packages"]:
            self.assertTrue((ROOT / "examples" / "hot_reload" / package).is_dir(), package)

    def test_test_packages_receive_a_compile_gate(self):
        checked = set(MANIFEST["check_packages"])
        bindings = set(MANIFEST["binding_packages"])
        for package in MANIFEST["test_packages"]:
            self.assertIn(package, checked | bindings, package)

    def test_windows_expected_assert_tests_are_fully_qualified(self):
        expected_assert_suites = {
            "windows_gfx_expected_assert_tests": "gfx",
            "windows_ui_expected_assert_tests": "ui",
        }
        for key, package in expected_assert_suites.items():
            for test_name in MANIFEST[key]:
                self.assertRegex(test_name, rf"^{package}\.[a-z][a-z0-9_]*$")

    def test_launchers_consume_shared_manifest(self):
        launchers = ["check.sh", "check.ps1", "test.sh", "test.ps1"]
        for launcher in launchers:
            source = (ROOT / "scripts" / launcher).read_text(encoding="utf-8")
            self.assertIn("gate-manifest.json", source, launcher)


if __name__ == "__main__":
    unittest.main()
