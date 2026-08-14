#!/usr/bin/env python3

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

import check_odin_style

EXCLUDED_SUFFIXES = ("_test.odin", "_tests.odin", "_fuzz_test.odin")
DIRECT_GLOBAL = re.compile(r"(?<![A-Za-z0-9_.])g(?![A-Za-z0-9_])")
DEFAULT_CONTEXT = re.compile(r"(?<![A-Za-z0-9_.])default_context\s*\(")
ACTIVE_CONTEXT = re.compile(
    r"\b(?:active_context|_context_activate|_context_restore|Context_Scope|"
    r"context_scope_enter|context_scope_leave)\b"
)
UI_GFX_IMPLICIT_DRAW = re.compile(
    r"\b(?:BeginDrawing|EndDrawing|BeginScissorMode|EndScissorMode|Draw[A-Z][A-Za-z0-9_]*|"
    r"context_scope_enter|context_scope_leave)\s*\("
)
CONTROL_FLOW = re.compile(r"\b(?:if|when|for|switch|defer)\b")
DEFAULT_CONTEXT_CALL = re.compile(
    r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\((?:[^;{}()]|\([^;{}()]*\))*default_context\s*\("
)
CONTEXT_ESCAPE = re.compile(
    r"(?<![A-Za-z0-9_.])(?:active_context|default_context|context_scope_enter)\s*\("
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


def procedure_body(source: str, procedure: check_odin_style.Procedure) -> str:
    lines = check_odin_style.mask_source(source).splitlines(keepends=True)
    return "".join(lines[procedure.start_line - 1:procedure.end_line])


def counts_for_source(source: str, path: str, pattern=DIRECT_GLOBAL) -> dict[str, int]:
    counts: dict[str, int] = {}
    for procedure in check_odin_style.procedures(source):
        count = len(pattern.findall(procedure_body(source, procedure)))
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


def compatibility_facade(procedure: check_odin_style.Procedure, body: str) -> bool:
    if procedure.name.startswith(("_", "context_", "frame_", "adapter_")):
        return False
    if len(DEFAULT_CONTEXT.findall(body)) != 1 or CONTROL_FLOW.search(body):
        return False
    call = DEFAULT_CONTEXT_CALL.search(body)
    if call is None:
        return False
    callee = call.group(1)
    if procedure.name[0].isupper():
        return callee.startswith(("context_", "Context", "_"))
    return callee.endswith(procedure.name)


def default_context_debt_for_source(source: str, path: str) -> dict[str, int]:
    debt: dict[str, int] = {}
    for procedure in check_odin_style.procedures(source):
        body = procedure_body(source, procedure)
        count = len(DEFAULT_CONTEXT.findall(body))
        if count > 0 and not compatibility_facade(procedure, body):
            debt[f"{path}:{procedure.name}"] = count
    return debt


def default_context_debt(root: Path) -> dict[str, int]:
    debt: dict[str, int] = {}
    for relative in tracked_sources(root, ["gfx/*.odin", "ui_gfx/*.odin"]):
        source = (root / relative).read_text(encoding="utf-8")
        debt.update(default_context_debt_for_source(source, relative))
    return debt


def zero_debt_failures(category: str, counts: dict[str, int]) -> list[str]:
    return [f"{key}: {category} is forbidden ({count} references)" for key, count in sorted(counts.items())]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", default=".")
    parser.add_argument("--measure", action="store_true")
    arguments = parser.parse_args()
    root = Path(arguments.root).resolve()
    globals_debt = current_counts(root)
    active_context_debt = current_counts(
        root,
        ["gfx/*.odin", "ui_gfx/*.odin"],
        ACTIVE_CONTEXT,
    )
    default_context_escapes = default_context_debt(root)
    implicit_draws = current_counts(root, ["ui_gfx/*.odin"], UI_GFX_IMPLICIT_DRAW)
    inventory = {
        "active_context_apis": active_context_debt,
        "default_context_escapes": default_context_escapes,
        "globals": globals_debt,
        "ui_gfx_implicit_draws": implicit_draws,
    }
    if arguments.measure:
        print(json.dumps(inventory, indent=2, sort_keys=True))
        return 0
    failures = zero_debt_failures("direct gfx global routing", globals_debt)
    failures += zero_debt_failures("active-context API", active_context_debt)
    failures += zero_debt_failures("internal default-context escape", default_context_escapes)
    failures += zero_debt_failures("ui_gfx implicit graphics routing", implicit_draws)
    for failure in failures:
        print(failure)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
