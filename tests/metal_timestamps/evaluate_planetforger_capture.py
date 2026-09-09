import argparse
import hashlib
import json
import math
from pathlib import Path

from scenario_qualification import validate_scenario


REQUIRED_GROUPS = ("window", "world.opaque", "world.scene-copy", "world.ocean")
HEALTH_FIELDS = ("o", "s", "q", "m", "sf", "rf", "g", "t", "sc", "cr")
BOUNDARY_CPU_FIELDS = {
    "pre_acquire": "pre",
    "stream_acquire": "sta",
    "post_acquire": "post",
    "flush": "flu",
    "stream_upload": "upl",
    "cleanup": "cln",
    "input": "inp",
    "frame_timing": "fti",
    "host_reload": "hrl",
    "host_refresh": "hrf",
    "host_draw": "hdr",
    "host_prepare": "hpr",
    "host_cursor": "hcu",
    "host_unaccounted": "hun",
}
PRESSURE_FIELDS = {
    "submissions_before_poll": "qbp",
    "submissions_after_poll": "qap",
    "submissions_at_submit": "qas",
    "submissions_high_water": "qhw",
    "oldest_submission_frame_age": "qoa",
}
SUBMISSION_CALL_FIELDS = {
    "intermediate_upload_count": "iuc",
    "intermediate_finish_count": "ifc",
    "intermediate_submit_count": "isc",
    "final_upload_count": "fuc",
    "final_finish_count": "ffc",
    "final_submit_count": "fsc",
    "intermediate_upload_max": "ium",
    "intermediate_finish_max": "ifm",
    "intermediate_submit_max": "ism",
    "final_upload_max": "fum",
    "final_finish_max": "ffm",
    "final_submit_max": "fsm",
}


def correlation(left, right):
    if len(left) != len(right) or len(left) < 2:
        return None
    left_mean = sum(left) / len(left)
    right_mean = sum(right) / len(right)
    numerator = sum((a - left_mean) * (b - right_mean) for a, b in zip(left, right))
    left_square = sum((value - left_mean) ** 2 for value in left)
    right_square = sum((value - right_mean) ** 2 for value in right)
    denominator = math.sqrt(left_square * right_square)
    return numerator / denominator if denominator else None


