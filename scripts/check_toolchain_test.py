#!/usr/bin/env python3

import importlib.util
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("check-toolchain.py")
SPEC = importlib.util.spec_from_file_location("check_toolchain", MODULE_PATH)
assert SPEC is not None
assert SPEC.loader is not None
check_toolchain = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check_toolchain)


class PinTests(unittest.TestCase):
    def test_read_pin_accepts_revision_and_trailing_newline(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ODIN_VERSION"
            path.write_text("dev-2026-06:285f6d87b\n", encoding="utf-8")
            self.assertEqual(check_toolchain.read_pin(path), "dev-2026-06:285f6d87b")

    def test_read_pin_rejects_invalid_value(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ODIN_VERSION"
            path.write_text("latest\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                check_toolchain.read_pin(path)

    def test_version_matches_exact_revision_token(self) -> None:
        expected = "dev-2026-06:285f6d87b"
        self.assertTrue(check_toolchain.version_matches(f"odin version {expected}\n", expected))
        self.assertFalse(check_toolchain.version_matches(f"odin version {expected}0\n", expected))
        self.assertFalse(check_toolchain.version_matches("odin version dev-2026-07:12345678\n", expected))


if __name__ == "__main__":
    unittest.main()
