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
ASSERTION = re.compile(r"(?<![A-Za-z0-9_#])(?:assert|ensure)\s*\(|#assert\s*\(")
RISK_PATTERNS = {
    "pointer": re.compile(r"\^\w|->\s*\^|raw_(?:data|ptr)|transmute"),
    "index": re.compile(r"\[[^\]\n]+\]|slice\.|ordered_remove|unordered_remove"),
    "queue": re.compile(
        r"\b(?:queue|ring|result_slots|head|count)\b|append\s*\(|inject_at"
    ),
    "ownership": re.compile(r"\b(?:make|new|delete|free|destroy|clone|resize)\s*\("),
    "state": re.compile(r"\b(?:state|running|active|frame|session|begin|end|start|stop|close)\b"),
    "untrusted_input": re.compile(r"\b(?:parse|decode|read|recv|payload|wire|ffi)\b"),
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


def risks_for(body: str) -> tuple[str, ...]:
    masked = check_odin_style.mask_source(body)
    return tuple(name for name, pattern in RISK_PATTERNS.items() if pattern.search(masked))


def is_trivial(body: str, risks: tuple[str, ...]) -> bool:
    masked = check_odin_style.mask_source(body)
    statements = [line for line in masked.splitlines()[1:-1] if line.strip()]
    if len(statements) > 12:
        return False
    wrapper_risks = set(risks) - {"pointer", "state"}
    calls = len(re.findall(r"[A-Za-z_][A-Za-z0-9_]*\s*\(", masked))
    return not wrapper_risks and "return" in masked and calls <= 2


def findings_for_source(source: str, path: str) -> list[Finding]:
    findings: list[Finding] = []
    for procedure in check_odin_style.procedures(source):
        body = procedure_text(source, procedure)
        masked = check_odin_style.mask_source(body)
        risks = risks_for(body)
        if is_trivial(body, risks):
            continue
        assertions = len(ASSERTION.findall(masked))
        if risks and assertions == 0:
            findings.append(Finding(path, procedure.name, procedure.start_line, risks, assertions))
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
        added = set(finding.risks) - allowed
        if added:
            failures.append(f"{key}: uncovered assertion risks added: {', '.join(sorted(added))}")
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
