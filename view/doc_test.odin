package view

import "core:testing"
import "ingot:ui"

@(test)
test_doc_add_links_siblings_in_order :: proc(t: ^testing.T) {
	doc: View_Doc
	root, root_ok := doc_add_keyed(&doc, VIEW_NODE_NONE, .Column, "root", "")
	testing.expect(t, root_ok, "root add failed")
	first, first_ok := doc_add_keyed(&doc, root, .Label, "a", "A")
	second, second_ok := doc_add_keyed(&doc, root, .Label, "b", "B")
	testing.expect(t, first_ok && second_ok, "child add failed")
	testing.expect_value(t, doc.nodes[root].first_child, first)
	testing.expect_value(t, doc.nodes[first].next_sibling, second)
	testing.expect_value(t, doc.nodes[second].next_sibling, VIEW_NODE_NONE)
	testing.expect_value(t, doc.nodes[second].parent, root)
}

@(test)
test_doc_add_rejects_leaf_parent :: proc(t: ^testing.T) {
	doc: View_Doc
	root, _ := doc_add_keyed(&doc, VIEW_NODE_NONE, .Column, "root", "")
	leaf, _ := doc_add_keyed(&doc, root, .Label, "leaf", "L")
	_, ok := doc_add_keyed(&doc, leaf, .Label, "child", "C")
	testing.expect(t, !ok, "a leaf must not accept a child")
}

@(test)
test_doc_add_rejects_overflow :: proc(t: ^testing.T) {
	doc: View_Doc
	root, _ := doc_add_keyed(&doc, VIEW_NODE_NONE, .Column, "root", "")
	for index in 1 ..< VIEW_NODES_MAX {
		_, ok := doc_add(&doc, root, View_Node{kind = .Separator})
		testing.expectf(t, ok, "add %d failed early", index)
	}
	_, ok := doc_add(&doc, root, View_Node{kind = .Separator})
	testing.expect(t, !ok, "add past capacity must fail")
	testing.expect_value(t, doc.count, i32(VIEW_NODES_MAX))
}

@(test)
test_doc_intern_rejects_blob_overflow :: proc(t: ^testing.T) {
	doc: View_Doc
	big := make([]u8, VIEW_TEXT_BYTES_MAX)
	defer delete(big)
	for index in 0 ..< len(big) do big[index] = 'x'
	_, _, ok := doc_intern(&doc, string(big))
	testing.expect(t, ok, "a blob-sized string must fit exactly once")
	_, _, again := doc_intern(&doc, "y")
	testing.expect(t, !again, "intern past capacity must fail")
}

@(test)
test_view_of_borrows_populated_prefix :: proc(t: ^testing.T) {
	doc: View_Doc
	doc_add_keyed(&doc, VIEW_NODE_NONE, .Column, "root", "")
	doc_add_keyed(&doc, 0, .Label, "a", "Alpha")
	view := view_of(&doc)
	testing.expect_value(t, len(view.nodes), 2)
	testing.expect_value(t, view.text, "rootaAlpha")
}

@(test)
test_walk_visits_every_node_once_and_balances :: proc(t: ^testing.T) {
	doc: View_Doc
	root, _ := doc_add_keyed(&doc, VIEW_NODE_NONE, .Column, "root", "")
	row, _ := doc_add_keyed(&doc, root, .Row, "row", "")
	doc_add_keyed(&doc, row, .Label, "a", "A")
	doc_add_keyed(&doc, row, .Label, "b", "B")
	doc_add_keyed(&doc, root, .Separator, "", "")
	view := view_of(&doc)

	enters: [VIEW_NODES_MAX]int
	exits := 0
	walk := walk_begin(view)
	for {
		step, more := walk_next(&walk)
		if !more do break
		if step.event == .Enter {
			enters[step.node] += 1
		} else {
			exits += 1
		}
	}
	testing.expect(t, walk_balanced(&walk), "walk did not balance")
	testing.expect_value(t, exits, 2)
	for index in 0 ..< int(doc.count) {
		testing.expectf(t, enters[index] == 1, "node %d entered %d times", index, enters[index])
	}
}

@(test)
test_walk_terminates_on_sibling_cycle :: proc(t: ^testing.T) {
	doc: View_Doc
	doc_add_keyed(&doc, VIEW_NODE_NONE, .Column, "root", "")
	doc_add_keyed(&doc, 0, .Label, "a", "A")
	// Forge a cycle the builder cannot produce, to prove the step budget is a
	// real bound and not an assumption about well-formed input.
	doc.nodes[1].next_sibling = 1
	walk := walk_begin(view_of(&doc))
	steps := 0
	for {
		_, more := walk_next(&walk)
		if !more do break
		steps += 1
		testing.expect(t, steps <= int(WALK_STEPS_MAX), "walk exceeded its own budget")
		if steps > int(WALK_STEPS_MAX) do break
	}
	testing.expect(t, steps <= int(WALK_STEPS_MAX), "walk did not terminate")
}

