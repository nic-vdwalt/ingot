#+build !js
package view

import "core:strings"
import "core:testing"
import "ingot:testx"
import "ingot:ui"

// The end-to-end equivalence tests.
//
// This file replaces what an earlier design called the parity oracle: a
// differential test between an interpreter and a code generator that each
// emitted widget calls. That test is gone because the thing it guarded against
// is gone - the generator emits the document, not the calls, so there is only
// one implementation of what a node means and nothing to differ.
//
// What remains worth proving is that the three representations of a document
// agree: the authoring buffer, the encoded file, and the generated literal.
//
//	View_Doc --encode--> bytes --decode--> View_Doc
//	View_Doc --generate--> Odin source --compile--> View
//
// The first is checked byte-for-byte here. The second is checked structurally
// against the committed fixture, and its compile step is covered by check.sh
// building the fixture as a consumer would.

@(private = "file")
Harness :: struct {
	runtime: ui.Ui_Runtime,
	frame:   ui.Ui_Frame,
	output:  ui.Ui_Output,
	u:       ui.Ui,
}

@(private = "file")
MONO_CELL :: f32(8)

@(private = "file")
mono_font :: proc(data: rawptr, size: i32) -> ui.Font_Id {
	return ui.Font_Id(1)
}

@(private = "file")
mono_measure :: proc(data: rawptr, font: ui.Font_Id, text: string, size, spacing: f32) -> ui.Vec2 {
	return ui.Vec2{MONO_CELL * f32(len(text)), size}
}

@(private = "file")
harness_begin :: proc() -> ^Harness {
	h := new(Harness)
	ui.ui_runtime_init(&h.runtime)
	ui.ui_runtime_set_text_backend(
		&h.runtime,
		ui.Text_Backend{font_for_size = mono_font, measure = mono_measure},
	)
	h.frame.output = &h.output
	ui.ui_frame_begin(&h.frame, &h.runtime)
	ui.begin(&h.u, &h.frame, {0, 0, 800, 600})
	return h
}

@(private = "file")
harness_end :: proc(h: ^Harness) {
	assert(h != nil, "harness_end: nil harness")
	ui.end(&h.u)
	ui.ui_frame_end(&h.frame)
	ui.ui_frame_destroy(&h.frame)
	ui.ui_runtime_destroy(&h.runtime)
	free(h)
}

// Paint_Digest summarises a frame's output. Comparing digests rather than raw
// buffers keeps a failure readable: a mismatched count says which aspect
// diverged, where a memcmp of two 8192-command arrays says only "different".
@(private = "file")
Paint_Digest :: struct {
	main_commands:    int,
	main_text_bytes:  int,
	main_checksum:    u32,
	overlay_commands: int,
	overlay_checksum: u32,
	semantic_nodes:   int,
	focusables:       int,
	events:           i32,
}

@(private = "file")
play_digest :: proc(source: View, bindings: ^Bindings) -> Paint_Digest {
	h := harness_begin()
	defer harness_end(h)
	view_play(&h.u, source, bindings)
	digest := Paint_Digest {
		main_commands    = h.output.main.count,
		main_text_bytes  = h.output.main.text_len,
		main_checksum    = paint_checksum(&h.output.main),
		overlay_commands = h.output.overlay.count,
		overlay_checksum = paint_checksum(&h.output.overlay),
		semantic_nodes   = h.frame.semantics.cur.count,
		focusables       = h.u.focus_seq,
	}
	if bindings != nil && bindings.events != nil do digest.events = bindings.events.count
	return digest
}

// paint_checksum hashes the emitted commands so a difference in any field of
// any command is caught, not just the count. It reuses the format's CRC for the
// same reason the generator does: one implementation rather than two.
@(private = "file")
paint_checksum :: proc(list: ^ui.Paint_List) -> u32 {
	assert(list != nil, "paint_checksum: nil list")
	if list.count == 0 do return 0
	bytes := (cast([^]u8)&list.commands[0])[:list.count * size_of(ui.Paint_Command)]
	return view_checksum(bytes)
}

@(private = "file")
State :: struct {
	enabled: bool,
	volume:  f32,
	sink:    Event_Sink,
	slots:   [2]Binding,
}

@(private = "file")
state_bindings :: proc(state: ^State) -> Bindings {
	assert(state != nil, "state_bindings: nil state")
	state.slots[0] = bind_boolean(&state.enabled)
	state.slots[1] = bind_number(&state.volume)
	return Bindings{slots = state.slots[:], events = &state.sink}
}

// The core equivalence: a document that has been through the file format must
// render exactly as the one that never left memory. This is what makes shipping
// a .ingv safe.
@(test)
test_encoded_document_renders_identically :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	authored := new(View_Doc, context.temp_allocator)
	_, ok := view_decode(FIXTURE_INGV, authored)
	testing.expect(t, ok, "fixture does not decode")

	buffer := make([]u8, view_encoded_size(view_of(authored)), context.temp_allocator)
	written, encoded := view_encode(view_of(authored), buffer)
	testing.expect(t, encoded, "encode failed")

	decoded := new(View_Doc, context.temp_allocator)
	_, redecoded := view_decode(buffer[:written], decoded)
	testing.expect(t, redecoded, "re-decode failed")

	before: State
	after: State
	before_bindings := state_bindings(&before)
	after_bindings := state_bindings(&after)
	testing.expect_value(
		t,
		play_digest(view_of(decoded), &after_bindings),
		play_digest(view_of(authored), &before_bindings),
	)
}

