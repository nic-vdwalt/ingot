#!/usr/bin/env python3

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("test-supervisor.py")

# Dies with SIGSEGV on the first run and prints ok on the second, keyed on a
# marker file inside the supervisor's log directory.
CRASH_ONCE = """
import os, signal, sys
marker = os.path.join(sys.argv[1], "crashed")
if os.path.exists(marker):
    print("ok")
else:
    open(marker, "w").close()
    os.kill(os.getpid(), signal.SIGSEGV)
"""


class TestSupervisorTest(unittest.TestCase):
    def run_supervisor(self, code, timeout="5", output_limit="1024", extra_args=(), code_args=()):
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
                    *extra_args,
                    "--",
                    sys.executable,
                    "-c",
                    code,
                    *[arg.replace("{log_dir}", directory) for arg in code_args],
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

    @unittest.skipIf(os.name == "nt", "signal exit codes are POSIX only")
    def test_retry_signal_exit(self):
        result = self.run_supervisor(
            CRASH_ONCE, extra_args=("--retry-signal-exit",), code_args=("{log_dir}",)
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.endswith(b"ok\n"), result.stdout)
        self.assertIn(b"died with signal 11", result.stderr)
        self.assertIn(b"retrying once", result.stderr)

    @unittest.skipIf(os.name == "nt", "signal exit codes are POSIX only")
    def test_signal_exit_without_flag(self):
        result = self.run_supervisor(CRASH_ONCE, code_args=("{log_dir}",))
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(b"retrying once", result.stderr)
        self.assertNotIn(b"ok", result.stdout)

    def test_retry_does_not_cover_nonzero_exit(self):
        result = self.run_supervisor("raise SystemExit(7)", extra_args=("--retry-signal-exit",))
        self.assertEqual(result.returncode, 7)
        self.assertNotIn(b"retrying once", result.stderr)


if __name__ == "__main__":
    unittest.main()
