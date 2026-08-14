#!/usr/bin/env python3

import argparse
import json
import re
import sys
from pathlib import Path

TEST_PROC = re.compile(r"@\(\s*test\s*\)\s+([A-Za-z_][A-Za-z0-9_]*)\s*::\s*proc\b")
EXPECT_ASSERT = re.compile(r"\btesting\.expect_assert_message\s*\(")


def expected_assert_tests(root: Path) -> set[str]:
    found: set[str] = set()
    for path in sorted((root / "gfx").glob("*test*.odin")):
        source = path.read_text(encoding="utf-8")
        declarations = list(TEST_PROC.finditer(source))
        for index, declaration in enumerate(declarations):
            end = declarations[index + 1].start() if index + 1 < len(declarations) else len(source)
            if EXPECT_ASSERT.search(source, declaration.end(), end):
                found.add(f"gfx.{declaration.group(1)}")
    return found


def check_registered(found: set[str], registered: list[str]) -> list[str]:
    failures: list[str] = []
    registered_set = set(registered)
    for name in sorted(found - registered_set):
        failures.append(f"{name}: expected-assert test is not registered for Windows isolation")
    for name in sorted(registered_set - found):
        failures.append(f"{name}: stale Windows expected-assert registration")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", default=".")
    arguments = parser.parse_args()
    root = Path(arguments.root).resolve()
    manifest = json.loads((root / "scripts/gate-manifest.json").read_text(encoding="utf-8"))
    failures = check_registered(
        expected_assert_tests(root), manifest["windows_gfx_expected_assert_tests"]
    )
    for failure in failures:
        print(failure, file=sys.stderr)
    return int(bool(failures))


if __name__ == "__main__":
    sys.exit(main())
