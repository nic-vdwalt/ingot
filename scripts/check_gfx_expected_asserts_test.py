#!/usr/bin/env python3

import tempfile
import unittest
from pathlib import Path

import check_gfx_expected_asserts


class GfxExpectedAssertsTest(unittest.TestCase):
    def test_discovers_expected_assert_test(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "gfx").mkdir()
            (root / "gfx/example_test.odin").write_text(
                '''package gfx

@(test)
rejects_bad_input :: proc(t: ^testing.T) {
\ttesting.expect_assert_message(t, "bad input")
\tassert(false, "bad input")
}
''',
                encoding="utf-8",
            )
            self.assertEqual(
                check_gfx_expected_asserts.expected_assert_tests(root),
                {"gfx.rejects_bad_input"},
            )

    def test_missing_and_stale_registrations_fail(self):
        failures = check_gfx_expected_asserts.check_registered(
            {"gfx.current"}, ["gfx.stale"]
        )
        self.assertEqual(len(failures), 2)
        self.assertIn("not registered", failures[0])
        self.assertIn("stale", failures[1])

    def test_conditional_non_gfx_body_discovery(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "fit").mkdir()
            (root / "fit/example_test.odin").write_text('''package fit
when FLAG {
    @(test)
    rejects :: proc(t: ^testing.T) {
        testing.expect_assert_message(t, "}")
    }
}
@(test)
ordinary :: proc(t: ^testing.T) {
    // testing.expect_assert_message(t, "not code")
    text := "testing.expect_assert_message("
    /* nested /* testing.expect_assert_message( */ comment */
}
helper :: proc(t: ^testing.T) { testing.expect_assert_message(t, "helper") }
''', encoding="utf-8")
            self.assertEqual(
                check_gfx_expected_asserts.expected_assert_tests(root, "fit"),
                {"fit.rejects"},
            )

    def manifest(self):
        return {
            "test_packages": ["gfx", "ui", "fit"],
            "windows_expected_assert_suites": [
                {"package": package, "define": f"INGOT_{package.upper()}_EXPECTED_ASSERTS",
                 "tests": [f"{package}.rejects"]}
                for package in ("gfx", "ui", "fit")
            ],
        }

    def test_schema_rejects_missing_duplicate_and_invalid_suites(self):
        for mutation in ("missing", "duplicate", "test", "define", "package", "empty"):
            manifest = self.manifest()
            suites = manifest["windows_expected_assert_suites"]
            if mutation == "missing":
                suites.pop()
            elif mutation == "duplicate":
                suites.append(suites[0])
            elif mutation == "test":
                suites[0]["tests"] *= 2
            elif mutation == "define":
                suites[0]["define"] = "unsafe"
            elif mutation == "package":
                suites[0]["package"] = "../gfx"
            else:
                suites[0]["tests"] = []
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                check_gfx_expected_asserts.validate_suites(manifest)

    def test_multi_suite_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            failures = check_gfx_expected_asserts.check_manifest(Path(directory), self.manifest())
            self.assertEqual(len(failures), 3)
            for package in ("gfx", "ui", "fit"):
                self.assertTrue(any(f"{package}.rejects" in failure for failure in failures))

    def test_duplicate_registration_fails(self):
        self.assertTrue(check_gfx_expected_asserts.check_registered(
            {"gfx.rejects"}, ["gfx.rejects", "gfx.rejects"]
        ))

    def test_exact_registration_passes(self):
        self.assertEqual(
            check_gfx_expected_asserts.check_registered(
                {"gfx.first", "gfx.second"}, ["gfx.second", "gfx.first"]
            ),
            [],
        )


if __name__ == "__main__":
    unittest.main()
