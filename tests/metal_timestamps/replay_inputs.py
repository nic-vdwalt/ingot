import base64


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
