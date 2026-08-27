#!/usr/bin/env python3

import argparse
import datetime
import hashlib
import json
import os
import platform
import re
import subprocess
from pathlib import Path

STATUS = ("compiled", "validated", "blocked", "failed")
SECRET = re.compile(r"(?i)(token|secret|password|authorization|api[_-]?key)=([^\s]+)")


def arguments():
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", required=True)
    parser.add_argument("--target", choices=("macOS", "Linux", "Windows", "Browser", "Internet TLS"), required=True)
    parser.add_argument("--status", choices=STATUS, required=True)
    parser.add_argument("--odin-revision", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--log-limit", type=int, default=1024 * 1024)
    parser.add_argument("--browser", default="")
    parser.add_argument("--gpu", default="")
    parser.add_argument("--driver", default="")
    parser.add_argument("--backend", default="")
    parser.add_argument("--note", default="")
    parser.add_argument("--monitor", default="")
    parser.add_argument("--dpi", default="")
    parser.add_argument("--window-system", default="")
    parser.add_argument("--presentation-mode", default="")
    parser.add_argument("--assistive-technology", default="")
    parser.add_argument("--input-devices", default="")
    parser.add_argument("--locale", default="")
    parser.add_argument("--network-mode", default="")
    parser.add_argument("--package-composition", default="")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    result = parser.parse_args()
    if result.command and result.command[0] == "--":
        result.command = result.command[1:]
    if not result.command or result.log_limit <= 0:
        parser.error("command and a positive log limit are required")
    return result


def redact(data):
    text = data.decode("utf-8", errors="replace")
    return SECRET.sub(lambda match: f"{match.group(1)}=[REDACTED]", text).encode()


def git_revision():
    return subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()


def main():
    args = arguments()
    process = subprocess.run(args.command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log = redact(process.stdout)[-args.log_limit :]
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    log_path = output.with_suffix(".log")
    log_path.write_bytes(log)
    status = args.status
    if process.returncode != 0 and status != "blocked":
        status = "failed"
    evidence = {
        "schema_version": 2,
        "target": args.target,
        "ingot_revision": git_revision(),
        "odin_revision": args.odin_revision,
        "date_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "platform": {
            "os": platform.system(),
            "version": platform.platform(),
            "architecture": platform.machine(),
        },
        "checks": [
            {
                "name": args.name,
                "command": args.command,
                "status": status,
                "exit_code": process.returncode,
                "log_sha256": hashlib.sha256(log).hexdigest(),
            }
        ],
    }
    for key in (
        "browser", "gpu", "driver", "backend", "monitor", "dpi",
        "window_system", "presentation_mode", "assistive_technology",
        "input_devices", "locale", "network_mode", "package_composition",
    ):
        value = getattr(args, key)
        if value:
            evidence["platform"][key] = value
    if args.note:
        evidence["checks"][0]["note"] = args.note
    output.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    print(output)
    return process.returncode


if __name__ == "__main__":
    raise SystemExit(main())