def classify_boundary_frame(delivery, renderer_unaccounted):
    if delivery["hun"] > 0.25:
        return "unaccounted"
    if delivery["qap"] >= 3 or delivery["qoa"] >= 3:
        return "submission_pressure"
    if delivery["aq"] > 1:
        return "drawable_acquisition"
    if max(delivery["en"], delivery["sb"], delivery["ifm"], delivery["ism"], delivery["ffm"], delivery["fsm"]) > 1:
        return "finish_or_submit"
    if delivery["ps"] > 1 or delivery["fti"] > 1:
        return "presentation_pacing"
    if renderer_unaccounted >= max(delivery["hc"] - delivery["rc"], 0):
        return "renderer_work"
    return "host_work"


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def percentile(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[math.ceil(fraction * len(ordered)) - 1]


def distribution(values):
    return {
        "count": len(values),
        "p50": percentile(values, 0.50),
        "p95": percentile(values, 0.95),
        "p99": percentile(values, 0.99),
    }


def evaluate_capture(telemetry_path, scenario_path, binary_paths=None, recording_path=None):
    telemetry_path = Path(telemetry_path)
    scenario_path = Path(scenario_path)
    records = [json.loads(line) for line in telemetry_path.read_text().splitlines() if line.strip()]
    scenario_error = None
    try:
        scenario_records = [
            json.loads(line) for line in scenario_path.read_text().splitlines() if line.strip()
        ]
        if not scenario_records or any(not isinstance(record, dict) for record in scenario_records):
            raise ValueError("scenario history must contain object records")
    except (OSError, UnicodeError, ValueError) as error:
        scenario_error = str(error)
        scenario_records = [{}]
    scenario_validation = validate_scenario(scenario_records)
    frame_owned = any(record.get("v") == 2 for record in scenario_records)
    identity_fields = ("scenario", "seed", "quality", "width", "height", "terrain_sha256")
    scenario_identity = {field: scenario_records[0].get(field) for field in identity_fields}
    measured_ranges = []
    measured_started = None
    timestamp_errors = []
    previous_seconds = None
    has_scenario_timestamps = any("native_seconds" in record for record in scenario_records)
    for record in scenario_records:
        native_seconds = record.get("native_seconds")
        phase = record.get("phase")
        if (
            isinstance(native_seconds, bool)
            or not isinstance(native_seconds, (int, float))
            or not math.isfinite(native_seconds)
            or native_seconds < 0
        ):
            timestamp_errors.append("invalid_scenario_timestamp")
            continue
        if previous_seconds is not None and native_seconds < previous_seconds:
            timestamp_errors.append("nonmonotonic_scenario_timestamp")
        previous_seconds = native_seconds
        if phase == "measured" and measured_started is None:
            measured_started = native_seconds
        elif phase != "measured" and measured_started is not None:
            measured_ranges.append((measured_started, native_seconds))
            measured_started = None
    if timestamp_errors:
        measured_ranges = []
    if scenario_error is None and any(value is None or value == "" for value in scenario_identity.values()):
        raise ValueError("scenario identity is incomplete")
    if scenario_error is None and scenario_identity["scenario"] != "ocean":
        raise ValueError("scenario identity is not ocean")
    if scenario_error is None and scenario_identity["quality"] not in ("fixed", "adaptive"):
        raise ValueError("scenario quality is invalid")
    if scenario_error is None and (scenario_identity["width"] <= 0 or scenario_identity["height"] <= 0):
        raise ValueError("scenario dimensions are invalid")
    if scenario_error is None and len(scenario_identity["terrain_sha256"]) != 64:
        raise ValueError("scenario terrain hash is invalid")
    if any(record.get(field) != value for record in scenario_records for field, value in scenario_identity.items()):
        raise ValueError("scenario identity changes within capture")
    group_counts = {name: 0 for name in REQUIRED_GROUPS}
    health = {name: 0 for name in HEALTH_FIELDS}
    delivery_frames = 0
    gpu_frames = 0
    raw_identities = set()
    all_delivery_identities = set()
    delivery_identities = set()
    duplicate_raw_identities = 0
    duplicate_delivery_identities = 0
    missing_gpu_callbacks = 0
    missing_present_callbacks = 0
    delivery_dropped = 0
    write_failures = 0
    pump_exhausted = 0
    completion_high_water = 0
    sequences = []
    cpu_metrics = {
        name: []
        for name in ("host", "renderer", "acquire", "encode", "submit", "present_call", "pacer_wait")
    }
    boundary_metrics = {name: [] for name in (*BOUNDARY_CPU_FIELDS, *PRESSURE_FIELDS)}
    boundary_metrics["renderer_draw"] = []
    submission_call_metrics = {name: [] for name in SUBMISSION_CALL_FIELDS}
    boundary_metrics.update({
        "host_closure_error": [],
        "renderer_closure_error": [],
        "renderer_unaccounted": [],
    })
    classifications = []
    correlation_rows = []
    boundary_versions = set()
    incomplete_boundary_frames = 0
    unknown_boundary_frames = 0
    displayed_ms = []
    presented = {}
    queue_completion_ms = []
    raw_frames = {}
    delivery_frames_by_identity = {}
    gpu_groups = {}
    invalid_cpu_durations = 0
    reversed_gpu_timestamps = 0
    reversed_present_timestamps = 0
    refresh_hz = scenario_records[0].get("refresh_hz", 0)
    reliability = None
    reliability_reason = None
    for record in records:
        if record.get("rt") != 1:
            continue
        if record.get("sq"):
            sequences.append(record["sq"])
        delivery_dropped = max(delivery_dropped, record.get("fdd", 0))
        write_failures = max(write_failures, record.get("wf", 0))
        pump_exhausted = max(pump_exhausted, record.get("px", 0))
        current_health = record.get("gh", {})
        for field in HEALTH_FIELDS:
            health[field] += current_health.get(field, 0)
        completion_high_water = max(completion_high_water, current_health.get("ch", 0))
        scope = record.get("rl", {})
        reliability = scope.get("g", reliability)
        reliability_reason = scope.get("r", reliability_reason)
        for frame in record.get("gfd", []):
            frame_identity = (frame.get("e", 0), frame.get("i", 0))
            if frame_identity in raw_identities:
                duplicate_raw_identities += 1
            raw_identities.add(frame_identity)
            raw_frames[frame_identity] = frame
            if not frame.get("v", False):
                health["invalid_gpu_frame"] = health.get("invalid_gpu_frame", 0) + 1
        for delivery in record.get("fd", []):
            submit_timestamp = delivery.get("st", 0)
            delivery_identity = (delivery.get("e", 0), delivery.get("i", 0))
            if delivery_identity in all_delivery_identities:
                duplicate_delivery_identities += 1
            all_delivery_identities.add(delivery_identity)
            missing_gpu_callbacks += int(delivery.get("mg", False))
            missing_present_callbacks += int(delivery.get("mp", False))
            gpu_timestamp = delivery.get("gt", 0)
            present_timestamp = delivery.get("pt", 0)
            if delivery.get("v", 0) & 2 and (submit_timestamp <= 0 or gpu_timestamp < submit_timestamp):
                reversed_gpu_timestamps += 1
            if delivery.get("v", 0) & 4 and (
                present_timestamp <= 0 or (submit_timestamp > 0 and present_timestamp < submit_timestamp)
            ):
                reversed_present_timestamps += 1
            if frame_owned:
                if not any(
                    delivery_identity[0] == epoch and start <= delivery_identity[1] < end
                    for epoch, start, end in scenario_validation["ranges"]
                ):
                    continue
            elif has_scenario_timestamps and not any(
                start <= submit_timestamp < end for start, end in measured_ranges
            ):
                continue
            delivery_frames += 1
            delivery_identities.add(delivery_identity)
            delivery_frames_by_identity[delivery_identity] = delivery
            fields = {
                "host": "hc",
                "renderer": "rc",
                "acquire": "aq",
                "encode": "en",
                "submit": "sb",
                "present_call": "ps",
                "pacer_wait": "pw",
            }
            for name, field in fields.items():
                value = delivery.get(field)
                if value is None:
                    continue
                if not isinstance(value, (int, float)) or value < 0:
                    invalid_cpu_durations += 1
                    continue
                cpu_metrics[name].append(value)
            boundary_version = delivery.get("bv", 0)
            boundary_versions.add(boundary_version)
            if boundary_version in (2, 3):
                required = {
                    "hc", "rc", "aq", "en", "sb", "ps",
                    *BOUNDARY_CPU_FIELDS.values(), *PRESSURE_FIELDS.values(),
                    *SUBMISSION_CALL_FIELDS.values(),
                }
                if boundary_version == 3:
                    required.add("rdw")
                if not required.issubset(delivery):
                    incomplete_boundary_frames += 1
                else:
                    valid_detail = True
                    detail_fields = {**BOUNDARY_CPU_FIELDS, **PRESSURE_FIELDS, **SUBMISSION_CALL_FIELDS}
                    if boundary_version == 3:
                        detail_fields["renderer_draw"] = "rdw"
                    for name, field in detail_fields.items():
                        value = delivery[field]
                        if not isinstance(value, (int, float)) or value < 0:
                            invalid_cpu_durations += 1
                            valid_detail = False
                        elif name in submission_call_metrics:
                            submission_call_metrics[name].append(value)
                        else:
                            boundary_metrics[name].append(value)
                    if valid_detail:
                        host_children = sum(delivery[field] for field in ("hrl", "hrf", "hdr", "hpr", "hcu", "hun"))
                        if boundary_version == 3:
                            renderer_fields = (
                                "rdw", "pre", "sta", "aq", "post", "flu", "fum", "ffm", "fsm", "ps", "cln", "inp", "fti",
                            )
                        else:
                            renderer_fields = (
                                "pre", "sta", "aq", "post", "flu", "upl", "en", "sb", "ps", "cln", "inp", "fti",
                            )
                        renderer_children = sum(delivery[field] for field in renderer_fields)
                        renderer_unaccounted = max(delivery["rc"] - renderer_children, 0)
                        boundary_metrics["host_closure_error"].append(abs(delivery["hc"] - host_children))
                        boundary_metrics["renderer_closure_error"].append(max(renderer_children - delivery["rc"], 0))
                        boundary_metrics["renderer_unaccounted"].append(renderer_unaccounted)
                        classification = classify_boundary_frame(delivery, renderer_unaccounted)
                        classifications.append({
                            "epoch": delivery_identity[0],
                            "frame": delivery_identity[1],
                            "host_ms": delivery["hc"],
                            "acquire_ms": delivery["aq"],
                            "classification": classification,
                        })
                        correlation_rows.append({
                            "host": delivery["hc"],
                            "acquire": delivery["aq"],
                            "after_poll": delivery["qap"],
                            "oldest_age": delivery["qoa"],
                        })
            elif boundary_version != 0:
                unknown_boundary_frames += 1
            if delivery.get("v", 0) & 2 and submit_timestamp > 0 and gpu_timestamp >= submit_timestamp:
                if delivery.get("gc", 0) >= 0:
                    queue_completion_ms.append(delivery["gc"])
            if delivery.get("v", 0) & 4 and present_timestamp > 0 and (
                submit_timestamp <= 0 or present_timestamp >= submit_timestamp
            ):
                presented[delivery_identity] = present_timestamp
    unique_sequences = set(sequences)
    sequence_duplicates = len(sequences) - len(unique_sequences)
    sequence_gaps = 0
    if unique_sequences:
        sequence_gaps = max(unique_sequences) - min(unique_sequences) + 1 - len(unique_sequences)
    deadline_samples = 0
    deadline_misses = 0
    previous = None
    for frame_identity, timestamp in sorted(presented.items()):
        if previous is not None and frame_identity[0] == previous[0][0] and frame_identity[1] == previous[0][1] + 1:
            interval = (timestamp - previous[1]) * 1000
            displayed_ms.append(interval)
            if refresh_hz > 0:
                deadline_samples += 1
                if interval > 1000 / refresh_hz * 1.10:
                    deadline_misses += 1
        previous = (frame_identity, timestamp)
    raw_without_delivery = len(raw_identities - all_delivery_identities)
    delivery_without_raw = len(all_delivery_identities - raw_identities)
    exact_joined = raw_identities & delivery_identities
    for identity in exact_joined:
        frame = raw_frames[identity]
        gpu_frames += 1
        for group in frame.get("g", []):
            name = group.get("n")
            milliseconds = group.get("ms")
            if name in group_counts:
                group_counts[name] += 1
            if isinstance(name, str) and isinstance(milliseconds, (int, float)) and milliseconds >= 0:
                gpu_groups.setdefault(name, []).append(milliseconds)
    failures = {
        **health,
        "missing_gpu_callbacks": missing_gpu_callbacks,
        "missing_present_callbacks": missing_present_callbacks,
        "delivery_dropped": delivery_dropped,
        "sequence_gaps": sequence_gaps,
        "sequence_duplicates": sequence_duplicates,
        "write_failures": write_failures,
        "pump_exhausted": pump_exhausted,
        "duplicate_raw_identities": duplicate_raw_identities,
        "duplicate_delivery_identities": duplicate_delivery_identities,
        "raw_without_delivery": raw_without_delivery,
        "delivery_without_raw": delivery_without_raw,
        "invalid_cpu_durations": invalid_cpu_durations,
        "reversed_gpu_timestamps": reversed_gpu_timestamps,
        "reversed_present_timestamps": reversed_present_timestamps,
        "incomplete_boundary_frames": incomplete_boundary_frames,
        "unknown_boundary_frames": unknown_boundary_frames,
    }
    healthy = all(value == 0 for value in failures.values())
    complete_groups = all(group_counts[name] > 0 for name in REQUIRED_GROUPS)
    binaries = {}
    for name, path in (binary_paths or {}).items():
        binaries[name] = {"path": str(path), "sha256": sha256(path)}
    recording = None
    recording_healthy = True
    if recording_path:
        recording_path = Path(recording_path)
        recording_records = [json.loads(line) for line in recording_path.read_text().splitlines() if line.strip()]
        health_records = [record for record in recording_records if record.get("k") == "telemetry_health"]
        end_records = [record for record in recording_records if record.get("k") == "end"]
        if len(health_records) != 1 or len(end_records) != 1:
            raise ValueError("recording must contain exactly one telemetry health and terminal record")
        recording_health = health_records[0]
        terminal = end_records[0]
        recording_failures = {
            field: recording_health.get(field, 0)
            for field in ("invalid_lines", "parse_errors", "resets", "read_errors", "pending_bytes")
        }
        recording_failures["discarding"] = int(recording_health.get("discarding", False))
        recording_failures["unfinished_tail"] = int(recording_health.get("unfinished_tail", False))
        recording_failures["drain_exhausted"] = int(recording_health.get("drain_exhausted", False))
        recording_healthy = (
            all(value == 0 for value in recording_failures.values())
            and terminal.get("e") is True
            and terminal.get("c") == 0
            and terminal.get("z") is False
        )
        recording = {
            "path": str(recording_path),
            "sha256": sha256(recording_path),
            "telemetry_health": recording_health,
            "terminal": terminal,
            "failures": recording_failures,
            "healthy": recording_healthy,
        }
    accepted = healthy and complete_groups and recording_healthy and scenario_error is None
    qualification_reasons = ["scenario_frame_clock_mapping_unverified"]
    if scenario_error is not None:
        qualification_reasons.append("scenario_history_unavailable_or_malformed")
    qualification_reasons.extend(sorted(set(timestamp_errors)))
    if frame_owned:
        qualification_reasons.extend(scenario_validation["reasons"])
    if not measured_ranges:
        qualification_reasons.append("no_bounded_measured_phase")
    if measured_started is not None:
        qualification_reasons.append("open_measured_tail")
    if not any(record.get("terminal_outcome") == "completed" for record in scenario_records):
        qualification_reasons.append("scenario_completion_unproven")
    if not accepted:
        qualification_reasons.append("legacy_analysis_checks_failed")
    exact_gpu_ms = [raw_frames[identity].get("ms") for identity in exact_joined]
    exact_gpu_ms = [value for value in exact_gpu_ms if isinstance(value, (int, float)) and value >= 0]
    long_frames = [item for item in classifications if item["host_ms"] > 9.167]
    acquire_frames = [item for item in classifications if item["acquire_ms"] > 1]
    host_p95 = percentile([item["host_ms"] for item in classifications], 0.95)
    p95_host_frames = [item for item in classifications if host_p95 is not None and item["host_ms"] >= host_p95]
    detailed_cpu_frames = boundary_metrics["host_closure_error"]
    classification_coverage = len(classifications) / delivery_frames if delivery_frames else 0
    pressure_correlations = {}
    for pressure_name in ("after_poll", "oldest_age"):
        pressure_correlations[pressure_name] = {
            "host": correlation(
                [row[pressure_name] for row in correlation_rows],
                [row["host"] for row in correlation_rows],
            ),
            "acquire": correlation(
                [row[pressure_name] for row in correlation_rows],
                [row["acquire"] for row in correlation_rows],
            ),
        }
    return {
        "telemetry": str(telemetry_path),
        "telemetry_sha256": sha256(telemetry_path),
        "scenario": str(scenario_path),
        "scenario_sha256": sha256(scenario_path) if scenario_path.is_file() else None,
        "scenario_error": scenario_error,
        "binaries": binaries,
        "recording": recording,
        "identity": scenario_identity,
        "observed_phases": sorted({record.get("phase") for record in scenario_records}),
        "qualification_route": "measured_phase" if measured_ranges else "unsegmented_immutable_scenario_identity",
        "delivery_frames": delivery_frames,
        "gpu_frames": gpu_frames,
        "joined_frames": len(exact_joined),
        "delivery_without_raw": delivery_without_raw,
        "group_counts": group_counts,
        "failures": failures,
        "completion_high_water": completion_high_water,
        "reliability": reliability,
        "reliability_reason": reliability_reason,
        "cpu_ms": {name: distribution(values) for name, values in cpu_metrics.items()},
        "host_ms": distribution(cpu_metrics["host"]),
        "renderer_ms": distribution(cpu_metrics["renderer"]),
        "acquire_ms": distribution(cpu_metrics["acquire"]),
        "encode_ms": distribution(cpu_metrics["encode"]),
        "submit_ms": distribution(cpu_metrics["submit"]),
        "present_call_ms": distribution(cpu_metrics["present_call"]),
        "pacer_wait_ms": distribution(cpu_metrics["pacer_wait"]),
        "displayed_ms": distribution(displayed_ms),
        "queue_completion_ms": distribution(queue_completion_ms),
        "exact_gpu_ms": distribution(exact_gpu_ms),
        "gpu_groups_ms": {name: distribution(values) for name, values in sorted(gpu_groups.items())},
        "boundary_schema": {
            "versions": sorted(boundary_versions),
            "detailed_frames": len(detailed_cpu_frames),
            "classification_coverage": classification_coverage,
            "long_frames": len(long_frames),
            "long_frames_classified": len(long_frames),
            "acquire_frames": len(acquire_frames),
            "acquire_frames_classified": len(acquire_frames),
            "p95_host_threshold_ms": host_p95,
            "p95_host_frames": len(p95_host_frames),
            "p95_host_frames_classified": len(p95_host_frames),
        },
        "boundary_ms": {name: distribution(values) for name, values in boundary_metrics.items()},
        "submission_calls": {
            name: distribution(values) for name, values in submission_call_metrics.items()
        },
        "pressure_correlations": pressure_correlations,
        "p95_host_classifications": p95_host_frames,
        "classifications": classifications,
        "classification_counts": {
            name: sum(item["classification"] == name for item in classifications)
            for name in (
                "host_work", "renderer_work", "submission_pressure", "drawable_acquisition",
                "finish_or_submit", "presentation_pacing", "unaccounted",
            )
        },
        "deadline_samples": deadline_samples,
        "deadline_misses": deadline_misses,
        "healthy": healthy,
        "complete_groups": complete_groups,
        "accepted": accepted,
        "qualified": False,
        "qualification_reasons": qualification_reasons,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("telemetry")
    parser.add_argument("scenario_jsonl")
    parser.add_argument("--output")
    parser.add_argument("--host")
    parser.add_argument("--game-library")
    parser.add_argument("--compiler")
    parser.add_argument("--wgpu-archive")
    parser.add_argument("--recording")
    arguments = parser.parse_args()
    binary_paths = {
        name: path
        for name, path in {
            "host": arguments.host,
            "game_library": arguments.game_library,
            "compiler": arguments.compiler,
            "wgpu_archive": arguments.wgpu_archive,
        }.items()
        if path
    }
    result = evaluate_capture(
        arguments.telemetry,
        arguments.scenario_jsonl,
        binary_paths,
        arguments.recording,
    )
    text = json.dumps(result, indent=1) + "\n"
    if arguments.output:
        Path(arguments.output).write_text(text)
    print(text, end="")
    if not result["qualified"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
