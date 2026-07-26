#!/usr/bin/env python3
"""Enforce ingot's physical Odin line and procedure limits."""

import argparse
import dataclasses
import json
import subprocess
import sys
from pathlib import Path

LINE_LIMIT = 100
PROCEDURE_LIMIT = 100
EXCLUDED_PREFIXES = (
    "accesskit/",
    "libvterm/",
    "gfx/rlgl",
    "gfx/platform_web.odin",
    "net/http_web.odin",
    "pty/pty_windows.odin",
    "ui/spell_windows.odin",
    "ui/window_style_windows.odin",
)


@dataclasses.dataclass(frozen=True)
class Procedure:
    name: str
    start_line: int
    end_line: int

    @property
    def lines(self) -> int:
        return self.end_line - self.start_line + 1


@dataclasses.dataclass(frozen=True)
class Violation:
    line: int
    message: str


def mask_source(source: str) -> str:
    output = list(source)
    index = 0
    block_depth = 0
    quote = ""
    raw = False
    while index < len(source):
        char = source[index]
        next_char = source[index + 1] if index + 1 < len(source) else ""
        if block_depth:
            if char == "/" and next_char == "*":
                output[index] = output[index + 1] = " "
                block_depth += 1
                index += 2
            elif char == "*" and next_char == "/":
                output[index] = output[index + 1] = " "
                block_depth -= 1
                index += 2
            else:
                if char != "\n":
                    output[index] = " "
                index += 1
            continue
        if quote:
            if char != "\n":
                output[index] = " "
            if raw:
                if char == quote:
                    quote = ""
                    raw = False
            elif char == "\\" and index + 1 < len(source):
                if source[index + 1] != "\n":
                    output[index + 1] = " "
                index += 2
                continue
            elif char == quote:
                quote = ""
            index += 1
            continue
        if char == "/" and next_char == "/":
            while index < len(source) and source[index] != "\n":
                output[index] = " "
                index += 1
            continue
        if char == "/" and next_char == "*":
            output[index] = output[index + 1] = " "
            block_depth = 1
            index += 2
            continue
        if char in ('"', "'"):
            output[index] = " "
            quote = char
            index += 1
            continue
        if char == "`":
            output[index] = " "
            quote = char
            raw = True
            index += 1
            continue
        index += 1
    return "".join(output)


def line_number(source: str, offset: int) -> int:
    return source.count("\n", 0, offset) + 1


def procedures(source: str) -> list[Procedure]:
    masked = mask_source(source)
    result: list[Procedure] = []
    cursor = 0
    marker = ":: proc"
    while True:
        marker_index = masked.find(marker, cursor)
        if marker_index < 0:
            break
        name_end = marker_index
        while name_end > 0 and masked[name_end - 1].isspace():
            name_end -= 1
        name_start = name_end - 1
        while name_start >= 0 and (masked[name_start].isalnum() or masked[name_start] == "_"):
            name_start -= 1
        name = masked[name_start + 1:name_end]
        if not name:
            cursor = marker_index + len(marker)
            continue
        scan = marker_index + len(marker)
        parens = brackets = 0
        body_start = -1
        while scan < len(masked):
            char = masked[scan]
            if char == "(":
                parens += 1
            elif char == ")":
                parens = max(0, parens - 1)
            elif char == "[":
                brackets += 1
            elif char == "]":
                brackets = max(0, brackets - 1)
            elif char == "{" and parens == 0 and brackets == 0:
                body_start = scan
                break
            elif parens == 0 and brackets == 0:
                if masked.startswith("---", scan) or char == ";":
                    break
            scan += 1
        if body_start < 0:
            cursor = marker_index + len(marker)
            continue
        depth = 1
        scan = body_start + 1
        while scan < len(masked) and depth:
            if masked[scan] == "{":
                depth += 1
            elif masked[scan] == "}":
                depth -= 1
            scan += 1
        if depth == 0:
            declaration_line = line_number(masked, name_start + 1)
            attribute_start = masked.rfind("\n", 0, name_start + 1) + 1
            previous_end = max(0, attribute_start - 1)
            previous_start = masked.rfind("\n", 0, previous_end) + 1
            if masked[previous_start:previous_end].strip().startswith("@("):
                declaration_line -= 1
            result.append(Procedure(name, declaration_line, line_number(masked, scan - 1)))
            cursor = scan
        else:
            cursor = marker_index + len(marker)
    return result


def check_source(source: str, baseline: dict[str, int] | None = None, path: str = "") -> list[Violation]:
    baseline = baseline or {}
    violations: list[Violation] = []
    for number, line in enumerate(source.splitlines(), 1):
        if len(line) > LINE_LIMIT:
            violations.append(Violation(number, f"line has {len(line)} characters; limit is {LINE_LIMIT}"))
    for procedure in procedures(source):
        key = f"{path}:{procedure.name}" if path else procedure.name
        allowed = baseline.get(key, PROCEDURE_LIMIT)
        if procedure.lines > allowed:
            violations.append(
                Violation(
                    procedure.start_line,
                    f"procedure {procedure.name} has {procedure.lines} lines; limit is {allowed}",
                )
            )
    return violations


def tracked_odin_files(root: Path) -> list[str]:
    process = subprocess.run(
        ["git", "ls-files", "*.odin"],
        cwd=root,
        check=True,
        capture_output=True,
        text=True,
    )
    return [path for path in process.stdout.splitlines() if not path.startswith(EXCLUDED_PREFIXES)]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", default=".")
    parser.add_argument("--baseline")
    parser.add_argument("--print-procedures", action="store_true")
    arguments = parser.parse_args()
    root = Path(arguments.root).resolve()
    baseline: dict[str, int] = {}
    if arguments.baseline:
        baseline = json.loads(Path(arguments.baseline).read_text())
    failed = False
    for relative in tracked_odin_files(root):
        source = (root / relative).read_text(encoding="utf-8")
        if arguments.print_procedures:
            for procedure in procedures(source):
                if procedure.lines > PROCEDURE_LIMIT:
                    print(f'\t"{relative}:{procedure.name}": {procedure.lines},')
            continue
        for violation in check_source(source, baseline, relative):
            print(f"{relative}:{violation.line}: {violation.message}")
            failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
