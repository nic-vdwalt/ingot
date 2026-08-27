#!/usr/bin/env python3

import argparse
import hashlib
import json
import os
import platform
import subprocess
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SUITE = ROOT / "benchmarks" / "end_to_end"
MANIFEST = json.loads((SUITE / "manifest.json").read_text(encoding="utf-8"))


def arguments():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("build", "run", "validate"))
    parser.add_argument("--workload", default="gallery")
    parser.add_argument("--warmup", type=int, default=300)
    parser.add_argument("--frames", type=int, default=2000)
    parser.add_argument("--repetitions", type=int, default=7)
    parser.add_argument("--output", type=Path, required=True)
    result = parser.parse_args()
    if result.warmup < 0 or result.frames <= 0 or result.repetitions <= 0:
        parser.error("warmup, frames, and repetitions are bounded positive counts")
    if result.frames > 1_000_000 or result.repetitions > 64:
        parser.error("collection exceeds suite bounds")
    return result


def workload(identifier):
    for value in MANIFEST["workloads"]:
        if value["id"] == identifier:
            return value
    raise SystemExit(f"unknown workload: {identifier}")


def metadata(args, selected):
    environment = {name: os.environ.get(name, "unknown") for name in MANIFEST["required_environment"]}
    return {
        "schema_version": MANIFEST["schema_version"],
        "date_utc": datetime.now(timezone.utc).isoformat(),
        "ingot_revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "odin_revision": subprocess.check_output(["odin", "version"], text=True).strip(),
        "platform": platform.platform(),
        "architecture": platform.machine(),
        "workload": selected,
        "warmup": args.warmup,
        "frames": args.frames,
        "repetitions": args.repetitions,
        "environment": environment,
        "scope": {
            "cpu_call_timings_are_gpu_timings": False,
            "presentation_mode_verified_by_operator": environment["INGOT_BENCH_PRESENT_MODE"] != "unknown",
            "headless_widget_results_reused": False,
        },
    }


def build(args, selected):
    output = args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    command = [
        "odin", "build", f"examples/{selected['example']}", "-collection:ingot=.",
        "-o:speed", "-define:INGOT_RENDER_STATS=true", f"-out:{output}",
    ]
    subprocess.run(command, cwd=ROOT, check=True)
    return {"binary": str(output), "sha256": hashlib.sha256(output.read_bytes()).hexdigest()}


def validate(path):
    data = json.loads(path.read_text(encoding="utf-8"))
    required = {"schema_version", "date_utc", "ingot_revision", "odin_revision", "workload", "environment", "scope"}
    missing = sorted(required - data.keys())
    if missing:
        raise SystemExit("missing fields: " + ", ".join(missing))
    if data["scope"].get("cpu_call_timings_are_gpu_timings") is not False:
        raise SystemExit("CPU-call timings must not be labeled GPU timings")
    print(f"validated {path}")


def main():
    args = arguments()
    selected = workload(args.workload)
    if args.command == "validate":
        validate(args.output)
        return
    built = build(args, selected)
    if args.command == "build":
        print(json.dumps(built, indent=2))
        return
    record = metadata(args, selected)
    record["artifact"] = built
    record["status"] = "fixture-built"
    record["note"] = "Runtime collection requires a dated operator-controlled native or browser run."
    args.output.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    print(args.output)


if __name__ == "__main__":
    main()
