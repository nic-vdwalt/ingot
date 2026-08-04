#!/usr/bin/env python3

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("test-supervisor.py")


class TestSupervisorTest(unittest.TestCase):
    def run_supervisor(self, code, timeout="5", output_limit="1024"):
        with tempfile.TemporaryDirectory() as directory:
            return subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--package",
                    "fixture",
                    "--timeout",
                    timeout,
                    "--output-limit",
                    output_limit,
                    "--log-dir",
                    directory,
                    "--",
                    sys.executable,
                    "-c",
                    code,
                ],
                check=False,
                capture_output=True,
            )

    def test_success(self):
        result = self.run_supervisor("print('ok')")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"ok\n")

    def test_nonzero_exit(self):
        result = self.run_supervisor("raise SystemExit(7)")
        self.assertEqual(result.returncode, 7)
        self.assertIn(b"exited with status 7", result.stderr)

    def test_timeout(self):
        result = self.run_supervisor("import time; time.sleep(10)", timeout="0.1")
        self.assertEqual(result.returncode, 124)
        self.assertIn(b"timed out", result.stderr)

    def test_output_limit(self):
        result = self.run_supervisor("print('x' * 4096)", output_limit="128")
        self.assertEqual(result.returncode, 125)
        self.assertLessEqual(len(result.stdout), 128)
        self.assertIn(b"output exceeded", result.stderr)


if __name__ == "__main__":
    unittest.main()
