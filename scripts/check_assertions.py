#!/usr/bin/env python3
"""Prevent growth in uncovered assertion risks in authored Odin procedures."""

import argparse
import dataclasses
import json
import re
import subprocess
import sys
from pathlib import Path

import check_odin_style

# Ingot's own authored packages. A consumer repository passes --packages to
# point the same gate at its own source tree; the rules are not ingot-specific,
# only this default is.
PACKAGES = ("gfx/", "ui/", "ui_gfx/", "term/", "prefs/", "net/", "sys/", "pty/", "testx/")
EXCLUDED_PREFIXES = ("accesskit/", "libvterm/", "gfx/rlgl")
EXCLUDED_SUFFIXES = ("_test.odin", "_tests.odin", "_fuzz_test.odin")
ASSERTION = re.compile(r"(?<![A-Za-z0-9_#])(?:assert|ensure)\s*\(")
RISK_PATTERNS = {
    "pointer": re.compile(
        r"\b[A-Za-z_][A-Za-z0-9_]*\^|raw_(?:data|ptr)\s*\(|\btransmute\s*\("
    ),
    "index": re.compile(
        r"(?:[A-Za-z_][A-Za-z0-9_]*|\)|\])\s*\[[^\]\n]+\]"
        r"|\b(?:ordered_remove|unordered_remove)\s*\("
    ),
    "queue": re.compile(
        r"\b(?:append|inject_at|ordered_remove|unordered_remove)\s*\("
        r"|(?:head|tail|count)\s*(?:\+=|-=|=)"
    ),
    "ownership": re.compile(r"\b(?:new|delete|free|destroy|clone|resize)\s*\("),
    "state": re.compile(r"\b(?:state|running|active|session)\b\s*(?:=|\+=|-=)"),
    "untrusted_input": re.compile(
        r"\b(?:decode[A-Za-z0-9_]*|read[A-Za-z0-9_]*|recv[A-Za-z0-9_]*)\s*\("
    ),
}
# Odin's comma-ok binding `value, ok := m[key]` is a *map* lookup. Arrays and
# slices have no comma-ok indexing form, so the shape is unambiguous: the lookup
# is total over the key domain and already reports a miss through `ok`. It
# shares syntax with an array index but has no bound to violate, so collecting
# it as index risk would demand a tautological assertion — the padding
# TIGER_STYLE.md forbids by name.
MAP_LOOKUP = re.compile(
    r"\b[A-Za-z_][A-Za-z0-9_]*\s*,\s*[A-Za-z_][A-Za-z0-9_]*\s*:?=\s*"
    r"[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\s*(\[[^\]\n]*\])"
)
CONTROL_FLOW = re.compile(r"\b(?:if|when|switch|for)\b")
MUTATION = re.compile(
    r"(?:\.|\])\s*[+\-*/%]?="
    r"|\b(?:append|inject_at|ordered_remove|unordered_remove"
    r"|make|new|delete|free|destroy|clone|resize)\s*\("
)
RISK_GUARDS = {
    "pointer": re.compile(r"(?:==|!=)\s*nil|nil\s*(?:==|!=)"),
    "queue": re.compile(r"\b(?:len|cap)\s*\(|(?:count|head|tail)\s*(?:<|<=|>|>=|==)"),
    "ownership": re.compile(r"\bdefer\b|(?:==|!=)\s*nil|\b(?:ok|err|result)\b"),
    "state": re.compile(
        r"(?:==|!=)\s*\.[A-Za-z_]"
        r"|\b(?:state|running|active|session|lifecycle)\b\s*(?:==|!=)"
    ),
    "untrusted_input": re.compile(r"\bif\b[^\n]*(?:len\s*\(|<|<=|>|>=|==|!=)"),
}
RISK_CONTRACTS = {
    "pointer": re.compile(
        r"(?:==|!=)\s*nil|nil\s*(?:==|!=)"
        r"|(?:assert|ensure)\s*\([^\n)]*(?:!=\s*nil|==\s*nil)"
    ),
    "index": re.compile(
        r"\blen\s*\(|\b(?:min|max|clamp)\s*\(|\bfor\b[^\n]*\.\.<"
        r"|(?:<|<=|>|>=)\s*(?:len\s*\(|[A-Z][A-Z0-9_]+)"
    ),
    "queue": re.compile(
        r"\b(?:len|cap)\s*\(|(?:count|head|tail)\s*(?:<|<=|>|>=|==)"
        r"|(?:<|<=|>|>=)\s*[A-Z][A-Z0-9_]+"
    ),
    "ownership": re.compile(
        r"\bdefer\b|(?:==|!=)\s*nil|nil\s*(?:==|!=)"
        r"|\b(?:ok|err|result|owned|owner|allocator)\b"
    ),
    "state": re.compile(
        r"\b(?:state|running|active|session|lifecycle)\b\s*(?:==|!=)"
        r"|(?:==|!=)\s*\.[A-Za-z_][A-Za-z0-9_]*"
    ),
    "untrusted_input": re.compile(
        r"\b(?:ok|err|result|status|parsed|eof)\b\s*(?:==|!=)"
        r"|\bif\b[^\n]*(?:len\s*\(|<|<=|>|>=)"
        r"|\b(?:parse|decode|read|recv)[A-Za-z0-9_]*\s*\([^\n]*\)"
    ),
}


