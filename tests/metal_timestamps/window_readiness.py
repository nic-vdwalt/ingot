import argparse
import json
from pathlib import Path

from replay_inputs import atlas_pixels, window_geometry


def selected_window_readiness(payload, record):
    missing = []
    if type(payload) is not dict or type(record) is not dict:
        return dict(bundle_version=1, ready=False,
                    missing_inputs=[dict(field="root", reason="expected evidence objects")])

    def require(condition, field, reason):
        if not condition:
            missing.append(dict(field=field, reason=reason))

    require(type(payload.get("version")) is int and payload["version"] == 8,
            "version", "requires schema 8 selected-pass inputs")
    shader = payload.get("batch_shader")
    require(type(shader) is str and 0 < len(shader) <= 65536,
            "batch_shader", "compiled built-in shader source unavailable")
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
    require(type(record.get("sample_count")) is int and record["sample_count"] == 1,
            "sample_count", "requires single-sample window")
    require(type(record.get("format")) is int and record["format"] in (22, 27),
            "format", "requires captured RGBA8Unorm or BGRA8Unorm target")
    for field in ("width", "height", "encoder_id", "submit_ordinal", "resolve_ordinal",
                  "resolve_encoder_id", "epoch", "frame", "generation", "map_request"):
        value = record.get(field)
        require(type(value) is int and value > 0, field, "missing positive identity or extent")
    require(type(record.get("depth_format")) is int and record["depth_format"] == 0,
            "depth_format",
            "depth attachment replay not retained")
    label = record.get("label")
    require(type(label) is dict and label.get("length") == 6 and
            type(label.get("bytes")) is list and label["bytes"][:6] == list(b"window"),
            "label", "requires the actual window pass")
    require(type(record.get("callback_status")) is int and record["callback_status"] == 1,
            "callback_status", "successful map callback required")
    for field in ("query_begin", "slot_index", "begin_tick", "end_tick"):
        value = record.get(field)
        require(type(value) is int and 0 <= value < 2**64, field, "raw identity/sample missing")
    count = record.get("draw_count")
    draws = record.get("draws")
    valid_draws = (type(count) is int and 0 < count <= 4 and
                   type(draws) is list and count <= len(draws) <= 4)
    require(valid_draws, "draws", "complete ordered draw list unavailable")
    require(type(record.get("draws_dropped")) is int and record["draws_dropped"] == 0,
            "draws_dropped", "draw descriptors lost")
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
            require(type(draw.get("pipeline_kind")) is int and draw["pipeline_kind"] == 0,
                    prefix + ".pipeline_kind",
                    "only built-in Solid pipeline supported")
            require(type(draw.get("pipeline_style")) is int and draw["pipeline_style"] in (0, 1, 2),
                    prefix + ".pipeline_style",
                    "custom blend factors unavailable")
            require(type(draw.get("shader_id")) is int and draw["shader_id"] == 0,
                    prefix + ".shader_id", "custom shader unavailable")
            if draw.get("neutral_texture") is True:
                require(draw.get("atlas_id") == 0 and draw.get("atlas_known") is False,
                        prefix + ".texture", "contradictory neutral/atlas identity")
            else:
                require(type(draw.get("atlas_filter")) is int and 0 <= draw["atlas_filter"] <= 5,
                        prefix + ".atlas_filter", "unsupported atlas sampler")
                try:
                    atlas_pixels(payload, draw)
                except ValueError as error:
                    require(False, prefix + ".texture", str(error))
            scissor = draw.get("scissor")
            require(type(scissor) is list and len(scissor) == 4 and
                    all(type(value) is int and 0 <= value < 2**32 for value in scissor),
                    prefix + ".scissor", "invalid scissor rectangle")
            if (type(scissor) is list and len(scissor) == 4 and
                    all(type(value) is int and value >= 0 for value in scissor) and
                    type(record.get("width")) is int and type(record.get("height")) is int):
                require(scissor[0] + scissor[2] <= record["width"] and
                        scissor[1] + scissor[3] <= record["height"],
                        prefix + ".scissor", "scissor exceeds attachment")
    query = record.get("query_begin")
    require(type(query) is int and 0 <= query < 128 and query % 2 == 0,
            "query_begin", "requires an aligned retained timestamp pair")
    slot = record.get("slot_index")
    require(type(slot) is int and 0 <= slot < 8, "slot_index", "invalid physical query slot")
    previous = record.get("previous")
    require(type(previous) is dict and type(previous.get("valid")) is bool,
            "previous", "prior mapped sample availability must be explicit")
    if type(previous) is dict and previous.get("valid") is True:
        for field in ("epoch", "frame", "generation", "begin_tick", "end_tick"):
            value = previous.get(field)
            require(type(value) is int and 0 <= value < 2**64,
                    "previous." + field, "prior mapped identity/sample missing")
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
