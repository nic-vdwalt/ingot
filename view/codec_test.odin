#+build !js
package view

import "core:testing"
import "ingot:testx"
import "ingot:ui"

// sample_doc builds a document exercising every field the codec writes, so a
// round-trip test proves the whole record survives rather than the few fields a
// minimal fixture would touch.
@(private = "file")
sample_doc :: proc(doc: ^View_Doc) {
	assert(doc != nil, "sample_doc: nil doc")
	doc_reset(doc)
	root, _ := doc_add_keyed(
		&doc^,
		VIEW_NODE_NONE,
		.Panel,
		"root",
		"",
		View_Node{gap = .MD, padding = .LG, align = .Start},
	)
	doc_add_keyed(&doc^, root, .Section_Header, "", "Settings")
	doc_add_keyed(
		&doc^,
		root,
		.Checkbox,
		"enabled",
		"Enabled",
		View_Node{binding = 0, ink = .Primary, flags = {.Disabled}},
	)
	doc_add_keyed(
		&doc^,
		root,
		.Slider,
		"volume",
		"Volume",
		View_Node{binding = 1, number_lo = 0, number_hi = 1, number_step = 0.05, size_main = 180},
	)
	row, _ := doc_add_keyed(
		&doc^,
		root,
		.Flex_Row,
		"actions",
		"",
		View_Node{size_main = 32, gap = .SM, justify = .End},
	)
	doc_add_keyed(
		&doc^,
		row,
		.Button,
		"save",
		"Save",
		View_Node {
			style = .Primary,
			track = ui.Track{kind = .Grow, weight = 1, min_size = 64, max_size = 240},
		},
	)
	doc_add_keyed(
		&doc^,
		row,
		.Button,
		"cancel",
		"Cancel",
		View_Node{style = .Ghost, track = ui.Track{kind = .Fixed, basis = 80}},
	)
	doc_add_keyed(
		&doc^,
		root,
		.Kv_Row,
		"",
		"Version",
		View_Node{text_role = .Note, ink = .Secondary},
	)
}

@(private = "file")
encode_to_temp :: proc(view: View) -> []u8 {
	buffer := make([]u8, view_encoded_size(view), context.temp_allocator)
	written, ok := view_encode(view, buffer)
	assert(ok, "encode_to_temp: encode failed")
	assert(written == len(buffer), "encode_to_temp: short write")
	return buffer
}

@(test)
test_roundtrip_preserves_every_field :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source: View_Doc
	sample_doc(&source)
	bytes := encode_to_temp(view_of(&source))

	decoded: View_Doc
	result, ok := view_decode(bytes, &decoded)
	testing.expectf(t, ok, "decode failed: %v", result)
	testing.expect_value(t, decoded.count, source.count)
	testing.expect_value(t, decoded.text_len, source.text_len)
	for index in 0 ..< int(source.count) {
		testing.expectf(
			t,
			decoded.nodes[index] == source.nodes[index],
			"node %d differs:\n want %v\n got  %v",
			index,
			source.nodes[index],
			decoded.nodes[index],
		)
	}
	testing.expect_value(
		t,
		string(decoded.text[:decoded.text_len]),
		string(source.text[:source.text_len]),
	)
}

@(test)
test_track_kind_wire_ordinals_and_hug_roundtrip :: proc(t: ^testing.T) {
	testing.expect_value(t, u8(ui.Track_Kind.Fit), u8(0))
	testing.expect_value(t, u8(ui.Track_Kind.Grow), u8(1))
	testing.expect_value(t, u8(ui.Track_Kind.Fixed), u8(2))
	testing.expect_value(t, u8(ui.Track_Kind.Percent), u8(3))
	testing.expect_value(t, u8(ui.Track_Kind.Hug), u8(4))
	defer free_all(context.temp_allocator)
	source: View_Doc
	sample_doc(&source)
	source.nodes[5].track = {
		kind     = .Hug,
		basis    = 96,
		min_size = 44,
		max_size = 160,
	}
	bytes := encode_to_temp(view_of(&source))
	decoded: View_Doc
	result, ok := view_decode(bytes, &decoded)
	testing.expectf(t, ok, "decode failed: %v", result)
	testing.expect_value(t, decoded.nodes[5].track, source.nodes[5].track)
}

