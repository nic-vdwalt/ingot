#!/usr/bin/env python3
import copy
import importlib.util
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "check_widget_capabilities", ROOT / "scripts" / "check_widget_capabilities.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class WidgetCapabilitiesTest(unittest.TestCase):
    def setUp(self):
        self.data = json.loads(MODULE.MANIFEST.read_text(encoding="utf-8"))

    def test_repository_inventory_is_valid(self):
        self.assertEqual(MODULE.validate(self.data), [])

    def test_duplicate_and_stale_evidence_fail(self):
        broken = copy.deepcopy(self.data)
        broken["capabilities"].append(copy.deepcopy(broken["capabilities"][0]))
        broken["capabilities"][0]["tests"] = ["ui/not-a-test.odin"]
        errors = MODULE.validate(broken)
        self.assertIn("duplicate widget capability name", errors)
        self.assertTrue(any("missing test evidence" in error for error in errors))

    def test_hidden_state_ownership_fails(self):
        broken = copy.deepcopy(self.data)
        broken["capabilities"][0]["state_owner"] = "framework"
        self.assertTrue(any("caller-owned" in error for error in MODULE.validate(broken)))


if __name__ == "__main__":
    unittest.main()
