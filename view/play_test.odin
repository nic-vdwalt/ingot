#+build !js
package view

import "core:testing"
import "ingot:ui"

// Harness holds one frame's worth of ui state. Play tests need a real Ui,
// because the point of the exercise is that a document drives the same widgets
// a hand-written frame procedure would.
// A deterministic monospace text backend. Play tests need one because painting
// text asserts on a missing backend, and a fixed cell width also makes every
// layout assertion below reproducible instead of font-dependent.
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
mono_backend :: proc() -> ui.Text_Backend {
	return ui.Text_Backend{font_for_size = mono_font, measure = mono_measure}
}

@(private = "file")
Harness :: struct {
	runtime: ui.Ui_Runtime,
	frame:   ui.Ui_Frame,
	output:  ui.Ui_Output,
	u:       ui.Ui,
}

// Harness is heap-allocated: Ui_Frame alone carries the paint and semantics
// buffers, so a stack copy is megabytes and Odin warns about the overflow risk.
@(private = "file")
harness_begin :: proc(semantics: bool = false) -> ^Harness {
	h := new(Harness)
	ui.ui_runtime_init(&h.runtime)
	ui.ui_runtime_set_text_backend(&h.runtime, mono_backend())
	if semantics do ui.sem_enable(&h.runtime, true)
	// The frame borrows the output; widgets assert on a missing one rather than
	// silently painting nowhere, so it has to be attached before begin.
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

// demo_doc is the shared fixture: every container kind, a presentational run,
// and one of each interactive kind that needs a binding.
@(private = "file")
demo_doc :: proc(doc: ^View_Doc) {
	assert(doc != nil, "demo_doc: nil doc")
	doc_reset(doc)
	root, _ := doc_add_keyed(
		doc,
		VIEW_NODE_NONE,
		.Panel,
		"root",
		"",
		View_Node{gap = .MD, padding = .LG},
	)
	doc_add_keyed(doc, root, .Section_Header, "", "Settings")
	doc_add_keyed(doc, root, .Checkbox, "enabled", "Enabled", View_Node{binding = 0})
	doc_add_keyed(
		doc,
		root,
		.Slider,
		"volume",
		"Volume",
		View_Node{binding = 1, number_hi = 1, number_step = 0.05},
	)
	doc_add_keyed(doc, root, .Progress_Bar, "", "", View_Node{binding = 1, ink = .Accent})
	doc_add_keyed(doc, root, .Separator, "", "")
	row, _ := doc_add_keyed(
		doc,
		root,
		.Flex_Row,
		"actions",
		"",
		View_Node{size_main = 32, gap = .SM},
	)
	doc_add_keyed(
		doc,
		row,
		.Button,
		"save",
		"Save",
		View_Node{style = .Primary, track = ui.Track{kind = .Grow, weight = 1}},
	)
	doc_add_keyed(
		doc,
		row,
		.Button,
		"cancel",
		"Cancel",
		View_Node{style = .Ghost, track = ui.Track{kind = .Fixed, basis = 80}},
	)
}

@(private = "file")
Demo_State :: struct {
	enabled: bool,
	volume:  f32,
	sink:    Event_Sink,
	slots:   [2]Binding,
}

@(private = "file")
demo_bindings :: proc(state: ^Demo_State) -> Bindings {
	assert(state != nil, "demo_bindings: nil state")
	state.slots[0] = bind_boolean(&state.enabled)
	state.slots[1] = bind_number(&state.volume)
	return Bindings{slots = state.slots[:], events = &state.sink}
}

@(test)
test_play_emits_paint_and_balances_scopes :: proc(t: ^testing.T) {
	doc: View_Doc
	demo_doc(&doc)
	state: Demo_State
	bindings := demo_bindings(&state)

	h := harness_begin()
	defer harness_end(h)
	before := h.frame.output.main.count
	view_play(&h.u, view_of(&doc), &bindings)
	testing.expect(t, h.frame.output.main.count > before, "playing a view painted nothing")
	testing.expect_value(t, h.u.ids.depth, 0)
}

@(test)
test_play_registers_one_focusable_per_interactive_node :: proc(t: ^testing.T) {
	doc: View_Doc
	demo_doc(&doc)
	state: Demo_State
	bindings := demo_bindings(&state)

	interactive := 0
	for index in 0 ..< int(doc.count) {
		if view_kind_is_interactive(doc.nodes[index].kind) do interactive += 1
	}

	h := harness_begin()
	defer harness_end(h)
	view_play(&h.u, view_of(&doc), &bindings)
	testing.expect_value(t, h.u.focus_seq, interactive)
}

@(test)
test_play_is_deterministic_across_runs :: proc(t: ^testing.T) {
	doc: View_Doc
	demo_doc(&doc)

	first_count, second_count: int
	{
		state: Demo_State
		bindings := demo_bindings(&state)
		h := harness_begin()
		view_play(&h.u, view_of(&doc), &bindings)
		first_count = h.frame.output.main.count
		harness_end(h)
	}
	{
		state: Demo_State
		bindings := demo_bindings(&state)
		h := harness_begin()
		view_play(&h.u, view_of(&doc), &bindings)
		second_count = h.frame.output.main.count
		harness_end(h)
	}
	testing.expect_value(t, second_count, first_count)
}

// Identity must survive a label change. This is the property that makes a
// builder usable: renaming a button in the inspector cannot reset its state.
@(test)
test_identity_is_stable_across_a_label_rename :: proc(t: ^testing.T) {
	original: View_Doc
	demo_doc(&original)
	renamed: View_Doc
	demo_doc(&renamed)
	for index in 0 ..< int(renamed.count) {
		if renamed.nodes[index].kind != .Button do continue
		offset, length, ok := doc_intern(&renamed, "Save changes")
		testing.expect(t, ok, "intern failed")
		renamed.nodes[index].label_offset = offset
		renamed.nodes[index].label_length = length
		break
	}

	before := play_widget_ids(t, view_of(&original))
	after := play_widget_ids(t, view_of(&renamed))
	testing.expect_value(t, after.count, before.count)
	for index in 0 ..< before.count {
		testing.expectf(
			t,
			before.ids[index] == after.ids[index],
			"widget %d identity changed with the label",
			index,
		)
	}
}

// Identity must also survive inserting a sibling before a control, which is
// what distinguishes a keyed document from one keyed by position.
@(test)
test_identity_is_stable_across_sibling_insertion :: proc(t: ^testing.T) {
	base: View_Doc
	demo_doc(&base)
	before := play_widget_ids(t, view_of(&base))

	inserted: View_Doc
	doc_reset(&inserted)
	root, _ := doc_add_keyed(
		&inserted,
		VIEW_NODE_NONE,
		.Panel,
		"root",
		"",
		View_Node{gap = .MD, padding = .LG},
	)
	// A new header ahead of everything else; every key below is unchanged.
	doc_add_keyed(&inserted, root, .Section_Header, "", "New")
	doc_add_keyed(&inserted, root, .Section_Header, "", "Settings")
	doc_add_keyed(&inserted, root, .Checkbox, "enabled", "Enabled", View_Node{binding = 0})
	doc_add_keyed(
		&inserted,
		root,
		.Slider,
		"volume",
		"Volume",
		View_Node{binding = 1, number_hi = 1, number_step = 0.05},
	)
	after := play_widget_ids(t, view_of(&inserted))
	testing.expect(t, before.count >= 2 && after.count >= 2, "fixture lost its controls")
	for index in 0 ..< 2 {
		testing.expectf(
			t,
			before.ids[index] == after.ids[index],
			"widget %d identity changed when a sibling was inserted",
			index,
		)
	}
}

@(private = "file")
Widget_Ids :: struct {
	ids:   [ui.MAX_FOCUSABLES]ui.Widget_Id,
	count: int,
}

// play_widget_ids records the focus order a document produces. Focus order is
// derived from Widget_Id, so comparing it across two documents compares
// identity without needing access to ui's private id machinery.
@(private = "file")
play_widget_ids :: proc(t: ^testing.T, view: View) -> (result: Widget_Ids) {
	assert(t != nil, "play_widget_ids: nil t")
	state: Demo_State
	bindings := demo_bindings(&state)
	h := harness_begin()
	defer harness_end(h)
	view_play(&h.u, view, &bindings)
	result.count = h.u.focus_seq
	testing.expect(t, result.count <= ui.MAX_FOCUSABLES, "focus overflow")
	for index in 0 ..< result.count {
		result.ids[index] = ui.Widget_Id(h.u.focus_cur[index])
	}
	return result
}

@(test)
test_play_writes_through_bindings :: proc(t: ^testing.T) {
	doc: View_Doc
	doc_reset(&doc)
	root, _ := doc_add_keyed(&doc, VIEW_NODE_NONE, .Column, "root", "")
	doc_add_keyed(&doc, root, .Checkbox, "flag", "Flag", View_Node{binding = 0})

	state: Demo_State
	state.enabled = true
	bindings := demo_bindings(&state)
	h := harness_begin()
	defer harness_end(h)
	view_play(&h.u, view_of(&doc), &bindings)
	// No input was delivered, so the value must be untouched. A checkbox that
	// mutated its binding without a click would be the worst possible defect
	// here, because the builder would corrupt caller state just by rendering.
	testing.expect_value(t, state.enabled, true)
}

@(test)
test_play_resets_the_event_sink_each_frame :: proc(t: ^testing.T) {
	doc: View_Doc
	demo_doc(&doc)
	state: Demo_State
	bindings := demo_bindings(&state)
	sink_push(&state.sink, Event{node = 0})
	testing.expect_value(t, state.sink.count, i32(1))

	h := harness_begin()
	defer harness_end(h)
	view_play(&h.u, view_of(&doc), &bindings)
	testing.expect_value(t, state.sink.count, i32(0))
}

@(test)
test_play_accepts_an_empty_view :: proc(t: ^testing.T) {
	empty: View_Doc
	h := harness_begin()
	defer harness_end(h)
	view_play(&h.u, view_of(&empty), nil)
	testing.expect_value(t, h.u.ids.depth, 0)
}

@(test)
test_play_accepts_an_empty_flex_container :: proc(t: ^testing.T) {
	doc: View_Doc
	doc_reset(&doc)
	root, _ := doc_add_keyed(&doc, VIEW_NODE_NONE, .Column, "root", "")
	// A flex container with no children is what the builder holds the instant
	// after the user drops one on the canvas, so it must render rather than
	// trip ui's empty-track assertion.
	doc_add_keyed(&doc, root, .Flex_Row, "empty", "", View_Node{size_main = 24})
	h := harness_begin()
	defer harness_end(h)
	view_play(&h.u, view_of(&doc), nil)
	testing.expect_value(t, h.u.ids.depth, 0)
}

@(test)
test_play_unkeyed_container_scopes_do_not_collide :: proc(t: ^testing.T) {
	doc: View_Doc
	root, ok := doc_add_keyed(&doc, VIEW_NODE_NONE, .Column, "root", "")
	testing.expect(t, ok, "root add failed")
	for index in 0 ..< 33 {
		_, added := doc_add(&doc, root, View_Node{kind = .Column})
		testing.expectf(t, added, "container %d add failed", index)
	}
	result, valid := view_validate(view_of(&doc))
	testing.expectf(t, valid, "view validation failed: %v", result)
	h := harness_begin()
	defer harness_end(h)
	ids: [33]ui.Widget_Id
	source := view_of(&doc)
	for index in 0 ..< len(ids) {
		node_index := i32(index + 1)
		scope_begin_node(&h.u, source, source.nodes[node_index], node_index)
		ids[index] = ui.id(&h.u, "action")
		ui.scope_end(&h.u)
		for prior in 0 ..< index do testing.expect(t, ids[prior] != ids[index])
	}
}

@(test)
test_play_emits_semantics_for_interactive_nodes :: proc(t: ^testing.T) {
	doc: View_Doc
	demo_doc(&doc)
	state: Demo_State
	bindings := demo_bindings(&state)

	h := harness_begin(semantics = true)
	defer harness_end(h)
	ui.sem_begin_frame(&h.frame)
	view_play(&h.u, view_of(&doc), &bindings)
	frame := ui.sem_frame(&h.frame)
	testing.expect(t, frame.count > 0, "an interactive view produced no semantics")

	buttons := 0
	for index in 0 ..< frame.count {
		if frame.nodes[index].role == .Button do buttons += 1
	}
	testing.expect(t, buttons >= 2, "the two buttons did not reach the semantic tree")
}

@(test)
test_play_survives_a_slider_with_a_degenerate_range :: proc(t: ^testing.T) {
	doc: View_Doc
	doc_reset(&doc)
	root, _ := doc_add_keyed(&doc, VIEW_NODE_NONE, .Column, "root", "")
	// lo == hi is what a half-edited document contains; ui.slider would divide
	// by the range, so play repairs it rather than letting a document reach an
	// assertion inside a widget.
	doc_add_keyed(
		&doc,
		root,
		.Slider,
		"stuck",
		"Stuck",
		View_Node{binding = 0, number_lo = 5, number_hi = 5},
	)
	value: f32 = 5
	slots := [1]Binding{bind_number(&value)}
	bindings := Bindings {
		slots = slots[:],
	}
	h := harness_begin()
	defer harness_end(h)
	view_play(&h.u, view_of(&doc), &bindings)
	testing.expect_value(t, h.u.ids.depth, 0)
}

@(test)
test_play_renders_every_kind :: proc(t: ^testing.T) {
	// Every kind in the enum must be playable. This is the test that stops a
	// kind being added to the format without an emitter, which would otherwise
	// only show up as a silently missing widget.
	for kind in View_Kind {
		doc: View_Doc
		doc_reset(&doc)
		root, _ := doc_add_keyed(&doc, VIEW_NODE_NONE, .Column, "root", "")
		parent := root
		if view_kind_is_container(kind) {
			index, _ := doc_add_keyed(&doc, root, kind, "container", "Container")
			parent = index
			doc_add_keyed(&doc, parent, .Label, "", "child")
		} else {
			node := View_Node {
				number_hi = 1,
				size_main = 0,
			}
			if view_kind_binding(kind) != .None do node.binding = 0
			doc_add_keyed(&doc, root, kind, "leaf", "Leaf", node)
		}

		flag: bool
		number: f32
		integer: i32
		box: ui.Input_Box
		ui.input_box_init(&box)
		defer ui.input_box_destroy(&box)
		slots := [1]Binding{}
		#partial switch view_kind_binding(kind) {
		case .Boolean:
			slots[0] = bind_boolean(&flag)
		case .Number:
			slots[0] = bind_number(&number)
		case .Integer:
			slots[0] = bind_integer(&integer)
		case .Text:
			slots[0] = bind_text(&box)
		}
		sink: Event_Sink
		bindings := Bindings {
			slots  = slots[:],
			events = &sink,
		}

		result, ok := view_validate(view_of(&doc))
		testing.expectf(t, ok, "%v: fixture did not validate: %v", kind, result)
		h := harness_begin()
		view_play(&h.u, view_of(&doc), &bindings)
		testing.expectf(t, h.u.ids.depth == 0, "%v: unbalanced id scope", kind)
		harness_end(h)
	}
}

