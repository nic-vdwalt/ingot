import argparse
import hashlib
import json
import math
from pathlib import Path

from scenario_qualification import finite_number, validate_scenario, verify_delivery_mapping


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
    boundary_version = delivery.get("bv")
    required = {
        "hc", "rc", "aq", "en", "sb", "ps",
        *BOUNDARY_CPU_FIELDS.values(), *PRESSURE_FIELDS.values(),
        *SUBMISSION_CALL_FIELDS.values(),
    }
    if boundary_version == 3:
        required.add("rdw")
    valid = (
        boundary_version in (2, 3)
        and required.issubset(delivery)
        and finite_number(renderer_unaccounted)
        and renderer_unaccounted >= 0
        and all(finite_number(delivery[field]) and delivery[field] >= 0 for field in required)
    )
    if not valid:
        return {
            "classification": None,
            "dominant_span": None,
            "dominant_ms": None,
            "secondary_observations": [],
            "pressure_correlates": [],
            "evidence_complete": False,
            "unexplained_ms": None,
        }

    candidates = [
        ("host_unaccounted", delivery["hun"], "unaccounted"),
        ("renderer_unaccounted", renderer_unaccounted, "unaccounted"),
        ("host_outside_renderer", max(delivery["hc"] - delivery["rc"], 0), "host_work"),
        ("pre_acquire", delivery["pre"], "renderer_work"),
        ("stream_acquire", delivery["sta"], "renderer_work"),
        ("drawable_acquisition", delivery["aq"], "drawable_acquisition"),
        ("post_acquire", delivery["post"], "renderer_work"),
        ("flush", delivery["flu"], "renderer_work"),
    ]
    if boundary_version == 3:
        candidates.extend((
            ("renderer_draw", delivery["rdw"], "renderer_work"),
            ("final_upload", delivery["fum"], "renderer_work"),
            ("final_finish", delivery["ffm"], "finish_or_submit"),
            ("final_submit", delivery["fsm"], "finish_or_submit"),
        ))
    else:
        candidates.extend((
            ("stream_upload", delivery["upl"], "renderer_work"),
            ("encode", delivery["en"], "finish_or_submit"),
            ("submit", delivery["sb"], "finish_or_submit"),
        ))
    candidates.extend((
        ("present_call", delivery["ps"], "presentation_pacing"),
        ("cleanup", delivery["cln"], "renderer_work"),
        ("input", delivery["inp"], "renderer_work"),
        ("frame_timing", delivery["fti"], "presentation_pacing"),
    ))
    dominant_span, dominant_ms, classification = max(candidates, key=lambda candidate: candidate[1])
    secondary_observations = []
    if delivery["aq"] > 1:
        secondary_observations.append("drawable_acquisition")
    if max(delivery["en"], delivery["sb"], delivery["ifm"], delivery["ism"], delivery["ffm"], delivery["fsm"]) > 1:
        secondary_observations.append("finish_or_submit")
    if delivery["ps"] > 1 or delivery["fti"] > 1:
        secondary_observations.append("presentation_pacing")
    pressure_correlates = []
    if delivery["qap"] >= 3 or delivery["qoa"] >= 3:
        pressure_correlates.append("submission_pressure")
    return {
        "classification": classification,
        "dominant_span": dominant_span,
        "dominant_ms": dominant_ms,
        "secondary_observations": secondary_observations,
        "pressure_correlates": pressure_correlates,
        "evidence_complete": True,
        "unexplained_ms": delivery["hun"] + renderer_unaccounted,
    }


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


