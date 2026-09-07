"""Classify replay runs and decide the Metal counter-publication mechanism."""
import argparse
import hashlib
import json
import statistics
from pathlib import Path

CLASSES = ("ordered", "zero_end", "reversed_nonzero", "reversed_prior_slot_value",
           "ordered_but_stale", "map_failed", "failed_command")
STALE_TOLERANCE_NS = 50_000
STAGE_NAMES = ("start_of_vertex", "end_of_vertex", "start_of_fragment", "end_of_fragment")


def load_run(path):
    records = [json.loads(line) for line in Path(path).read_text().splitlines() if line]
    if not records or records[0].get("kind") != "header" or records[-1].get("kind") != "footer":
        raise ValueError("run is not a complete header/samples/footer file")
    return records


def sample_ticks(sample):
    if "gpu_begin" in sample:
        return sample["gpu_begin"], sample["gpu_end"]
    return sample["begin"], sample["end"]


def percentile(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(0, int(len(ordered) * fraction + 0.999999) - 1)]


def publication_summary(records):
    publications = [record for record in records if record.get("kind") == "publication"]
    observed = [record for record in publications if record.get("first_new_end_host_ns", 0) > 0]
    sample_lags = [record["first_new_end_host_ns"] - record["end_sample_ns"]
                   for record in observed if record.get("end_sample_ns", 0) > 0]
    gpu_end_lags = [record["first_new_end_host_ns"] - record["gpu_end_ns"]
                    for record in observed if record.get("gpu_end_ns", 0) > 0]
    completion_lags = [record["first_new_end_host_ns"] - record["completed_host_ns"]
                       for record in observed if record.get("completed_host_ns", 0) > 0]
    return {
        "records": len(publications),
        "observed": len(observed),
        "before_gpu_end": sum(value < 0 for value in gpu_end_lags),
        "at_or_after_gpu_end": sum(value >= 0 for value in gpu_end_lags),
        "before_completion": sum(value < 0 for value in completion_lags),
        "at_or_after_completion": sum(value >= 0 for value in completion_lags),
        "sample_to_publication_ns_median": int(statistics.median(sample_lags)) if sample_lags else None,
        "sample_to_publication_ns_p95": percentile(sample_lags, 0.95),
        "gpu_end_to_publication_ns_median": int(statistics.median(gpu_end_lags)) if gpu_end_lags else None,
        "gpu_end_to_publication_ns_p95": percentile(gpu_end_lags, 0.95),
        "completion_to_publication_ns_median": int(statistics.median(completion_lags)) if completion_lags else None,
        "completion_to_publication_ns_p95": percentile(completion_lags, 0.95),
    }


def per_index_summary(samples):
    result = {}
    first_use_zero = 0
    histories = {}
    stale_by_k = {}
    for sample in samples:
        gpu = sample.get("gpu_samples")
        cpu = sample.get("cpu_samples")
        indices = sample.get("indices")
        if not isinstance(gpu, list) or not isinstance(cpu, list) or not isinstance(indices, list):
            continue
        prior_cpu = sample.get("prior_cpu_samples", [0] * len(indices))
        names = STAGE_NAMES if len(indices) == 4 else ("begin", "end")
        for offset, index in enumerate(indices):
            if offset >= len(gpu) or offset >= len(cpu):
                continue
            name = names[offset]
            value = result.setdefault(name, {"samples": 0, "matches_cpu": 0, "zero": 0,
                                             "stale_prior_index": 0})
            value["samples"] += 1
            value["matches_cpu"] += gpu[offset] == cpu[offset]
            value["zero"] += gpu[offset] == 0
            prior = prior_cpu[offset] if offset < len(prior_cpu) else 0
            value["stale_prior_index"] += gpu[offset] != 0 and gpu[offset] == prior
            history = histories.setdefault(index, [])
            if offset == len(indices) - 1 and not history and gpu[offset] == 0:
                first_use_zero += 1
            for old_iteration, old in reversed(history):
                if gpu[offset] != 0 and gpu[offset] == old:
                    distance = sample["iteration"] - old_iteration
                    stale_by_k[str(distance)] = stale_by_k.get(str(distance), 0) + 1
                    break
            history.append((sample["iteration"], cpu[offset]))
    return result, first_use_zero, stale_by_k


