#!/usr/bin/env python3

import argparse
import json
import random
import sys
from pathlib import Path

import bench


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ui-binary", type=Path, required=True)
    parser.add_argument("--imgui-binary", type=Path, required=True)
    parser.add_argument("--case", action="append", type=bench.parse_case, required=True)
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
    for binary in (args.ui_binary, args.imgui_binary):
        if not binary.is_file():
            parser.error(f"binary does not exist: {binary}")
    return args


def validate_cases(cases):
    manifest = bench.load_json(bench.SUITE / "manifest.json")
    workloads = bench.load_json(bench.SUITE / manifest["workloads"])["workloads"]
    supported = {
        workload["id"]
        for workload in workloads
        if {"ingot", "imgui"}.issubset(
            workload.get("frameworks", ("ingot", "imgui", "egui"))
        ) and "ui" in workload.get("ingot_layers", ("fit", "ui"))
    }
    for workload, _ in cases:
        if workload not in supported:
            raise RuntimeError(f"workload does not support UI and ImGui: {workload}")


def main():
    args = parse_args()
    validate_cases(args.case)
    jobs = [
        (workload, scale, repetition)
        for workload, scale in args.case
        for repetition in range(args.repetitions)
    ]
    rng = random.Random(args.seed)
    rng.shuffle(jobs)
    binaries = {
        "ui": (args.ui_binary.resolve(), "ingot", "ui"),
        "imgui": (args.imgui_binary.resolve(), "imgui", "core"),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as handle:
        for pair_index, (workload, scale, repetition) in enumerate(jobs):
            order = ["ui", "imgui"]
            rng.shuffle(order)
            pair_id = f"ui_imgui:{workload}:{scale}:{repetition}:{pair_index}"
            for pair_order, variant in enumerate(order):
                binary, framework, layer = binaries[variant]
                record = bench.execute(
                    binary,
                    framework,
                    layer,
                    workload,
                    scale,
                    args.warmup,
                    args.frames,
                    repetition,
                    args.timeout,
                )
                record.update({
                    "pair_id": pair_id,
                    "pair_kind": "ui_imgui",
                    "variant": variant,
                    "pair_order": pair_order,
                })
                handle.write(json.dumps(record, separators=(",", ":"), sort_keys=True) + "\n")
                handle.flush()
    print(args.output.resolve())


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError) as error:
        print(f"UI/ImGui benchmark: {error}", file=sys.stderr)
        raise SystemExit(1)
