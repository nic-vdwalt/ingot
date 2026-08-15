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
            if record.get("pair_kind") != "ingot_layer":
                raise RuntimeError(f"unexpected pair kind at line {line_number}")
            records.append(record)
    if not records:
        raise RuntimeError("no records")
    return records


def phase_median(record, phase):
    values = record["samples_ns"].get(phase, [])
    return statistics.median(values) if values else 0.0


def validate_pair(pair_id, records):
    if len(records) != 2 or {record["pair_order"] for record in records} != {0, 1}:
        raise RuntimeError(f"{pair_id}: incomplete pair")
    variants = {record["variant"]: record for record in records}
    if set(variants) != {"fit", "ui"}:
        raise RuntimeError(f"{pair_id}: invalid variants")
    fit = variants["fit"]
    direct = variants["ui"]
    if fit["layer"] != "fit" or direct["layer"] != "ui":
        raise RuntimeError(f"{pair_id}: layer mismatch")
    for field in ("workload", "scale", "state_checksum"):
        if fit[field] != direct[field]:
            raise RuntimeError(f"{pair_id}: mismatch for {field}")
    for field in ("submitted_widgets", "visible_widgets"):
        if fit["output"][field] != direct["output"][field]:
            raise RuntimeError(f"{pair_id}: output mismatch for {field}")
    for record in (fit, direct):
        if not record.get("valid"):
            raise RuntimeError(f"{pair_id}: invalid nominal record")
        output = record["output"]
        if output["dropped_commands"] or output["dropped_text_bytes"]:
            raise RuntimeError(f"{pair_id}: nominal dropped output")
        if not record["samples_ns"].get("frame"):
            raise RuntimeError(f"{pair_id}: missing frame samples")
    return fit, direct


def summarize(records, seed):
    pairs = defaultdict(list)
    for record in records:
        pairs[record["pair_id"]].append(record)
    grouped = defaultdict(list)
    for pair_id, pair in pairs.items():
        fit, direct = validate_pair(pair_id, pair)
        grouped[(fit["workload"], fit["scale"])].append((fit, direct))
    rows = []
    for index, key in enumerate(sorted(grouped)):
        ratios = []
        deltas = []
        attribution = []
        for fit, direct in grouped[key]:
            fit_frame = phase_median(fit, "frame")
            ui_frame = phase_median(direct, "frame")
            ratios.append(fit_frame / ui_frame)
            deltas.append(fit_frame - ui_frame)
            attribution.append({
                "fit_frame_ns": fit_frame,
                "ui_frame_ns": ui_frame,
                "fit_build_ns": phase_median(fit, "build"),
                "fit_measure_ns": phase_median(fit, "measure"),
                "fit_layout_render_ns": phase_median(fit, "layout_render"),
                "fit_finalize_ns": phase_median(fit, "frame_finalize"),
                "ui_build_ns": phase_median(direct, "build"),
                "ui_finalize_ns": phase_median(direct, "finalize"),
                "fit_output": fit["output"],
                "ui_output": direct["output"],
            })
        low, high = bootstrap_median(ratios, seed + index)
        rows.append({
            "workload": key[0],
            "scale": key[1],
            "pairs": len(ratios),
            "median_ratio": statistics.median(ratios),
            "median_delta_ns": statistics.median(deltas),
            "ci95_low": low,
            "ci95_high": high,
            "fit_frame_median_ns": statistics.median(item["fit_frame_ns"] for item in attribution),
            "ui_frame_median_ns": statistics.median(item["ui_frame_ns"] for item in attribution),
            "attribution": attribution,
        })
    return rows


def median_attribution(row, field):
    return statistics.median(item[field] for item in row["attribution"])


def write_markdown(rows, path):
    lines = [
        "# Ingot Fit vs Direct UI Paired Evidence",
        "",
        "Ratios use adjacent fresh-process complete-frame medians. Values above 1.0 mean Fit is slower.",
        "",
        "## Complete-frame Fit vs direct UI",
        "",
        "| Workload | Scale | Pairs | Fit median (µs) | UI median (µs) | Fit/UI | Paired 95% CI | Delta (µs) |",
        "|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for row in rows:
        lines.append(
            f"| {row['workload']} | {row['scale']} | {row['pairs']} | "
            f"{row['fit_frame_median_ns'] / 1000:.2f} | {row['ui_frame_median_ns'] / 1000:.2f} | "
            f"{row['median_ratio']:.4f} | {row['ci95_low']:.4f}–{row['ci95_high']:.4f} | "
            f"{row['median_delta_ns'] / 1000:.2f} |"
        )
    lines.extend([
        "",
        "## API-scope attribution",
        "",
        "| Workload | Scale | Fit description build (µs) | Fit measure (µs) | Fit layout/render (µs) | Fit core finalize (µs) | UI submission (µs) | UI finalize (µs) | Fit/UI paint commands | Fit/UI text bytes |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ])
    for row in rows:
        fit_output = row["attribution"][0]["fit_output"]
        ui_output = row["attribution"][0]["ui_output"]
        lines.append(
            f"| {row['workload']} | {row['scale']} | "
            f"{median_attribution(row, 'fit_build_ns') / 1000:.2f} | "
            f"{median_attribution(row, 'fit_measure_ns') / 1000:.2f} | "
            f"{median_attribution(row, 'fit_layout_render_ns') / 1000:.2f} | "
            f"{median_attribution(row, 'fit_finalize_ns') / 1000:.2f} | "
            f"{median_attribution(row, 'ui_build_ns') / 1000:.2f} | "
            f"{median_attribution(row, 'ui_finalize_ns') / 1000:.2f} | "
            f"{fit_output['paint_commands']}/{ui_output['paint_commands']} | "
            f"{fit_output['text_bytes']}/{ui_output['text_bytes']} |"
        )
    lines.extend([
        "",
        "Internal columns are descriptive and are not primitive-equivalent. Only complete `frame` ratios are cross-package performance evidence. Paint-command differences are reported rather than treated as conformance failures.",
        "",
    ])
    path.write_text("\n".join(lines), encoding="utf-8")


def main():
    args = parse_args()
    rows = summarize(load_records(args.input), args.seed)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    (args.output_dir / "paired.json").write_text(
        json.dumps({"rows": rows}, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    write_markdown(rows, args.output_dir / "report.md")
    print(args.output_dir.resolve())


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError) as error:
        print(f"Ingot layer report: {error}", file=sys.stderr)
        raise SystemExit(1)
