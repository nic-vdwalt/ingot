#!/usr/bin/env python3
"""Enforce ingot's physical and control-flow TigerStyle rules."""

import argparse
import dataclasses
import json
import re
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
    "net/http_curl.odin",
    "net/http_web.odin",
    "net/ws_curl.odin",
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


WAIVER = re.compile(r"^\s*//\s*tigerstyle:\s*allow-unbounded-loop\s*--\s*(.+?)\s*$")
INVALID_WAIVER = re.compile(r"^\s*//\s*tigerstyle:\s*allow-unbounded-loop(?:\s*--\s*)?$")


def procedure_source(source: str, procedure: Procedure) -> str:
    return "\n".join(source.splitlines()[procedure.start_line - 1 : procedure.end_line])


def direct_recursion_violations(source: str, procedure: Procedure) -> list[Violation]:
    body = mask_source(procedure_source(source, procedure))
    pattern = re.compile(rf"(?<![.A-Za-z0-9_]){re.escape(procedure.name)}\s*\(")
    result: list[Violation] = []
    for match in pattern.finditer(body):
        line = procedure.start_line + body.count("\n", 0, match.start())
        if line == procedure.start_line:
            continue
        result.append(Violation(line, f"direct recursion: procedure {procedure.name} calls itself"))
    return result


def loop_header_bounded(header: str) -> bool:
    compact = " ".join(header.split())
    if not compact or compact == "true":
        return False
    if re.search(r"\bin\b", compact):
        return True
    if compact.count(";") == 2:
        _, condition, update = (part.strip() for part in compact.split(";"))
        if not condition:
            return False
        if not update:
            return bool(re.search(r"\b(?:len|cap)\s*\(", condition))
        return bool(
            re.search(r"(?:==|<|<=|>|>=|!=)", condition)
            and re.search(r"(?:\+=|-=|\+\+|--|=)", update)
        )
    return bool(
        re.search(r"(?:<|<=|>|>=|!=)", compact)
        or re.search(r"\b(?:time|timeout|deadline|elapsed|duration|since)\b", compact, re.I)
    )


def control_flow_violations(source: str, procedure: Procedure) -> list[Violation]:
    original = procedure_source(source, procedure)
    masked = mask_source(original)
    original_lines = original.splitlines()
    result = direct_recursion_violations(source, procedure)
    for match in re.finditer(r"\bfor\b(?P<header>[^{}]*)\{", masked):
        line_offset = masked.count("\n", 0, match.start())
        line = procedure.start_line + line_offset
        if loop_header_bounded(match.group("header")):
            continue
        previous = line_offset - 1
        while previous >= 0 and not original_lines[previous].strip():
            previous -= 1
        if previous >= 0 and WAIVER.match(original_lines[previous]):
            continue
        result.append(Violation(line, "loop has no structurally provable upper bound"))
    for index, line_text in enumerate(original_lines):
        if INVALID_WAIVER.match(line_text):
            result.append(Violation(procedure.start_line + index, "unbounded-loop waiver requires a rationale"))
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
        violations.extend(control_flow_violations(source, procedure))
    return sorted(violations, key=lambda violation: (violation.line, violation.message))


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
        path = root / relative
        if not path.is_file():
            continue
        source = path.read_text(encoding="utf-8")
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