@(test)
test_reencode_is_byte_identical :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source: View_Doc
	sample_doc(&source)
	first := encode_to_temp(view_of(&source))

	decoded: View_Doc
	_, ok := view_decode(first, &decoded)
	testing.expect(t, ok, "decode failed")
	second := encode_to_temp(view_of(&decoded))
	testing.expect_value(t, len(second), len(first))
	for index in 0 ..< len(first) {
		testing.expectf(t, first[index] == second[index], "byte %d differs", index)
	}
}

@(test)
test_encoded_size_matches_written :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc: View_Doc
	sample_doc(&doc)
	view := view_of(&doc)
	size := view_encoded_size(view)
	buffer := make([]u8, size, context.temp_allocator)
	written, ok := view_encode(view, buffer)
	testing.expect(t, ok, "encode failed")
	testing.expect_value(t, written, size)
}

@(test)
test_encode_rejects_short_buffer :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc: View_Doc
	sample_doc(&doc)
	view := view_of(&doc)
	small := make([]u8, view_encoded_size(view) - 1, context.temp_allocator)
	_, ok := view_encode(view, small)
	testing.expect(t, !ok, "encode into a short buffer must fail")
}

@(test)
test_empty_document_roundtrips :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	empty: View_Doc
	bytes := encode_to_temp(view_of(&empty))
	testing.expect_value(t, len(bytes), VIEW_HEADER_BYTES)
	decoded: View_Doc
	result, ok := view_decode(bytes, &decoded)
	testing.expectf(t, ok, "empty decode failed: %v", result)
	testing.expect_value(t, decoded.count, i32(0))
}

// --- negative space ---------------------------------------------------------
//
// Every way a file can be wrong gets a named test. These are the cases that
// matter: the decoder's whole job is to survive them, and a decoder is only as
// good as the malformed inputs it has been shown.

@(private = "file")
corrupt :: proc(source: []u8) -> []u8 {
	clone := make([]u8, len(source), context.temp_allocator)
	copy(clone, source)
	return clone
}

@(private = "file")
expect_fault :: proc(t: ^testing.T, data: []u8, want: Decode_Fault, label: string) {
	doc: View_Doc
	result, ok := view_decode(data, &doc)
	testing.expectf(t, !ok, "%s: decode should have failed", label)
	testing.expectf(t, result.fault == want, "%s: want %v, got %v", label, want, result.fault)
	testing.expectf(t, doc.count == 0, "%s: doc not reset after failure", label)
	testing.expectf(t, doc.text_len == 0, "%s: text not reset after failure", label)
}

@(test)
test_decode_rejects_empty_input :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	expect_fault(t, nil, .Short_Header, "nil")
	expect_fault(t, []u8{}, .Short_Header, "empty")
}

@(test)
test_decode_rejects_truncated_header :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc: View_Doc
	sample_doc(&doc)
	bytes := encode_to_temp(view_of(&doc))
	for length in 0 ..< VIEW_HEADER_BYTES {
		expect_fault(t, bytes[:length], .Short_Header, "truncated header")
	}
}

@(test)
test_decode_rejects_bad_magic :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc: View_Doc
	sample_doc(&doc)
	for index in 0 ..< 4 {
		bytes := corrupt(encode_to_temp(view_of(&doc)))
		bytes[index] ~= 0xff
		expect_fault(t, bytes, .Bad_Magic, "bad magic")
	}
}

@(test)
test_decode_rejects_wrong_version :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc: View_Doc
	sample_doc(&doc)
	bytes := corrupt(encode_to_temp(view_of(&doc)))
	bytes[4] = u8(VIEW_FORMAT_VERSION + 1)
	expect_fault(t, bytes, .Bad_Version, "future version")

	older := corrupt(encode_to_temp(view_of(&doc)))
	older[4] = 0
	expect_fault(t, older, .Bad_Version, "version zero")
}

@(test)
test_decode_rejects_reserved_flags :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc: View_Doc
	sample_doc(&doc)
	bytes := corrupt(encode_to_temp(view_of(&doc)))
	bytes[8] = 1
	expect_fault(t, bytes, .Reserved_Flags, "reserved flags set")
}

@(test)
test_decode_rejects_node_count_over_cap :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc: View_Doc
	sample_doc(&doc)
	bytes := corrupt(encode_to_temp(view_of(&doc)))
	over := u32(VIEW_NODES_MAX + 1)
	bytes[12] = u8(over)
	bytes[13] = u8(over >> 8)
	bytes[14] = u8(over >> 16)
	bytes[15] = u8(over >> 24)
	expect_fault(t, bytes, .Node_Count, "node count over cap")
}

