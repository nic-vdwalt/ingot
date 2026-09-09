import math


IDENTITY_FIELDS = (
    "scenario", "seed", "quality", "width", "height", "render_scale",
    "opaque_method", "terrain_sha256", "requested_warmup", "requested_duration",
)


def finite_number(value):
    return type(value) in (int, float) and math.isfinite(value)


def validate_scenario(records):
    reasons = set()
    ranges = []
    if not records or any(not isinstance(record, dict) for record in records):
        return {"reasons": ["scenario_history_unavailable_or_malformed"], "ranges": []}
    first = records[0]
    identity = {key: first.get(key) for key in IDENTITY_FIELDS}
    if any(value is None or value == "" for value in identity.values()):
        reasons.add("scenario_identity_incomplete")
    if any(record.get(key) != value for record in records for key, value in identity.items()):
        reasons.add("scenario_identity_changed")
    if first.get("scenario") not in ("ocean", "terrain-edit", "streaming"):
        reasons.add("unsupported_scenario")
    seed = first.get("seed")
    if not isinstance(seed, str) or not seed.isascii() or not seed.isdecimal() or len(seed) > 20:
        reasons.add("invalid_scenario_seed")
    elif int(seed) > 2**64 - 1:
        reasons.add("invalid_scenario_seed")
    if first.get("opaque_method") != "intact pass":
        reasons.add("scenario_topology_not_frozen")
    if first.get("quality") != "fixed" or not finite_number(first.get("render_scale")) or first.get("render_scale") != 1:
        reasons.add("scenario_quality_not_frozen")
    for field in ("width", "height"):
        if type(first.get(field)) is not int or first[field] <= 0:
            reasons.add("invalid_scenario_dimensions")
    digest = first.get("terrain_sha256")
    if not isinstance(digest, str) or len(digest) != 64 or any(
        char not in "0123456789abcdef" for char in digest
    ):
        reasons.add("invalid_terrain_hash")
    warmup, duration = first.get("requested_warmup"), first.get("requested_duration")
    bounds_valid = finite_number(warmup) and warmup >= 0 and finite_number(duration) and duration > 0
    if not bounds_valid:
        reasons.add("invalid_scenario_duration")
    previous_time = None
    previous_frame = None
    measured_start = None
    measured_seconds = None
    measurement_origin = None
    terminal_count = 0
    for index, record in enumerate(records):
        if type(record.get("v")) is not int or record.get("v") != 2 or record.get("clock_domain") != "context_monotonic_seconds" or type(record.get("clock_revision")) is not int or record.get("clock_revision") != 1:
            reasons.add("scenario_frame_clock_mapping_unverified")
        frame = (record.get("frame_epoch"), record.get("frame_index"))
        mapping_valid = all(type(value) is int and value > 0 for value in frame)
        if not mapping_valid or record.get("frame_mapping_valid") is not True or record.get("frame_boundary") != "before_game_draw":
            reasons.add("invalid_scenario_frame_mapping")
        if mapping_valid and previous_frame is not None:
            if frame[0] != previous_frame[0] or frame[1] <= previous_frame[1]:
                reasons.add("nonmonotonic_scenario_frame")
        if mapping_valid:
            previous_frame = frame
        seconds, elapsed = record.get("native_seconds"), record.get("actual_elapsed")
        times_valid = finite_number(seconds) and seconds >= 0 and finite_number(elapsed) and elapsed >= 0
        if not times_valid:
            reasons.add("invalid_scenario_timestamp")
        elif previous_time is not None and seconds < previous_time:
            reasons.add("nonmonotonic_scenario_timestamp")
        if times_valid:
            previous_time = seconds
            if finite_number(first.get("native_seconds")) and finite_number(first.get("actual_elapsed")):
                origin = first["native_seconds"] - first["actual_elapsed"]
                if abs(seconds - elapsed - origin) > 0.000001:
                    reasons.add("scenario_clock_origin_changed")
            if bounds_valid:
                started = record.get("measurement_started")
                start_time = record.get("measured_started")
                if started is True:
                    if not finite_number(start_time) or start_time > seconds or elapsed < warmup:
                        reasons.add("invalid_measured_start")
                    elif measurement_origin is None:
                        measurement_origin = start_time
                        if record.get("phase") != "measured" or start_time != seconds:
                            reasons.add("measured_start_boundary_missing")
                    elif start_time != measurement_origin:
                        reasons.add("measured_start_changed")
                    if record.get("phase") not in ("measured", "cooldown"):
                        reasons.add("scenario_phase_time_mismatch")
                elif started is not False or start_time != 0 or measurement_origin is not None:
                    reasons.add("invalid_measured_start")
                elif record.get("phase") != "warmup" or elapsed >= warmup:
                    reasons.add("scenario_phase_time_mismatch")
        if any(record.get(field) is not False for field in (
            "minimized", "hidden", "occluded", "visibility_interrupted", "publication_failed",
        )):
            reasons.add("scenario_visibility_or_publication_failure")
        phase = record.get("phase")
        if phase not in ("warmup", "measured", "cooldown"):
            reasons.add("invalid_scenario_phase")
        if phase == "measured" and measured_start is None:
            measured_start, measured_seconds = frame, seconds
        elif phase != "measured" and measured_start is not None:
            if mapping_valid and times_valid and finite_number(measured_seconds):
                ranges.append((measured_start[0], measured_start[1], frame[1]))
                if bounds_valid and seconds - measured_seconds < duration:
                    reasons.add("measured_duration_incomplete")
            measured_start = None
        if record.get("terminal") is True:
            terminal_count += 1
            if index != len(records) - 1 or phase != "cooldown" or record.get("terminal_outcome") != "completed":
                reasons.add("scenario_completion_unproven")
            if bounds_valid and times_valid and elapsed < warmup + duration:
                reasons.add("scenario_duration_incomplete")
        elif record.get("terminal") is not False or record.get("terminal_outcome") != "":
            reasons.add("invalid_terminal_state")
    if terminal_count != 1:
        reasons.add("scenario_completion_unproven")
    if measured_start is not None:
        reasons.add("open_measured_tail")
    if len(ranges) != 1:
        reasons.add("no_single_bounded_measured_phase")
    return {"reasons": sorted(reasons), "ranges": ranges if not reasons else []}