@(test)
test_validate_accepts_a_built_document :: proc(t: ^testing.T) {
	doc: View_Doc
	root, _ := doc_add_keyed(&doc, VIEW_NODE_NONE, .Panel, "root", "")
	doc_add_keyed(&doc, root, .Section_Header, "", "Settings")
	doc_add_keyed(
		&doc,
		root,
		.Checkbox,
		"enabled",
		"Enabled",
		View_Node{binding = 0, ink = .Primary},
	)
	result, ok := view_validate(view_of(&doc))
	testing.expectf(t, ok, "validate rejected a built document: %v", result)
}

@(test)
test_validate_rejects_unreachable_node :: proc(t: ^testing.T) {
	doc: View_Doc
	doc_add_keyed(&doc, VIEW_NODE_NONE, .Column, "root", "")
	doc_add_keyed(&doc, 0, .Label, "a", "A")
	doc.nodes[0].first_child = VIEW_NODE_NONE
	result, ok := view_validate(view_of(&doc))
	testing.expect(t, !ok, "an orphan must not validate")
	testing.expect_value(t, result.fault, Validate_Fault.Unreachable)
}

@(test)
test_validate_rejects_duplicate_sibling_keys :: proc(t: ^testing.T) {
	doc: View_Doc
	root, _ := doc_add_keyed(&doc, VIEW_NODE_NONE, .Column, "root", "")
	doc_add_keyed(&doc, root, .Button, "save", "Save")
	doc_add_keyed(&doc, root, .Button, "save", "Save again")
	result, ok := view_validate(view_of(&doc))
	testing.expect(t, !ok, "duplicate sibling keys must not validate")
	testing.expect_value(t, result.fault, Validate_Fault.Duplicate_Key)
}

@(test)
test_validate_allows_same_key_in_different_scopes :: proc(t: ^testing.T) {
	doc: View_Doc
	root, _ := doc_add_keyed(&doc, VIEW_NODE_NONE, .Column, "root", "")
	left, _ := doc_add_keyed(&doc, root, .Row, "left", "")
	right, _ := doc_add_keyed(&doc, root, .Row, "right", "")
	doc_add_keyed(&doc, left, .Button, "ok", "OK")
	doc_add_keyed(&doc, right, .Button, "ok", "OK")
	result, ok := view_validate(view_of(&doc))
	testing.expectf(t, ok, "scoped keys must not collide: %v", result)
}

@(test)
test_validate_rejects_interactive_without_key :: proc(t: ^testing.T) {
	doc: View_Doc
	root, _ := doc_add_keyed(&doc, VIEW_NODE_NONE, .Column, "root", "")
	doc_add_keyed(&doc, root, .Button, "", "Unnamed")
	result, ok := view_validate(view_of(&doc))
	testing.expect(t, !ok, "an interactive node needs a key")
	testing.expect_value(t, result.fault, Validate_Fault.Missing_Key)
}

@(test)
test_validate_rejects_slider_without_label :: proc(t: ^testing.T) {
	doc: View_Doc
	root, _ := doc_add_keyed(&doc, VIEW_NODE_NONE, .Column, "root", "")
	doc_add_keyed(&doc, root, .Slider, "volume", "", View_Node{binding = 0, number_hi = 1})
	result, ok := view_validate(view_of(&doc))
	testing.expect(t, !ok, "ui.slider asserts on an empty a11y label")
	testing.expect_value(t, result.fault, Validate_Fault.Missing_Label)
}

@(test)
test_validate_rejects_missing_binding :: proc(t: ^testing.T) {
	doc: View_Doc
	root, _ := doc_add_keyed(&doc, VIEW_NODE_NONE, .Column, "root", "")
	doc_add_keyed(&doc, root, .Checkbox, "on", "On", View_Node{binding = VIEW_BINDING_NONE})
	result, ok := view_validate(view_of(&doc))
	testing.expect(t, !ok, "a checkbox needs a binding")
	testing.expect_value(t, result.fault, Validate_Fault.Missing_Binding)
}

@(test)
test_validate_rejects_text_range_past_blob :: proc(t: ^testing.T) {
	doc: View_Doc
	doc_add_keyed(&doc, VIEW_NODE_NONE, .Label, "", "A")
	doc.nodes[0].label_length = 64
	result, ok := view_validate(view_of(&doc))
	testing.expect(t, !ok, "a label past the blob must not validate")
	testing.expect_value(t, result.fault, Validate_Fault.Text_Range)
}

@(test)
test_validate_rejects_link_out_of_range :: proc(t: ^testing.T) {
	doc: View_Doc
	doc_add_keyed(&doc, VIEW_NODE_NONE, .Column, "root", "")
	doc.nodes[0].first_child = 99
	result, ok := view_validate(view_of(&doc))
	testing.expect(t, !ok, "an out-of-range link must not validate")
	testing.expect_value(t, result.fault, Validate_Fault.Bad_Link)
}

