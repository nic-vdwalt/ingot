#!/usr/bin/env python3

import argparse
import csv
import json
import math
import random
import statistics
from collections import defaultdict
from pathlib import Path

BOOTSTRAP_ITERATIONS = 2000


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--seed", type=int, default=12648430)
    return parser.parse_args()


def percentile(values, quantile):
    if not values:
        return 0.0
    ordered = sorted(values)
    position = (len(ordered) - 1) * quantile
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return float(ordered[lower])
    weight = position - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def bootstrap_interval(values, seed):
    if not values:
        return 0.0, 0.0
    if len(values) == 1:
        return float(values[0]), float(values[0])
    rng = random.Random(seed)
    estimates = []
    for _ in range(BOOTSTRAP_ITERATIONS):
        sample = [values[rng.randrange(len(values))] for _ in values]
        estimates.append(statistics.median(sample))
    return percentile(estimates, 0.025), percentile(estimates, 0.975)


def load_records(path):
    records = []
    with path.open(encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            record = json.loads(line)
            if record.get("valid") or record.get("workload") == "capacity":
                records.append(record)
            else:
                raise RuntimeError(f"invalid nominal record at line {line_number}")
    if not records:
        raise RuntimeError("no records")
    return records


def phase_statistics(samples):
    return {
        "median_ns": statistics.median(samples),
        "p95_ns": percentile(samples, 0.95),
        "p99_ns": percentile(samples, 0.99),
        "min_ns": min(samples),
        "max_ns": max(samples),
        "mean_ns": statistics.mean(samples),
        "stddev_ns": statistics.pstdev(samples),
    }


def aggregate(records, seed):
    groups = defaultdict(list)
    for record in records:
        key = (
            record["framework"], record["framework_revision"], record["backend"],
            record["layer"], record["workload"], record["scale"],
        )
        groups[key].append(record)
    rows = []
    for key, group in sorted(groups.items()):
        phases = sorted({phase for record in group for phase in record["samples_ns"]})
        for phase in phases:
            samples = [sample for record in group for sample in record["samples_ns"].get(phase, [])]
            if not samples:
                continue
            process_medians = [statistics.median(record["samples_ns"][phase]) for record in group]
            low, high = bootstrap_interval(process_medians, seed + len(rows))
            stats = phase_statistics(samples)
            submitted = statistics.median(record["output"]["submitted_widgets"] for record in group)
            stats.update({
                "framework": key[0], "framework_revision": key[1], "backend": key[2],
                "layer": key[3], "workload": key[4], "scale": key[5], "phase": phase,
                "repetitions": len(group), "sample_count": len(samples),
                "ci95_low_ns": low, "ci95_high_ns": high,
                "submitted_widgets": submitted,
                "throughput_widgets_per_second": 0 if stats["median_ns"] == 0 else submitted * 1e9 / stats["median_ns"],
            })
            rows.append(stats)
    return rows


def write_csv(rows, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    fields = [
        "framework", "framework_revision", "backend", "layer", "workload", "scale",
        "phase", "repetitions", "sample_count", "median_ns", "p95_ns", "p99_ns",
        "min_ns", "max_ns", "mean_ns", "stddev_ns", "ci95_low_ns", "ci95_high_ns",
        "submitted_widgets", "throughput_widgets_per_second",
    ]
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def capacity_rows(records):
    groups = defaultdict(list)
    for record in records:
        if record["workload"] == "capacity":
            groups[record["framework"]].append(record)
    rows = []
    for framework, group in sorted(groups.items()):
        valid = [record["scale"] for record in group if record["valid"]]
        invalid = [record["scale"] for record in group if not record["valid"]]
        rows.append({
            "framework": framework,
            "last_valid_scale": max(valid) if valid else 0,
            "first_invalid_scale": min(invalid) if invalid else 0,
        })
    return rows


def write_markdown(rows, records, path):
    grouped = defaultdict(dict)
    for row in rows:
        key = (row["framework"], row["framework_revision"], row["workload"], row["scale"])
        grouped[key][row["phase"]] = row
    lines = [
        "# Widget Benchmark Report", "",
        "CPU phases use each adapter's recorded boundaries. Total comparisons use frame-to-frame",
        "values only; this report does not compute an overall winner.", "",
        "## Core frame latency", "",
        "| Framework | Revision | Workload | Scale | Total median/p95 (µs) | Build median/p95 (µs) | Finalize median/p95 (µs) |",
        "|---|---|---|---:|---:|---:|---:|",
    ]
    for key, phases in sorted(grouped.items()):
        build = phases.get("build")
        finalize = phases.get("finalize")
        frame = phases.get("frame")
        if build is None or finalize is None:
            continue
        total = "-" if frame is None else f"{frame['median_ns'] / 1000:.2f}/{frame['p95_ns'] / 1000:.2f}"
        lines.append(
            f"| {key[0]} | `{key[1][:12]}` | {key[2]} | {key[3]} | {total} | "
            f"{build['median_ns'] / 1000:.2f}/{build['p95_ns'] / 1000:.2f} | "
            f"{finalize['median_ns'] / 1000:.2f}/{finalize['p95_ns'] / 1000:.2f} |"
        )
    lines.extend([
        "", "## Fit phase breakdown", "",
        "| Workload | Scale | Measure median/p95 (µs) | Layout/render median/p95 (µs) | Frame finalize median/p95 (µs) |",
        "|---|---:|---:|---:|---:|",
    ])
    for key, phases in sorted(grouped.items()):
        if key[0] != "ingot" or "measure" not in phases or "layout_render" not in phases:
            continue
        measure = phases["measure"]
        render = phases["layout_render"]
        frame_finalize = phases.get("frame_finalize")
        finalize_text = "-" if frame_finalize is None else (
            f"{frame_finalize['median_ns'] / 1000:.2f}/{frame_finalize['p95_ns'] / 1000:.2f}"
        )
        lines.append(
            f"| {key[2]} | {key[3]} | {measure['median_ns'] / 1000:.2f}/{measure['p95_ns'] / 1000:.2f} | "
            f"{render['median_ns'] / 1000:.2f}/{render['p95_ns'] / 1000:.2f} | {finalize_text} |"
        )
    capacities = capacity_rows(records)
    lines.extend(["", "## Capacity validity", "", "| Framework | Last valid | First invalid |", "|---|---:|---:|"])
    for row in capacities:
        lines.append(f"| {row['framework']} | {row['last_valid_scale']} | {row['first_invalid_scale']} |")
    lines.extend([
        "", "## Interpretation", "",
        "- Invalid or dropped-output nominal samples are rejected before aggregation.",
        "- Capacity runs are retained only in the capacity table and are not timing wins.",
        "- CPU, renderer work, memory, startup, idle, and accessibility evidence must remain separate.",
        "- Compare runs only when their recorded environment and manifest revisions match.", "",
    ])
    path.write_text("\n".join(lines), encoding="utf-8")


def main():
    args = parse_args()
    records = load_records(args.input)
    rows = aggregate(records, args.seed)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    write_csv(rows, args.output_dir / "aggregate.csv")
    write_markdown(rows, records, args.output_dir / "report.md")
    (args.output_dir / "aggregate.json").write_text(
        json.dumps(rows, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


if __name__ == "__main__":
    main()
