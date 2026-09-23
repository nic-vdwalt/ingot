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
    if checked_u32(payload.get("version")) not in (6, 7, 8, 9, 10, 11):
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
# Upload budget by export schema: the v6 loading capture saturated 256 before
# its first frame, so schema 10 exporters retain up to 2048.
ATLAS_UPLOADS_MAX_BY_VERSION = {7: 256, 8: 256, 9: 256, 10: 2048, 11: 2048}
ATLAS_BYTES_MAX = 1024 * 1024


def atlas_pixels(payload, draw):
    checked_object(payload)
    checked_object(draw)
    version = checked_u32(payload.get("version"))
    if version not in ATLAS_UPLOADS_MAX_BY_VERSION or draw.get("atlas_known") is not True:
        raise ValueError("unsupported or incomplete atlas evidence")
    uploads_max = ATLAS_UPLOADS_MAX_BY_VERSION[version]
    identity = checked_u32(draw.get("atlas_id"))
    prefix = checked_u32(draw.get("atlas_upload_count"))
    uploads = checked_array(payload.get("atlas_uploads"), uploads_max)
    atlas_count = checked_u32(payload.get("atlas_count"))
    if not 0 < identity <= atlas_count:
        raise ValueError("invalid atlas identity")
    if not 0 <= prefix <= len(uploads) <= uploads_max:
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


# Pinned wgpu enum values (tools/odin-902106f/vendor/wgpu/wgpu.odin) the batch
# pipeline contract is written against. Any other value is a different pipeline.
VERTEX_FLOAT32X2 = 0x1D
VERTEX_FLOAT32X4 = 0x1F
VERTEX_UINT32 = 0x20
STEP_MODE_VERTEX = 1
TOPOLOGY_TRIANGLE_LIST = 4
FRONT_FACE_CCW = 1
CULL_MODE_NONE = 1
BLEND_ADD = 0
BLEND_ONE = 2
BLEND_ONE_MINUS_SRC_ALPHA = 6
BLEND_DST = 7
WRITE_MASK_ALL = 0xF
BATCH_PIPELINE_COUNT = 8
BLEND_SLOT_COUNT = 4
BATCH_ATTRIBUTES = (
    (VERTEX_FLOAT32X2, 0, 0),
    (VERTEX_FLOAT32X4, 8, 1),
    (VERTEX_FLOAT32X2, 24, 2),
    (VERTEX_UINT32, 32, 3),
)
BATCH_BLENDS = {
    0: (BLEND_ADD, BLEND_ONE, BLEND_ONE_MINUS_SRC_ALPHA),
    1: (BLEND_ADD, BLEND_ONE, BLEND_ONE),
    2: (BLEND_ADD, BLEND_DST, BLEND_ONE_MINUS_SRC_ALPHA),
}


def checked_blend(value):
    checked_object(value)
    return tuple(checked_u32(value.get(field))
                 for field in ("operation", "src_factor", "dst_factor"))


def batch_pipeline(payload, draw, record):
    """Return the retained descriptor the draw's (kind, blend) selected at the
    record's attachment format, verified against the fixed batch contract."""
    checked_object(payload)
    checked_object(draw)
    checked_object(record)
    if checked_u32(payload.get("version")) not in (9, 10, 11):
        raise ValueError("unsupported pipeline schema")
    kind = checked_u32(draw.get("pipeline_kind"))
    style = checked_u32(draw.get("pipeline_style"))
    if kind > 1 or style >= BLEND_SLOT_COUNT:
        raise ValueError("draw selects no batch pipeline")
    pipelines = checked_array(payload.get("batch_pipelines"), BATCH_PIPELINE_COUNT)
    if len(pipelines) != BATCH_PIPELINE_COUNT:
        raise ValueError("incomplete batch pipeline set")
    entry = checked_object(pipelines[style + kind * BLEND_SLOT_COUNT])
    if entry.get("known") is not True:
        raise ValueError("selected pipeline descriptor not retained")
    if checked_u32(entry.get("format")) != checked_u32(record.get("format")):
        raise ValueError("retained pipeline targets another format")
    if type(entry.get("vertex_stride")) is not int or entry["vertex_stride"] != 36:
        raise ValueError("unexpected vertex stride")
    if checked_u32(entry.get("step_mode")) != STEP_MODE_VERTEX:
        raise ValueError("unexpected vertex step mode")
    attributes = checked_array(entry.get("attributes"), 4)
    if len(attributes) != 4:
        raise ValueError("incomplete vertex attributes")
    for attribute, expected in zip(attributes, BATCH_ATTRIBUTES):
        checked_object(attribute)
        actual = (checked_u32(attribute.get("format")),
                  attribute.get("offset"), checked_u32(attribute.get("shader_location")))
        if type(actual[1]) is not int or actual != expected:
            raise ValueError("vertex attribute differs from batch contract")
    if (checked_u32(entry.get("topology")) != TOPOLOGY_TRIANGLE_LIST or
            checked_u32(entry.get("front_face")) != FRONT_FACE_CCW or
            checked_u32(entry.get("cull_mode")) != CULL_MODE_NONE or
            entry.get("unclipped_depth") is not False):
        raise ValueError("unexpected primitive state")
    if (checked_u32(entry.get("sample_count")) != 1 or
            checked_u32(entry.get("sample_mask")) != 0xffffffff or
            entry.get("alpha_to_coverage") is not False):
        raise ValueError("unexpected multisample state")
    if entry.get("blend_enabled") is not True:
        raise ValueError("blend disabled on a blendable window target")
    color = checked_blend(entry.get("blend_color"))
    alpha = checked_blend(entry.get("blend_alpha"))
    if style not in BATCH_BLENDS or color != BATCH_BLENDS[style] or alpha != color:
        raise ValueError("blend state differs from the recorded style")
    if type(entry.get("write_mask")) is not int or entry["write_mask"] != WRITE_MASK_ALL:
        raise ValueError("unexpected colour write mask")
    return entry


MAX_SPANS = 64


def submission_topology(payload, record):
    """Return the replayable command topology of the record's submission.

    Only the single-span, single-encoder shape is replayable today: one timed
    pass, then resolve + copy in the same encoder, one submit, one map request.
    Any other recorded shape is an explicit rejection, not a truncation."""
    checked_object(payload)
    checked_object(record)
    if checked_u32(payload.get("version")) < 11:
        raise ValueError("submission topology not exported before schema 11")
    span_count = checked_u32(record.get("span_count"))
    encoder_spans = checked_u32(record.get("encoder_spans"))
    query_begin = checked_u32(record.get("query_begin"))
    if not 0 < span_count <= MAX_SPANS or query_begin % 2 or query_begin // 2 >= span_count:
        raise ValueError("span index outside the submitted span set")
    if not 0 < encoder_spans <= span_count:
        raise ValueError("encoder span count inconsistent with the submission")
    for field in ("encoder_id", "resolve_encoder_id", "submit_ordinal", "resolve_ordinal"):
        if type(record.get(field)) is not int or not 0 < record[field] < 2**64:
            raise ValueError("missing submission identity")
    if record["resolve_encoder_id"] != record["encoder_id"]:
        raise ValueError("resolve recorded in another encoder")
    if record["resolve_ordinal"] != record["submit_ordinal"]:
        raise ValueError("resolve and submit ordinals differ")
    if span_count != 1 or encoder_spans != 1:
        raise ValueError("multi-span submission topology is not replayable yet")
    return dict(spans=1, encoders=1,
                sequence=["pass", "resolve_query_set", "copy_buffer_to_buffer", "submit",
                          "map_async"])
