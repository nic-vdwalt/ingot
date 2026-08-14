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

    def test_exact_registration_passes(self):
        self.assertEqual(
            check_gfx_expected_asserts.check_registered(
                {"gfx.first", "gfx.second"}, ["gfx.second", "gfx.first"]
            ),
            [],
        )


if __name__ == "__main__":
    unittest.main()