def normalize_telemetry(record, errors):
    def invalid(path):
        errors.append("telemetry_schema_invalid:" + path)

    def unsigned(value):
        return type(value) is int and 0 <= value <= 2**64 - 1

    def unsigned32(value):
        return type(value) is int and 0 <= value < 2**32

    def fields(value, names, predicate, path):
        for name in names:
            if name in value and not predicate(value[name]):
                invalid(path + "." + name)
                del value[name]

    fields(record, ("sq", "fdd", "wf", "px", "pd", "pfd", "pdd", "eo"),
           unsigned, "record")
    fields(record, ("rt",), unsigned32, "record")
    for name in ("gh", "rl"):
        if not isinstance(record.get(name, {}), dict):
            invalid(name)
            record[name] = {}
    fields(record.get("gh", {}), (*HEALTH_FIELDS, "ch"), unsigned, "gh")
    if record.get("rt") == 1:
        for key in ("sq", "fdd", "wf", "px", "pd", "pfd", "pdd", "eo"):
            if key not in record:
                invalid("record.missing." + key)
        for key in HEALTH_FIELDS:
            if key not in record.get("gh", {}):
                invalid("gh.missing." + key)
    fields(record.get("rl", {}), ("v",), unsigned32, "rl")
    fields(record.get("rl", {}), ("s", "g", "r"), lambda value: isinstance(value, str), "rl")
    for name in ("gfd", "fd"):
        entries = record.get(name, [])
        record[name] = []
        if not isinstance(entries, list):
            invalid(name)
            continue
        for entry in entries:
            if not isinstance(entry, dict):
                invalid(name + ".entry")
                continue
            if any(not unsigned(entry.get(key)) or entry[key] == 0 for key in ("e", "i")):
                invalid(name + ".identity")
                continue
            record[name].append(entry)
            if name == "fd":
                fields(entry, ("v",), lambda value: type(value) is int and 0 <= value < 256, name)
                fields(entry, ("bv", "qbp", "qap", "qas", "qhw", "iuc", "ifc", "isc",
                               "fuc", "ffc", "fsc"), unsigned32, name)
                fields(entry, ("qoa",), unsigned, name)
                fields(entry, ("su", "mg", "mp"), lambda value: type(value) is bool, name)
                numeric = ("st", "gt", "pt", "gc", "hc", "rc", "aq", "en", "sb",
                           "ps", "pw", "rdw", *BOUNDARY_CPU_FIELDS.values(),
                           *SUBMISSION_CALL_FIELDS.values())
                fields(entry, numeric, finite_number, name)
                for key in numeric:
                    if key in entry and entry[key] < 0:
                        invalid(name + "." + key)
                for key in ("v", "st", "gt", "pt", "hc", "rc", "aq", "en", "sb", "ps", "pw",
                            "su", "mg", "mp"):
                    if key not in entry:
                        invalid(name + ".missing." + key)
                continue
            fields(entry, ("v",), lambda value: type(value) is bool, name)
            fields(entry, ("tg",), unsigned32, name)
            fields(entry, ("ms",), finite_number, name)
            for key in ("v", "ms", "tg", "g"):
                if key not in entry:
                    invalid("gfd.missing." + key)
            if "ms" in entry and entry["ms"] < 0:
                invalid("gfd.ms")
            groups = entry.get("g", [])
            entry["g"] = []
            if not isinstance(groups, list):
                invalid("gfd.g")
                continue
            for group in groups:
                if not isinstance(group, dict) or not isinstance(group.get("n"), str):
                    invalid("gfd.g.entry")
                    continue
                entry["g"].append(group)
                fields(group, ("c",), unsigned32, "gfd.g")
                if "c" not in group or group["c"] == 0:
                    invalid("gfd.g.c")
                if not finite_number(group.get("ms")) or group["ms"] < 0:
                    invalid("gfd.g.ms")
                    group.pop("ms", None)
    return record