def evaluate_run(records):
    header, footer = records[0], records[-1]
    samples = sorted((record for record in records if record.get("kind") == "sample"),
                     key=lambda record: record["iteration"])
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
                                  "attachment_mismatch", "unsupported")}
    unsupported_reasons = []
    for record in records:
        if record.get("kind") in other:
            other[record["kind"]] += 1
        if record.get("kind") == "unsupported":
            unsupported_reasons.append(record.get("reason", "unknown"))
    index_summary, first_use_zero, stale_by_k = per_index_summary(samples)
    gap_values = [sample["gap_gpu_ns"] for sample in samples if sample.get("gap_gpu_ns", 0) > 0]
    summary = {
        "mode": header.get("mode", "webgpu_pinned_replay"),
        "experiment": header.get("experiment", header.get("mode", "webgpu_pinned_replay")),
        "frame": header.get("frame"),
        "iterations": header.get("iterations"),
        "samples": len(samples),
        "classes": counts,
        "reversed_total": counts["reversed_nonzero"] + counts["reversed_prior_slot_value"],
        "stale_by_one_pass": stale_by_one_pass,
        "stale_by_k_passes": stale_by_k,
        "first_use_zero": first_use_zero,
        "per_index": index_summary,
        "median_duration_ns": int(statistics.median(durations)) if durations else None,
        "median_stale_lag_ns": int(statistics.median(stale_lags)) if stale_lags else None,
        "gap_dispatches": header.get("gap_dispatches", 0),
        "measured_gap_ns_median": int(statistics.median(gap_values)) if gap_values else None,
        "publication": publication_summary(records),
        "other_records": other,
        "unsupported_reasons": unsupported_reasons,
        "drained": footer.get("drained"),
        "command_failures": footer.get("command_failures"),
        "source_sha256": header.get("source_sha256"),
        "executable_sha256": header.get("executable_sha256"),
    }
    return summary


def candidate_passes(summary):
    counts = summary["classes"]
    first_use_zero = 1 if counts["zero_end"] == 1 else 0
    index_current = all(
        values["matches_cpu"] == values["samples"] and values["stale_prior_index"] == 0
        for values in summary.get("per_index", {}).values()
    )
    return (summary["samples"] > 0 and summary["drained"] is True
            and summary["command_failures"] == 0
            and summary["reversed_total"] == 0
            and counts["ordered_but_stale"] == 0
            and counts["map_failed"] == 0 and counts["failed_command"] == 0
            and counts["zero_end"] == first_use_zero
            and summary["stale_by_one_pass"] == 0
            and not summary.get("stale_by_k_passes")
            and index_current)


def evaluate_sweep(paths):
    rows = []
    for path in paths:
        records = load_run(path) if not isinstance(path, list) else path
        summary = evaluate_run(records)
        if summary["experiment"].startswith("gap_") or summary["gap_dispatches"] > 0:
            rows.append({
                "run": Path(path).name if not isinstance(path, list) else summary["experiment"],
                "gap_dispatches": summary["gap_dispatches"],
                "measured_gap_ns_median": summary["measured_gap_ns_median"],
                "reversed_total": summary["reversed_total"],
                "samples": summary["samples"],
            })
    return sorted(rows, key=lambda row: (row["gap_dispatches"], row["run"]))


def ordered_fraction(summary):
    return summary["classes"]["ordered"] / summary["samples"] if summary["samples"] else 0


