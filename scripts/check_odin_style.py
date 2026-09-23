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
    "artifacts/",
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

# `assert` and `assert_contextless` are @(disabled=ODIN_DISABLE_ASSERT): under
# -disable-assert the compiler drops the whole call, including its arguments.
# A condition that does work (uploads, commits, fills a buffer) silently stops
# doing it, so conditions may only call procedures known to be pure. `ensure`
# is never disabled and is deliberately not matched.
ASSERT_CALL = re.compile(r"(?<![A-Za-z0-9_#.])(?:assert_contextless|assert)\s*\(")
CONDITION_CALL = re.compile(
    r"(?<![A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*(?:\s*\.\s*[A-Za-z_][A-Za-z0-9_]*)*)\s*\("
)
ASSERT_WAIVER = re.compile(r"^\s*//\s*tigerstyle:\s*allow-assert-call\s*--\s*(.+?)\s*$")
PURE_BUILTINS = frozenset(
    {
        "abs", "align_of", "auto_cast", "cap", "card", "cast", "clamp", "imag", "len", "max",
        "min", "offset_of", "raw_data", "real", "size_of", "transmute", "type_info_of",
        "type_of", "typeid_of", "bool", "b8", "b16", "b32", "b64", "int", "uint", "i8", "i16",
        "i32", "i64", "i128", "u8", "u16", "u32", "u64", "u128", "uintptr", "f16", "f32",
        "f64", "rune", "string", "cstring", "rawptr", "c_int", "c_long", "c_uint",
    }
)
PURE_PATTERNS = (
    re.compile(r"(?:^|_)(?:is|has|can)_"),
    re.compile(r"^prepared_[a-z_]+$"),
    re.compile(r"^terrain_recipe_validate_v[0-9]+$"),
    re.compile(r"_IsValid$"),
    re.compile(
        r"_(?:valid|finite|settled|fits|matches|active|ready|balanced|open|kind|count"
        r"|capacity|size|format|phase|epoch|in_flight|available|focused|nodes"
        r"|is_ancestor|child_count|schema|length|contains|equal|equals)$"
    ),
)
# Pure queries defined outside the scanned tree (core:/base:), where no marker
# can be written. A procedure declared in this tree declares its purity with a
# `// tigerstyle: pure` marker instead; listing it here is reported.
EXTERNAL_PURE_NAMES = frozenset(
    {
        "atomic_load", "atomic_load_explicit", "builder_len", "has_prefix", "has_suffix",
        "memory", "to_string",
    }
)