def investigation_field_errors(record):
    strings = ("run_id", "process_start", "executable_id", "scenario", "seed", "quality",
               "present_mode", "backend", "hardware", "os", "compiler", "optimization",
               "cache_policy", "terrain_variant", "terrain_sha256", "terrain_validation",
               "opaque_method", "phase", "terminal_outcome", "frame_boundary", "clock_domain")
    booleans = ("terrain_artifact_saved", "terminal", "visibility_interrupted",
                "frame_mapping_valid", "publication_failed", "measurement_started",
                "minimized", "hidden", "occluded")
    numbers = ("render_scale", "refresh_hz", "native_seconds", "clock_origin_seconds",
               "requested_warmup", "requested_duration", "actual_elapsed", "measured_started")
    validators = {key: lambda value: isinstance(value, str) for key in strings}
    validators.update({key: lambda value: type(value) is bool for key in booleans})
    validators.update({key: finite_number for key in numbers})
    validators.update({key: lambda value: type(value) is int and -(2**31) <= value < 2**31
                       for key in ("width", "height")})
    validators.update({key: lambda value: type(value) is int and 0 <= value < 2**64
                       for key in ("frame_epoch", "frame_index")})
    validators["clock_revision"] = lambda value: type(value) is int and 0 <= value < 2**32
    validators.update({key: lambda value: isinstance(value, list) and len(value) == 3
                       and all(finite_number(item) and abs(item) <= 3.4028234663852886e38
                               for item in value)
                       for key in ("camera_position", "camera_target")})
    return ["recording_investigation_field_invalid:" + key
            for key, validator in validators.items() if key in record and not validator(record[key])]


def recording_telemetry_errors(value):
    unsigned64 = lambda item: type(item) is int and 0 <= item < 2**64
    unsigned32 = lambda item: type(item) is int and 0 <= item < 2**32
    unsigned8 = lambda item: type(item) is int and 0 <= item < 256
    boolean = lambda item: type(item) is bool
    string = lambda item: isinstance(item, str)
    schemas = {}

    def schema(name, groups):
        schemas[name] = {key: predicate for keys, predicate in groups for key in keys.split()}

    schema("root", [
        ("rt om odm sbc hz", unsigned32),
        ("sq wf px i fdd d di vd rp mc", unsigned64),
        ("fl fm fp f50 f95 f99 gl gm gp bt mr pr aq en sb ps fc", finite_number),
        ("gv", boolean), ("grr", string),
        ("grl", lambda item: item in ("Unknown", "Reliable", "Unreliable", "Unsupported")
         if isinstance(item, str) else unsigned8(item)),
        ("rs", lambda item: finite_number(item) and abs(item) <= 3.4028234663852886e38),
        ("ww wh tw th", lambda item: type(item) is int and -(2**31) <= item < 2**31),
    ])
    schema("gh", [("o s q m sf rf g t sc cr ie ii ib it ign isu", unsigned64),
                  ("co ch ip is iqb iqe", unsigned32), ("iv", boolean), ("il", string)])
    schema("rl", [("v", unsigned32), ("s g r", string)])
    schema("gfd", [("e i", unsigned64), ("ms", finite_number),
                   ("v", boolean), ("tg", unsigned32)])
    schema("g", [("n", string), ("ms", finite_number), ("c", unsigned32)])
    schema("gg", [("n", string), ("l m k", finite_number), ("c", unsigned32)])
    schema("p", [("n", string), ("l m k", finite_number)])
    schema("fd", [
        ("e i qoa", unsigned64), ("su mg mp", boolean), ("v", unsigned8),
        ("bv qbp qap qas qhw iuc ifc isc fuc ffc fsc", unsigned32),
        ("rc rdw hc aq en sb ps pw st gt gc pt pi pre sta post flu upl cln inp fti "
         "hrl hrf hdr hpr hcu hun ium ifm ism fum ffm fsm", finite_number),
    ])
    errors = []
    pending = [("root", value, "y")]
    while pending:
        name, item, path = pending.pop()
        if not isinstance(item, dict):
            errors.append("recording_field_invalid:tel." + path)
            continue
        for key, predicate in schemas[name].items():
            if key in item and not predicate(item[key]):
                errors.append("recording_field_invalid:tel." + path + "." + key)
        children = ("gh", "rl", "gfd", "fd", "gg", "p") if name == "root" else (
            ("g",) if name == "gfd" else ())
        for key in children:
            if key not in item:
                continue
            child_path = path + "." + key
            if key in ("gh", "rl"):
                pending.append((key, item[key], child_path))
            elif not isinstance(item[key], list):
                errors.append("recording_field_invalid:tel." + child_path)
            else:
                pending.extend((key, child, child_path + "." + str(index))
                               for index, child in enumerate(item[key]))
    return errors