def verify_delivery_mapping(records, deliveries):
    reasons = set()
    first_origin = records[0].get("clock_origin_seconds") if records else None
    previous_boundary = None
    for record in records:
        origin = record.get("clock_origin_seconds")
        seconds = record.get("native_seconds")
        if not finite_number(origin) or origin <= 0 or origin != first_origin or not finite_number(seconds):
            reasons.add("delivery_clock_origin_unverified")
            continue
        boundary = origin + seconds
        frame = (record.get("frame_epoch"), record.get("frame_index"))
        if not all(type(value) is int and value > 0 for value in frame):
            reasons.add("invalid_scenario_frame_mapping")
            continue
        delivery = deliveries.get(frame)
        if delivery is None:
            reasons.add("scenario_boundary_delivery_missing")
            continue
        submitted = delivery.get("st")
        if not finite_number(submitted) or submitted < boundary:
            reasons.add("scenario_delivery_clock_mismatch")
        if previous_boundary is not None:
            previous_frame, previous_time = previous_boundary
            if all(type(value) is int for value in (*previous_frame, *frame)):
                owned = sorted(
                    (identity, item) for identity, item in deliveries.items()
                    if identity[0] == frame[0] and previous_frame[1] <= identity[1] < frame[1]
                )
                if frame[0] != previous_frame[0] or len(owned) != frame[1] - previous_frame[1]:
                    reasons.add("scenario_frame_ownership_gap")
                last_submit = None
                for _, item in owned:
                    timestamp = item.get("st")
                    if not finite_number(timestamp) or not previous_time <= timestamp < boundary:
                        reasons.add("scenario_delivery_clock_mismatch")
                    elif last_submit is not None and timestamp < last_submit:
                        reasons.add("scenario_delivery_boundary_order_invalid")
                    last_submit = timestamp if finite_number(timestamp) else None
            previous_delivery = deliveries.get(previous_frame, {})
            previous_submit = previous_delivery.get("st")
            if not finite_number(previous_submit) or previous_submit >= boundary or boundary <= previous_time:
                reasons.add("scenario_delivery_boundary_order_invalid")
        previous_boundary = (frame, boundary)
    return sorted(reasons)
