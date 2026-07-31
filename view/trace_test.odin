#+build !js
package view

import "core:testing"
import "ingot:ui"

// Trace geometry and hit-testing. The trace is what makes the builder's canvas
// clickable, so a wrong rect here is a selection that lands on the wrong
// element there. Tests use the mono text backend so every measurement is
// deterministic.

@(private = "file")
MONO_CELL :: f32(8)

@(private = "file")
mono_font :: proc(data: rawptr, size: i32) -> ui.Font_Id {
	return ui.Font_Id(1)
}

@(private = "file")
mono_measure :: proc(
	data: rawptr,
	font: ui.Font_Id,
	text: string,
	size, spacing: f32,
) -> ui.Vec2 {
	return ui.Vec2{MONO_CELL * f32(len(text)), size}
}

@(private = "file")
Harness :: struct {
	runtime: ui.Ui_Runtime,
	frame:   ui.Ui_Frame,
	output:  ui.Ui_Output,
	u:       ui.Ui,
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

@(private = "file")
trace_doc :: proc(doc: ^View_Doc) {
	assert(doc != nil, "trace_doc: nil doc")
	doc_reset(doc)
	// Panel, not a width-0 Column: column_begin treats size_main as the literal
	// width, so a zero-width root would collapse every rect in the trace.
	root, _ := doc_add_keyed(doc, VIEW_NODE_NONE, .Panel, "root", "", View_Node{gap = .SM})
	doc_add_keyed(doc, root, .Section_Header, "", "Header")
	doc_add_keyed(doc, root, .Label, "", "A label")
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
		View_Node{track = ui.Track{kind = .Grow, weight = 1}},
	)
	doc_add_keyed(
		doc,
		row,
		.Button,
		"cancel",
		"Cancel",
		View_Node{track = ui.Track{kind = .Fixed, basis = 80}},
	)
	doc_add_keyed(doc, root, .Separator, "", "")
	doc_add_keyed(doc, root, .Spinner, "", "", View_Node{size_main = 24})
}

@(private = "file")
play_with_trace :: proc(doc: ^View_Doc, trace: ^Play_Trace) {
	assert(doc != nil && trace != nil, "play_with_trace: nil argument")
	h := harness_begin()
	defer harness_end(h)
	view_play_traced(&h.u, view_of(doc), nil, trace)
}

@(private = "file")
rect_center :: proc(rect: ui.Rect_I32) -> ui.Vector2 {
	return ui.Vector2{f32(rect.x) + f32(rect.w) / 2, f32(rect.y) + f32(rect.h) / 2}
}

@(private = "file")
rect_inside :: proc(inner, outer: ui.Rect_I32) -> bool {
	if inner.w <= 0 || inner.h <= 0 do return true
	return(
		inner.x >= outer.x &&
		inner.y >= outer.y &&
		inner.x + inner.w <= outer.x + outer.w &&
		inner.y + inner.h <= outer.y + outer.h \
	)
}

@(test)
test_trace_records_a_rect_for_every_carving_node :: proc(t: ^testing.T) {
	doc: View_Doc
	trace_doc(&doc)
	trace: Play_Trace
	play_with_trace(&doc, &trace)
	testing.expect_value(t, trace.count, doc.count)
	for index in 0 ..< int(doc.count) {
		node := doc.nodes[index]
		rect := trace.rects[index]
		if view_kind_carves_slot(node.kind) && node.kind != .Column {
			testing.expectf(
				t,
				rect.w > 0 && rect.h > 0,
				"%v at %d has zero rect %v",
				node.kind,
				index,
				rect,
			)
		}
	}
}

@(test)
test_trace_children_sit_inside_their_container :: proc(t: ^testing.T) {
	doc: View_Doc
	trace_doc(&doc)
	trace: Play_Trace
	play_with_trace(&doc, &trace)
	for index in 0 ..< int(doc.count) {
		parent := doc.nodes[index].parent
		if parent == VIEW_NODE_NONE do continue
		testing.expectf(
			t,
			rect_inside(trace.rects[index], trace.rects[parent]),
			"node %d rect %v escapes parent %d rect %v",
			index,
			trace.rects[index],
			parent,
			trace.rects[parent],
		)
	}
}

@(test)
test_trace_siblings_do_not_overlap :: proc(t: ^testing.T) {
	doc: View_Doc
	trace_doc(&doc)
	trace: Play_Trace
	play_with_trace(&doc, &trace)
	source := view_of(&doc)
	for index in 0 ..< int(doc.count) {
		first := trace.rects[index]
		if first.w <= 0 || first.h <= 0 do continue
		sibling := source.nodes[index].next_sibling
		for sibling != VIEW_NODE_NONE {
			second := trace.rects[sibling]
			if second.w > 0 && second.h > 0 {
				overlap_x := first.x < second.x + second.w && second.x < first.x + first.w
				overlap_y := first.y < second.y + second.h && second.y < first.y + first.h
				testing.expectf(
					t,
					!(overlap_x && overlap_y),
					"nodes %d (%v) and %d (%v) overlap",
					index,
					first,
					sibling,
					second,
				)
			}
			sibling = source.nodes[sibling].next_sibling
		}
	}
}

