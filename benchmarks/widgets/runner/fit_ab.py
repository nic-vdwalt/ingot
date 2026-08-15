#!/usr/bin/env python3

import argparse
import json
import random
import sys
from pathlib import Path

import bench


def parse_case(value):
    workload, separator, scale = value.partition(":")
    if not separator or not workload:
        raise argparse.ArgumentTypeError("case must be workload:scale")
    try:
        scale = int(scale)
    except ValueError as error:
        raise argparse.ArgumentTypeError("case scale must be an integer") from error
    if scale <= 0:
        raise argparse.ArgumentTypeError("case scale must be positive")
    return workload, scale


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--case", action="append", type=parse_case, required=True)
    parser.add_argument("--warmup", type=int, default=300)
    parser.add_argument("--frames", type=int, default=2000)
    parser.add_argument("--repetitions", type=int, default=7)
    parser.add_argument("--seed", type=int, default=12648430)
    parser.add_argument("--timeout", type=float, default=300.0)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.warmup < 0 or args.frames <= 0 or args.repetitions <= 0:
        parser.error("invalid collection size")
    if args.timeout <= 0:
        parser.error("timeout must be positive")
    for binary in (args.baseline, args.candidate):
        if not binary.is_file():
            parser.error(f"binary does not exist: {binary}")
    return args


def execute(binary, workload, scale, warmup, frames, repetition, timeout, cache_mode=None):
    command = [
        str(binary),
        f"--workload={workload}",
        f"--scale={scale}",
        f"--warmup={warmup}",
        f"--frames={frames}",
        f"--repetition={repetition}",
    ]
    if cache_mode is not None:
        command.append(f"--measure-cache={cache_mode}")
    raw = bench.run_command(command, timeout=timeout)
    try:
        record = json.loads(raw)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"invalid JSON from {binary}: {error}") from error
    for field in ("framework", "framework_revision", "backend", "layer", "workload", "invalid_reason"):
        if isinstance(record.get(field), str):
            record[field] = record[field].strip()
    for field in ("os", "arch", "cpu", "toolchain"):
        if isinstance(record.get("environment", {}).get(field), str):
            record["environment"][field] = record["environment"][field].strip()
    bench.validate_record(record, "ingot", workload, scale, frames)
    record["runner_environment"] = bench.environment_metadata()
    return record


def write_pair(handle, rng, args, workload, scale, repetition, pair_kind):
    pair_id = f"{pair_kind}:{workload}:{scale}:{repetition}"
    if pair_kind == "revision":
        arms = [
            ("baseline", args.baseline, None),
            ("candidate", args.candidate, "enabled"),
        ]
    else:
        arms = [
            ("enabled", args.candidate, "enabled"),
            ("bypassed", args.candidate, "bypassed"),
        ]
    rng.shuffle(arms)
    for pair_order, (variant, binary, cache_mode) in enumerate(arms):
        record = execute(
            binary.resolve(),
            workload,
            scale,
            args.warmup,
            args.frames,
            repetition,
            args.timeout,
            cache_mode,
        )
        record["pair_id"] = pair_id
        record["pair_kind"] = pair_kind
        record["variant"] = variant
        record["pair_order"] = pair_order
        record["cache_mode"] = cache_mode or "legacy-default"
        handle.write(json.dumps(record, separators=(",", ":"), sort_keys=True) + "\n")
        handle.flush()


def main():
    args = parse_args()
    rng = random.Random(args.seed)
    jobs = [
        (workload, scale, repetition, pair_kind)
        for repetition in range(args.repetitions)
        for workload, scale in args.case
        for pair_kind in (("cache",) if workload == "input_active" else ("revision", "cache"))
    ]
    rng.shuffle(jobs)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as handle:
        for job in jobs:
            write_pair(handle, rng, args, *job)
    print(args.output.resolve())


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError) as error:
        print(f"Fit A/B benchmark: {error}", file=sys.stderr)
        raise SystemExit(1)
