#!/usr/bin/env python3

import argparse
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path

TARGETS = ("macOS", "Linux", "Windows", "Browser", "Internet TLS")
STATUSES = ("compiled", "validated", "blocked", "failed")
FIELDS = (
    "monitor", "dpi", "window_system", "gpu", "driver", "backend",
    "presentation_mode", "assistive_technology", "input_devices", "locale",
    "browser", "network_mode", "package_composition",
)


def arguments():
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", choices=TARGETS, required=True)
    parser.add_argument("--status", choices=STATUSES, required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--ingot-revision", required=True)
    parser.add_argument("--odin-revision", required=True)
    parser.add_argument("--os", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--architecture", required=True)
    parser.add_argument("--artifact")
    parser.add_argument("--log")
    parser.add_argument("--note", default="")
    parser.add_argument("--output", type=Path, required=True)
    for field in FIELDS:
        parser.add_argument("--" + field.replace("_", "-"), default="")
    return parser.parse_args()


def main():
    args = arguments()
    platform = {"os": args.os, "version": args.version, "architecture": args.architecture}
    for field in FIELDS:
        value = getattr(args, field)
        if value:
            platform[field] = value
    artifact = None
    if args.artifact:
        path = Path(args.artifact)
        artifact = {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
    log_hash = "0" * 64
    if args.log:
        log_hash = hashlib.sha256(Path(args.log).read_bytes()).hexdigest()
    check = {
        "name": args.name,
        "command": ["operator-controlled-validation"],
        "status": args.status,
        "exit_code": 0 if args.status in ("compiled", "validated") else 1,
        "log_sha256": log_hash,
    }
    if args.note:
        check["note"] = args.note
    record = {
        "schema_version": 2,
        "target": args.target,
        "ingot_revision": args.ingot_revision,
        "odin_revision": args.odin_revision,
        "date_utc": datetime.now(timezone.utc).isoformat(),
        "platform": platform,
        "checks": [check],
    }
    if artifact:
        record["artifact"] = artifact
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    print(args.output)


if __name__ == "__main__":
    main()
