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
            if record.get("pair_kind") != "ui_imgui":
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
    if set(variants) != {"ui", "imgui"}:
        raise RuntimeError(f"{pair_id}: invalid variants")
    direct = variants["ui"]
    imgui = variants["imgui"]
    if direct["framework"] != "ingot" or direct["layer"] != "ui":
        raise RuntimeError(f"{pair_id}: direct UI identity mismatch")
    if imgui["framework"] != "imgui" or imgui["layer"] != "core":
        raise RuntimeError(f"{pair_id}: ImGui identity mismatch")
    for field in ("workload", "scale", "state_checksum"):
        if direct[field] != imgui[field]:
            raise RuntimeError(f"{pair_id}: mismatch for {field}")
    if direct["output"]["submitted_widgets"] != imgui["output"]["submitted_widgets"]:
        raise RuntimeError(f"{pair_id}: submitted widget mismatch")
    for record in (direct, imgui):
        if not record.get("valid"):
            raise RuntimeError(f"{pair_id}: invalid nominal record")
        output = record["output"]
        if output["dropped_commands"] or output["dropped_text_bytes"]:
            raise RuntimeError(f"{pair_id}: nominal dropped output")
        if not record["samples_ns"].get("frame"):
            raise RuntimeError(f"{pair_id}: missing frame samples")
    return direct, imgui


def summarize(records, seed):
    pairs = defaultdict(list)
    for record in records:
        pairs[record["pair_id"]].append(record)
    grouped = defaultdict(list)
    for pair_id, pair in pairs.items():
        direct, imgui = validate_pair(pair_id, pair)
        grouped[(direct["workload"], direct["scale"])].append((direct, imgui))
    rows = []
    for index, key in enumerate(sorted(grouped)):
        ratios = []
        deltas = []
        observations = []
        for direct, imgui in grouped[key]:
            ui_frame = phase_median(direct, "frame")
            imgui_frame = phase_median(imgui, "frame")
            ratios.append(ui_frame / imgui_frame)
            deltas.append(ui_frame - imgui_frame)
            observations.append({
                "ui_frame_ns": ui_frame,
                "imgui_frame_ns": imgui_frame,
                "ui_build_ns": phase_median(direct, "build"),
                "ui_finalize_ns": phase_median(direct, "finalize"),
                "imgui_build_ns": phase_median(imgui, "build"),
                "imgui_finalize_ns": phase_median(imgui, "finalize"),
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
            "ui_frame_median_ns": statistics.median(
                item["ui_frame_ns"] for item in observations
            ),
            "imgui_frame_median_ns": statistics.median(
                item["imgui_frame_ns"] for item in observations
            ),
            "observations": observations,
        })
    return rows


def median_observation(row, field):
    return statistics.median(item[field] for item in row["observations"])


def write_markdown(rows, path):
    lines = [
        "# Direct Ingot UI vs Dear ImGui Paired Evidence",
        "",
        "Ratios use adjacent fresh-process complete-frame medians. Values below 1.0 mean direct Ingot UI is faster.",
        "",
        "| Workload | Scale | Pairs | UI median (µs) | ImGui median (µs) | UI/ImGui | Paired 95% CI | Delta (µs) |",
        "|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for row in rows:
        lines.append(
            f"| {row['workload']} | {row['scale']} | {row['pairs']} | "
            f"{row['ui_frame_median_ns'] / 1000:.2f} | "
            f"{row['imgui_frame_median_ns'] / 1000:.2f} | "
            f"{row['median_ratio']:.4f} | "
            f"{row['ci95_low']:.4f}–{row['ci95_high']:.4f} | "
            f"{row['median_delta_ns'] / 1000:.2f} |"
        )
    lines.extend([
        "",
        "| Workload | Scale | UI submission (µs) | UI finalize (µs) | ImGui build (µs) | ImGui finalize (µs) |",
        "|---|---:|---:|---:|---:|---:|",
    ])
    for row in rows:
        lines.append(
            f"| {row['workload']} | {row['scale']} | "
            f"{median_observation(row, 'ui_build_ns') / 1000:.2f} | "
            f"{median_observation(row, 'ui_finalize_ns') / 1000:.2f} | "
            f"{median_observation(row, 'imgui_build_ns') / 1000:.2f} | "
            f"{median_observation(row, 'imgui_finalize_ns') / 1000:.2f} |"
        )
    lines.extend([
        "",
        "Only complete `frame` ratios are cross-framework evidence. Internal phases are descriptive and not primitive-equivalent.",
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
        print(f"UI/ImGui report: {error}", file=sys.stderr)
        raise SystemExit(1)