@(test)
test_trace_node_at_finds_the_deepest_node :: proc(t: ^testing.T) {
	doc: View_Doc
	trace_doc(&doc)
	trace: Play_Trace
	play_with_trace(&doc, &trace)
	source := view_of(&doc)
	// The centre of each leaf's own rect must resolve to that leaf, not to an
	// enclosing container. This is the property that makes clicking work.
	for index in 0 ..< int(doc.count) {
		node := doc.nodes[index]
		if view_kind_is_container(node.kind) do continue
		rect := trace.rects[index]
		if rect.w <= 0 || rect.h <= 0 do continue
		hit := trace_node_at(&trace, source, rect_center(rect))
		testing.expectf(t, hit == i32(index), "centre of node %d resolved to %d", index, hit)
	}
}

@(test)
test_trace_container_at_skips_leaves :: proc(t: ^testing.T) {
	doc: View_Doc
	trace_doc(&doc)
	trace: Play_Trace
	play_with_trace(&doc, &trace)
	source := view_of(&doc)
	// Find the save button and probe its centre: the container hit must be the
	// flex row it lives in, never the button itself.
	button := i32(VIEW_NODE_NONE)
	row := i32(VIEW_NODE_NONE)
	for index in 0 ..< int(doc.count) {
		if doc.nodes[index].kind == .Button && button == VIEW_NODE_NONE do button = i32(index)
		if doc.nodes[index].kind == .Flex_Row do row = i32(index)
	}
	testing.expect(t, button != VIEW_NODE_NONE && row != VIEW_NODE_NONE, "fixture lost its shape")
	hit := trace_container_at(&trace, source, rect_center(trace.rects[button]))
	testing.expect_value(t, hit, row)
}

@(test)
test_trace_miss_returns_none :: proc(t: ^testing.T) {
	doc: View_Doc
	trace_doc(&doc)
	trace: Play_Trace
	play_with_trace(&doc, &trace)
	source := view_of(&doc)
	testing.expect_value(t, trace_node_at(&trace, source, {-50, -50}), i32(VIEW_NODE_NONE))
	testing.expect_value(t, trace_node_at(&trace, source, {10000, 10000}), i32(VIEW_NODE_NONE))
}

@(test)
test_trace_rect_is_total_over_bad_indices :: proc(t: ^testing.T) {
	trace: Play_Trace
	testing.expect_value(t, trace_rect(&trace, -1), ui.Rect_I32{})
	testing.expect_value(t, trace_rect(&trace, 0), ui.Rect_I32{})
	testing.expect_value(t, trace_rect(&trace, VIEW_NODES_MAX + 5), ui.Rect_I32{})
}

// Tracing must not change what is painted. view_play with a nil trace and
// view_play_traced with a live one must produce identical output, because the
// builder's Edit canvas is still the real runtime.
@(test)
test_tracing_does_not_change_the_paint :: proc(t: ^testing.T) {
	doc: View_Doc
	trace_doc(&doc)

	plain_count, plain_checksum: int
	{
		h := harness_begin()
		view_play(&h.u, view_of(&doc), nil)
		plain_count = h.output.main.count
		plain_checksum = int(paint_commands_checksum(&h.output.main))
		harness_end(h)
	}
	traced_count, traced_checksum: int
	{
		trace: Play_Trace
		h := harness_begin()
		view_play_traced(&h.u, view_of(&doc), nil, &trace)
		traced_count = h.output.main.count
		traced_checksum = int(paint_commands_checksum(&h.output.main))
		harness_end(h)
	}
	testing.expect_value(t, traced_count, plain_count)
	testing.expect_value(t, traced_checksum, plain_checksum)
}

@(private = "file")
paint_commands_checksum :: proc(list: ^ui.Paint_List) -> u32 {
	assert(list != nil, "paint_commands_checksum: nil list")
	if list.count == 0 do return 0
	bytes := (cast([^]u8)&list.commands[0])[:list.count * size_of(ui.Paint_Command)]
	return view_checksum(bytes)
}

// The risk the plan named: justified flex runs pack slots away from the cursor
// delta. If this fails, the fallback is per-slot capture inside the flex run.
@(test)
test_trace_survives_a_justified_flex_row :: proc(t: ^testing.T) {
	doc: View_Doc
	doc_reset(&doc)
	root, _ := doc_add_keyed(&doc, VIEW_NODE_NONE, .Panel, "root", "")
	row, _ := doc_add_keyed(
		&doc,
		root,
		.Flex_Row,
		"row",
		"",
		View_Node{size_main = 32, justify = .End},
	)
	first, _ := doc_add_keyed(
		&doc,
		row,
		.Button,
		"a",
		"A",
		View_Node{track = ui.Track{kind = .Fixed, basis = 60}},
	)
	second, _ := doc_add_keyed(
		&doc,
		row,
		.Button,
		"b",
		"B",
		View_Node{track = ui.Track{kind = .Fixed, basis = 60}},
	)
	trace: Play_Trace
	play_with_trace(&doc, &trace)
	source := view_of(&doc)

	// The row's rect is reliable regardless of justification; the buttons' own
	// rects may be offset by the packing. What must hold: probing each button's
	// TRACE rect centre resolves within the row (never to a sibling container),
	// and the row is the container hit everywhere inside it.
	row_rect := trace.rects[row]
	testing.expect(t, row_rect.w > 0 && row_rect.h > 0, "row has no rect")
	for leaf in ([2]i32{first, second}) {
		rect := trace.rects[leaf]
		if rect.w <= 0 do continue
		hit := trace_container_at(&trace, source, rect_center(rect))
		testing.expectf(t, hit == row, "button %d container hit was %d", leaf, hit)
	}
}