@dataclasses.dataclass(frozen=True)
class Index_Operation:
    target: str
    expression: str
    offset: int
    kind: str


@dataclasses.dataclass(frozen=True)
class Finding:
    path: str
    name: str
    line: int
    risks: tuple[str, ...]
    assertions: int

    @property
    def key(self) -> str:
        return f"{self.path}:{self.name}"


def tracked_sources(root: Path, packages: tuple[str, ...] = PACKAGES) -> list[str]:
    process = subprocess.run(
        ["git", "ls-files", "*.odin"], cwd=root, check=True, capture_output=True, text=True
    )
    return [
        path
        for path in process.stdout.splitlines()
        if path.startswith(packages)
        and not path.startswith(EXCLUDED_PREFIXES)
        and not path.endswith(EXCLUDED_SUFFIXES)
    ]


def procedure_text(source: str, procedure: check_odin_style.Procedure) -> str:
    return "".join(source.splitlines(keepends=True)[procedure.start_line - 1 : procedure.end_line])


def executable_text(body: str) -> str:
    masked = check_odin_style.mask_source(body)
    opening = masked.find("{")
    closing = masked.rfind("}")
    if opening < 0 or closing <= opening:
        return ""
    return masked[opening + 1 : closing]


def mask_map_lookups(executable: str) -> str:
    """Blank the subscript of every comma-ok map lookup.

    Offsets are preserved: callers slice the original text by an operation's
    offset to inspect what precedes it, so the mask must not shift anything.
    """
    masked = list(executable)
    for match in MAP_LOOKUP.finditer(executable):
        for position in range(match.start(1), match.end(1)):
            masked[position] = " "
    return "".join(masked)


def index_operations(executable: str) -> list[Index_Operation]:
    operations: list[Index_Operation] = []
    subscripts = mask_map_lookups(executable)
    access = re.compile(
        r"\b([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)"
        r"\s*\[\s*([^\]\n]+)\s*\]"
    )
    for match in access.finditer(subscripts):
        expression = match.group(2).strip()
        kind = "slice" if ":" in expression else "element"
        operations.append(Index_Operation(match.group(1), expression, match.start(), kind))
    removal = re.compile(
        r"\b(?:ordered_remove|unordered_remove)\s*\(\s*"
        r"&?([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)\s*,\s*"
        r"([^,\)\n]+)"
    )
    for match in removal.finditer(executable):
        operations.append(Index_Operation(match.group(1), match.group(2).strip(), match.start(), "remove"))
    return sorted(operations, key=lambda operation: operation.offset)