@(test)
test_decode_rejects_text_length_over_cap :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc: View_Doc
	sample_doc(&doc)
	bytes := corrupt(encode_to_temp(view_of(&doc)))
	over := u32(VIEW_TEXT_BYTES_MAX + 1)
	bytes[16] = u8(over)
	bytes[17] = u8(over >> 8)
	bytes[18] = u8(over >> 16)
	bytes[19] = u8(over >> 24)
	expect_fault(t, bytes, .Text_Length, "text length over cap")
}

@(test)
test_decode_rejects_truncated_payload :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc: View_Doc
	sample_doc(&doc)
	bytes := encode_to_temp(view_of(&doc))
	// Step through the payload rather than testing one length: a length check
	// that is wrong by one record is only visible at that one length.
	for length := VIEW_HEADER_BYTES; length < len(bytes); length += 1 {
		short: View_Doc
		result, ok := view_decode(bytes[:length], &short)
		testing.expectf(t, !ok, "truncated to %d should have failed", length)
		testing.expectf(
			t,
			result.fault == .Short_Payload || result.fault == .Checksum,
			"truncated to %d: unexpected fault %v",
			length,
			result.fault,
		)
	}
}

@(test)
test_decode_rejects_trailing_bytes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc: View_Doc
	sample_doc(&doc)
	bytes := encode_to_temp(view_of(&doc))
	longer := make([]u8, len(bytes) + 1, context.temp_allocator)
	copy(longer, bytes)
	expect_fault(t, longer, .Trailing_Bytes, "trailing byte")
}

@(test)
test_decode_rejects_checksum_mismatch :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc: View_Doc
	sample_doc(&doc)
	bytes := corrupt(encode_to_temp(view_of(&doc)))
	bytes[VIEW_HEADER_BYTES] ~= 0x01
	expect_fault(t, bytes, .Checksum, "flipped payload bit")
}

@(test)
test_decode_rejects_out_of_range_enum :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc: View_Doc
	sample_doc(&doc)
	bytes := corrupt(encode_to_temp(view_of(&doc)))
	// Byte 0 of record 0 is View_Kind. Set it past the enum and repair the
	// checksum, so the test exercises the enum check rather than the CRC.
	bytes[VIEW_HEADER_BYTES] = u8(len(View_Kind))
	rewrite_checksum(bytes)
	expect_fault(t, bytes, .Bad_Enum, "kind past enum")
}

@(test)
test_decode_rejects_document_that_fails_validation :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc: View_Doc
	doc_add_keyed(&doc, VIEW_NODE_NONE, .Column, "root", "")
	doc_add_keyed(&doc, 0, .Label, "a", "A")
	// Orphan the child: encoding is happy to write it, decoding must not accept
	// it, because view_play would then walk a tree with a node it never visits.
	doc.nodes[0].first_child = VIEW_NODE_NONE
	bytes := corrupt(encode_to_temp(view_of(&doc)))
	rewrite_checksum(bytes)
	result, ok := view_decode(bytes, &doc)
	testing.expect(t, !ok, "an invalid document must not decode")
	testing.expect_value(t, result.fault, Decode_Fault.Invalid_Document)
	testing.expect_value(t, result.validate.fault, Validate_Fault.Unreachable)
}

@(test)
test_decode_rejects_non_finite_numbers_as_invalid_documents :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	values := [?]u32{0x7f80_0000, 0xff80_0000, 0x7fc0_0000}
	fields := [?]int {
		TRACK_PERCENT_RECORD_OFFSET,
		NUMBER_LO_RECORD_OFFSET,
		NUMBER_HI_RECORD_OFFSET,
		NUMBER_STEP_RECORD_OFFSET,
	}
	for value in values {
		for field in fields {
			doc: View_Doc
			root, _ := doc_add_keyed(&doc, VIEW_NODE_NONE, .Column, "root", "")
			doc_add_keyed(&doc, root, .Label, "a", "A")
			bytes := corrupt(encode_to_temp(view_of(&doc)))
			at := VIEW_HEADER_BYTES + VIEW_RECORD_BYTES + field
			bytes[at + 0] = u8(value)
			bytes[at + 1] = u8(value >> 8)
			bytes[at + 2] = u8(value >> 16)
			bytes[at + 3] = u8(value >> 24)
			rewrite_checksum(bytes)
			result, ok := view_decode(bytes, &doc)
			testing.expect(t, !ok, "non-finite wire number must not decode")
			testing.expect_value(t, result.fault, Decode_Fault.Invalid_Document)
			testing.expect_value(t, result.validate.fault, Validate_Fault.Non_Finite_Number)
		}
	}
}