def mechanism_verdict(summaries, trace=None):
    values = list(summaries.values()) if isinstance(summaries, dict) else list(summaries)
    by_experiment = {}
    for summary in values:
        by_experiment.setdefault(summary["experiment"], []).append(summary)
    evidence = []
    conflicts = []
    unique = by_experiment.get("unique_indices", [])
    unique_failed = any(
        summary["first_use_zero"] < min(64, summary.get("iterations") or 64) * 0.9
        for summary in unique
    )
    if unique and unique_failed:
        evidence.append("M1 fresh end indices returned non-zero before reuse")
        return {"mechanism": "H-D", "candidate": None, "evidence": evidence,
                "excluded": ["H-A", "H-B", "H-C"], "conflicts": conflicts}
    tracked = by_experiment.get("tracked_dependency", [])
    deferred = {name: by_experiment.get("deferred_" + name, [])
                for name in ("enqueued", "scheduled", "completed")}
    trace_before = trace is not None and trace.get("blit_before_fragment_fraction", 0) >= 0.5
    tracked_passes = bool(tracked) and all(candidate_passes(summary) for summary in tracked)
    all_deferred_pass = all(deferred[name] and all(candidate_passes(summary)
                                                   for summary in deferred[name])
                            for name in deferred)
    if tracked_passes and all_deferred_pass and trace_before:
        evidence.extend(["M4 tracked dependency is at least 99% ordered",
                         "M6 all deferred shapes are at least 99% ordered",
                         "M7 resolve blit starts before fragment completion"])
        return {"mechanism": "H-C", "candidate": "tracked_dependency", "evidence": evidence,
                "excluded": ["H-A", "H-B", "H-D"], "conflicts": conflicts}
    gaps = sorted((summary for name, group in by_experiment.items() if name.startswith("gap_")
                   for summary in group), key=lambda summary: summary["gap_dispatches"])
    baseline = by_experiment.get("gpu_resolve", []) + by_experiment.get("publication_latency", [])
    baseline_bad = bool(baseline) and any(summary["reversed_total"] > 0 for summary in baseline)
    passing_gaps = [summary for summary in gaps if candidate_passes(summary)]
    trace_after = trace is not None and trace.get("blit_before_fragment_fraction", 1) < 0.5
    precompletion_deferred = [
        name for name in ("enqueued", "scheduled")
        if deferred[name] and all(candidate_passes(summary) for summary in deferred[name])
    ]
    if baseline_bad and passing_gaps and not tracked_passes and trace_after:
        threshold = min(summary["measured_gap_ns_median"] for summary in passing_gaps
                        if summary["measured_gap_ns_median"] is not None)
        publication = [summary["publication"] for summary in by_experiment.get("publication_latency", [])]
        medians = [item.get("sample_to_publication_ns_median") for item in publication
                   if item.get("sample_to_publication_ns_median") is not None]
        p95s = [item.get("sample_to_publication_ns_p95") for item in publication
                if item.get("sample_to_publication_ns_p95") is not None]
        evidence.extend(["M0 observes the current end sample after the resolve read",
                         "M3 finite in-buffer gap removes reversals",
                         "M4 tracked dependency does not",
                         "M7 resolve blit starts after fragment completion"])
        candidate = None
        if precompletion_deferred:
            candidate = precompletion_deferred[0] + "_deferred_resolve"
            evidence.append("M6 " + precompletion_deferred[0] + " deferred resolve is current")
        else:
            conflicts.append("M6 has no current pre-completion deferred resolve")
        return {"mechanism": "H-A", "candidate": candidate,
                "publication_latency_ns_median": int(statistics.median(medians)) if medians else None,
                "publication_latency_ns_p95_max": max(p95s) if p95s else None,
                "latency_upper_bound_ns": threshold, "evidence": evidence,
                "excluded": ["H-B", "H-C", "H-D"], "conflicts": conflicts}
    max_gap_bad = bool(gaps) and all(summary["reversed_total"] > 0 for summary in gaps[-2:])
    only_completed = bool(deferred["completed"]) and all(
        candidate_passes(summary) for summary in deferred["completed"])
    only_completed = only_completed and all(
        not deferred[name] or any(not candidate_passes(summary) for summary in deferred[name])
        for name in ("enqueued", "scheduled"))
    publication = [summary["publication"] for summary in by_experiment.get("publication_latency", [])]
    after_end = bool(publication) and all(item["observed"] and
                                          item["at_or_after_gpu_end"] / item["observed"] >= 0.9
                                          for item in publication)
    if baseline_bad and max_gap_bad and not tracked_passes and only_completed and after_end and trace_after:
        evidence.extend(["M0 publication is at or after GPU end", "M3 maximum gap still reverses",
                         "M4 tracked dependency does not", "M6 only completed-handler resolve passes",
                         "M7 resolve blit starts after fragment completion"])
        return {"mechanism": "H-B", "candidate": "completed_handler_resolve",
                "evidence": evidence, "excluded": ["H-A", "H-C", "H-D"],
                "conflicts": conflicts}
    missing = []
    for experiment in ("publication_latency", "unique_indices", "tracked_dependency",
                       "deferred_enqueued", "deferred_scheduled", "deferred_completed"):
        if experiment not in by_experiment:
            missing.append(experiment)
    if not gaps:
        missing.append("gap_sweep")
    if trace is None:
        missing.append("metal_system_trace")
    if tracked_passes:
        conflicts.append("tracked dependency passed without an H-C-complete trace/deferred pattern")
    if passing_gaps:
        conflicts.append("a finite gap passed without the complete H-A decision row")
    return {"mechanism": "inconclusive", "candidate": None, "evidence": evidence,
            "excluded": [], "conflicts": conflicts, "missing": missing}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("runs", nargs="+")
    parser.add_argument("--manifest")
    parser.add_argument("--sweep")
    parser.add_argument("--verdict")
    parser.add_argument("--trace")
    arguments = parser.parse_args()
    results = {}
    for run in arguments.runs:
        records = load_run(run)
        summary = evaluate_run(records)
        summary["candidate_passes"] = candidate_passes(summary)
        summary["sha256"] = hashlib.sha256(Path(run).read_bytes()).hexdigest()
        results[Path(run).name] = summary
    if arguments.sweep:
        Path(arguments.sweep).write_text(json.dumps(evaluate_sweep(arguments.runs), indent=1) + "\n")
    if arguments.verdict:
        trace = json.loads(Path(arguments.trace).read_text()) if arguments.trace else None
        verdict = mechanism_verdict(results, trace)
        verdict["supporting_runs"] = [
            {"run": name, "sha256": summary["sha256"]}
            for name, summary in sorted(results.items())
        ]
        Path(arguments.verdict).write_text(json.dumps(verdict, indent=1) + "\n")
    text = json.dumps(results, indent=1)
    if arguments.manifest:
        Path(arguments.manifest).write_text(text + "\n")
    print(text)


if __name__ == "__main__":
    main()