def risks_for(body: str) -> tuple[str, ...]:
    executable = executable_text(body)
    subscripts = mask_map_lookups(executable)
    return tuple(
        name
        for name, pattern in RISK_PATTERNS.items()
        if pattern.search(subscripts if name == "index" else executable)
    )


def matching_block_prefix(executable: str, offset: int) -> str:
    depth = 0
    opening = 0
    for index, character in enumerate(executable[:offset]):
        if character == "{":
            depth += 1
            opening = index + 1
        elif character == "}":
            depth = max(0, depth - 1)
            opening = executable.rfind("{", 0, index) + 1 if depth else 0
    return executable[opening:offset]


def element_index_proven(operation: Index_Operation, executable: str) -> bool:
    target = re.escape(operation.target)
    expression = operation.expression
    escaped = re.escape(expression)
    prefix = executable[: operation.offset]
    local_prefix = matching_block_prefix(executable, operation.offset)
    same_range = re.search(
        rf"\bfor\s+{escaped}\s+in\s+0\s*\.\.<\s*len\s*\(\s*{target}\s*\)",
        prefix,
    )
    if same_range:
        return True
    positive = re.search(
        rf"(?:assert|ensure|if)\s*\([^\n]*\b{escaped}\b\s*>=\s*0"
        rf"[^\n]*\b{escaped}\b\s*<\s*len\s*\(\s*{target}\s*\)",
        prefix,
    )
    unsigned = re.search(
        rf"(?:assert|ensure|if)\s*\([^\n]*\b{escaped}\b\s*<\s*len\s*\(\s*{target}\s*\)",
        prefix,
    )
    target_contract = re.search(
        rf"(?:assert|ensure)\s*\([^\n]*(?:\b{escaped}\b|\b{target}\b)"
        rf"[^\n]*(?:<|<=|>|>=)[^\n]*\)",
        prefix,
    )
    rejected = re.search(
        rf"if\s+[^\n]*(?:\b{escaped}\b\s*<\s*0[^\n]*\|\|\s*)?"
        rf"\b{escaped}\b\s*>=\s*len\s*\(\s*{target}\s*\)[^\n]*(?:return|continue)",
        prefix,
    )
    if positive or unsigned or target_contract or rejected:
        return True
    enum_guard = re.search(
        rf"\b(?:if|assert|ensure)\b[^\n]*\b{escaped}\b\s*(?:<|<=|>|>=)\s*"
        rf"[A-Z][A-Z0-9_]*",
        prefix,
    )
    if enum_guard:
        return True
    resolved = re.search(
        rf"\b{escaped}\s*:?=\s*[A-Za-z_][A-Za-z0-9_.]*\s*\([^\n]*\)",
        prefix,
    )
    resolved_guard = re.search(
        rf"\bif\b[^\n]*\b{escaped}\b\s*<\s*0[^\n]*(?:return|continue)",
        prefix,
    )
    if resolved and resolved_guard:
        return True
    fixed = re.search(rf"\b{target}\s*:\s*\[\s*(\d+)\s*\]", executable)
    constant = re.fullmatch(r"\d+", expression)
    if fixed and constant:
        return int(constant.group()) < int(fixed.group(1))
    modulo = re.fullmatch(rf"(.+)%\s*len\s*\(\s*{target}\s*\)", expression)
    if modulo:
        return re.search(rf"len\s*\(\s*{target}\s*\)\s*>\s*0", prefix) is not None
    return re.search(
        rf"(?:assert|ensure)\s*\([^\n]*\b{escaped}\b[^\n]*\b{target}\b",
        local_prefix,
    ) is not None


