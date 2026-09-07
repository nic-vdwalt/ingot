import base64
import struct


def packed_words(words, count):
    if len(words) != count or any(type(word) is not int or not 0 <= word <= 0xffffffff
                                  for word in words):
        raise ValueError("invalid u32 word array")
    return struct.pack("<" + "I" * count, *words)


def window_geometry(payload, draw):
    if payload.get("version") not in (6, 7):
        raise ValueError("unsupported geometry schema")
    identity = draw.get("geometry_id", 0)
    geometry = payload["geometry"]
    if type(identity) is not int or not 0 < identity <= len(geometry) <= 16:
        raise ValueError("missing geometry identity")
    if not draw.get("projection_known") or not draw.get("indexed"):
        raise ValueError("incomplete window draw")
    if draw.get("path") not in (1, "Batch_Builtin") or not draw.get("known"):
        raise ValueError("not a known built-in batch draw")
    entry = geometry[identity - 1]
    vertices, indices = entry["vertices"], entry["indices"]
    if not 0 < len(vertices) <= 2048 or not 0 < len(indices) <= 4096:
        raise ValueError("geometry exceeds retention bounds")
    if draw["count"] != len(indices) or draw["instances"] != 1:
        raise ValueError("draw geometry mismatch")
    if any(type(index) is not int or not 0 <= index < len(vertices) for index in indices):
        raise ValueError("index outside retained vertices")
    vertex_bytes = bytearray()
    for vertex in vertices:
        vertex_bytes.extend(packed_words(vertex["position_bits"], 2))
        vertex_bytes.extend(packed_words(vertex["color_bits"], 4))
        vertex_bytes.extend(packed_words(vertex["uv_bits"], 2))
        if vertex["mode"] not in (0, 1):
            raise ValueError("unsupported vertex mode")
        vertex_bytes.extend(packed_words([vertex["mode"]], 1))
    return (bytes(vertex_bytes), packed_words(indices, len(indices)),
            packed_words(draw["projection_bits"], 4))


ATLAS_DIM = 2048
ATLAS_UPLOADS_MAX = 256
ATLAS_BYTES_MAX = 1024 * 1024


def atlas_pixels(payload, draw):
    if payload.get("version") != 7 or not draw.get("atlas_known"):
        raise ValueError("unsupported or incomplete atlas evidence")
    identity = draw["atlas_id"]
    prefix = draw["atlas_upload_count"]
    uploads = payload["atlas_uploads"]
    if not 0 < identity <= payload["atlas_count"]:
        raise ValueError("invalid atlas identity")
    if not 0 <= prefix <= len(uploads) <= ATLAS_UPLOADS_MAX:
        raise ValueError("invalid upload prefix")
    encoded = payload["atlas_bytes"]
    if isinstance(encoded, str):
        if len(encoded) > 4 * ((ATLAS_BYTES_MAX + 2) // 3):
            raise ValueError("atlas bytes exceed budget")
        data = base64.b64decode(encoded, validate=True)
    else:
        if len(encoded) > ATLAS_BYTES_MAX:
            raise ValueError("atlas bytes exceed budget")
        data = bytes(encoded)
    if len(data) > ATLAS_BYTES_MAX:
        raise ValueError("atlas bytes exceed budget")
    output = bytearray(ATLAS_DIM * ATLAS_DIM)
    for upload in uploads[:prefix]:
        if upload["atlas_id"] != identity:
            continue
        x, y = upload["x"], upload["y"]
        width, height = upload["width"], upload["height"]
        offset, count = upload["byte_offset"], upload["byte_count"]
        if not (0 <= x < ATLAS_DIM and 0 <= y < ATLAS_DIM
                and 0 < width <= ATLAS_DIM - x
                and 0 < height <= ATLAS_DIM - y
                and count == width * height
                and 0 <= offset <= len(data) - count):
            raise ValueError("invalid atlas upload range")
        for row in range(height):
            source = offset + row * width
            target = (y + row) * ATLAS_DIM + x
            output[target:target + width] = data[source:source + width]
    return output
