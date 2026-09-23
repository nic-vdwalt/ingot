#!/usr/bin/env python3
"""Keep the scripts consumer repositories call from ingot stable.

Consumers invoke these scripts from their own gates through a pinned ingot
checkout, so removing a flag or function here breaks them only when they next
bump the pin. scripts/consumer-contract.json lists what they rely on; this test
fails the ingot gate instead. Removing an entry is a breaking change that needs
a CHANGELOG note, see docs/consumer-gates.md.
"""

import json
import os
import re
import subprocess
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
CONTRACT = json.loads((SCRIPTS / "consumer-contract.json").read_text(encoding="utf-8"))
OPTION = re.compile(r"(?<![\w-])(--[a-z][a-z0-9-]*)")


def help_options(script: str) -> set[str]:
    result = subprocess.run(
        [sys.executable, str(SCRIPTS / script), "--help"],
        capture_output=True,
        check=False,
        text=True,
        env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
    )
    if result.returncode != 0:
        raise AssertionError(f"{script} --help exited {result.returncode}: {result.stderr}")
    return set(OPTION.findall(result.stdout))


def shell_functions(script: str) -> set[str]:
    source = (SCRIPTS / script).read_text(encoding="utf-8")
    return set(re.findall(r"^([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{", source, re.M))


class ConsumerContractTest(unittest.TestCase):
    def test_python_scripts_keep_their_flags(self):
        for script, flags in CONTRACT["python_flags"].items():
            with self.subTest(script=script):
                missing = set(flags) - help_options(script)
                self.assertFalse(missing, f"{script} dropped consumer flags: {sorted(missing)}")

    def test_shell_helpers_keep_their_functions(self):
        for script, functions in CONTRACT["shell_functions"].items():
            with self.subTest(script=script):
                missing = set(functions) - shell_functions(script)
                self.assertFalse(missing, f"{script} dropped consumer functions: {sorted(missing)}")

    def test_shell_scripts_exist(self):
        for script in CONTRACT["shell_scripts"]:
            with self.subTest(script=script):
                self.assertTrue((SCRIPTS / script).is_file(), f"{script} is missing")

    def test_option_pattern_ignores_prose(self):
        self.assertEqual(OPTION.findall("usage: x [--baseline B] a-b --x-y"), ["--baseline", "--x-y"])


if __name__ == "__main__":
    unittest.main()
