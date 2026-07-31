// Encoding a document to bytes.
//
// Goal: produce a file that view_decode can read back byte-identically on any
// target, and that a diff tool can show meaningfully.
//
// Method: field by field, little-endian, in the order wire.odin declares. The
// encoder asserts what it knows to be true of a document it just built; the
// decoder checks the same things about bytes it did not build. Encoding a
// document that would not validate is a programmer error and asserts, because
// writing a file that cannot be read back is never a recoverable situation.
package view

// view_encoded_size reports the exact byte length view_encode will write, so a
// caller can size a buffer without guessing or growing one.
view_encoded_size :: proc(view: View) -> int {
	assert(len(view.nodes) <= VIEW_NODES_MAX, "view_encoded_size: too many nodes")
	assert(len(view.text) <= VIEW_TEXT_BYTES_MAX, "view_encoded_size: text too long")
	return VIEW_HEADER_BYTES + VIEW_RECORD_BYTES * len(view.nodes) + len(view.text)
}

// view_encode writes view into out and returns the number of bytes written.
// It returns ok = false only when out is too small, which is the caller's
// concern; malformed content is an assertion, not a return value.
view_encode :: proc(view: View, out: []u8) -> (written: int, ok: bool) {
	assert(len(view.nodes) <= VIEW_NODES_MAX, "view_encode: too many nodes")
	assert(len(view.text) <= VIEW_TEXT_BYTES_MAX, "view_encode: text too long")
	size := view_encoded_size(view)
	if len(out) < size do return 0, false

	payload_at := VIEW_HEADER_BYTES
	body := Cursor {
		data = out[payload_at:size],
	}
	for node in view.nodes {
		encode_node(&body, node)
	}
	assert(body.at == VIEW_RECORD_BYTES * len(view.nodes), "view_encode: record size mismatch")
	copy(body.data[body.at:], view.text)
	body.at += len(view.text)
	assert(body.at == size - VIEW_HEADER_BYTES, "view_encode: payload size mismatch")

	header := Cursor {
		data = out[:payload_at],
	}
	magic := VIEW_MAGIC
	for byte in magic do put_u8(&header, byte)
	put_u32(&header, VIEW_FORMAT_VERSION)
	put_u32(&header, 0)
	put_u32(&header, u32(len(view.nodes)))
	put_u32(&header, u32(len(view.text)))
	put_u32(&header, view_checksum(out[payload_at:size]))
	assert(header.at == VIEW_HEADER_BYTES, "view_encode: header size mismatch")
	return size, true
}

// encode_node writes one record. The field order here is the format; it is
// mirrored exactly by decode_node, and the two are checked against each other
// by the record-size assertion above rather than by inspection.
@(private = "file")
encode_node :: proc(c: ^Cursor, node: View_Node) {
	assert(c != nil, "encode_node: nil cursor")
	start := c.at
	put_u8(c, u8(node.kind))
	put_u16(c, transmute(u16)node.flags)
	put_i32(c, node.parent)
	put_i32(c, node.first_child)
	put_i32(c, node.next_sibling)
	put_u32(c, node.key_offset)
	put_u16(c, node.key_length)
	put_u32(c, node.label_offset)
	put_u16(c, node.label_length)
	put_u32(c, node.value_offset)
	put_u16(c, node.value_length)
	put_i32(c, node.binding)
	put_u8(c, u8(node.ink))
	put_u8(c, u8(node.text_role))
	put_u8(c, u8(node.gap))
	put_u8(c, u8(node.padding))
	put_u8(c, u8(node.align))
	put_u8(c, u8(node.justify))
	put_u8(c, u8(node.style))
	encode_track(c, node)
	put_i32(c, node.size_main)
	put_i32(c, node.integer)
	put_f32(c, node.number_lo)
	put_f32(c, node.number_hi)
	put_f32(c, node.number_step)
	assert(c.at - start == VIEW_RECORD_BYTES, "encode_node: record size drifted")
}

@(private = "file")
encode_track :: proc(c: ^Cursor, node: View_Node) {
	assert(c != nil, "encode_track: nil cursor")
	put_u8(c, u8(node.track.kind))
	put_i32(c, node.track.basis)
	put_i32(c, node.track.weight)
	put_f32(c, node.track.percent)
	put_i32(c, node.track.min_size)
	put_i32(c, node.track.max_size)
}