// The generated literal must render identically to the decoded document. The
// literal itself is built here from the same fields the generator writes, which
// is the closest an in-package test can get to compiling the emitted file; the
// compile is covered by check.sh building the fixture.
@(test)
test_generated_literal_renders_identically :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	decoded := new(View_Doc, context.temp_allocator)
	_, ok := view_decode(FIXTURE_INGV, decoded)
	testing.expect(t, ok, "fixture does not decode")

	// A View built from borrowed slices, exactly as generated code produces.
	nodes := make([]View_Node, int(decoded.count), context.temp_allocator)
	copy(nodes, decoded.nodes[:decoded.count])
	literal := View {
		nodes = nodes,
		text  = strings.clone(string(decoded.text[:decoded.text_len]), context.temp_allocator),
	}

	from_doc: State
	from_literal: State
	doc_bindings := state_bindings(&from_doc)
	literal_bindings := state_bindings(&from_literal)
	testing.expect_value(
		t,
		play_digest(literal, &literal_bindings),
		play_digest(view_of(decoded), &doc_bindings),
	)
}

// Playing the same document twice must produce the same frame. Determinism is
// what makes every other comparison in this file meaningful, so it is asserted
// rather than assumed.
@(test)
test_playing_twice_is_identical :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc := new(View_Doc, context.temp_allocator)
	_, ok := view_decode(FIXTURE_INGV, doc)
	testing.expect(t, ok, "fixture does not decode")

	first: State
	second: State
	first_bindings := state_bindings(&first)
	second_bindings := state_bindings(&second)
	testing.expect_value(
		t,
		play_digest(view_of(doc), &second_bindings),
		play_digest(view_of(doc), &first_bindings),
	)
}

// A document is not required to survive being re-encoded once; it is required
// to survive it any number of times. A codec that loses a bit per generation
// passes a single round trip and fails this.
@(test)
test_repeated_round_trips_are_stable :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	current := new(View_Doc, context.temp_allocator)
	_, ok := view_decode(FIXTURE_INGV, current)
	testing.expect(t, ok, "fixture does not decode")

	reference := make([]u8, view_encoded_size(view_of(current)), context.temp_allocator)
	written, encoded := view_encode(view_of(current), reference)
	testing.expect(t, encoded, "encode failed")
	reference = reference[:written]

	next := new(View_Doc, context.temp_allocator)
	for generation in 0 ..< 8 {
		buffer := make([]u8, view_encoded_size(view_of(current)), context.temp_allocator)
		size, round_ok := view_encode(view_of(current), buffer)
		testing.expectf(t, round_ok, "generation %d: encode failed", generation)
		testing.expectf(t, size == len(reference), "generation %d: size drifted", generation)
		for index in 0 ..< min(size, len(reference)) {
			if buffer[index] != reference[index] {
				testing.expectf(t, false, "generation %d: byte %d drifted", generation, index)
				return
			}
		}
		_, decoded_ok := view_decode(buffer[:size], next)
		testing.expectf(t, decoded_ok, "generation %d: decode failed", generation)
		current^ = next^
	}
}

// Identity must be stable across processes, not merely within one run. Ids are
// derived from key paths, so the same document played in two independent
// runtimes must register the same focus order - that is what lets a saved view
// keep its state across a restart.
@(test)
test_identity_is_stable_across_runtimes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc := new(View_Doc, context.temp_allocator)
	_, ok := view_decode(FIXTURE_INGV, doc)
	testing.expect(t, ok, "fixture does not decode")

	first := focus_order(view_of(doc))
	second := focus_order(view_of(doc))
	testing.expect_value(t, second.count, first.count)
	testing.expect(t, first.count > 0, "fixture registered no focusables")
	for index in 0 ..< first.count {
		testing.expectf(t, first.ids[index] == second.ids[index], "id %d differs", index)
	}
}

@(private = "file")
Focus_Order :: struct {
	ids:   [ui.MAX_FOCUSABLES]ui.Focus_Id,
	count: int,
}

@(private = "file")
focus_order :: proc(source: View) -> (result: Focus_Order) {
	state: State
	bindings := state_bindings(&state)
	h := harness_begin()
	defer harness_end(h)
	view_play(&h.u, source, &bindings)
	result.count = h.u.focus_seq
	assert(result.count <= ui.MAX_FOCUSABLES, "focus_order: overflow")
	copy(result.ids[:result.count], h.u.focus_cur[:result.count])
	return result
}

