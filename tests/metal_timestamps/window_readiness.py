import argparse
import json
from pathlib import Path

from replay_inputs import atlas_pixels, window_geometry


def selected_window_readiness(payload, record):
    missing = []

    def require(condition, field, reason):
        if not condition:
            missing.append(dict(field=field, reason=reason))

    require(payload.get("version") == 7, "version", "requires schema 7 inputs")
    require(record.get("clear_bits_known") is True, "clear_bits_known",
            "exact attachment clear words were not retained")
    words = record.get("color_clear_bits")
    require(type(words) is list and len(words) == 4 and
            all(type(word) is int and 0 <= word < 2**64 for word in words),
            "color_clear_bits", "requires four exact f64 words")
    require(type(record.get("load")) is int and record["load"] == 2,
            "load", "initial attachment contents unavailable")
    require(type(record.get("store")) is int and record["store"] == 1,
            "store", "unsupported store contract")
    require(record.get("sample_count") == 1, "sample_count", "requires single-sample window")
    for field in ("width", "height", "encoder_id", "submit_ordinal", "resolve_ordinal",
                  "resolve_encoder_id", "epoch", "frame", "generation", "map_request"):
        value = record.get(field)
        require(type(value) is int and value > 0, field, "missing positive identity or extent")
    require(record.get("depth_format") in (0, "Undefined"), "depth_format",
            "depth attachment replay not retained")
    count = record.get("draw_count")
    draws = record.get("draws")
    valid_draws = (type(count) is int and 0 < count <= 4 and
                   type(draws) is list and count <= len(draws) <= 4)
    require(valid_draws, "draws", "complete ordered draw list unavailable")
    require(record.get("draws_dropped") == 0, "draws_dropped", "draw descriptors lost")
    if valid_draws:
        for index, draw in enumerate(draws[:count]):
            prefix = f"draws[{index}]"
            if type(draw) is not dict:
                require(False, prefix, "invalid draw object")
                continue
            try:
                window_geometry(payload, draw)
            except ValueError as error:
                require(False, prefix + ".geometry", str(error))
            require(draw.get("pipeline_kind") == 0, prefix + ".pipeline_kind",
                    "only built-in Solid pipeline supported")
            require(draw.get("pipeline_style") in (0, 1, 2), prefix + ".pipeline_style",
                    "custom blend factors unavailable")
            require(draw.get("shader_id") == 0, prefix + ".shader_id", "custom shader unavailable")
            if draw.get("neutral_texture") is not True:
                try:
                    atlas_pixels(payload, draw)
                except ValueError as error:
                    require(False, prefix + ".texture", str(error))
            scissor = draw.get("scissor")
            require(type(scissor) is list and len(scissor) == 4 and
                    all(type(value) is int and 0 <= value < 2**32 for value in scissor),
                    prefix + ".scissor", "invalid scissor rectangle")
    require(False, "source_manifest", "immutable actual-build shader/pipeline manifest required")
    require(False, "queue_topology", "complete producer/resolve command topology required")
    return dict(bundle_version=1, ready=False, missing_inputs=missing)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("capture", type=Path)
    parser.add_argument("--failure", type=int, default=0)
    args = parser.parse_args()
    payload = json.loads(args.capture.read_text())
    failures = payload.get("failures", [])
    if not 0 <= args.failure < len(failures):
        parser.error("failure index outside retained records")
    print(json.dumps(selected_window_readiness(payload, failures[args.failure]), indent=2))


if __name__ == "__main__":
    main()