@(test)
test_decode_rejects_absurd_length :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	huge := make([]u8, VIEW_FILE_BYTES_MAX + 1, context.temp_allocator)
	doc: View_Doc
	_, ok := view_decode(huge, &doc)
	testing.expect(t, !ok, "a file larger than any legal file must be rejected")
}

// rewrite_checksum repairs the header checksum after a test mutates the
// payload, so each negative test can target one check instead of always
// tripping the CRC first.
@(private = "file")
rewrite_checksum :: proc(bytes: []u8) {
	assert(len(bytes) >= VIEW_HEADER_BYTES, "rewrite_checksum: short buffer")
	sum := view_checksum(bytes[VIEW_HEADER_BYTES:])
	bytes[20] = u8(sum)
	bytes[21] = u8(sum >> 8)
	bytes[22] = u8(sum >> 16)
	bytes[23] = u8(sum >> 24)
}

// The fuzz-shaped test: random bytes, random mutations of a valid file, and
// random header fields. The invariant is not that any of these decode, but that
// none of them crashes or hangs.
@(test)
test_decode_survives_random_input :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	rng := testx.prng_make(0x5eed_071e_0000_0001)
	doc: View_Doc
	sample_doc(&doc)
	valid := encode_to_temp(view_of(&doc))

	scratch: View_Doc
	for round in 0 ..< 512 {
		noise := testx.random_bytes(&rng, 256)
		_, _ = view_decode(noise, &scratch)

		mutated := corrupt(valid)
		flips := testx.int_range(&rng, 1, 8)
		for _ in 0 ..< flips {
			at := testx.int_range(&rng, 0, len(mutated))
			mutated[at] ~= u8(1 << u32(testx.int_range(&rng, 0, 8)))
		}
		result, ok := view_decode(mutated, &scratch)
		if !ok {
			testing.expectf(t, scratch.count == 0, "round %d: doc not reset", round)
			testing.expectf(t, result.fault != .None, "round %d: failure with no fault", round)
		}
	}
}

@(test)
test_decode_rejects_negative_track_sizes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc: View_Doc
	root, _ := doc_add_keyed(&doc, VIEW_NODE_NONE, .Flex_Row, "root", "")
	doc_add_keyed(&doc, root, .Label, "a", "A", View_Node{track = ui.Track{kind = .Grow}})
	// Forge the wire bytes rather than the document: this is the check that
	// stops a hostile file reaching ui's flex solver, so it must be exercised
	// through the decoder rather than through view_validate alone.
	bytes := corrupt(encode_to_temp(view_of(&doc)))
	// Record 1, past the fixed prefix, is the child's track.basis.
	at := VIEW_HEADER_BYTES + VIEW_RECORD_BYTES + TRACK_BASIS_RECORD_OFFSET
	bytes[at + 0] = 0xff
	bytes[at + 1] = 0xff
	bytes[at + 2] = 0xff
	bytes[at + 3] = 0xff
	rewrite_checksum(bytes)
	expect_fault(t, bytes, .Bad_Enum, "negative track basis")
}

// Record offsets derived from the field order encode_node writes.
@(private = "file")
TRACK_KIND_RECORD_OFFSET :: 1 + 2 + 4 * 3 + (4 + 2) * 3 + 4 + 7
@(private = "file")
TRACK_BASIS_RECORD_OFFSET :: TRACK_KIND_RECORD_OFFSET + 1
@(private = "file")
TRACK_PERCENT_RECORD_OFFSET :: TRACK_BASIS_RECORD_OFFSET + 4 + 4
@(private = "file")
NUMBER_LO_RECORD_OFFSET :: TRACK_PERCENT_RECORD_OFFSET + 4 + 4 + 4 + 4 + 4
@(private = "file")
NUMBER_HI_RECORD_OFFSET :: NUMBER_LO_RECORD_OFFSET + 4
@(private = "file")
NUMBER_STEP_RECORD_OFFSET :: NUMBER_HI_RECORD_OFFSET + 4
