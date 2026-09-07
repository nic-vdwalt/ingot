"""Export one certified selected-window failure as a replay bundle.

The bundle is the exact byte-level input set the pinned WebGPU replay
(`replay/main.odin`) consumes: captured WGSL, per-draw vertex/index bytes,
projection words, atlas pixels, retained pipeline descriptors, attachment
clear words, scissors and the single-span submission topology. Nothing is
defaulted: any input the capture did not retain is a rejection.
"""
import argparse
import hashlib
import json
import struct
from pathlib import Path

from replay_inputs import (atlas_pixels, attachment_clear_bytes, batch_pipeline,
                           checked_object, checked_u32, submission_topology,
                           window_geometry, ATLAS_DIM)
from window_readiness import selected_window_readiness

FRAGMENT_ENTRY_BY_KIND = {0: "fs_ui", 1: "fs_image"}
BUNDLE_VERSION = 1


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def export_bundle(payload, index, destination, build_dir=None, capture_path=None):
    checked_object(payload)
    failures = payload.get("failures")
    if type(failures) is not list or not 0 <= index < len(failures):
        raise ValueError("failure index outside the retained set")
    record = checked_object(failures[index])
    readiness = selected_window_readiness(payload, record, build_dir=build_dir,
                                          capture_path=capture_path)
    if readiness["ready"] is not True:
        raise ValueError("record is not replay ready: " +
                         json.dumps(readiness["missing_inputs"]))
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    shader = payload.get("batch_shader")
    if type(shader) is not str or not shader:
        raise ValueError("captured shader missing")
    (destination / "shader.wgsl").write_text(shader)
    clear_color, depth_clear = attachment_clear_bytes(record)
    topology = submission_topology(payload, record)
    draw_count = checked_u32(record.get("draw_count"))
    draws = record.get("draws")
    if type(draws) is not list or len(draws) < draw_count:
        raise ValueError("draw list shorter than draw_count")
    if checked_u32(record.get("draws_dropped")) != 0:
        raise ValueError("record dropped draws; the pass is not complete")
    manifest_draws = []
    projection = None
    atlases = {}
    for draw_index in range(draw_count):
        draw = checked_object(draws[draw_index])
        vertex_bytes, index_bytes, projection_bytes = window_geometry(payload, draw)
        if projection is None:
            projection = projection_bytes
        elif projection != projection_bytes:
            raise ValueError("draws within one pass used different projections")
        pipeline = batch_pipeline(payload, draw, record)
        kind = checked_u32(draw.get("pipeline_kind"))
        vertex_name = f"draw{draw_index}.vertices.bin"
        index_name = f"draw{draw_index}.indices.bin"
        (destination / vertex_name).write_bytes(vertex_bytes)
        (destination / index_name).write_bytes(index_bytes)
        atlas = None
        if draw.get("neutral_texture") is True:
            if checked_u32(draw.get("atlas_id")) != 0:
                raise ValueError("neutral draw names an atlas")
        else:
            atlas_id = checked_u32(draw.get("atlas_id"))
            pixels = atlas_pixels(payload, draw)
            name = f"atlas{atlas_id}.r8"
            prefix = checked_u32(draw.get("atlas_upload_count"))
            if atlas_id in atlases and atlases[atlas_id]["upload_prefix"] != prefix:
                raise ValueError("one atlas drawn at two upload prefixes in one pass")
            (destination / name).write_bytes(pixels)
            atlases[atlas_id] = {"file": name, "width": ATLAS_DIM, "height": ATLAS_DIM,
                                 "upload_prefix": prefix, "sha256": sha256_bytes(pixels)}
            atlas = {"atlas_id": atlas_id, "filter": checked_u32(draw.get("atlas_filter"))}
        scissor = draw.get("scissor")
        if type(scissor) is not list or len(scissor) != 4 or \
                any(type(v) is not int or v < 0 for v in scissor):
            raise ValueError("invalid scissor")
        manifest_draws.append({
            "vertices": vertex_name, "vertex_sha256": sha256_bytes(vertex_bytes),
            "indices": index_name, "index_sha256": sha256_bytes(index_bytes),
            "index_count": len(index_bytes) // 4,
            "fragment_entry": FRAGMENT_ENTRY_BY_KIND[kind],
            "pipeline": pipeline, "atlas": atlas, "scissor": scissor,
        })
    capture_sha = None
    if capture_path is not None:
        capture_sha = sha256_bytes(Path(capture_path).read_bytes())
    manifest = {
        "bundle_version": BUNDLE_VERSION,
        "source_capture_sha256": capture_sha,
        "readiness_bundle_version": readiness["bundle_version"],
        "schema_version": checked_u32(payload.get("version")),
        "failure_index": index,
        "frame": checked_u32(record.get("frame")),
        "epoch": checked_u32(record.get("epoch")),
        "slot_index": checked_u32(record.get("slot_index")),
        "submit_ordinal": record.get("submit_ordinal"),
        "observed": {"begin_tick": record.get("begin_tick"),
                     "end_tick": record.get("end_tick"),
                     "previous": record.get("previous"),
                     "callback_status": record.get("callback_status")},
        "attachment": {
            "width": checked_u32(record.get("width")),
            "height": checked_u32(record.get("height")),
            "format": checked_u32(record.get("format")),
            "load": checked_u32(record.get("load")),
            "store": checked_u32(record.get("store")),
            "sample_count": checked_u32(record.get("sample_count")),
            "depth_format": checked_u32(record.get("depth_format")),
            "color_clear_bits": list(struct.unpack("<4Q", clear_color)),
            "depth_clear_bits": struct.unpack("<I", depth_clear)[0],
        },
        "projection_bits": list(struct.unpack("<4I", projection)),
        "shader": "shader.wgsl", "shader_sha256": sha256_bytes(shader.encode()),
        "atlases": atlases,
        "draws": manifest_draws,
        "topology": topology,
    }
    (destination / "manifest.json").write_text(json.dumps(manifest, indent=1))
    return manifest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("capture")
    parser.add_argument("--failure", type=int, required=True)
    parser.add_argument("--dest", required=True)
    parser.add_argument("--build-dir")
    arguments = parser.parse_args()
    capture = Path(arguments.capture)
    payload = json.loads(capture.read_text())
    manifest = export_bundle(payload, arguments.failure, arguments.dest,
                             build_dir=Path(arguments.build_dir) if arguments.build_dir else None,
                             capture_path=capture)
    print(json.dumps({"frame": manifest["frame"], "draws": len(manifest["draws"]),
                      "atlases": sorted(manifest["atlases"])}))


if __name__ == "__main__":
    main()
