#!/usr/bin/env python3

import argparse
import json
import math
import random
import statistics
import sys
from collections import defaultdict
from pathlib import Path

BOOTSTRAP_ITERATIONS = 10000


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--seed", type=int, default=12648430)
    return parser.parse_args()


def percentile(values, quantile):
    ordered = sorted(values)
    position = (len(ordered) - 1) * quantile
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return float(ordered[lower])
    weight = position - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def bootstrap_median(values, seed):
    if len(values) == 1:
        return values[0], values[0]
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
            try:
                record = json.loads(line)
            except json.JSONDecodeError as error:
                raise RuntimeError(f"{path}:{line_number}: {error}") from error
            if not record.get("valid"):
                raise RuntimeError(f"invalid record at line {line_number}")
            output = record["output"]
            if output["dropped_commands"] or output["dropped_text_bytes"]:
                raise RuntimeError(f"dropped output at line {line_number}")
            records.append(record)
    if not records:
        raise RuntimeError("no records")
    return records


def require_match(left, right):
    if left["workload"] != right["workload"] or left["scale"] != right["scale"]:
        raise RuntimeError(f"{left['pair_id']}: identity mismatch")
    if left["state_checksum"] != right["state_checksum"]:
        raise RuntimeError(f"{left['pair_id']}: state checksum mismatch")
    for field in ("submitted_widgets", "visible_widgets", "paint_commands", "text_bytes"):
        if left["output"][field] != right["output"][field]:
            raise RuntimeError(f"{left['pair_id']}: output mismatch for {field}")


def phase_median(record, phase):
    values = record["samples_ns"].get(phase, [])
    return statistics.median(values) if values else 0.0


def summarize(records, seed):
    pairs = defaultdict(list)
    for record in records:
        pairs[record["pair_id"]].append(record)
    ratios = defaultdict(list)
    attribution = defaultdict(list)
    for pair_id, pair in pairs.items():
        if len(pair) != 2 or {record["pair_order"] for record in pair} != {0, 1}:
            raise RuntimeError(f"{pair_id}: incomplete pair")
        first, second = pair
        require_match(first, second)
        by_variant = {record["variant"]: record for record in pair}
        pair_kind = first["pair_kind"]
        if pair_kind == "revision":
            denominator = by_variant["baseline"]
            numerator = by_variant["candidate"]
        elif pair_kind == "cache":
            denominator = by_variant["enabled"]
            numerator = by_variant["bypassed"]
        else:
            raise RuntimeError(f"{pair_id}: unknown pair kind")
        key = (pair_kind, first["workload"], first["scale"])
        ratios[key].append(phase_median(numerator, "frame") / phase_median(denominator, "frame"))
        attribution[key].append({
            "denominator_frame_ns": phase_median(denominator, "frame"),
            "numerator_frame_ns": phase_median(numerator, "frame"),
            "denominator_measure_ns": phase_median(denominator, "measure"),
            "numerator_measure_ns": phase_median(numerator, "measure"),
            "denominator_layout_render_ns": phase_median(denominator, "layout_render"),
            "numerator_layout_render_ns": phase_median(numerator, "layout_render"),
            "denominator_telemetry": denominator.get("telemetry", {}),
            "numerator_telemetry": numerator.get("telemetry", {}),
        })
    rows = []
    for index, key in enumerate(sorted(ratios)):
        values = ratios[key]
        low, high = bootstrap_median(values, seed + index)
        rows.append({
            "pair_kind": key[0],
            "workload": key[1],
            "scale": key[2],
            "pairs": len(values),
            "median_ratio": statistics.median(values),
            "ci95_low": low,
            "ci95_high": high,
            "attribution": attribution[key],
        })
    return rows


def accepted(rows):
    dashboard = next(
        (row for row in rows if row["pair_kind"] == "revision" and
         row["workload"] == "complex_dashboard" and row["scale"] == 50),
        None,
    )
    if dashboard is None or dashboard["median_ratio"] > 0.95 or dashboard["ci95_high"] >= 1.0:
        return False
    return all(
        row["median_ratio"] <= 1.03
        for row in rows
        if row["pair_kind"] == "revision" and row is not dashboard
    )


def write_markdown(rows, passed, path):
    lines = [
        "# Fit Paired A/B Evidence",
        "",
        f"Acceptance: **{'PASS' if passed else 'FAIL'}**",
        "",
        "Ratios use paired fresh-process complete-frame medians. Values below 1.0 favor the numerator.",
        "",
        "| Pair | Workload | Scale | Pairs | Median ratio | 95% CI |",
        "|---|---|---:|---:|---:|---:|",
    ]
    for row in rows:
        lines.append(
            f"| {row['pair_kind']} | {row['workload']} | {row['scale']} | {row['pairs']} | "
            f"{row['median_ratio']:.4f} | {row['ci95_low']:.4f}–{row['ci95_high']:.4f} |"
        )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    args = parse_args()
    rows = summarize(load_records(args.input), args.seed)
    passed = accepted(rows)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    payload = {"accepted": passed, "rows": rows}
    (args.output_dir / "paired.json").write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    write_markdown(rows, passed, args.output_dir / "report.md")
    print(args.output_dir.resolve())
    if not passed:
        raise SystemExit(2)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError) as error:
        print(f"Fit A/B report: {error}", file=sys.stderr)
        raise SystemExit(1)
