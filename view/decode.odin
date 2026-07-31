// Decoding bytes to a document.
//
// Goal: read any byte sequence at all without crashing, hanging, or producing a
// document that view_play could then trust wrongly.
//
// Method: nothing in this file asserts on file content. A corrupt, truncated,
// hostile or simply older file is an operating error, and this procedure is
// what handles it; TIGER_STYLE.md distinguishes that from a programmer error,
// and a view could plausibly arrive over a network, where crashing on bad bytes
// would be a denial of service.
//
// The header is checked before the payload is touched, the payload length is
// derived from checked header fields, and every enum tag is range-checked as it
// is read. A successful decode ends by running view_validate, so a caller that
// only calls view_decode still gets every structural guarantee.
package view

import "ingot:ui"

Decode_Fault :: enum u8 {
	None,
	Short_Header,
	Bad_Magic,
	Bad_Version,
	Reserved_Flags,
	Node_Count,
	Text_Length,
	Short_Payload,
	Trailing_Bytes,
	Checksum,
	Bad_Enum,
	Invalid_Document,
}

Decode_Result :: struct {
	fault:    Decode_Fault,
	validate: Validate_Result,
}

// view_decode reads bytes into doc. doc is left in a well-defined empty state
// on any failure, so a caller that ignores the fault still cannot play garbage.
view_decode :: proc(data: []u8, doc: ^View_Doc) -> (result: Decode_Result, ok: bool) {
	assert(doc != nil, "view_decode: nil doc")
	doc_reset(doc)
	if len(data) > VIEW_FILE_BYTES_MAX do return {fault = .Trailing_Bytes}, false

	node_count, text_length := 0, 0
	result, ok = decode_header(data, &node_count, &text_length)
	if !ok do return result, false

	payload := data[VIEW_HEADER_BYTES:]
	records := VIEW_RECORD_BYTES * node_count
	if len(payload) < records + text_length do return {fault = .Short_Payload}, false
	if len(payload) > records + text_length do return {fault = .Trailing_Bytes}, false

	body := Cursor {
		data = payload[:records],
	}
	for index in 0 ..< node_count {
		node, node_ok := decode_node(&body)
		if !node_ok do return {fault = .Bad_Enum}, false
		doc.nodes[index] = node
	}
	doc.count = i32(node_count)
	copy(doc.text[:], payload[records:records + text_length])
	doc.text_len = u32(text_length)

	// Structure is validated here rather than left to the caller, so that a
	// successful decode means exactly one thing: this document is safe to play.
	validate, valid := view_validate(view_of(doc))
	if !valid {
		doc_reset(doc)
		return {fault = .Invalid_Document, validate = validate}, false
	}
	return {}, true
}

// decode_header checks every header field before any of them is used to size or
// index the payload. Checking the counts first is what stops an absurd
// node_count from becoming work.
@(private = "file")
decode_header :: proc(
	data: []u8,
	node_count: ^int,
	text_length: ^int,
) -> (
	result: Decode_Result,
	ok: bool,
) {
	assert(node_count != nil && text_length != nil, "decode_header: nil out parameter")
	if len(data) < VIEW_HEADER_BYTES do return {fault = .Short_Header}, false
	header := Cursor {
		data = data[:VIEW_HEADER_BYTES],
	}
	expected := VIEW_MAGIC
	for index in 0 ..< len(expected) {
		byte, byte_ok := get_u8(&header)
		if !byte_ok || byte != expected[index] do return {fault = .Bad_Magic}, false
	}
	version, version_ok := get_u32(&header)
	if !version_ok do return {fault = .Short_Header}, false
	if version != VIEW_FORMAT_VERSION do return {fault = .Bad_Version}, false
	flags, flags_ok := get_u32(&header)
	if !flags_ok do return {fault = .Short_Header}, false
	if flags != 0 do return {fault = .Reserved_Flags}, false
	nodes, nodes_ok := get_u32(&header)
	if !nodes_ok do return {fault = .Short_Header}, false
	if nodes > u32(VIEW_NODES_MAX) do return {fault = .Node_Count}, false
	text, text_ok := get_u32(&header)
	if !text_ok do return {fault = .Short_Header}, false
	if text > u32(VIEW_TEXT_BYTES_MAX) do return {fault = .Text_Length}, false
	checksum, checksum_ok := get_u32(&header)
	if !checksum_ok do return {fault = .Short_Header}, false

	payload := data[VIEW_HEADER_BYTES:]
	span := VIEW_RECORD_BYTES * int(nodes) + int(text)
	if len(payload) < span do return {fault = .Short_Payload}, false
	if view_checksum(payload[:span]) != checksum do return {fault = .Checksum}, false

	node_count^ = int(nodes)
	text_length^ = int(text)
	return {}, true
}

// decode_node mirrors encode_node field for field. Every enum is range-checked
// as it is read, because an out-of-range tag would otherwise reach a switch
// that assumes the enum is exhaustive.
@(private = "file")
decode_node :: proc(c: ^Cursor) -> (node: View_Node, ok: bool) {
	assert(c != nil, "decode_node: nil cursor")
	start := c.at
	node.kind = get_enum(c, View_Kind, len(View_Kind)) or_return
	flags := get_u16(c) or_return
	node.flags = transmute(View_Flags)flags
	node.parent = get_i32(c) or_return
	node.first_child = get_i32(c) or_return
	node.next_sibling = get_i32(c) or_return
	node.key_offset = get_u32(c) or_return
	node.key_length = get_u16(c) or_return
	node.label_offset = get_u32(c) or_return
	node.label_length = get_u16(c) or_return
	node.value_offset = get_u32(c) or_return
	node.value_length = get_u16(c) or_return
	node.binding = get_i32(c) or_return
	node.ink = get_enum(c, ui.Ink, len(ui.Ink)) or_return
	node.text_role = get_enum(c, ui.Text_Role, len(ui.Text_Role)) or_return
	node.gap = get_enum(c, ui.Space, len(ui.Space)) or_return
	node.padding = get_enum(c, ui.Space, len(ui.Space)) or_return
	node.align = get_enum(c, ui.Cross_Align, len(ui.Cross_Align)) or_return
	node.justify = get_enum(c, ui.Main_Align, len(ui.Main_Align)) or_return
	node.style = get_enum(c, ui.Btn_Style, len(ui.Btn_Style)) or_return
	node.track = decode_track(c) or_return
	node.size_main = get_i32(c) or_return
	node.integer = get_i32(c) or_return
	node.number_lo = get_f32(c) or_return
	node.number_hi = get_f32(c) or_return
	node.number_step = get_f32(c) or_return
	if c.at - start != VIEW_RECORD_BYTES do return {}, false
	return node, true
}

@(private = "file")
decode_track :: proc(c: ^Cursor) -> (track: ui.Track, ok: bool) {
	assert(c != nil, "decode_track: nil cursor")
	track.kind = get_enum(c, ui.Track_Kind, len(ui.Track_Kind)) or_return
	track.basis = get_i32(c) or_return
	track.weight = get_i32(c) or_return
	track.percent = get_f32(c) or_return
	track.min_size = get_i32(c) or_return
	track.max_size = get_i32(c) or_return
	return track, true
}