def recording_field_errors(record):
    string_value = lambda value: isinstance(value, str)
    boolean_value = lambda value: type(value) is bool
    integer_value = lambda value: type(value) is int and -(2**63) <= value < 2**63
    float32_value = lambda value: finite_number(value) and abs(value) <= 3.4028234663852886e38
    schemas = {
        "run": {"t": finite_number, "m": string_value, "p": integer_value,
                "x": string_value, "i": finite_number},
        "sample": {**{key: float32_value for key in ("r", "f", "v", "c", "su", "st", "g")},
                   "t": finite_number,
                   "q": lambda value: type(value) is int and 0 <= value < 256},
        "phase": {"t": finite_number, "name": string_value},
        "activation": {"t": finite_number, "attempt": integer_value,
                       "requested": boolean_value, "known": boolean_value},
        "end": {"t": finite_number, "r": string_value, "e": boolean_value,
                "c": lambda value: type(value) is int and -(2**31) <= value < 2**31,
                "s": integer_value, "z": boolean_value},
        "tel": {"t": finite_number, "y": lambda value: isinstance(value, dict)},
    }
    kind = record.get("k")
    if not isinstance(kind, str):
        return ["recording_kind_invalid"]
    errors = ["recording_field_invalid:" + kind + "." + key
              for key, predicate in schemas.get(kind, {}).items()
              if key in record and not predicate(record[key])]
    if kind == "tel" and isinstance(record.get("y"), dict):
        errors.extend(recording_telemetry_errors(record["y"]))
    return errors