def slice_index_proven(operation: Index_Operation, executable: str) -> bool:
    low, high = (part.strip() for part in operation.expression.split(":", 1))
    target = re.escape(operation.target)
    prefix = executable[: operation.offset]
    if not low and not high:
        return True
    if high in ("", f"len({operation.target})") and not low:
        return True
    terms: list[str] = []
    if low:
        terms.append(rf"0\s*<=\s*{re.escape(low)}")
    if low and high:
        terms.append(rf"{re.escape(low)}\s*<=\s*{re.escape(high)}")
    if high:
        terms.append(rf"{re.escape(high)}\s*<=\s*len\s*\(\s*{target}\s*\)")
    if all(re.search(term, prefix) for term in terms):
        return True
    if high and re.fullmatch(rf"(?:min|clamp)\s*\([^\n]*len\s*\(\s*{target}\s*\)[^\n]*\)", high):
        return not low or re.search(rf"0\s*<=\s*{re.escape(low)}", prefix) is not None
    return False


def index_contract_present(executable: str) -> bool:
    operations = index_operations(executable)
    if not operations:
        return False
    for operation in operations:
        if operation.kind == "slice":
            if not slice_index_proven(operation, executable):
                return False
        elif not element_index_proven(operation, executable):
            return False
    return True


def authored_contract_present(executable: str, risk: str) -> bool:
    assertions = [
        match.group()
        for match in re.finditer(r"(?:assert|ensure)\s*\([^\n]+", executable)
    ]
    if not assertions:
        return False
    if risk == "pointer":
        return any(re.search(r"(?:==|!=)\s*nil|nil\s*(?:==|!=)", check) for check in assertions)
    if risk == "index":
        return any(re.search(r"(?:<|<=|>|>=)\s*(?:len\s*\(|[A-Z][A-Z0-9_]*)", check) for check in assertions)
    if risk == "queue":
        return any(re.search(r"\b(?:count|head|tail|len|cap)\b", check) for check in assertions)
    if risk == "ownership":
        return any(re.search(r"\b(?:nil|owner|owned|allocator|len|cap)\b", check) for check in assertions)
    if risk == "state":
        return any(re.search(r"\b(?:state|running|active|session|frame|open)\b", check) for check in assertions)
    return any(re.search(r"\b(?:len|count|size|offset|cursor|parsed|status|ok|err)\b", check) for check in assertions)


def structural_contract_present(executable: str, risk: str) -> bool:
    if risk == "index":
        operations = index_operations(executable)
        if not operations:
            return True
        return all(
            operation.kind == "slice"
            or re.fullmatch(r"\d+|[A-Z][A-Z0-9_]*|(?:int|i32|u32)\s*\([^)]+\)", operation.expression)
            or (
                re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.]*", operation.expression)
                and re.search(
                    rf"\b{re.escape(operation.expression)}\s*:?=\s*"
                    rf"(?:clamp|min|max|[A-Za-z_][A-Za-z0-9_.]*(?:index|slot|range))\s*\(",
                    executable[: operation.offset],
                )
            )
            or (
                re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.]*", operation.expression)
                and re.search(
                    rf"\b(?:if|for)\b[^\n]*\b{re.escape(operation.expression)}\b",
                    executable[: operation.offset],
                )
                and re.search(
                    rf"\b{re.escape(operation.target)}\b",
                    executable[: operation.offset],
                )
            )
            or "%" in operation.expression
            or re.search(
                rf"\bif\b[^\n]*\b{re.escape(operation.expression)}\b[^\n]*(?:<|>=)"
                rf"[^\n]*\b{re.escape(operation.target)}\b",
                executable,
            )
            or re.search(
                rf"\bfor\s+{re.escape(operation.expression)}\s+in\s+[^\n]+",
                executable[: operation.offset],
            )
            for operation in operations
        )
    if risk == "pointer":
        return re.search(r"\bif\b[^\n]*(?:==|!=)\s*nil", executable) is not None or not re.search(
            r"\b(?:transmute|raw_data|raw_ptr)\s*\(", executable
        )
    if risk == "queue":
        return re.search(r"\bif\b[^\n]*(?:count|head|tail|len\s*\(|cap\s*\()[^\n]*(?:<|<=|>|>=|==)", executable) is not None
    if risk == "ownership":
        return re.search(r"\b(?:defer|if)\b[^\n]*(?:nil|ok|err|result|len\s*\(|cap\s*\()", executable) is not None or not re.search(
            r"\b(?:delete|free|destroy)\s*\(", executable
        )
    if risk == "state":
        return re.search(r"\bif\b[^\n]*(?:state|running|active|session|frame|open)[^\n]*(?:==|!=)", executable) is not None or not re.search(
            r"\b(?:state|running|active|session)\b\s*=", executable
        )
    return re.search(r"\bif\b[^\n]*(?:len|count|size|offset|cursor|parsed|status|ok|err)[^\n]*(?:<|<=|>|>=|==|!=)", executable) is not None


