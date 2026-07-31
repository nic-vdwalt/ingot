// The wire format: shared layout, checksum, and the primitive readers and
// writers both directions use.
//
// Goal: a byte layout that cannot drift with the target. Explicitly sized
// little-endian fields, written and read one at a time. Never a struct memcpy,
// which would let padding, field order and endianness leak into the file and
// make the format silently ABI-dependent.
//
// Method: the record layout is described once, as constants, and both encode
// and decode are written against it. The assertions are paired across the seam:
// what the encoder asserts about a well-formed document, the decoder checks
// about untrusted bytes. It is the pairing that catches an asymmetric change,
// not either side alone.
package view

VIEW_MAGIC :: [4]u8{'I', 'N', 'G', 'V'}
VIEW_FORMAT_VERSION :: u32(1)

// Header: magic, version, flags, node_count, text_length, checksum.
VIEW_HEADER_BYTES :: 24

// One record, field by field, in the order encode_node writes it:
//
//	kind          u8      flags         u16
//	parent        i32     first_child   i32     next_sibling  i32
//	key_offset    u32     key_length    u16
//	label_offset  u32     label_length  u16
//	value_offset  u32     value_length  u16
//	binding       i32
//	ink u8  text_role u8  gap u8  padding u8  align u8  justify u8  style u8
//	track: kind u8, basis i32, weight i32, percent f32, min i32, max i32
//	size_main i32  integer i32
//	number_lo f32  number_hi f32  number_step f32
//
// The total is derived from the field counts rather than hand-written. The
// first draft of this constant was wrong by two bytes, and the encoder's paired
// assertion caught it on the first test run; deriving it means the arithmetic
// cannot drift from the field list again.
VIEW_RECORD_U8S :: 9 // kind, ink, text_role, gap, padding, align, justify, style, track.kind
VIEW_RECORD_U16S :: 4 // flags, key_length, label_length, value_length
VIEW_RECORD_U32S :: 13 // 3 links, 3 offsets, binding, 4 track, size_main, integer
VIEW_RECORD_F32S :: 4 // track.percent, number_lo, number_hi, number_step
VIEW_RECORD_BYTES ::
	VIEW_RECORD_U8S + VIEW_RECORD_U16S * 2 + VIEW_RECORD_U32S * 4 + VIEW_RECORD_F32S * 4

// The largest a legal file can be. Decode rejects anything longer before it
// allocates or indexes, so an absurd length in a header cannot become work.
VIEW_FILE_BYTES_MAX :: VIEW_HEADER_BYTES + VIEW_RECORD_BYTES * VIEW_NODES_MAX + VIEW_TEXT_BYTES_MAX

#assert(VIEW_RECORD_BYTES > 0)
#assert(VIEW_FILE_BYTES_MAX > VIEW_HEADER_BYTES)

// view_checksum is the CRC-32 (IEEE, reflected) the header carries over the
// payload. It catches truncation and casual corruption; it is not a signature
// and is not claimed to be one. A view from an untrusted source is made safe by
// view_validate, not by this.
//
// It is public because it is part of the format: any tool that writes or
// patches a .ingv file needs the same function, and a second implementation
// would be a second chance to get the polynomial wrong.
view_checksum :: proc(payload: []u8) -> u32 {
	crc := ~u32(0)
	for byte in payload {
		crc ~= u32(byte)
		for _ in 0 ..< 8 {
			mask := -(crc & 1)
			crc = (crc >> 1) ~ (0xedb88320 & u32(mask))
		}
	}
	return ~crc
}

// Cursor tracks a position in a byte slice. Both directions use it so an
// off-by-one can only exist in one place.
@(private = "package")
Cursor :: struct {
	data: []u8,
	at:   int,
}

@(private = "package")
put_u8 :: proc(c: ^Cursor, value: u8) {
	assert(c != nil, "put_u8: nil cursor")
	assert(c.at + 1 <= len(c.data), "put_u8: buffer overrun")
	c.data[c.at] = value
	c.at += 1
}

@(private = "package")
put_u16 :: proc(c: ^Cursor, value: u16) {
	assert(c != nil, "put_u16: nil cursor")
	assert(c.at + 2 <= len(c.data), "put_u16: buffer overrun")
	c.data[c.at + 0] = u8(value)
	c.data[c.at + 1] = u8(value >> 8)
	c.at += 2
}

@(private = "package")
put_u32 :: proc(c: ^Cursor, value: u32) {
	assert(c != nil, "put_u32: nil cursor")
	assert(c.at + 4 <= len(c.data), "put_u32: buffer overrun")
	c.data[c.at + 0] = u8(value)
	c.data[c.at + 1] = u8(value >> 8)
	c.data[c.at + 2] = u8(value >> 16)
	c.data[c.at + 3] = u8(value >> 24)
	c.at += 4
}

@(private = "package")
put_i32 :: proc(c: ^Cursor, value: i32) {
	put_u32(c, u32(value))
}

// Floats go over the wire as their IEEE-754 bit pattern in the same
// little-endian order as every integer, so the file has exactly one byte order.
// This must transmute, not convert: u32(1.0) is 1, which would silently write
// the wrong bytes for every non-integral value.
@(private = "package")
put_f32 :: proc(c: ^Cursor, value: f32) {
	put_u32(c, transmute(u32)value)
}

// The readers return ok rather than asserting. Every byte they see came from a
// file, so a short read is an operating error and must be handled.
@(private = "package")
get_u8 :: proc(c: ^Cursor) -> (value: u8, ok: bool) {
	assert(c != nil, "get_u8: nil cursor")
	if c.at + 1 > len(c.data) do return 0, false
	value = c.data[c.at]
	c.at += 1
	return value, true
}

@(private = "package")
get_u16 :: proc(c: ^Cursor) -> (value: u16, ok: bool) {
	assert(c != nil, "get_u16: nil cursor")
	if c.at + 2 > len(c.data) do return 0, false
	value = u16(c.data[c.at + 0]) | (u16(c.data[c.at + 1]) << 8)
	c.at += 2
	return value, true
}

@(private = "package")
get_u32 :: proc(c: ^Cursor) -> (value: u32, ok: bool) {
	assert(c != nil, "get_u32: nil cursor")
	if c.at + 4 > len(c.data) do return 0, false
	value =
		u32(c.data[c.at + 0]) |
		(u32(c.data[c.at + 1]) << 8) |
		(u32(c.data[c.at + 2]) << 16) |
		(u32(c.data[c.at + 3]) << 24)
	c.at += 4
	return value, true
}

@(private = "package")
get_i32 :: proc(c: ^Cursor) -> (value: i32, ok: bool) {
	raw := get_u32(c) or_return
	return i32(raw), true
}

@(private = "package")
get_f32 :: proc(c: ^Cursor) -> (value: f32, ok: bool) {
	raw := get_u32(c) or_return
	return transmute(f32)raw, true
}

// get_enum reads a one-byte enum and rejects any value outside the declared
// range. Every enum in a record crosses the file boundary, so an out-of-range
// tag is the most likely way a corrupt file reaches a switch that assumes
// exhaustiveness.
@(private = "package")
get_enum :: proc(c: ^Cursor, $T: typeid, count: int) -> (value: T, ok: bool) {
	assert(count > 0, "get_enum: empty enum")
	raw := get_u8(c) or_return
	if int(raw) >= count do return T{}, false
	return T(raw), true
}
