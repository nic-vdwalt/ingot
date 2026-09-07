"""Classify replay runs (pinned WebGPU replay and native Metal controls).

Each run is a JSONL file: a header, per-iteration `sample` records and a
footer. Samples carry the raw begin/end ticks the run's readback returned and
the prior physical contents of the same readback slot. The evaluator never
treats an ordered pair as a valid duration by itself: it also tests the
stale-by-one-pass signature, where the end tick of iteration N equals the end
of iteration N-1 (begin(N-1) plus that pass's duration), which is what an
in-command-buffer GPU resolve of a stage-boundary counter returned on the
inspected device.
"""
import argparse
import hashlib
import json
import statistics
from pathlib import Path

CLASSES = ("ordered", "zero_end", "reversed_nonzero", "reversed_prior_slot_value",
           "ordered_but_stale", "map_failed", "failed_command")
# A stale end lands within this tolerance of the previous pass's own end.
STALE_TOLERANCE_NS = 50_000


def load_run(path):
    records = [json.loads(line) for line in Path(path).read_text().splitlines() if line]
    if not records or records[0].get("kind") != "header" or records[-1].get("kind") != "footer":
        raise ValueError("run is not a complete header/samples/footer file")
    return records


def sample_ticks(sample):
    if "gpu_begin" in sample:
        return sample["gpu_begin"], sample["gpu_end"]
    return sample["begin"], sample["end"]


def evaluate_run(records):
    header, footer = records[0], records[-1]
    samples = sorted((r for r in records if r.get("kind") == "sample"),
                     key=lambda r: r["iteration"])
    counts = {name: 0 for name in CLASSES}
    for sample in samples:
        counts[sample["class"]] = counts.get(sample["class"], 0) + 1
    stale_lags = []
    durations = []
    for previous, current in zip(samples[:-1], samples[1:]):
        begin, end = sample_ticks(current)
        prior_begin, _ = sample_ticks(previous)
        if end and end < begin:
            stale_lags.append(end - prior_begin)
        elif end and end > begin:
            durations.append(end - begin)
    stale_by_one_pass = 0
    if stale_lags and durations:
        typical = statistics.median(durations)
        stale_by_one_pass = sum(1 for lag in stale_lags
                                if abs(lag - typical) <= STALE_TOLERANCE_NS)
    other = {kind: 0 for kind in ("error", "command_failed", "acquire", "no_free_slot",
                                  "attachment_mismatch")}
    for record in records:
        if record.get("kind") in other:
            other[record["kind"]] += 1
    return {
        "mode": header.get("mode", "webgpu_pinned_replay"),
        "frame": header.get("frame"),
        "iterations": header.get("iterations"),
        "samples": len(samples),
        "classes": counts,
        "reversed_total": counts["reversed_nonzero"] + counts["reversed_prior_slot_value"],
        "stale_by_one_pass": stale_by_one_pass,
        "median_duration_ns": int(statistics.median(durations)) if durations else None,
        "median_stale_lag_ns": int(statistics.median(stale_lags)) if stale_lags else None,
        "other_records": other,
        "drained": footer.get("drained"),
        "command_failures": footer.get("command_failures"),
    }


def candidate_passes(summary):
    """A backend or driver candidate only passes when the captured pass
    replays with every sample ordered after the first use and nothing
    stale; the first sample may be a zero end when the counter storage was
    never written before."""
    counts = summary["classes"]
    first_use_zero = 1 if counts["zero_end"] == 1 else 0
    return (summary["samples"] > 0 and summary["drained"] is True
            and summary["command_failures"] == 0
            and summary["reversed_total"] == 0
            and counts["ordered_but_stale"] == 0
            and counts["map_failed"] == 0 and counts["failed_command"] == 0
            and counts["zero_end"] == first_use_zero
            and summary["stale_by_one_pass"] == 0)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("runs", nargs="+")
    parser.add_argument("--manifest")
    arguments = parser.parse_args()
    results = {}
    for run in arguments.runs:
        records = load_run(run)
        summary = evaluate_run(records)
        summary["candidate_passes"] = candidate_passes(summary)
        summary["sha256"] = hashlib.sha256(Path(run).read_bytes()).hexdigest()
        results[Path(run).name] = summary
    text = json.dumps(results, indent=1)
    if arguments.manifest:
        Path(arguments.manifest).write_text(text)
    print(text)


if __name__ == "__main__":
    main()