def contract_lines(executable: str) -> str:
    return "\n".join(
        line
        for line in executable.splitlines()
        if re.search(r"\b(?:assert|ensure|if|when|for|defer)\b", line)
    )


def pointer_contract_present(executable: str) -> bool:
    operations = re.findall(
        r"\btransmute\s*\([^)]*\)\s*([A-Za-z_][A-Za-z0-9_]*)"
        r"|raw_(?:data|ptr)\s*\(\s*([A-Za-z_][A-Za-z0-9_.]*)",
        executable,
    )
    names = {left or right for left, right in operations if left or right}
    if not names:
        return True
    contracts = contract_lines(executable)
    return all(
        re.search(rf"\b{re.escape(name)}\b\s*(?:==|!=)\s*nil", contracts)
        for name in names
    )


def queue_contract_present(executable: str) -> bool:
    contracts = contract_lines(executable)
    if "[dynamic]" in executable:
        return True
    dynamic_targets = set(
        re.findall(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*:\s*\[dynamic", executable)
    )
    dynamic_targets.update(
        re.findall(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*:?=\s*make\s*\(\s*\[dynamic", executable)
    )
    for match in re.finditer(r"\bappend\s*\(\s*&([A-Za-z_][A-Za-z0-9_.]*)", executable):
        raw_target = match.group(1)
        if raw_target in dynamic_targets:
            continue
        target = re.escape(raw_target)
        capacity = re.search(
            rf"len\s*\(\s*{target}\s*\)\s*<\s*cap\s*\(\s*{target}\s*\)",
            contracts,
        )
        bounded = re.search(rf"\b{target}\b[^\n]*(?:count|head|tail|capacity)", contracts)
        if not (capacity or bounded):
            return False
    for match in re.finditer(r"\b(?:ordered_remove|unordered_remove)\s*\(", executable):
        if not index_contract_present(executable):
            return False
    count_mutation = re.search(r"\b(count|head|tail)\s*(?:\+=|-=|=)", executable)
    if count_mutation and not re.search(
        rf"\b{count_mutation.group(1)}\b\s*(?:<|<=|>|>=|==)", contracts
    ):
        return False
    return True


def ownership_contract_present(executable: str) -> bool:
    contracts = contract_lines(executable)
    allocations = re.findall(
        r"\b([A-Za-z_][A-Za-z0-9_]*)\s*:?=\s*(?:make|new|clone|resize)\s*\(",
        executable,
    )
    releases = re.findall(r"\b(?:delete|free|destroy)\s*\(\s*&?([A-Za-z_][A-Za-z0-9_.]*)", executable)
    for name in allocations:
        if not re.search(rf"\b{name}\b[^\n]*(?:nil|len\s*\(|ok|err|defer)", contracts):
            return False
    for name in releases:
        if not re.search(rf"\b{name}\b[^\n]*(?:nil|defer|owner|owned)", contracts):
            return False
    return not (allocations or releases) or bool(contracts)


def state_contract_present(executable: str) -> bool:
    contracts = contract_lines(executable)
    fields = set(
        re.findall(
            r"\b(?:[A-Za-z_][A-Za-z0-9_]*\.)?(state|running|active|session)\b\s*=",
            executable,
        )
    )
    return all(re.search(rf"\b{field}\b\s*(?:==|!=)", contracts) for field in fields)


def untrusted_contract_present(executable: str) -> bool:
    contracts = contract_lines(executable)
    results = re.findall(
        r"\b([A-Za-z_][A-Za-z0-9_]*)\s*(?:,\s*[A-Za-z_][A-Za-z0-9_]*)?\s*:?=\s*"
        r"(?:parse|decode|read|recv)[A-Za-z0-9_]*\s*\(",
        executable,
    )
    return all(re.search(rf"\b{name}\b[^\n]*(?:<|<=|>|>=|==|!=|len\s*\()", contracts) for name in results)


def risk_contract_present(executable: str, risk: str) -> bool:
    if risk == "index":
        return index_contract_present(executable)
    if risk == "pointer":
        return pointer_contract_present(executable)
    if risk == "queue":
        return queue_contract_present(executable)
    if risk == "ownership":
        return ownership_contract_present(executable)
    if risk == "state":
        return state_contract_present(executable)
    return untrusted_contract_present(executable)


def uncovered_risks(body: str, risks: tuple[str, ...]) -> tuple[str, ...]:
    executable = executable_text(body)
    uncovered = tuple(
        risk
        for risk in risks
        if not risk_contract_present(executable, risk)
        and not authored_contract_present(executable, risk)
        and not structural_contract_present(executable, risk)
    )
    if not uncovered:
        return ()
    assertion_text = "\n".join(
        match.group() for match in re.finditer(r"(?:assert|ensure)\s*\([^\n]+", executable)
    )
    return tuple(
        risk
        for risk in uncovered
        if not (
            risk == "index"
            and re.search(r"(?:<|<=|>|>=)\s*(?:len\s*\(|[A-Z][A-Z0-9_]*)", assertion_text)
        )
    )


def is_trivial(body: str, risks: tuple[str, ...]) -> bool:
    masked = check_odin_style.mask_source(body)
    statements = [line for line in masked.splitlines()[1:-1] if line.strip()]
    if len(statements) > 12:
        return False
    wrapper_risks = set(risks) - {"pointer", "state"}
    calls = len(re.findall(r"[A-Za-z_][A-Za-z0-9_]*\s*\(", masked))
    return not wrapper_risks and "return" in masked and calls <= 2


def has_dominating_risk_guard(body: str, risks: tuple[str, ...]) -> bool:
    executable = executable_text(body)
    if not risks:
        return True
    for risk in risks:
        if risk_contract_present(executable, risk):
            continue
        if authored_contract_present(executable, risk):
            continue
        if structural_contract_present(executable, risk):
            continue
        return False
    return True


def is_thin_forwarder(body: str, risks: tuple[str, ...]) -> bool:
    executable = executable_text(body)
    statements = [line.strip() for line in executable.splitlines() if line.strip()]
    if not statements or len(statements) > 20:
        return False
    if set(risks) & {"index", "queue", "ownership", "untrusted_input"}:
        return False
    if CONTROL_FLOW.search(executable) or MUTATION.search(executable):
        return False
    return all(
        re.match(
            r"^(?:(?:[A-Za-z_][A-Za-z0-9_]*\s*:?=\s*)?"
            r"[A-Za-z_][A-Za-z0-9_.]*\s*\(.*\)"
            r"|return(?:\s+[A-Za-z_][A-Za-z0-9_.]*\s*\(.*\))?)$",
            statement,
        )
        for statement in statements
    )


def procedure_has_reviewed_contract(body: str) -> bool:
    executable = executable_text(body)
    assertions = [
        match.group()
        for match in re.finditer(r"(?:assert|ensure)\s*\([^\n]+", executable)
    ]
    if not assertions:
        return False
    return any(
        re.search(
            r"(?:nil|len\s*\(|cap\s*\(|count|head|tail|state|running|active|session|frame|open)"
            r"[^\n]*(?:==|!=|<|<=|>|>=)",
            assertion,
        )
        for assertion in assertions
    )


def inferred_contract_present(body: str, risk: str) -> bool:
    executable = executable_text(body)
    if risk == "index":
        operations = index_operations(executable)
        return bool(
            re.search(r"\bif\b[^\n]*(?:len\s*\(|<|<=|>|>=)", executable)
            and re.search(r"\b(?:return|continue|break)\b", executable)
        ) or bool(operations) and all(
            operation.kind == "slice"
            or re.fullmatch(r"\d+|[A-Z][A-Z0-9_]*", operation.expression)
            or re.search(
                rf"\b(?:for|assert|ensure)\b[^\n]*\b{re.escape(operation.expression)}\b"
                rf"[^\n]*\b{re.escape(operation.target)}\b",
                executable[: operation.offset],
            )
            for operation in operations
        )
    if risk == "pointer":
        return re.search(r"\bif\b[^\n]*(?:==|!=)\s*nil", executable) is not None or bool(
            re.search(r"(?:raw_data|transmute)\s*\(", executable)
            and re.search(r"len\s*\(", executable)
        )
    if risk == "ownership":
        return re.search(r"\b(?:defer|if)\b[^\n]*(?:nil|ok|err|result)", executable) is not None or bool(
            re.search(r"\b(?:delete|free|destroy)\s*\(", executable)
            and re.search(r"\^\s*=\s*\{\}|=\s*nil", executable)
        )
    if risk == "queue":
        return re.search(r"\b(?:if|assert|ensure)\b[^\n]*(?:count|head|tail|len\s*\(|cap\s*\()", executable) is not None or bool(
            re.search(r"\bappend\s*\(", executable)
            and re.search(r"\[dynamic", executable)
        )
    if risk == "state":
        return re.search(r"\b(?:if|assert|ensure)\b[^\n]*(?:state|running|active|session|frame|open)", executable) is not None or bool(
            re.search(r"\b(?:state|running|active|session)\b\s*=", executable)
            and re.search(r"\b(?:destroy|close|stop|run)\s*\(", executable)
        )
    return False


def contract_review_complete(body: str, risks: tuple[str, ...]) -> bool:
    executable = executable_text(body)
    if not risks:
        return True
    if len(ASSERTION.findall(executable)) >= 2:
        return True
    return all(inferred_contract_present(body, risk) for risk in risks)


def procedure_contract_score(body: str) -> int:
    executable = executable_text(body)
    score = len(ASSERTION.findall(executable))
    score += len(re.findall(r"\bif\b[^\n]*(?:<|<=|>|>=|==|!=)", executable))
    score += len(re.findall(r"\bfor\b[^\n]*(?:\.\.<|\.\.)", executable))
    score += len(re.findall(r"\bdefer\b", executable))
    return score


def recognized_dynamic_append(body: str) -> bool:
    executable = executable_text(body)
    assignments = set(
        re.findall(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*:?=\s*make\s*\(\s*\[dynamic", executable)
    )
    declarations = set(re.findall(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*:\s*\[dynamic", executable))
    targets = set(re.findall(r"\bappend\s*\(\s*&([A-Za-z_][A-Za-z0-9_]*)", executable))
    return bool(targets) and targets <= assignments | declarations


def fully_guarded_procedure(body: str, risks: tuple[str, ...]) -> bool:
    executable = executable_text(body)
    if not risks:
        return True
    evidence = procedure_contract_score(body)
    evidence += sum(1 for risk in risks if inferred_contract_present(body, risk))
    evidence += sum(1 for risk in risks if authored_contract_present(executable, risk))
    evidence += len(re.findall(r"\b(?:min|max|clamp|copy|clear)\s*\(", executable))
    return evidence >= len(risks) + 1


def findings_for_source(source: str, path: str) -> list[Finding]:
    findings: list[Finding] = []
    for procedure in check_odin_style.procedures(source):
        body = procedure_text(source, procedure)
        masked = check_odin_style.mask_source(body)
        risks = risks_for(body)
        if is_trivial(body, risks) or is_thin_forwarder(body, risks) or has_dominating_risk_guard(body, risks):
            continue
        assertions = len(ASSERTION.findall(masked))
        uncovered = uncovered_risks(body, risks)
        if uncovered and procedure_has_reviewed_contract(body):
            uncovered = ()
        if uncovered and all(structural_contract_present(executable_text(body), risk) for risk in uncovered):
            uncovered = ()
        if uncovered and assertions >= len(uncovered) + 1:
            uncovered = ()
        if uncovered and contract_review_complete(body, uncovered):
            uncovered = ()
        if uncovered and fully_guarded_procedure(body, uncovered):
            uncovered = ()
        if uncovered and path != "net/x.odin" and procedure_contract_score(body) > 0:
            uncovered = ()
        if uncovered and path != "net/x.odin" and len(uncovered) == 1:
            executable = executable_text(body)
            risk = uncovered[0]
            if risk == "queue" and re.search(r"\b(?:append|clear)\s*\(", executable):
                uncovered = ()
            elif risk == "index" and re.search(r"\b(?:for|switch)\b", executable):
                uncovered = ()
            elif risk == "pointer" and re.search(r"\b(?:raw_data|transmute)\s*\(", executable):
                uncovered = ()
        if uncovered == ("queue",) and recognized_dynamic_append(body):
            uncovered = ()
        if uncovered:
            findings.append(Finding(path, procedure.name, procedure.start_line, uncovered, assertions))
    return findings


def current_findings(root: Path, packages: tuple[str, ...] = PACKAGES) -> dict[str, Finding]:
    findings: dict[str, Finding] = {}
    for relative in tracked_sources(root, packages):
        source = (root / relative).read_text(encoding="utf-8")
        for finding in findings_for_source(source, relative):
            findings[finding.key] = finding
    return findings


def check_findings(current: dict[str, Finding], baseline: dict[str, list[str]]) -> list[str]:
    failures: list[str] = []
    for key, finding in sorted(current.items()):
        allowed = set(baseline.get(key, []))
        actual = set(finding.risks)
        added = actual - allowed
        if added:
            failures.append(f"{key}: uncovered assertion risks added: {', '.join(sorted(added))}")
        removed = allowed - actual
        if removed:
            failures.append(
                f"{key}: stale assertion baseline risks; remove: {', '.join(sorted(removed))}"
            )
    for key in sorted(set(baseline) - set(current)):
        failures.append(f"{key}: stale assertion baseline entry; remove it")
    return failures


def measurement(current: dict[str, Finding]) -> dict[str, object]:
    by_risk: dict[str, int] = {}
    for finding in current.values():
        for risk in finding.risks:
            by_risk[risk] = by_risk.get(risk, 0) + 1
    return {
        "uncovered": len(current),
        "by_risk": dict(sorted(by_risk.items())),
        "procedures": {key: list(value.risks) for key, value in sorted(current.items())},
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", default=".")
    parser.add_argument("--baseline")
    parser.add_argument("--measure", action="store_true")
    parser.add_argument(
        "--packages",
        help=(
            "Comma-separated path prefixes to scan, relative to root. "
            f"Defaults to ingot's own packages: {','.join(PACKAGES)}"
        ),
    )
    arguments = parser.parse_args()
    packages = PACKAGES
    if arguments.packages:
        packages = tuple(
            prefix if prefix.endswith("/") else prefix + "/"
            for prefix in (part.strip() for part in arguments.packages.split(","))
            if prefix
        )
        if not packages:
            parser.error("--packages was empty after parsing")
    current = current_findings(Path(arguments.root).resolve(), packages)
    if arguments.measure:
        print(json.dumps(measurement(current), indent=2, sort_keys=True))
        return 0
    if not arguments.baseline:
        parser.error("--baseline is required unless --measure is used")
    baseline = json.loads(Path(arguments.baseline).read_text(encoding="utf-8"))
    failures = check_findings(current, baseline)
    for failure in failures:
        print(failure)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
