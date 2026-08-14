package fuzz_view

// Memory-safety fuzzer for the ingot:view decoder.
//
// The decoder is the only part of ingot:view that consumes untrusted bytes: a
// .ingv file may be shipped, fetched, edited by hand, or corrupted in transit.
// Its contract is absolute and is what this harness checks - no input, however
// malformed, may crash, hang, read out of bounds, or produce a document that
// view_validate would then reject.
//
// Three input classes, because they reach different code:
//   1. Random bytes - almost all rejected at the header, exercises early exits.
//   2. Mutations of a valid file - reaches the record loop and the enum checks,
//      which random bytes essentially never do because the CRC rejects them.
//   3. Forged headers over a valid payload - poisons node_count and text_length
//      independently, the classic length-field attack.
//
// The seed is printed FIRST so any crash reproduces exactly:
//   fuzz_view -seed:12345 -iterations:100000 [-rounds:N]

import "core:fmt"
import "core:mem"
import fuzzx "ingot:fuzz/fuzzx"
import "ingot:view"

ITERATIONS_DEFAULT :: 100_000
MAXIMUM_INPUT_BYTES :: 2048

Prng :: fuzzx.Prng

// build_sample constructs a valid document covering every node group, so
// mutations of its encoding land in real records rather than in padding.
build_sample :: proc(doc: ^view.View_Doc) {
	view.doc_reset(doc)
	root, _ := view.doc_add_keyed(
		doc,
		view.VIEW_NODE_NONE,
		.Panel,
		"root",
		"",
		view.View_Node{gap = .MD, padding = .LG},
	)
	view.doc_add_keyed(doc, root, .Section_Header, "", "Settings")
	view.doc_add_keyed(doc, root, .Checkbox, "enabled", "Enabled", view.View_Node{binding = 0})
	view.doc_add_keyed(
		doc,
		root,
		.Slider,
		"volume",
		"Volume",
		view.View_Node{binding = 1, number_hi = 1, number_step = 0.05},
	)
	row, _ := view.doc_add_keyed(
		doc,
		root,
		.Flex_Row,
		"actions",
		"",
		view.View_Node{size_main = 32, gap = .SM},
	)
	view.doc_add_keyed(doc, row, .Button, "save", "Save", view.View_Node{style = .Primary})
	view.doc_add_keyed(doc, row, .Button, "cancel", "Cancel", view.View_Node{style = .Ghost})
	view.doc_add_keyed(doc, root, .Separator, "", "")
	view.doc_add_keyed(doc, root, .Spinner, "", "", view.View_Node{size_main = 24})
}

encode_sample :: proc(doc: ^view.View_Doc) -> []u8 {
	source := view.view_of(doc)
	buffer := make([]u8, view.view_encoded_size(source), context.temp_allocator)
	written, ok := view.view_encode(source, buffer)
	if !ok || written != len(buffer) {
		fmt.eprintfln("fuzz_view: encoding the sample failed; the harness is broken")
		panic("fuzz_view: sample encode failed")
	}
	return buffer
}

// exercise_decode is the invariant. Success must mean the document is playable;
// failure must mean the document is empty. There is no third state, and a
// decoder that returned ok with a half-populated doc would be the worst
// outcome - view_play would then trust it.
exercise_decode :: proc(c: ^fuzzx.Ctx, data: []u8, doc: ^view.View_Doc) {
	c.input = data
	result, ok := view.view_decode(data, doc)
	if !ok {
		fuzzx.check(c, doc.count == 0, "failed decode left nodes behind")
		fuzzx.check(c, doc.text_len == 0, "failed decode left text behind")
		fuzzx.check(c, result.fault != .None, "failed decode reported no fault")
		return
	}
	fuzzx.check(c, result.fault == .None, "successful decode reported a fault")
	fuzzx.check(c, doc.count >= 0, "negative node count")
	fuzzx.check(c, int(doc.count) <= view.VIEW_NODES_MAX, "node count over cap")
	fuzzx.check(c, doc.text_len <= view.VIEW_TEXT_BYTES_MAX, "text length over cap")
	// A successful decode has already validated. Re-running it must agree:
	// disagreement would mean validation is not deterministic, which would make
	// every other guarantee in the package conditional.
	_, valid := view.view_validate(view.view_of(doc))
	fuzzx.check(c, valid, "decode accepted a document validation rejects")
	exercise_reencode(c, doc)
}