def evaluate_capture(telemetry_path, scenario_path, binary_paths=None, recording_path=None):
    telemetry_path = Path(telemetry_path)
    scenario_path = Path(scenario_path)
    telemetry_errors = []
    input_errors = []

    def input_hash(path, label):
        try:
            return sha256(path)
        except OSError:
            input_errors.append("input_hash_unavailable:" + label)
            return None

    telemetry_hash = input_hash(telemetry_path, "telemetry")
    scenario_hash = input_hash(scenario_path, "scenario")
    records = []
    try:
        for line in telemetry_path.read_text().splitlines():
            if not line.strip():
                continue
            try:
                record = json.loads(line)
                if not isinstance(record, dict):
                    raise ValueError("telemetry record is not an object")
                records.append(normalize_telemetry(record, telemetry_errors))
            except ValueError:
                telemetry_errors.append("malformed_telemetry_record")
    except (OSError, UnicodeError):
        telemetry_errors.append("telemetry_unavailable")
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
        if not finite_number(native_seconds) or native_seconds < 0:
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
    identity_errors = []
    if any(value is None or value == "" for value in scenario_identity.values()):
        identity_errors.append("scenario_identity_incomplete")
    if scenario_identity["scenario"] not in ("ocean", "terrain-edit", "streaming"):
        identity_errors.append("unsupported_scenario")
    if scenario_identity["quality"] not in ("fixed", "adaptive"):
        identity_errors.append("invalid_scenario_quality")
    if any(type(scenario_identity[field]) is not int or scenario_identity[field] <= 0
           for field in ("width", "height")):
        identity_errors.append("invalid_scenario_dimensions")
    digest = scenario_identity["terrain_sha256"]
    if not isinstance(digest, str) or len(digest) != 64 or any(char not in "0123456789abcdef" for char in digest):
        identity_errors.append("invalid_terrain_hash")
    if any(record.get(field) != value for record in scenario_records for field, value in scenario_identity.items()):
        identity_errors.append("scenario_identity_changed")
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
    if not finite_number(refresh_hz) or refresh_hz < 0:
        identity_errors.append("invalid_scenario_refresh_rate")
        refresh_hz = 0
    reliability = None
    reliability_reason = None
    reliability_verified = True
    transport_failures = dict.fromkeys(("pd", "pfd", "pdd", "eo"), 0)
    for record in records:
        for field in transport_failures:
            transport_failures[field] = max(transport_failures[field], record.get(field, 0))
        delivery_dropped = max(delivery_dropped, record.get("fdd", 0))
        write_failures = max(write_failures, record.get("wf", 0))
        pump_exhausted = max(pump_exhausted, record.get("px", 0))
        current_health = record.get("gh", {})
        for field in HEALTH_FIELDS:
            health[field] += current_health.get(field, 0)
        completion_high_water = max(completion_high_water, current_health.get("ch", 0))
        if record.get("rt") != 1:
            continue
        if "sq" in record:
            sequences.append(record["sq"])
        scope = record.get("rl", {})
        reliability = scope.get("g", reliability)
        reliability_reason = scope.get("r", reliability_reason)
        reliability_verified &= (
            scope.get("v") == 1 and scope.get("s") == "gpu_pass"
            and scope.get("g") == "reliable"
            and scope.get("r") == "completion_gated_metal_resolve"
        )
        for frame in record.get("gfd", []):
            frame_identity = (frame.get("e", 0), frame.get("i", 0))
            if frame_identity in raw_identities:
                duplicate_raw_identities += 1
            raw_identities.add(frame_identity)
            raw_frames[frame_identity] = frame
            if not frame.get("v", False):
                health["invalid_gpu_frame"] = health.get("invalid_gpu_frame", 0) + 1
            if frame.get("tg", 0):
                health["truncated_gpu_frame_groups"] = health.get("truncated_gpu_frame_groups", 0) + frame["tg"]
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
            validity = delivery.get("v", 0)
            fields = {
                "renderer": "rc",
                "acquire": "aq",
                "encode": "en",
                "submit": "sb",
                "present_call": "ps",
            }
            if validity & 8:
                fields["host"] = "hc"
            if validity & 16:
                fields["pacer_wait"] = "pw"
            for name, field in fields.items():
                value = delivery.get(field)
                if value is None:
                    continue
                if not finite_number(value) or value < 0:
                    invalid_cpu_durations += 1
                    continue
                cpu_metrics[name].append(value)
            boundary_version = delivery.get("bv", 0)
            boundary_versions.add(boundary_version)
            if boundary_version in (2, 3):
                if validity & 8 == 0 or validity & 16 == 0:
                    incomplete_boundary_frames += 1
                    continue
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
                    valid_detail = all(finite_number(delivery[field]) and delivery[field] >= 0
                                       for field in required)
                    detail_fields = {**BOUNDARY_CPU_FIELDS, **PRESSURE_FIELDS, **SUBMISSION_CALL_FIELDS}
                    if boundary_version == 3:
                        detail_fields["renderer_draw"] = "rdw"
                    for name, field in detail_fields.items():
                        value = delivery[field]
                        if not finite_number(value) or value < 0:
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
                        evidence = classify_boundary_frame(delivery, renderer_unaccounted)
                        classifications.append({
                            "epoch": delivery_identity[0],
                            "frame": delivery_identity[1],
                            "host_ms": delivery["hc"],
                            "acquire_ms": delivery["aq"],
                            **evidence,
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
                if finite_number(delivery.get("gc")) and delivery["gc"] >= 0:
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
            if isinstance(name, str) and finite_number(milliseconds) and milliseconds >= 0:
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
        "packet_drops": transport_failures["pd"],
        "packet_gpu_frames_dropped": transport_failures["pfd"],
        "packet_deliveries_dropped": transport_failures["pdd"],
        "encode_overflows": transport_failures["eo"],
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
        binaries[name] = {"path": str(path), "sha256": input_hash(path, "binary." + name)}
    recording = None
    recording_healthy = True
    recording_protocol_reasons = []
    if recording_path:
        recording_path = Path(recording_path)
        try:
            with recording_path.open("rb") as handle:
                recording_bytes = handle.read(16 * 1024 * 1024 + 1)
            if len(recording_bytes) > 16 * 1024 * 1024:
                recording_protocol_reasons.append("recording_size_limit_exceeded")
                raise ValueError("recording exceeds native size limit")
            if any(len(line) > 64 * 1024 for line in recording_bytes.split(b"\n")):
                recording_protocol_reasons.append("recording_line_limit_exceeded")
                raise ValueError("recording exceeds native line limit")
            recording_text = recording_bytes.decode("utf-8")
            if not recording_text.endswith("\n"):
                recording_protocol_reasons.append("recording_unterminated_tail")
            if any(not line.strip() for line in recording_text.splitlines()):
                recording_protocol_reasons.append("recording_blank_record")
            recording_records = [json.loads(line) for line in recording_text.splitlines() if line.strip()]
            if any(not isinstance(record, dict) for record in recording_records):
                recording_records = []
        except (OSError, UnicodeError, ValueError):
            recording_records = []
        health_records = [record for record in recording_records if record.get("k") == "telemetry_health"]
        end_records = [record for record in recording_records if record.get("k") == "end"]
        recording_complete = len(health_records) == 1 and len(end_records) == 1
        metadata = [record for record in recording_records if record.get("k") == "run"]
        if len(metadata) != 1 or type(metadata[0].get("v")) is not int or metadata[0]["v"] not in (1, 2):
            recording_protocol_reasons.append("recording_metadata_invalid")
        elif not recording_records or recording_records[0].get("k") != "run":
            recording_protocol_reasons.append("recording_metadata_not_first")
        for record in recording_records:
            recording_protocol_reasons.extend(recording_field_errors(record))
            if record.get("k") == "investigation":
                recording_protocol_reasons.extend(investigation_field_errors(record))
            if record.get("k") == "investigation" and (
                type(record.get("v")) is not int or record["v"] not in (1, 2)
            ):
                recording_protocol_reasons.append("recording_investigation_version_unsupported")
        recording_health = health_records[0] if health_records else {}
        terminal = end_records[0] if end_records else {}
        integer_fields = ("invalid_lines", "parse_errors", "resets", "read_errors",
                          "pending_bytes", "startup_absent")
        boolean_fields = ("discarding", "unfinished_tail", "drain_exhausted")
        if any(type(recording_health.get(field)) is not int
               or not 0 <= recording_health[field] < 2**(63 if field == "pending_bytes" else 64)
               for field in integer_fields) or any(
            type(recording_health.get(field)) is not bool for field in boolean_fields
        ):
            recording_protocol_reasons.append("recording_health_fields_invalid")
        if type(terminal.get("c")) is not int:
            recording_protocol_reasons.append("recording_exit_code_invalid")
        recording_failures = {
            field: recording_health.get(field, 0)
            for field in ("invalid_lines", "parse_errors", "resets", "read_errors", "pending_bytes")
        }
        for field in boolean_fields:
            recording_failures[field] = recording_health.get(field, False)
        recording_healthy = (
            recording_complete
            and recording_records[-1] == terminal
            and all(value == 0 for value in recording_failures.values())
            and terminal.get("e") is True
            and terminal.get("c") == 0
            and terminal.get("z") is False
        )
        recording = {
            "path": str(recording_path),
            "sha256": input_hash(recording_path, "recording"),
            "telemetry_health": recording_health,
            "terminal": terminal,
            "failures": recording_failures,
            "healthy": recording_healthy,
        }
    accepted = healthy and complete_groups and recording_healthy and scenario_error is None and not identity_errors
    qualification_reasons = [] if frame_owned else ["scenario_frame_clock_mapping_unverified"]
    qualification_reasons.extend(telemetry_errors)
    qualification_reasons.extend(input_errors)
    qualification_reasons.extend(sorted(set(recording_protocol_reasons)))
    qualification_reasons.extend("full_capture_failure:" + name
                                 for name, count in failures.items() if count != 0)
    if recording is not None and not recording_healthy:
        qualification_reasons.append("recording_completion_or_health_failed")
    if not reliability_verified or not sequences:
        qualification_reasons.append("full_capture_reliability_unverified")
    if sequences and (sequences[0] != 1 or any(
        current != previous + 1 for previous, current in zip(sequences, sequences[1:])
    )):
        qualification_reasons.append("raw_sequence_origin_or_order_invalid")
    if recording is None:
        qualification_reasons.append("recording_completion_unverified")
    if not delivery_frames:
        qualification_reasons.append("no_measured_deliveries")
    if frame_owned and any(
        delivery.get("v") != 31 or delivery.get("su") is not True
        for delivery in delivery_frames_by_identity.values()
    ):
        qualification_reasons.append("measured_delivery_validity_incomplete")
    for identity in exact_joined:
        groups = raw_frames[identity].get("g", [])
        names = [group.get("n") for group in groups]
        if any(names.count(name) != 1 for name in REQUIRED_GROUPS) or any(
            not finite_number(group.get("ms")) or group["ms"] < 0 for group in groups
        ):
            qualification_reasons.append("measured_frame_groups_incomplete")
            break
    if scenario_error is not None:
        qualification_reasons.append("scenario_history_unavailable_or_malformed")
    qualification_reasons.extend(sorted(set(timestamp_errors)))
    qualification_reasons.extend(identity_errors)
    if frame_owned:
        qualification_reasons.extend(scenario_validation["reasons"])
        if not scenario_validation["reasons"]:
            full_deliveries = {
                (delivery.get("e"), delivery.get("i")): delivery
                for record in records if record.get("rt") == 1
                for delivery in record.get("fd", [])
            }
            qualification_reasons.extend(verify_delivery_mapping(scenario_records, full_deliveries))
    if not measured_ranges:
        qualification_reasons.append("no_bounded_measured_phase")
    if measured_started is not None:
        qualification_reasons.append("open_measured_tail")
    if not any(record.get("terminal_outcome") == "completed" for record in scenario_records):
        qualification_reasons.append("scenario_completion_unproven")
    if not accepted:
        qualification_reasons.append("legacy_analysis_checks_failed")
    exact_gpu_ms = [raw_frames[identity].get("ms") for identity in exact_joined]
    exact_gpu_ms = [value for value in exact_gpu_ms if finite_number(value) and value >= 0]
    long_frames = [item for item in classifications if item["host_ms"] > 9.167]
    acquire_frames = [item for item in classifications if item["acquire_ms"] > 1]
    host_p95 = percentile([item["host_ms"] for item in classifications], 0.95)
    p95_host_frames = [item for item in classifications if host_p95 is not None and item["host_ms"] >= host_p95]
    detailed_cpu_frames = boundary_metrics["host_closure_error"]
    complete_classifications = [item for item in classifications if item["evidence_complete"]]
    complete_long_frames = [item for item in long_frames if item["evidence_complete"]]
    complete_acquire_frames = [item for item in acquire_frames if item["evidence_complete"]]
    complete_p95_host_frames = [item for item in p95_host_frames if item["evidence_complete"]]
    classification_coverage = len(complete_classifications) / delivery_frames if delivery_frames else 0
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
        "telemetry_sha256": telemetry_hash,
        "scenario": str(scenario_path),
        "scenario_sha256": scenario_hash,
        "scenario_error": scenario_error,
        "binaries": binaries,
        "recording": recording,
        "identity": scenario_identity,
        "observed_phases": sorted({record.get("phase") for record in scenario_records if isinstance(record.get("phase"), str)}),
        "qualification_route": "frame_owned_v2" if frame_owned else "legacy_unqualified",
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
            "long_frames_classified": len(complete_long_frames),
            "acquire_frames": len(acquire_frames),
            "acquire_frames_classified": len(complete_acquire_frames),
            "p95_host_threshold_ms": host_p95,
            "p95_host_frames": len(p95_host_frames),
            "p95_host_frames_classified": len(complete_p95_host_frames),
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
        "observation_counts": {
            "drawable_acquisition": sum(
                "drawable_acquisition" in item["secondary_observations"] for item in classifications
            ),
            "finish_or_submit": sum(
                "finish_or_submit" in item["secondary_observations"] for item in classifications
            ),
            "presentation_pacing": sum(
                "presentation_pacing" in item["secondary_observations"] for item in classifications
            ),
            "submission_pressure": sum(
                "submission_pressure" in item["pressure_correlates"] for item in classifications
            ),
        },
        "deadline_samples": deadline_samples,
        "deadline_misses": deadline_misses,
        "healthy": healthy,
        "complete_groups": complete_groups,
        "accepted": accepted,
        "qualified": not qualification_reasons,
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
