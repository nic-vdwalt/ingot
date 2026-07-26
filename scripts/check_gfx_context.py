#!/usr/bin/env python3

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

import check_odin_style

EXCLUDED_SUFFIXES = ("_test.odin", "_fuzz_test.odin")
DIRECT_GLOBAL = re.compile(r"(?<![A-Za-z0-9_])g(?![A-Za-z0-9_])")


def tracked_sources(root: Path) -> list[str]:
    process = subprocess.run(
        ["git", "ls-files", "gfx/*.odin"],
        cwd=root,
        check=True,
        capture_output=True,
        text=True,
    )
    return [path for path in process.stdout.splitlines() if not path.endswith(EXCLUDED_SUFFIXES)]


def counts_for_source(source: str, path: str) -> dict[str, int]:
    masked = check_odin_style.mask_source(source)
    counts: dict[str, int] = {}
    for procedure in check_odin_style.procedures(source):
        lines = masked.splitlines(keepends=True)
        body = "".join(lines[procedure.start_line - 1:procedure.end_line])
        count = len(DIRECT_GLOBAL.findall(body))
        if count > 0:
            counts[f"{path}:{procedure.name}"] = count
    return counts


def current_counts(root: Path) -> dict[str, int]:
    counts: dict[str, int] = {}
    for relative in tracked_sources(root):
        source = (root / relative).read_text(encoding="utf-8")
        counts.update(counts_for_source(source, relative))
    return counts


def check_counts(current: dict[str, int], baseline: dict[str, int]) -> list[str]:
    failures: list[str] = []
    for key, count in sorted(current.items()):
        allowed = baseline.get(key, 0)
        if count > allowed:
            failures.append(f"{key}: direct gfx global references increased from {allowed} to {count}")
    for key in sorted(set(baseline) - set(current)):
        failures.append(f"{key}: stale baseline entry; remove it")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", default=".")
    parser.add_argument("--baseline")
    parser.add_argument("--measure", action="store_true")
    arguments = parser.parse_args()
    root = Path(arguments.root).resolve()
    current = current_counts(root)
    if arguments.measure:
        print(json.dumps(current, indent=2, sort_keys=True))
        return 0
    if not arguments.baseline:
        parser.error("--baseline is required unless --measure is used")
    baseline = json.loads(Path(arguments.baseline).read_text(encoding="utf-8"))
    failures = check_counts(current, baseline)
    for failure in failures:
        print(failure)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
