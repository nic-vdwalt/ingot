#!/usr/bin/env python3

import argparse
import hashlib
import json
import os
import platform
import random
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SUITE = ROOT / "benchmarks" / "widgets"
BUILD = SUITE / "build"
CACHE = SUITE / "cache"
RESULTS = SUITE / "results"
OUTPUT_LIMIT = 64 * 1024 * 1024


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("build", "smoke", "run", "validate"))
    parser.add_argument("--framework", choices=("all", "ingot", "imgui", "egui"), default="all")
    parser.add_argument("--workload")
    parser.add_argument("--scale", type=int)
    parser.add_argument("--warmup", type=int)
    parser.add_argument("--frames", type=int)
    parser.add_argument("--repetitions", type=int)
    parser.add_argument("--seed", type=int, default=12648430)
    parser.add_argument("--timeout", type=float, default=300.0)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.scale is not None and args.scale <= 0:
        parser.error("scale must be positive")
    if args.timeout <= 0:
        parser.error("timeout must be positive")
    return args


def load_json(path):
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def run_command(command, timeout=300, capture=True):
    completed = subprocess.run(
        command,
        cwd=ROOT,
        check=False,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        timeout=timeout,
        text=False,
    )
    output = completed.stdout or b""
    errors = completed.stderr or b""
    if len(output) + len(errors) > OUTPUT_LIMIT:
        raise RuntimeError(f"command output exceeded {OUTPUT_LIMIT} bytes")
    if completed.returncode != 0:
        detail = (output + errors)[-8192:].decode("utf-8", errors="replace")
        raise RuntimeError(f"command failed ({completed.returncode}): {' '.join(command)}\n{detail}")
    return output


def verify_font(manifest):
    font = ROOT / manifest["font"]["path"]
    digest = hashlib.sha256(font.read_bytes()).hexdigest()
    if digest != manifest["font"]["sha256"]:
        raise RuntimeError(f"font hash mismatch: {font}")


def ensure_imgui(manifest, timeout):
    framework = manifest["frameworks"]["imgui"]
    checkout = CACHE / "imgui"
    revision = framework["revision"]
    if not checkout.exists():
        CACHE.mkdir(parents=True, exist_ok=True)
        run_command([
            "git", "clone", "--quiet", framework["repository"], str(checkout)
        ], timeout=timeout)
    run_command(["git", "-C", str(checkout), "fetch", "--quiet", "--tags"], timeout=timeout)
    run_command(["git", "-C", str(checkout), "checkout", "--quiet", revision], timeout=timeout)
    actual = run_command(["git", "-C", str(checkout), "rev-parse", "HEAD"], timeout=timeout).decode().strip()
    if actual != revision:
        raise RuntimeError(f"Dear ImGui revision mismatch: {actual}")
    return checkout


def build_framework(framework, manifest, timeout):
    BUILD.mkdir(parents=True, exist_ok=True)
    if framework == "ingot":
        output = BUILD / "ingot-widget-bench"
        run_command([
            "odin", "build", "benchmarks/widgets/ingot", "-collection:ingot=.",
            "-o:speed", "-define:INGOT_UI_TELEMETRY=true", "-out:" + str(output),
        ], timeout=timeout)
        return output
    if framework == "imgui":
        checkout = ensure_imgui(manifest, timeout)
        output = BUILD / "imgui-widget-bench"
        sources = ["imgui.cpp", "imgui_draw.cpp", "imgui_tables.cpp", "imgui_widgets.cpp"]
        run_command([
            os.environ.get("CXX", "c++"), "-std=c++17", "-O3", "-DNDEBUG",
            "-I" + str(checkout), str(SUITE / "imgui" / "main.cpp"),
            *[str(checkout / source) for source in sources], "-o", str(output),
        ], timeout=timeout)
        return output
    if framework == "egui":
        run_command([
            "cargo", "build", "--release", "--locked", "--manifest-path",
            str(SUITE / "egui" / "Cargo.toml"),
        ], timeout=timeout)
        source = SUITE / "egui" / "target" / "release" / "egui-widget-bench"
        output = BUILD / "egui-widget-bench"
        shutil.copy2(source, output)
        return output
    raise RuntimeError(f"unsupported framework: {framework}")


def frameworks_for(selection):
    return [selection] if selection != "all" else ["ingot", "imgui", "egui"]


def build_all(selection, manifest, timeout):
    verify_font(manifest)
    return {framework: build_framework(framework, manifest, timeout)
            for framework in frameworks_for(selection)}


