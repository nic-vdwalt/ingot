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
    "ownership": re.compile(r"\b(?:make|new|delete|free|destroy|clone|resize)\s*\("),
    "state": re.compile(
        r"\b(?:state|running|active|session)\b\s*(?:=|\+=|-=)"
        r"|\b(?:begin|end|start|stop|close)\s*\("
    ),
    "untrusted_input": re.compile(
        r"\b(?:parse[A-Za-z0-9_]*|decode[A-Za-z0-9_]*"
        r"|read[A-Za-z0-9_]*|recv[A-Za-z0-9_]*)\s*\("
    ),
}
CONTROL_FLOW = re.compile(r"\b(?:if|when|switch|for)\b")
MUTATION = re.compile(
    r"(?:\.|\])\s*[+\-*/%]?="
    r"|\b(?:append|inject_at|ordered_remove|unordered_remove"
    r"|make|new|delete|free|destroy|clone|resize)\s*\("
)
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
        r"\bdefer\b|(?:==|!=)\s*nil|nil\s*(?:==|!=)|\b(?:ok|err|result)\b"
    ),
    "state": re.compile(
        r"\b(?:state|running|active|session|lifecycle)\b\s*(?:==|!=)"
        r"|(?:==|!=)\s*\.[A-Za-z_][A-Za-z0-9_]*"
    ),
    "untrusted_input": re.compile(
        r"\b(?:ok|err|result|status|parsed|eof)\b\s*(?:==|!=)"
        r"|\bif\b[^\n]*(?:len\s*\(|<|<=|>|>=)"
    ),
}


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


def tracked_sources(root: Path) -> list[str]:
    process = subprocess.run(
        ["git", "ls-files", "*.odin"], cwd=root, check=True, capture_output=True, text=True
    )
    return [
        path
        for path in process.stdout.splitlines()
        if path.startswith(PACKAGES)
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


def mask_proven_bounded_indexes(executable: str) -> str:
    masked = list(executable)
    loop = re.compile(
        r"for\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\s+0\s*\.\.<\s*"
        r"len\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)\s*\{"
    )
    for match in loop.finditer(executable):
        index_name, collection = match.group(1), match.group(2)
        depth = 1
        cursor = match.end()
        while cursor < len(executable) and depth > 0:
            if executable[cursor] == "{":
                depth += 1
            elif executable[cursor] == "}":
                depth -= 1
            cursor += 1
        if depth != 0:
            continue
        safe = re.compile(
            rf"\b{re.escape(collection)}\s*\[\s*{re.escape(index_name)}\s*\]"
        )
        for index_match in safe.finditer(executable, match.end(), cursor - 1):
            masked[index_match.start() : index_match.end()] = " " * len(index_match.group())
    return "".join(masked)


def risks_for(body: str) -> tuple[str, ...]:
    executable = executable_text(body)
    index_executable = mask_proven_bounded_indexes(executable)
    return tuple(
        name
        for name, pattern in RISK_PATTERNS.items()
        if pattern.search(index_executable if name == "index" else executable)
    )


def index_contract_present(executable: str) -> bool:
    masked = mask_proven_bounded_indexes(executable)
    indexes = re.findall(
        r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\[\s*([^\]\n]+)\s*\]",
        masked,
    )
    if not indexes:
        return True
    for collection, expression in indexes:
        expression = expression.strip()
        bound = re.compile(rf"\blen\s*\(\s*{re.escape(collection)}\s*\)")
        constant = re.fullmatch(r"\d+|[A-Z][A-Z0-9_]*", expression)
        range_loop = re.search(
            rf"\bfor\s+{re.escape(expression)}\s+in\s+(?:0\s*\.\.<|[^\n]+\.\.)",
            executable,
        )
        guarded = re.search(
            rf"\b{re.escape(expression)}\s*(?:<|<=)\s*"
            rf"(?:len\s*\(\s*{re.escape(collection)}\s*\)|[A-Z][A-Z0-9_]*)",
            executable,
        )
        enum_cast = re.fullmatch(r"(?:int|i32|u32)\s*\([^)]+\)", expression)
        ring = "%" in expression
        if not (bound.search(executable) or constant or range_loop or guarded or enum_cast or ring):
            return False
    return True


def risk_contract_present(executable: str, risk: str) -> bool:
    if risk == "index":
        return index_contract_present(executable)
    if RISK_CONTRACTS[risk].search(executable):
        return True
    if risk == "queue":
        return re.search(r"(?:assert|ensure)\s*\([^\n)]*\bqueue\b", executable) is not None
    return False


def uncovered_risks(body: str, risks: tuple[str, ...]) -> tuple[str, ...]:
    executable = executable_text(body)
    return tuple(risk for risk in risks if not risk_contract_present(executable, risk))


def is_trivial(body: str, risks: tuple[str, ...]) -> bool:
    masked = check_odin_style.mask_source(body)
    statements = [line for line in masked.splitlines()[1:-1] if line.strip()]
    if len(statements) > 12:
        return False
    wrapper_risks = set(risks) - {"pointer", "state"}
    calls = len(re.findall(r"[A-Za-z_][A-Za-z0-9_]*\s*\(", masked))
    return not wrapper_risks and "return" in masked and calls <= 2


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


def findings_for_source(source: str, path: str) -> list[Finding]:
    findings: list[Finding] = []
    for procedure in check_odin_style.procedures(source):
        body = procedure_text(source, procedure)
        masked = check_odin_style.mask_source(body)
        risks = risks_for(body)
        if is_trivial(body, risks) or is_thin_forwarder(body, risks):
            continue
        assertions = len(ASSERTION.findall(masked))
        uncovered = uncovered_risks(body, risks)
        if uncovered:
            findings.append(Finding(path, procedure.name, procedure.start_line, uncovered, assertions))
    return findings


def current_findings(root: Path) -> dict[str, Finding]:
    findings: dict[str, Finding] = {}
    for relative in tracked_sources(root):
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
    arguments = parser.parse_args()
    current = current_findings(Path(arguments.root).resolve())
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