// exercise_reencode checks the round trip on anything that decoded, including
// documents the fuzzer stumbled into rather than the harness built. Encoding
// must be total over valid documents.
exercise_reencode :: proc(c: ^fuzzx.Ctx, doc: ^view.View_Doc) {
	source := view.view_of(doc)
	size := view.view_encoded_size(source)
	buffer := make([]u8, size, context.temp_allocator)
	written, ok := view.view_encode(source, buffer)
	fuzzx.check(c, ok, "re-encoding a decoded document failed")
	fuzzx.check(c, written == size, "re-encode wrote a different length than promised")

	again: view.View_Doc
	_, decoded_ok := view.view_decode(buffer[:written], &again)
	fuzzx.check(c, decoded_ok, "a re-encoded document did not decode")
	fuzzx.check(c, again.count == doc.count, "round trip changed the node count")
	fuzzx.check(c, again.text_len == doc.text_len, "round trip changed the text length")
	again_size := view.view_encoded_size(view.view_of(&again))
	again_buffer := make([]u8, again_size, context.temp_allocator)
	again_written, again_ok := view.view_encode(view.view_of(&again), again_buffer)
	fuzzx.check(c, again_ok, "encoding the round-tripped document failed")
	fuzzx.check(c, again_written == written, "round trip changed the encoded length")
	for index in 0 ..< min(written, again_written) {
		if buffer[index] != again_buffer[index] {
			fuzzx.check(c, false, "round trip changed bytes")
			return
		}
	}
}

// forge_header rewrites the count fields over a valid payload without repairing
// the checksum, then sometimes repairs it. Unrepaired exercises the CRC;
// repaired pushes a poisoned length all the way into the record loop.
forge_header :: proc(p: ^Prng, valid: []u8) -> []u8 {
	buffer := make([]u8, len(valid), context.temp_allocator)
	copy(buffer, valid)
	if len(buffer) < view.VIEW_HEADER_BYTES do return buffer
	field := fuzzx.int_range(p, 0, 2)
	at := 12 + field * 4
	value := u32(fuzzx.int_range(p, 0, 1 << 20))
	buffer[at + 0] = u8(value)
	buffer[at + 1] = u8(value >> 8)
	buffer[at + 2] = u8(value >> 16)
	buffer[at + 3] = u8(value >> 24)
	if fuzzx.int_range(p, 0, 2) == 0 do repair_checksum(buffer)
	return buffer
}

// repair_checksum recomputes the header CRC so a mutation reaches the checks
// past it. Without this the CRC would reject nearly every mutated input and the
// record loop would go essentially untested.
repair_checksum :: proc(buffer: []u8) {
	if len(buffer) < view.VIEW_HEADER_BYTES do return
	sum := view.view_checksum(buffer[view.VIEW_HEADER_BYTES:])
	buffer[20] = u8(sum)
	buffer[21] = u8(sum >> 8)
	buffer[22] = u8(sum >> 16)
	buffer[23] = u8(sum >> 24)
}

mutate_valid :: proc(p: ^Prng, valid: []u8) -> []u8 {
	buffer := fuzzx.mutate(p, valid)
	if fuzzx.int_range(p, 0, 2) == 0 do repair_checksum(buffer)
	return buffer
}

make_input :: proc(p: ^Prng, valid: []u8) -> []u8 {
	switch fuzzx.int_range(p, 0, 10) {
	case 0, 1:
		return fuzzx.random_bytes(p, MAXIMUM_INPUT_BYTES)
	case 2:
		return forge_header(p, valid)
	case 3:
		// Truncation at an arbitrary point: the short-read paths are the ones a
		// partial write or a interrupted download actually produces.
		cut := fuzzx.int_range(p, 0, len(valid) + 1)
		return valid[:cut]
	case:
		return mutate_valid(p, valid)
	}
}

main :: proc() {
	seed, iterations, rounds := fuzzx.parse_options(ITERATIONS_DEFAULT)
	fmt.printfln("fuzz_view seed=%d iterations=%d rounds=%d", seed, iterations, rounds)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)

	sample: view.View_Doc
	build_sample(&sample)

	for round in 0 ..< rounds {
		round_seed := seed + u64(round)
		if rounds > 1 do fmt.printfln("fuzz_view round %d seed=%d", round, round_seed)
		p := fuzzx.prng_make(round_seed)
		c := fuzzx.Ctx {
			name = "fuzz_view",
			seed = round_seed,
		}
		doc: view.View_Doc
		for i in 0 ..< iterations {
			c.iteration = i
			valid := encode_sample(&sample)
			exercise_decode(&c, make_input(&p, valid), &doc)
			free_all(context.temp_allocator)
		}
	}

	fuzzx.report(&track, "fuzz_view", seed)
	fmt.printfln("fuzz_view ok")
}