def workload_cases(args, manifest):
    workloads = load_json(SUITE / manifest["workloads"])["workloads"]
    cases = []
    for workload in workloads:
        if args.workload and workload["id"] != args.workload:
            continue
        scales = [args.scale] if args.scale is not None else workload["scales"]
        cases.extend((workload["id"], scale) for scale in scales)
    if not cases:
        raise RuntimeError("no workload cases selected")
    return cases


def environment_metadata():
    return {
        "os": platform.platform(),
        "arch": platform.machine(),
        "cpu": platform.processor() or "unknown",
        "python": sys.version.split()[0],
        "display": os.environ.get("INGOT_BENCH_DISPLAY", "1280x720@unknown"),
        "power_mode": os.environ.get("INGOT_BENCH_POWER_MODE", "unknown"),
    }


def validate_record(record, framework, workload, scale, frames):
    required = {
        "schema_version", "framework", "framework_revision", "backend", "layer",
        "workload", "scale", "repetition", "warmup_frames", "measured_frames",
        "valid", "state_checksum", "samples_ns", "output", "environment",
    }
    missing = sorted(required - record.keys())
    if missing:
        raise RuntimeError(f"missing result fields: {missing}")
    if record["framework"] != framework or record["workload"] != workload or record["scale"] != scale:
        raise RuntimeError("result identity mismatch")
    for phase in ("build", "finalize"):
        if len(record["samples_ns"].get(phase, [])) != frames:
            raise RuntimeError(f"unexpected {phase} sample count")
    output = record["output"]
    if workload != "capacity" and (output["dropped_commands"] or output["dropped_text_bytes"]):
        raise RuntimeError("nominal workload dropped output")
    if not record["valid"] and workload != "capacity":
        raise RuntimeError(f"invalid sample: {record.get('invalid_reason', '')}")


def execute(binary, framework, workload, scale, warmup, frames, repetition, timeout):
    command = [
        str(binary), f"--workload={workload}", f"--scale={scale}",
        f"--warmup={warmup}", f"--frames={frames}", f"--repetition={repetition}",
    ]
    started = time.monotonic_ns()
    raw = run_command(command, timeout=timeout)
    elapsed = time.monotonic_ns() - started
    try:
        record = json.loads(raw)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"invalid JSON from {framework}: {error}") from error
    validate_record(record, framework, workload, scale, frames)
    record["process_wall_ns"] = elapsed
    record["runner_environment"] = environment_metadata()
    return record


def result_path(args, command):
    if args.output:
        return args.output.resolve()
    RESULTS.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
    return RESULTS / f"{command}-{stamp}.jsonl"


def run_suite(args, manifest, smoke):
    binaries = build_all(args.framework, manifest, args.timeout)
    cases = workload_cases(args, manifest)
    if smoke:
        cases = cases[:1]
    collection = manifest["collection"]
    warmup = args.warmup if args.warmup is not None else (2 if smoke else collection["warmup_frames"])
    frames = args.frames if args.frames is not None else (3 if smoke else collection["measured_frames"])
    repetitions = args.repetitions if args.repetitions is not None else (1 if smoke else collection["repetitions"])
    jobs = [(framework, workload, scale, repetition)
            for workload, scale in cases
            for repetition in range(repetitions)
            for framework in binaries]
    random.Random(args.seed).shuffle(jobs)
    output = result_path(args, "smoke" if smoke else "run")
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as handle:
        for framework, workload, scale, repetition in jobs:
            record = execute(
                binaries[framework], framework, workload, scale, warmup,
                frames, repetition, args.timeout,
            )
            handle.write(json.dumps(record, separators=(",", ":"), sort_keys=True) + "\n")
            handle.flush()
    print(output)


def validate_results(path):
    records = []
    with path.open(encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            try:
                record = json.loads(line)
            except json.JSONDecodeError as error:
                raise RuntimeError(f"{path}:{line_number}: {error}") from error
            validate_record(
                record, record["framework"], record["workload"],
                record["scale"], record["measured_frames"],
            )
            records.append(record)
    if not records:
        raise RuntimeError("result file is empty")
    print(f"validated {len(records)} records")


def main():
    args = parse_args()
    manifest = load_json(SUITE / "manifest.json")
    if args.command == "build":
        binaries = build_all(args.framework, manifest, args.timeout)
        for framework, path in binaries.items():
            print(f"{framework}: {path}")
    elif args.command == "smoke":
        run_suite(args, manifest, True)
    elif args.command == "run":
        run_suite(args, manifest, False)
    else:
        if not args.output:
            raise RuntimeError("validate requires --output PATH")
        validate_results(args.output.resolve())


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"widget benchmark: {error}", file=sys.stderr)
        raise SystemExit(1)
