// The builder's document operations: seeding, adding, and deleting nodes.
//
// Every mutation goes through view.doc_* so the tree stays well-formed by
// construction, and every one of them ends with the document still passing
// view_validate. Delete is the interesting case: removing a node renumbers
// every index, so it is done by rebuilding rather than by patching links.
package main

import "core:fmt"
import "ingot:ui"
import "ingot:view"

// seed_document gives the builder something to look at on first run. It is the
// same shape as view/testdata/settings.ingv, so the example and the test
// fixture stay recognisably related.
seed_document :: proc(data: ^State) {
	assert(data != nil, "seed_document: nil state")
	doc := &data.doc
	view.doc_reset(doc)
	root, _ := view.doc_add_keyed(
		doc,
		view.VIEW_NODE_NONE,
		.Panel,
		"root",
		"",
		view.View_Node{gap = .MD, padding = .MD},
	)
	view.doc_add_keyed(doc, root, .Section_Header, "", "Settings")
	view.doc_add_keyed(
		doc,
		root,
		.Checkbox,
		"enabled",
		"Enabled",
		view.View_Node{binding = BINDING_BOOLEAN},
	)
	row, _ := view.doc_add_keyed(
		doc,
		root,
		.Flex_Row,
		"actions",
		"",
		view.View_Node{size_main = 32, gap = .SM},
	)
	view.doc_add_keyed(
		doc,
		row,
		.Button,
		"save",
		"Save",
		view.View_Node{style = .Primary, track = ui.Track{kind = .Grow, weight = 1}},
	)
	view.doc_add_keyed(
		doc,
		row,
		.Button,
		"cancel",
		"Cancel",
		view.View_Node{style = .Ghost, track = ui.Track{kind = .Fixed, basis = 90}},
	)
	data.selected = root
}

// add_node inserts under the selection, or under the selection's parent when
// the selection is a leaf. Falling back to the parent is what makes clicking a
// palette entry always do something: the alternative is a silent no-op whenever
// a leaf happens to be selected.
add_node :: proc(data: ^State, kind: view.View_Kind) {
	assert(data != nil, "add_node: nil state")
	doc := &data.doc
	parent := add_target(data)
	if parent == view.VIEW_NODE_NONE {
		set_status(data, "no container to add into", true)
		return
	}
	node := view.View_Node {
		track = ui.Track{kind = .Grow, weight = 1},
		size_main = default_size(kind),
		number_hi = 1,
	}
	binding := view.view_kind_binding(kind)
	#partial switch binding {
	case .Boolean:
		node.binding = BINDING_BOOLEAN
	case .Number:
		node.binding = BINDING_NUMBER
	case .Integer:
		node.binding = BINDING_INTEGER
	case .Text:
		node.binding = BINDING_TEXT
	}
	key := fmt.tprintf("n%d", doc.count)
	label := default_label(kind)
	index, ok := view.doc_add_keyed(doc, parent, kind, key, label, node)
	if !ok {
		set_status(data, "document is full", true)
		return
	}
	data.selected = index
	set_status(data, fmt.tprintf("added %v", kind))
}

// add_target resolves where a new node goes: the selection if it is a
// container, otherwise its parent.
add_target :: proc(data: ^State) -> i32 {
	assert(data != nil, "add_target: nil state")
	doc := &data.doc
	if doc.count == 0 do return view.VIEW_NODE_NONE
	if data.selected < 0 || data.selected >= doc.count do return 0
	if view.view_kind_is_container(doc.nodes[data.selected].kind) do return data.selected
	return doc.nodes[data.selected].parent
}

// default_label gives a new node text where the kind requires it. A node the
// user cannot see is a node they cannot select, and several kinds assert on
// empty text rather than rendering blank.
default_label :: proc(kind: view.View_Kind) -> string {
	if view.view_kind_is_container(kind) do return ""
	#partial switch kind {
	case .Separator, .Spacer:
		return ""
	}
	return fmt.tprintf("%v", kind)
}

default_size :: proc(kind: view.View_Kind) -> i32 {
	#partial switch kind {
	case .Row, .Flex_Row:
		return 40
	case .Column, .Flex_Column:
		return 0
	}
	return 0
}

// delete_node removes the selection and its subtree by rebuilding the document
// without them.
//
// Rebuilding rather than unlinking is deliberate: every index in the document
// refers to an array position, so removing one node renumbers the rest, and
// patching parent, first_child and next_sibling in place is exactly the kind of
// index arithmetic that produces a tree which still validates but is subtly
// wrong. A rebuild has one invariant - visit the survivors in order - and
// view.doc_add re-establishes the links itself.
delete_node :: proc(data: ^State) {
	assert(data != nil, "delete_node: nil state")
	doc := &data.doc
	if doc.count == 0 do return
	if data.selected <= 0 || data.selected >= doc.count {
		set_status(data, "select a node other than the root to delete", true)
		return
	}
	doomed := data.selected
	rebuilt := new(view.View_Doc, context.temp_allocator)
	mapping := make([]i32, doc.count, context.temp_allocator)
	for index in 0 ..< len(mapping) do mapping[index] = view.VIEW_NODE_NONE

	source := view.view_of(doc)
	walk := view.walk_begin(source)
	for {
		step, more := view.walk_next(&walk)
		if !more do break
		if step.event != .Enter do continue
		if step.node == doomed || descends_from(doc, step.node, doomed) do continue
		copy_node(rebuilt, doc, step.node, mapping)
	}
	data.doc = rebuilt^
	data.selected = clamp(doomed - 1, 0, max(data.doc.count - 1, 0))
	set_status(data, "deleted")
}

// descends_from walks up the parent chain. The loop is bounded by the node
// count rather than by trusting the tree, because this runs on a document the
// user is actively editing.
descends_from :: proc(doc: ^view.View_Doc, node: i32, ancestor: i32) -> bool {
	assert(doc != nil, "descends_from: nil doc")
	cursor := node
	steps := 0
	for cursor != view.VIEW_NODE_NONE {
		steps += 1
		assert(steps <= int(doc.count) + 1, "descends_from: unbounded parent chain")
		if cursor == ancestor do return true
		cursor = doc.nodes[cursor].parent
	}
	return false
}

// copy_node appends one survivor, re-interning its text and remapping its
// parent. Preorder guarantees the parent was copied first, which is what makes
// the mapping lookup total.
copy_node :: proc(dst: ^view.View_Doc, src: ^view.View_Doc, index: i32, mapping: []i32) {
	assert(dst != nil && src != nil, "copy_node: nil document")
	assert(index >= 0 && index < src.count, "copy_node: index out of range")
	node := src.nodes[index]
	parent := node.parent
	target := parent == view.VIEW_NODE_NONE ? view.VIEW_NODE_NONE : mapping[parent]
	source := view.view_of(src)
	entry := node
	entry.key_offset, entry.key_length, _ = view.doc_intern(
		dst,
		view.view_text(source, node.key_offset, node.key_length),
	)
	entry.label_offset, entry.label_length, _ = view.doc_intern(
		dst,
		view.view_text(source, node.label_offset, node.label_length),
	)
	entry.value_offset, entry.value_length, _ = view.doc_intern(
		dst,
		view.view_text(source, node.value_offset, node.value_length),
	)
	copied, ok := view.doc_add(dst, target, entry)
	if !ok do return
	mapping[index] = copied
}