// A randomly built document must survive the whole pipeline. The fixture proves
// one shape works; this proves the pipeline is total over the shapes a builder
// can actually produce, which is the property that matters once a user is
// dragging widgets around.
// Scaled up by -define:INGOT_FUZZ_ITER for a soak run, matching how the term
// and text-input in-package fuzzers take their iteration count.
RANDOM_PIPELINE_ROUNDS :: #config(INGOT_FUZZ_ITER, 64)
RANDOM_PIPELINE_SEED :: #config(INGOT_FUZZ_SEED, 0x11ee_2244)

@(test)
test_random_documents_survive_the_pipeline :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// Seeded from a define so a failure replays exactly, and so a soak run can
	// sweep seeds the way fuzz/run.sh does for the standalone harnesses.
	rng := testx.prng_make(RANDOM_PIPELINE_SEED)
	// These outlive the loop's temp arena, so they must not come from it: the
	// free_all below would leave the next round writing into freed memory.
	authored := new(View_Doc)
	defer free(authored)
	decoded := new(View_Doc)
	defer free(decoded)

	for round in 0 ..< RANDOM_PIPELINE_ROUNDS {
		build_random_document(authored, &rng)
		result, valid := view_validate(view_of(authored))
		testing.expectf(t, valid, "round %d: built an invalid document: %v", round, result)
		if !valid do return

		buffer := make([]u8, view_encoded_size(view_of(authored)), context.temp_allocator)
		written, encoded := view_encode(view_of(authored), buffer)
		testing.expectf(t, encoded, "round %d: encode failed", round)
		_, ok := view_decode(buffer[:written], decoded)
		testing.expectf(t, ok, "round %d: decode failed", round)
		if !ok do return

		before: State
		after: State
		before_bindings := state_bindings(&before)
		after_bindings := state_bindings(&after)
		testing.expectf(
			t,
			play_digest(view_of(authored), &before_bindings) ==
			play_digest(view_of(decoded), &after_bindings),
			"round %d: rendering diverged after a round trip",
			round,
		)
		free_all(context.temp_allocator)
	}
}

// build_random_document produces a valid tree of bounded depth. It only emits
// kinds whose bindings the two-slot table above can satisfy, because the point
// is to vary structure, not to re-test the binding checks.
@(private = "file")
build_random_document :: proc(doc: ^View_Doc, rng: ^testx.Prng) {
	assert(doc != nil && rng != nil, "build_random_document: nil argument")
	doc_reset(doc)
	root, _ := doc_add_keyed(doc, VIEW_NODE_NONE, .Column, "root", "", View_Node{gap = .SM})
	containers: [VIEW_DEPTH_MAX]i32
	containers[0] = root
	open := 1
	nodes := testx.int_range(rng, 1, 24)
	for index in 0 ..< nodes {
		parent := containers[testx.int_range(rng, 0, open)]
		key := KEYS[index % len(KEYS)]
		if open < VIEW_DEPTH_MAX - 1 && testx.int_range(rng, 0, 4) == 0 {
			kind := CONTAINER_KINDS[testx.int_range(rng, 0, len(CONTAINER_KINDS))]
			child, err := doc_add_keyed(doc, parent, kind, key, "", View_Node{gap = .SM})
			if err != .None do break
			containers[open] = child
			open += 1
			continue
		}
		add_random_leaf(doc, parent, key, rng)
	}
}

@(private = "file")
add_random_leaf :: proc(doc: ^View_Doc, parent: i32, key: string, rng: ^testx.Prng) {
	assert(doc != nil && rng != nil, "add_random_leaf: nil argument")
	kind := LEAF_KINDS[testx.int_range(rng, 0, len(LEAF_KINDS))]
	node := View_Node {
		track = ui.Track{kind = .Grow, weight = 1},
		size_main = i32(testx.int_range(rng, 0, 40)),
		number_hi = 1,
	}
	#partial switch view_kind_binding(kind) {
	case .Boolean:
		node.binding = 0
	case .Number:
		node.binding = 1
	}
	label := LABELS[testx.int_range(rng, 0, len(LABELS))]
	doc_add_keyed(doc, parent, kind, key, label, node)
}

@(private = "file")
CONTAINER_KINDS := [?]View_Kind{.Row, .Column, .Panel, .Flex_Row, .Flex_Column}

// Only kinds whose binding the fixture's two-slot table can satisfy, and whose
// labels are always supplied above.
@(private = "file")
LEAF_KINDS := [?]View_Kind {
	.Button,
	.Icon_Button,
	.Back_Button,
	.Checkbox,
	.Collapsible_Header,
	.Slider,
	.Label,
	.Section_Header,
	.Status_Pill,
	.Kv_Row,
	.Progress_Bar,
	.Spinner,
	.Separator,
	.Spacer,
}

@(private = "file")
LABELS := [?]string{"Alpha", "Beta", "Gamma", "Delta"}

@(private = "file")
KEYS := [?]string {
	"k00",
	"k01",
	"k02",
	"k03",
	"k04",
	"k05",
	"k06",
	"k07",
	"k08",
	"k09",
	"k10",
	"k11",
	"k12",
	"k13",
	"k14",
	"k15",
	"k16",
	"k17",
	"k18",
	"k19",
	"k20",
	"k21",
	"k22",
	"k23",
}
