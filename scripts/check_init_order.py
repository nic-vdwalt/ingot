#!/usr/bin/env python3
"""Keep `_default_context_init` the only `@(init)` procedure in `gfx`.

`gfx.default_context_storage` is roughly 11 MB and is deliberately left without
a static initialiser, because a single initialised field moves the whole struct
from `.bss` to `.data` and the wasm target then emits 11 MB of zeros into every
module (see `scripts/check_wasm_bloat.py`). Its reserved id is assigned by an
`@(init)` procedure instead.

That trade depends on the id being in place before anything reads it, and the
ordering between `@(init)` procedures is not specified by the language. It is
Odin's `init_procedures_cmp`: package import order, then filename, then source
offset.

Across packages that ordering is safe by construction. Import cycles are a
compile error, so the import graph is a DAG and an imported package always
sorts before its importer - anything reaching `gfx` runs after
`_default_context_init`.

Within `gfx` it is not. The tiebreak is the *filename*, and `context.odin` does
not sort first: roughly half the package precedes it (`api.odin`, `audio.odin`,
`batch.odin`, `camera.odin`, `colors.odin`, ...). A second `@(init)` in any of
those files would run first and read an unassigned id - and a zero id means
"unassigned" throughout the resource handle code, so the failure is aliased
handles rather than a crash.

There is no baseline file. The allowed set is exactly one known declaration, so
it is encoded here.

Usage:
    check_init_order.py [ROOT]
"""

import argparse
import dataclasses
import re
import subprocess
import sys
from pathlib import Path

import check_odin_style

PACKAGE = "gfx/"
# Test sources are scanned too: an @(init) in api_tests.odin would break the
# invariant in the test build exactly as one in api.odin breaks the real build.
ALLOWED_PATH = "gfx/context.odin"
ALLOWED_NAME = "_default_context_init"

# `@(init)` or `@(init, private)` / `@(private, init)`, as an attribute element
# rather than a bare word, so prose mentioning the attribute does not match.
INIT_ATTRIBUTE = re.compile(r"@\(\s*(?:[A-Za-z_][A-Za-z0-9_]*\s*,\s*)*init\b")
DECLARATION = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)\s*::\s*proc\b")


@dataclasses.dataclass(frozen=True)
class Init_Procedure:
    path: str
    name: str
    line: int

    @property
    def key(self) -> str:
        return f"{self.path}:{self.name}"


def tracked_sources(root: Path) -> list[str]:
    process = subprocess.run(
        ["git", "ls-files", f"{PACKAGE}*.odin"],
        cwd=root,
        check=True,
        capture_output=True,
        text=True,
    )
    return process.stdout.splitlines()


def init_procedures_for_source(source: str, path: str) -> list[Init_Procedure]:
    """Every `@(init)` procedure declared in one file.

    Comments and string literals are masked first: `context.odin` and
    `resource_state_test.odin` both discuss `@(init)` at length in prose, and
    matching that text would make the guard fire on its own documentation.
    """
    masked = check_odin_style.mask_source(source)
    found: list[Init_Procedure] = []
    for attribute in INIT_ATTRIBUTE.finditer(masked):
        declaration = DECLARATION.search(masked, attribute.end())
        if not declaration:
            continue
        found.append(
            Init_Procedure(
                path,
                declaration.group(1),
                check_odin_style.line_number(masked, attribute.start()),
            )
        )
    return found


def check_procedures(found: list[Init_Procedure]) -> list[str]:
    failures: list[str] = []
    allowed = [
        procedure
        for procedure in found
        if procedure.path == ALLOWED_PATH and procedure.name == ALLOWED_NAME
    ]
    for procedure in sorted(found, key=lambda item: (item.path, item.line)):
        if procedure in allowed:
            continue
        failures.append(
            f"{procedure.path}:{procedure.line}: unexpected @(init) procedure "
            f"{procedure.name}"
        )
    if not allowed:
        failures.append(
            f"{ALLOWED_PATH}: {ALLOWED_NAME} is missing; "
            "the default context id would never be assigned"
        )
    if len(allowed) > 1:
        failures.append(
            f"{ALLOWED_PATH}: {ALLOWED_NAME} is declared {len(allowed)} times"
        )
    return failures


def current_procedures(root: Path) -> list[Init_Procedure]:
    found: list[Init_Procedure] = []
    for relative in tracked_sources(root):
        source = (root / relative).read_text(encoding="utf-8")
        found.extend(init_procedures_for_source(source, relative))
    return found


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", default=".")
    parser.add_argument(
        "--report", action="store_true", help="list every @(init) found in gfx"
    )
    arguments = parser.parse_args()
    root = Path(arguments.root).resolve()
    found = current_procedures(root)

    if arguments.report:
        for procedure in sorted(found, key=lambda item: (item.path, item.line)):
            print(f"{procedure.path}:{procedure.line}: {procedure.name}")
        return 0

    failures = check_procedures(found)
    for failure in failures:
        print(failure, file=sys.stderr)
    if failures:
        print(
            "\n@(init) order within a package is filename order, and\n"
            "gfx/context.odin does not sort first - roughly half of gfx\n"
            "precedes it. A second @(init) in an earlier-named file runs\n"
            "before _default_context_init and reads an unassigned context id,\n"
            "which aliases resource handles rather than failing loudly.\n"
            "\n"
            "Call the initialisation from _default_context_init instead of\n"
            "adding another @(init) to the package.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