@(test)
test_validate_rejects_depth_overflow :: proc(t: ^testing.T) {
	doc: View_Doc
	parent := VIEW_NODE_NONE
	for depth in 0 ..= VIEW_DEPTH_MAX {
		index, ok := doc_add(&doc, parent, View_Node{kind = .Column})
		testing.expectf(t, ok, "add at depth %d failed", depth)
		parent = index
	}
	result, ok := view_validate(view_of(&doc))
	testing.expect(t, !ok, "a tree deeper than the ui stacks must not validate")
	testing.expect_value(t, result.fault, Validate_Fault.Depth)
}

@(test)
test_validate_rejects_leaf_with_child :: proc(t: ^testing.T) {
	doc: View_Doc
	doc_add_keyed(&doc, VIEW_NODE_NONE, .Column, "root", "")
	doc_add_keyed(&doc, 0, .Label, "a", "A")
	doc_add_keyed(&doc, 0, .Label, "b", "B")
	doc.nodes[1].first_child = 2
	result, ok := view_validate(view_of(&doc))
	testing.expect(t, !ok, "a leaf with a child must not validate")
	testing.expect_value(t, result.fault, Validate_Fault.Leaf_Has_Child)
}

@(test)
test_bindings_ok_requires_matching_kinds :: proc(t: ^testing.T) {
	doc: View_Doc
	root, _ := doc_add_keyed(&doc, VIEW_NODE_NONE, .Column, "root", "")
	doc_add_keyed(&doc, root, .Checkbox, "on", "On", View_Node{binding = 0})
	view := view_of(&doc)

	number: f32
	wrong := Bindings {
		slots = []Binding{bind_number(&number)},
	}
	result, ok := view_bindings_ok(view, &wrong)
	testing.expect(t, !ok, "a checkbox must not bind to a number")
	testing.expect_value(t, result.fault, Validate_Fault.Binding_Kind)

	flag: bool
	right := Bindings {
		slots = []Binding{bind_boolean(&flag)},
	}
	_, right_ok := view_bindings_ok(view, &right)
	testing.expect(t, right_ok, "a matching binding table must be accepted")
}

@(test)
test_bindings_ok_rejects_index_past_table :: proc(t: ^testing.T) {
	doc: View_Doc
	root, _ := doc_add_keyed(&doc, VIEW_NODE_NONE, .Column, "root", "")
	doc_add_keyed(&doc, root, .Checkbox, "on", "On", View_Node{binding = 7})
	empty := Bindings{}
	result, ok := view_bindings_ok(view_of(&doc), &empty)
	testing.expect(t, !ok, "a binding index past the table must be rejected")
	testing.expect_value(t, result.fault, Validate_Fault.Binding_Range)
}

@(test)
test_sink_push_counts_overflow_instead_of_dropping_silently :: proc(t: ^testing.T) {
	sink: Event_Sink
	for index in 0 ..< VIEW_EVENTS_MAX + 3 {
		sink_push(&sink, Event{node = i32(index)})
	}
	testing.expect_value(t, sink.count, i32(VIEW_EVENTS_MAX))
	testing.expect_value(t, sink.dropped, i32(3))
}

@(test)
test_kind_tables_agree_on_every_kind :: proc(t: ^testing.T) {
	// A container never binds and never registers focus. Checking the tables
	// against each other over the whole enum means adding a kind cannot leave
	// one of them stale.
	for kind in View_Kind {
		if view_kind_is_container(kind) {
			testing.expectf(t, !view_kind_is_interactive(kind), "%v: container is focusable", kind)
			testing.expectf(
				t,
				view_kind_binding(kind) == .None,
				"%v: container has a binding",
				kind,
			)
		}
		if view_kind_is_flex(kind) {
			testing.expectf(t, view_kind_is_container(kind), "%v: flex is not a container", kind)
		}
	}
}

@(test)
test_bounds_fit_the_ui_stacks :: proc(t: ^testing.T) {
	testing.expect(t, VIEW_DEPTH_MAX <= ui.MAX_ID_DEPTH, "depth exceeds the identity stack")
	testing.expect(t, VIEW_DEPTH_MAX <= ui.MAX_LAYOUT_DEPTH, "depth exceeds the layout stack")
}

@(test)
test_validate_rejects_text_input_without_label :: proc(t: ^testing.T) {
	doc: View_Doc
	root, _ := doc_add_keyed(&doc, VIEW_NODE_NONE, .Column, "root", "")
	doc_add_keyed(&doc, root, .Text_Input, "name", "", View_Node{binding = 0})
	result, ok := view_validate(view_of(&doc))
	testing.expect(t, !ok, "ui.text_input asserts on an empty accessible label")
	testing.expect_value(t, result.fault, Validate_Fault.Missing_Label)
}
