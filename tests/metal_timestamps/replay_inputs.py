import base64
import struct


def checked_u32(value):
    if type(value) is not int or not 0 <= value <= 0xffffffff:
        raise ValueError("invalid u32")
    return value


def checked_object(value):
    if type(value) is not dict:
        raise ValueError("expected object")
    return value


def checked_array(value, maximum):
    if type(value) is not list or len(value) > maximum:
        raise ValueError("invalid bounded array")
    return value


def packed_words(words, count):
    checked_array(words, count)
    if len(words) != count or any(type(word) is not int or not 0 <= word <= 0xffffffff
                                  for word in words):
        raise ValueError("invalid u32 word array")
    return struct.pack("<" + "I" * count, *words)


def attachment_clear_bytes(record):
    checked_object(record)
    if record.get("clear_bits_known") is not True:
        raise ValueError("exact attachment clears unavailable")
    words = checked_array(record.get("color_clear_bits"), 4)
    if len(words) != 4 or any(type(word) is not int or not 0 <= word < 2**64
                              for word in words):
        raise ValueError("invalid f64 clear words")
    return struct.pack("<4Q", *words), packed_words([record.get("depth_clear_bits")], 1)


def window_geometry(payload, draw):
    checked_object(payload)
    checked_object(draw)
    if checked_u32(payload.get("version")) not in (6, 7, 8):
        raise ValueError("unsupported geometry schema")
    identity = draw.get("geometry_id", 0)
    geometry = checked_array(payload.get("geometry"), 16)
    if type(identity) is not int or not 0 < identity <= len(geometry) <= 16:
        raise ValueError("missing geometry identity")
    if draw.get("projection_known") is not True or draw.get("indexed") is not True:
        raise ValueError("incomplete window draw")
    path = draw.get("path")
    if not ((type(path) is int and path == 1) or path == "Batch_Builtin") \
            or draw.get("known") is not True:
        raise ValueError("not a known built-in batch draw")
    entry = checked_object(geometry[identity - 1])
    vertices = checked_array(entry.get("vertices"), 2048)
    indices = checked_array(entry.get("indices"), 4096)
    if not 0 < len(vertices) <= 2048 or not 0 < len(indices) <= 4096:
        raise ValueError("geometry exceeds retention bounds")
    if checked_u32(draw.get("count")) != len(indices) \
            or checked_u32(draw.get("instances")) != 1:
        raise ValueError("draw geometry mismatch")
    if any(type(index) is not int or not 0 <= index < len(vertices) for index in indices):
        raise ValueError("index outside retained vertices")
    vertex_bytes = bytearray()
    for vertex in vertices:
        checked_object(vertex)
        vertex_bytes.extend(packed_words(vertex.get("position_bits"), 2))
        vertex_bytes.extend(packed_words(vertex.get("color_bits"), 4))
        vertex_bytes.extend(packed_words(vertex.get("uv_bits"), 2))
        if checked_u32(vertex.get("mode")) not in (0, 1):
            raise ValueError("unsupported vertex mode")
        vertex_bytes.extend(packed_words([vertex["mode"]], 1))
    return (bytes(vertex_bytes), packed_words(indices, len(indices)),
            packed_words(draw.get("projection_bits"), 4))


ATLAS_DIM = 2048
ATLAS_UPLOADS_MAX = 256
ATLAS_BYTES_MAX = 1024 * 1024


def atlas_pixels(payload, draw):
    checked_object(payload)
    checked_object(draw)
    if checked_u32(payload.get("version")) not in (7, 8) or draw.get("atlas_known") is not True:
        raise ValueError("unsupported or incomplete atlas evidence")
    identity = checked_u32(draw.get("atlas_id"))
    prefix = checked_u32(draw.get("atlas_upload_count"))
    uploads = checked_array(payload.get("atlas_uploads"), ATLAS_UPLOADS_MAX)
    atlas_count = checked_u32(payload.get("atlas_count"))
    if not 0 < identity <= atlas_count:
        raise ValueError("invalid atlas identity")
    if not 0 <= prefix <= len(uploads) <= ATLAS_UPLOADS_MAX:
        raise ValueError("invalid upload prefix")
    encoded = payload.get("atlas_bytes")
    if isinstance(encoded, str):
        if len(encoded) > 4 * ((ATLAS_BYTES_MAX + 2) // 3):
            raise ValueError("atlas bytes exceed budget")
        data = base64.b64decode(encoded, validate=True)
    else:
        checked_array(encoded, ATLAS_BYTES_MAX)
        if any(type(value) is not int or not 0 <= value <= 255 for value in encoded):
            raise ValueError("invalid atlas byte")
        data = bytes(encoded)
    if len(data) > ATLAS_BYTES_MAX:
        raise ValueError("atlas bytes exceed budget")
    output = bytearray(ATLAS_DIM * ATLAS_DIM)
    for upload in uploads[:prefix]:
        checked_object(upload)
        upload_id = checked_u32(upload.get("atlas_id"))
        if not 0 < upload_id <= atlas_count:
            raise ValueError("invalid upload atlas identity")
        x, y, width, height, offset, count = (
            checked_u32(upload.get(field)) for field in
            ("x", "y", "width", "height", "byte_offset", "byte_count"))
        if not (0 <= x < ATLAS_DIM and 0 <= y < ATLAS_DIM
                and 0 < width <= ATLAS_DIM - x
                and 0 < height <= ATLAS_DIM - y
                and count == width * height
                and 0 <= offset <= len(data) - count):
            raise ValueError("invalid atlas upload range")
        if upload_id != identity:
            continue
        for row in range(height):
            source = offset + row * width
            target = (y + row) * ATLAS_DIM + x
            output[target:target + width] = data[source:source + width]
    return output
