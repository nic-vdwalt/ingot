#!/usr/bin/env python3

import argparse
import json
from pathlib import Path

TARGETS = ("macOS", "Linux", "Windows", "Browser", "Internet TLS")
STATUS = {"compiled", "validated", "blocked", "failed"}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("evidence_dir")
    parser.add_argument("output")
    args = parser.parse_args()
    records = {target: [] for target in TARGETS}
    for path in sorted(Path(args.evidence_dir).glob("*.json")):
        if path.name == "schema.json":
            continue
        data = json.loads(path.read_text(encoding="utf-8"))
        if data.get("schema_version") not in (1, 2) or len(data.get("checks", [])) == 0:
            raise SystemExit(f"invalid evidence: {path}")
        for check in data["checks"]:
            if check.get("status") not in STATUS:
                raise SystemExit(f"invalid status: {path}")
            target = check.get("target") or data.get("target")
            if target not in records:
                raise SystemExit(f"missing or invalid target: {path}")
            records[target].append((check["status"], path.name))
    lines = ["| Target | Evidence | Status |", "|---|---|---|"]
    for target in TARGETS:
        entries = records[target]
        if not entries:
            lines.append(f"| {target} | None | Not recorded |")
            continue
        statuses = {entry[0] for entry in entries}
        status = "failed" if "failed" in statuses else "blocked" if "blocked" in statuses else "validated" if statuses == {"validated"} else "compiled"
        links = ", ".join(f"[{name}](validation/{name})" for _, name in entries)
        lines.append(f"| {target} | {links} | {status} |")
    Path(args.output).write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
