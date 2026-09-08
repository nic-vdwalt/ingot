import argparse
import hashlib
import json
import math
from pathlib import Path


REQUIRED_GROUPS = ("window", "world.opaque", "world.scene-copy", "world.ocean")
HEALTH_FIELDS = ("o", "s", "q", "m", "sf", "rf", "g", "t", "sc", "cr")


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
    scenario_records = [json.loads(line) for line in scenario_path.read_text().splitlines() if line.strip()]
    if not scenario_records:
        raise ValueError("scenario identity is missing")
    identity_fields = ("scenario", "seed", "quality", "width", "height", "terrain_sha256")
    scenario_identity = {field: scenario_records[0].get(field) for field in identity_fields}
    if any(value is None or value == "" for value in scenario_identity.values()):
        raise ValueError("scenario identity is incomplete")
    if scenario_identity["scenario"] != "ocean":
        raise ValueError("scenario identity is not ocean")
    if scenario_identity["quality"] not in ("fixed", "adaptive"):
        raise ValueError("scenario quality is invalid")
    if scenario_identity["width"] <= 0 or scenario_identity["height"] <= 0:
        raise ValueError("scenario dimensions are invalid")
    if len(scenario_identity["terrain_sha256"]) != 64:
        raise ValueError("scenario terrain hash is invalid")
    if any(record.get(field) != value for record in scenario_records for field, value in scenario_identity.items()):
        raise ValueError("scenario identity changes within capture")
    group_counts = {name: 0 for name in REQUIRED_GROUPS}
    health = {name: 0 for name in HEALTH_FIELDS}
    delivery_frames = 0
    gpu_frames = 0
    raw_identities = set()
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
            gpu_frames += 1
            frame_identity = (frame.get("e", 0), frame.get("i", 0))
            if frame_identity in raw_identities:
                duplicate_raw_identities += 1
            raw_identities.add(frame_identity)
            raw_frames[frame_identity] = frame
            if not frame.get("v", False):
                health["invalid_gpu_frame"] = health.get("invalid_gpu_frame", 0) + 1
            for group in frame.get("g", []):
                name = group.get("n")
                milliseconds = group.get("ms")
                if name in group_counts:
                    group_counts[name] += 1
                if isinstance(name, str) and isinstance(milliseconds, (int, float)) and milliseconds >= 0:
                    gpu_groups.setdefault(name, []).append(milliseconds)
        for delivery in record.get("fd", []):
            delivery_frames += 1
            delivery_identity = (delivery.get("e", 0), delivery.get("i", 0))
            if delivery_identity in delivery_identities:
                duplicate_delivery_identities += 1
            delivery_identities.add(delivery_identity)
            delivery_frames_by_identity[delivery_identity] = delivery
            missing_gpu_callbacks += int(delivery.get("mg", False))
            missing_present_callbacks += int(delivery.get("mp", False))
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
            submit_timestamp = delivery.get("st", 0)
            gpu_timestamp = delivery.get("gt", 0)
            present_timestamp = delivery.get("pt", 0)
            if delivery.get("v", 0) & 2:
                if submit_timestamp <= 0 or gpu_timestamp < submit_timestamp:
                    reversed_gpu_timestamps += 1
                elif delivery.get("gc", 0) >= 0:
                    queue_completion_ms.append(delivery["gc"])
            if delivery.get("v", 0) & 4:
                if present_timestamp <= 0 or (submit_timestamp > 0 and present_timestamp < submit_timestamp):
                    reversed_present_timestamps += 1
                else:
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
    raw_without_delivery = len(raw_identities - delivery_identities)
    delivery_without_raw = len(delivery_identities - raw_identities)
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
        "invalid_cpu_durations": invalid_cpu_durations,
        "reversed_gpu_timestamps": reversed_gpu_timestamps,
        "reversed_present_timestamps": reversed_present_timestamps,
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
    accepted = healthy and complete_groups and recording_healthy
    exact_joined = raw_identities & delivery_identities
    exact_gpu_ms = [raw_frames[identity].get("ms") for identity in exact_joined]
    exact_gpu_ms = [value for value in exact_gpu_ms if isinstance(value, (int, float)) and value >= 0]
    return {
        "telemetry": str(telemetry_path),
        "telemetry_sha256": sha256(telemetry_path),
        "scenario": str(scenario_path),
        "scenario_sha256": sha256(scenario_path),
        "binaries": binaries,
        "recording": recording,
        "identity": scenario_identity,
        "observed_phases": sorted({record.get("phase") for record in scenario_records}),
        "qualification_route": "unsegmented_immutable_scenario_identity",
        "delivery_frames": delivery_frames,
        "gpu_frames": gpu_frames,
        "joined_frames": len(raw_identities & delivery_identities),
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
        "deadline_samples": deadline_samples,
        "deadline_misses": deadline_misses,
        "healthy": healthy,
        "complete_groups": complete_groups,
        "accepted": accepted,
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
    if not result["accepted"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