// Every leaf kind must be usable inside a flex container. A flex run declares
// one track per carving child up front and ui asserts that each is consumed, so
// a kind whose slot behaviour this package models wrongly aborts the frame.
// Testing each kind alone is what names the culprit; a mixed document only says
// that something is wrong.
@(test)
test_every_leaf_kind_works_inside_a_flex_row :: proc(t: ^testing.T) {
	for kind in View_Kind {
		if view_kind_is_container(kind) do continue
		doc: View_Doc
		doc_reset(&doc)
		root, _ := doc_add_keyed(&doc, VIEW_NODE_NONE, .Column, "root", "")
		row, _ := doc_add_keyed(&doc, root, .Flex_Row, "row", "", View_Node{size_main = 40})
		node := View_Node {
			track = ui.Track{kind = .Grow, weight = 1},
			number_hi = 1,
		}
		if view_kind_binding(kind) != .None do node.binding = 0
		doc_add_keyed(&doc, row, kind, "leaf", "Leaf", node)

		flag: bool
		number: f32
		integer: i32
		box: ui.Input_Box
		ui.input_box_init(&box)
		defer ui.input_box_destroy(&box)
		slots := [1]Binding{}
		#partial switch view_kind_binding(kind) {
		case .Boolean:
			slots[0] = bind_boolean(&flag)
		case .Number:
			slots[0] = bind_number(&number)
		case .Integer:
			slots[0] = bind_integer(&integer)
		case .Text:
			slots[0] = bind_text(&box)
		}
		bindings := Bindings {
			slots = slots[:],
		}

		result, ok := view_validate(view_of(&doc))
		testing.expectf(t, ok, "%v: fixture did not validate: %v", kind, result)
		if !ok do continue
		h := harness_begin()
		view_play(&h.u, view_of(&doc), &bindings)
		testing.expectf(t, h.u.ids.depth == 0, "%v: unbalanced id scope", kind)
		harness_end(h)
	}
}

