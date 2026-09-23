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
CONTROLLED_GLOBAL_ROUTING = {
    "gfx/context.odin:default_context": 1,
    "gfx/context.odin:set_default_context": 2,
}
CONTROL_FLOW = re.compile(r"\b(?:if|when|for|switch|defer)\b")
DEFAULT_CONTEXT_CALL = re.compile(
    r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\((?:[^;{}()]|\([^;{}()]*\))*default_context\s*\("
)
CONTEXT_ESCAPE = re.compile(
    r"(?<![A-Za-z0-9_.])(?:active_context|default_context|context_scope_enter)\s*\("
)
# PascalCase in ingot:gfx is reserved for the raylib migration facade: an
# exported PascalCase procedure must carry a name that vendor:raylib declares.
# Ingot-native capabilities use snake_case (`context_*`, `frame_*`, or a plain
# default-owner wrapper). The raylib vocabulary is read from the pinned
# toolchain, never from a hand-kept list, so a missing vendor file is an error.
RAYLIB_DECLARATION = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*::", re.M)
RAYLIB_SOURCES = (("raylib.odin", ""), ("raymath.odin", ""), ("rlgl/rlgl.odin", "Rl"))
PASCAL_CASE_EXCLUDED_PREFIXES = ("gfx/rlgl/",)


def odin_root() -> Path:
    process = subprocess.run(["odin", "root"], check=True, capture_output=True, text=True)
    return Path(process.stdout.strip())


def raylib_names(vendor_root: Path) -> frozenset[str]:
    names: set[str] = set()
    for relative, prefix in RAYLIB_SOURCES:
        path = vendor_root / relative
        if not path.is_file():
            raise FileNotFoundError(f"raylib vocabulary source missing: {path}")
        names.update(prefix + name for name in RAYLIB_DECLARATION.findall(path.read_text()))
    return frozenset(names)


def _declaration_attributes(lines: list[str], declaration_index: int) -> list[str]:
    attributes: list[str] = []
    index = declaration_index - 1
    while index >= 0:
        stripped = lines[index].strip()
        if stripped.startswith("@("):
            attributes.append(stripped)
        elif not stripped.startswith("//"):
            break
        index -= 1
    return attributes


def pascal_case_violations(source: str, path: str, allowed: frozenset[str]) -> list[str]:
    lines = source.splitlines()
    if any(line.startswith("#+private") for line in lines[:8]):
        return []
    masked_lines = check_odin_style.mask_source(source).splitlines()
    failures: list[str] = []
    for procedure in check_odin_style.procedures(source):
        if not procedure.name[:1].isupper() or procedure.name in allowed:
            continue
        declaration = re.compile(rf"^\s*{re.escape(procedure.name)}\s*::")
        index = next(
            (
                line
                for line in range(procedure.start_line - 1, procedure.end_line)
                if declaration.match(lines[line])
            ),
            procedure.start_line - 1,
        )
        # A procedure type (`Run_Proc :: proc()`) has no body; the shared parser
        # runs on to the next declaration's brace, so reject any span that
        # crosses another top-level declaration before its opening brace.
        signature = "\n".join(masked_lines[index:procedure.end_line])
        signature = signature[: signature.find("{") if "{" in signature else len(signature)]
        if RAYLIB_DECLARATION.search(signature.split("\n", 1)[1] if "\n" in signature else ""):
            continue
        attributes = _declaration_attributes(lines, index)
        if any("private" in attribute or "deprecated" in attribute for attribute in attributes):
            continue
        failures.append(
            f"{path}:{index + 1}: {procedure.name}: Ingot-only PascalCase API; "
            "use snake_case (context_*, frame_*, or a default-owner wrapper)"
        )
    return failures


def pascal_case_layer_failures(root: Path, allowed: frozenset[str]) -> list[str]:
    failures: list[str] = []
    for relative in tracked_sources(root, ["gfx/*.odin"]):
        if relative.startswith(PASCAL_CASE_EXCLUDED_PREFIXES):
            continue
        source = (root / relative).read_text(encoding="utf-8")
        failures.extend(pascal_case_violations(source, relative, allowed))
    return failures


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


def controlled_global_debt(counts: dict[str, int]) -> dict[str, int]:
    debt = counts.copy()
    for key, expected_count in CONTROLLED_GLOBAL_ROUTING.items():
        if debt.get(key) == expected_count:
            del debt[key]
    return debt


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", default=".")
    parser.add_argument("--measure", action="store_true")
    parser.add_argument(
        "--raylib-vendor",
        type=Path,
        help="vendor/raylib directory; defaults to $(odin root)/vendor/raylib",
    )
    arguments = parser.parse_args()
    root = Path(arguments.root).resolve()
    vendor_root = arguments.raylib_vendor or odin_root() / "vendor" / "raylib"
    pascal_case_failures = pascal_case_layer_failures(root, raylib_names(vendor_root))
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
    failures = zero_debt_failures(
        "direct gfx global routing",
        controlled_global_debt(globals_debt),
    )
    failures += zero_debt_failures("active-context API", active_context_debt)
    failures += zero_debt_failures("internal default-context escape", default_context_escapes)
    failures += zero_debt_failures("ui_gfx implicit graphics routing", implicit_draws)
    failures += pascal_case_failures
    for failure in failures:
        print(failure)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
