#!/usr/bin/env python3

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
IMPORT = re.compile(r'"ingot:([a-zA-Z0-9_/]+)"')
RULES = {
    "fit": {"action", "gfx", "ui", "ui_gfx"},
    "ui": {"action"},
    "ui_gfx": {"gfx", "ui", "accesskit"},
}
TEST_ONLY = {"fuzz/fuzzx", "gfx", "testx"}


def imports(package: str) -> set[str]:
    result: set[str] = set()
    for source in (ROOT / package).glob("*.odin"):
        found = set(IMPORT.findall(source.read_text(encoding="utf-8")))
        if source.name.endswith("_test.odin"):
            found -= TEST_ONLY
        result.update(found)
    return result


def main() -> int:
    failures: list[str] = []
    for package, allowed in RULES.items():
        actual = imports(package)
        forbidden = sorted(actual - allowed)
        if forbidden:
            failures.append(f"{package} imports forbidden packages: {', '.join(forbidden)}")
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print("package boundaries: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
