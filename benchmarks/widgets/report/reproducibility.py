#!/usr/bin/env python3

import argparse
import json
import statistics
from collections import defaultdict
from pathlib import Path


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("first", type=Path)
    parser.add_argument("second", type=Path)
    parser.add_argument("--tolerance-percent", type=float, default=15.0)
    return parser.parse_args()


def medians(path):
    values = defaultdict(list)
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            record = json.loads(line)
            if not record["valid"] or record["workload"] == "capacity":
                continue
            key = (record["framework"], record["layer"], record["workload"], record["scale"])
            values[key].append(statistics.median(record["samples_ns"]["build"]))
    return {key: statistics.median(samples) for key, samples in values.items()}


def main():
    args = parse_args()
    if args.tolerance_percent <= 0:
        raise SystemExit("tolerance must be positive")
    first = medians(args.first)
    second = medians(args.second)
    if first.keys() != second.keys():
        raise SystemExit("reproducibility inputs have different case sets")
    failures = []
    for key in sorted(first):
        baseline = first[key]
        delta = 0.0 if baseline == 0 else abs(second[key] - baseline) * 100.0 / baseline
        if delta > args.tolerance_percent:
            failures.append((key, delta))
    if failures:
        for key, delta in failures:
            print(f"{key}: {delta:.2f}%", flush=True)
        raise SystemExit(1)
    print(f"reproducible: {len(first)} cases within {args.tolerance_percent:.2f}%")


if __name__ == "__main__":
    main()