# Purity is declared where the procedure is written, not in a central list:
#
#     // tigerstyle: pure
#     @(private)
#     frame_z :: proc(frame: ^Ui_Frame) -> Z_Order {
#
# Attributes may sit between the marker and the declaration. The body check
# below is a heuristic backstop, not a proof: it rejects direct mutator calls
# and writes through a parameter, but cannot see mutation done by callees.
PURE_MARKER = re.compile(r"^\s*//\s*tigerstyle:\s*pure\s*$")
PROC_DECLARATION = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*::\s*(?:#force_inline\s+)?proc\b")
TYPE_DECLARATION = re.compile(
    r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*::\s*(?:#type\s+)?(?:distinct\b|struct\b|enum\b|union\b"
    r"|bit_set\b|bit_field\b|matrix\s*\[|map\s*\[|#simd\b|\[|\^"
    r"|(?:bool|b8|b16|b32|b64|int|uint|i8|i16|i32|i64|i128|u8|u16|u32|u64|u128|uintptr"
    r"|f16|f32|f64|rune|string|cstring|rawptr)\s*$)"
)
MUTATOR_CALL = re.compile(
    r"\b(append|append_elem|append_elems|inject_at|delete|free|free_all|new|make|clear"
    r"|resize|reserve|pop|pop_front|ordered_remove|unordered_remove|atomic_store"
    r"|atomic_store_explicit|atomic_add|atomic_sub|atomic_exchange"
    r"|atomic_compare_exchange\w*)\s*\("
)


@dataclasses.dataclass(frozen=True)
class PurityIndex:
    pure_names: frozenset[str]
    type_names: frozenset[str]


def condition_call_is_pure(qualified: str, purity: PurityIndex | None = None) -> bool:
    name = qualified.split(".")[-1].strip()
    if name in PURE_BUILTINS or name in EXTERNAL_PURE_NAMES:
        return True
    if purity is not None and (name in purity.pure_names or name in purity.type_names):
        return True
    return any(pattern.search(name) for pattern in PURE_PATTERNS)


def procedure_parameters(signature: str) -> list[str]:
    open_index = signature.find("(", signature.find("proc"))
    if open_index < 0:
        return []
    depth = 0
    close_index = open_index
    for close_index in range(open_index, len(signature)):
        if signature[close_index] in "([{":
            depth += 1
        elif signature[close_index] in ")]}":
            depth -= 1
            if depth == 0:
                break
    pieces: list[str] = []
    depth = 0
    start = open_index + 1
    for index in range(open_index + 1, close_index + 1):
        char = signature[index]
        if char in "([{":
            depth += 1
        elif char in ")]}" and depth > 0:
            depth -= 1
        elif (char == "," and depth == 0) or index == close_index:
            pieces.append(signature[start:index])
            start = index + 1
    names: list[str] = []
    for piece in pieces:
        head = piece.split(":", 1)[0]
        head = re.sub(r"^\s*(?:using\s+|#\w+\s+|\$|\.\.)*", "", head)
        match = re.match(r"[A-Za-z_][A-Za-z0-9_]*", head)
        if match:
            names.append(match.group(0))
    return names


def pure_body_violations(masked: str, procedure: Procedure) -> list[Violation]:
    lines = masked.splitlines()[procedure.start_line - 1 : procedure.end_line]
    text = "\n".join(lines)
    body_start = text.find("{", text.find("proc"))
    parameters = procedure_parameters(text[:body_start] if body_start >= 0 else text)
    result: list[Violation] = []
    for match in MUTATOR_CALL.finditer(text, max(body_start, 0)):
        line = procedure.start_line + text.count("\n", 0, match.start())
        result.append(
            Violation(
                line,
                f"pure-marked proc {procedure.name} mutates state: calls {match.group(1)}",
            )
        )
    if parameters:
        names = "|".join(re.escape(name) for name in parameters)
        write = re.compile(
            rf"(?<![A-Za-z0-9_.])({names})\s*(?:\^|\.\s*[A-Za-z_]\w*|\[[^\]\n]*\])"
            rf"(?:\s*(?:\^|\.\s*[A-Za-z_]\w*|\[[^\]\n]*\]))*\s*(?:<<|>>|&~|[-+*/%|&~^])?=(?!=)"
        )
        for match in write.finditer(text, max(body_start, 0)):
            line = procedure.start_line + text.count("\n", 0, match.start())
            result.append(
                Violation(
                    line,
                    f"pure-marked proc {procedure.name} mutates state: writes through "
                    f"parameter {match.group(1)}",
                )
            )
    return result


def purity_declarations(source: str) -> tuple[set[str], set[str], list[Violation]]:
    masked = mask_source(source)
    original_lines = source.splitlines()
    masked_lines = masked.splitlines()
    pure_names: set[str] = set()
    type_names: set[str] = set()
    violations: list[Violation] = []
    marked_lines: dict[int, str] = {}
    for index, line_text in enumerate(masked_lines):
        type_match = TYPE_DECLARATION.match(line_text)
        if type_match:
            type_names.add(type_match.group(1))
        proc_match = PROC_DECLARATION.match(line_text)
        if proc_match and proc_match.group(1) in EXTERNAL_PURE_NAMES:
            violations.append(
                Violation(
                    index + 1,
                    f"{proc_match.group(1)} is declared here; declare purity with a "
                    "`// tigerstyle: pure` marker instead of EXTERNAL_PURE_NAMES",
                )
            )
    for index, line_text in enumerate(original_lines):
        if not PURE_MARKER.match(line_text):
            continue
        following = index + 1
        while following < len(masked_lines) and (
            not masked_lines[following].strip() or masked_lines[following].strip().startswith("@(")
        ):
            following += 1
        match = None
        if following < len(masked_lines):
            match = PROC_DECLARATION.match(masked_lines[following])
        if not match:
            violations.append(
                Violation(index + 1, "dangling pure marker: no procedure declaration follows")
            )
            continue
        pure_names.add(match.group(1))
        marked_lines[following + 1] = match.group(1)
    for procedure in procedures(source):
        declaration_line = procedure.start_line
        while declaration_line <= procedure.end_line and declaration_line not in marked_lines:
            if PROC_DECLARATION.match(masked_lines[declaration_line - 1]):
                break
            declaration_line += 1
        if marked_lines.get(declaration_line) == procedure.name:
            violations.extend(pure_body_violations(masked, procedure))
    return pure_names, type_names, violations


def build_purity_index(sources: list[str]) -> PurityIndex:
    pure_names: set[str] = set()
    type_names: set[str] = set()
    for source in sources:
        names, types, _ = purity_declarations(source)
        pure_names |= names
        type_names |= types
    return PurityIndex(frozenset(pure_names), frozenset(type_names))


def assert_condition_end(masked: str, start: int) -> int:
    depth = 0
    index = start
    while index < len(masked):
        char = masked[index]
        if char in "([{":
            depth += 1
        elif char in ")]}":
            if depth == 0:
                return index
            depth -= 1
        elif char == "," and depth == 0:
            return index
        index += 1
    return index


def assert_side_effect_violations(
    source: str, purity: PurityIndex | None = None
) -> list[Violation]:
    masked = mask_source(source)
    original_lines = source.splitlines()
    result: list[Violation] = []
    for match in ASSERT_CALL.finditer(masked):
        condition_start = match.end()
        condition = masked[condition_start : assert_condition_end(masked, condition_start)]
        impure = [
            call.group(1)
            for call in CONDITION_CALL.finditer(condition)
            if not condition_call_is_pure(call.group(1), purity)
        ]
        if not impure:
            continue
        line = line_number(masked, match.start())
        previous = line - 2
        while previous >= 0 and not original_lines[previous].strip():
            previous -= 1
        if previous >= 0 and ASSERT_WAIVER.match(original_lines[previous]):
            continue
        name = " ".join(impure[0].split())
        result.append(
            Violation(
                line,
                f"assert condition calls '{name}'; -disable-assert elides it. "
                "Hoist the call into a local",
            )
        )
    return result


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


def check_source(
    source: str,
    baseline: dict[str, int] | None = None,
    path: str = "",
    purity: PurityIndex | None = None,
) -> list[Violation]:
    baseline = baseline or {}
    pure_names, type_names, violations = purity_declarations(source)
    if purity is None:
        purity = PurityIndex(frozenset(pure_names), frozenset(type_names))
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
    violations.extend(assert_side_effect_violations(source, purity))
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
    sources: dict[str, str] = {}
    for relative in tracked_odin_files(root):
        path = root / relative
        if path.is_file():
            sources[relative] = path.read_text(encoding="utf-8")
    purity = build_purity_index(list(sources.values()))
    for relative, source in sources.items():
        if arguments.print_procedures:
            for procedure in procedures(source):
                if procedure.lines > PROCEDURE_LIMIT:
                    print(f'\t"{relative}:{procedure.name}": {procedure.lines},')
            continue
        for violation in check_source(source, baseline, relative, purity):
            print(f"{relative}:{violation.line}: {violation.message}")
            failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
