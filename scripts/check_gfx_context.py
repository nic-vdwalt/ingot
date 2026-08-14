#!/usr/bin/env python3

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

import check_odin_style

EXCLUDED_SUFFIXES = ("_test.odin", "_tests.odin", "_fuzz_test.odin")
DIRECT_GLOBAL = re.compile(r"(?<![A-Za-z0-9_])g(?![A-Za-z0-9_])")
CONTEXT_ESCAPE = re.compile(r"\b(?:active_context|default_context|context_scope_enter)\s*\(")
UI_GFX_IMPLICIT_DRAW = re.compile(
    r"\b(?:BeginDrawing|EndDrawing|BeginScissorMode|EndScissorMode|Draw[A-Z][A-Za-z0-9_]*|"
    r"context_scope_enter|context_scope_leave)\s*\("
)


def tracked_sources(root: Path, patterns: list[str]) -> list[str]:
    process = subprocess.run(
        ["git", "ls-files", *patterns],
        cwd=root,
        check=True,
        capture_output=True,
        text=True,
    )
    return [path for path in process.stdout.splitlines() if not path.endswith(EXCLUDED_SUFFIXES)]


def counts_for_source(source: str, path: str, pattern=DIRECT_GLOBAL) -> dict[str, int]:
    masked = check_odin_style.mask_source(source)
    counts: dict[str, int] = {}
    lines = masked.splitlines(keepends=True)
    for procedure in check_odin_style.procedures(source):
        body = "".join(lines[procedure.start_line - 1:procedure.end_line])
        count = len(pattern.findall(body))
        if count > 0:
            counts[f"{path}:{procedure.name}"] = count
    return counts


def current_counts(root: Path, patterns=None, debt_pattern=DIRECT_GLOBAL) -> dict[str, int]:
    if patterns is None:
        patterns = ["gfx/*.odin"]
    counts: dict[str, int] = {}
    for relative in tracked_sources(root, patterns):
        source = (root / relative).read_text(encoding="utf-8")
        counts.update(counts_for_source(source, relative, debt_pattern))
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
    parser.add_argument("--escape-baseline")
    parser.add_argument("--measure", action="store_true")
    arguments = parser.parse_args()
    root = Path(arguments.root).resolve()
    current = current_counts(root)
    escapes = current_counts(root, ["gfx/*.odin", "ui_gfx/*.odin"], CONTEXT_ESCAPE)
    implicit_draws = current_counts(root, ["ui_gfx/*.odin"], UI_GFX_IMPLICIT_DRAW)
    if arguments.measure:
        print(
            json.dumps(
                {"globals": current, "escapes": escapes, "ui_gfx_implicit_draws": implicit_draws},
                indent=2,
                sort_keys=True,
            )
        )
        return 0
    if not arguments.baseline:
        parser.error("--baseline is required unless --measure is used")
    baseline_path = Path(arguments.baseline)
    escape_path = (
        Path(arguments.escape_baseline)
        if arguments.escape_baseline
        else baseline_path.with_name("gfx_context_escape_baseline.json")
    )
    baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
    escape_baseline = json.loads(escape_path.read_text(encoding="utf-8"))
    failures = check_counts(current, baseline)
    failures += check_counts(escapes, escape_baseline)
    for key, count in sorted(implicit_draws.items()):
        failures.append(f"{key}: ui_gfx implicit graphics routing is forbidden ({count} references)")
    for failure in failures:
        print(failure)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