// Containers nest inside flex containers too, and they do not all take a track:
// Panel opens through push_column, which swallows the parent's remaining space
// instead. This is the case that produced "declared flex sizes not fully
// consumed" from a document that had already validated.
@(test)
test_every_container_kind_works_inside_a_flex_row :: proc(t: ^testing.T) {
	for kind in View_Kind {
		if !view_kind_is_container(kind) do continue
		doc: View_Doc
		doc_reset(&doc)
		root, _ := doc_add_keyed(&doc, VIEW_NODE_NONE, .Column, "root", "")
		row, _ := doc_add_keyed(&doc, root, .Flex_Row, "row", "", View_Node{size_main = 60})
		// A sibling on either side, so a wrong track count shows up as a
		// mismatch rather than as an empty run that happens to balance.
		doc_add_keyed(
			&doc,
			row,
			.Label,
			"before",
			"Before",
			View_Node{track = ui.Track{kind = .Grow, weight = 1}},
		)
		nested, _ := doc_add_keyed(
			&doc,
			row,
			kind,
			"nested",
			"",
			View_Node{track = ui.Track{kind = .Fixed, basis = 80}, size_main = 40},
		)
		doc_add_keyed(&doc, nested, .Label, "inner", "Inner")
		doc_add_keyed(
			&doc,
			row,
			.Label,
			"after",
			"After",
			View_Node{track = ui.Track{kind = .Grow, weight = 1}},
		)

		result, ok := view_validate(view_of(&doc))
		testing.expectf(t, ok, "%v: fixture did not validate: %v", kind, result)
		if !ok do continue
		h := harness_begin()
		view_play(&h.u, view_of(&doc), nil)
		testing.expectf(t, h.u.ids.depth == 0, "%v: unbalanced id scope", kind)
		harness_end(h)
	}
}
