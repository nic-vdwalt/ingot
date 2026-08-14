package main

import "core:fmt"
import "ingot:view"

seed_document :: proc(data: ^State) {
	assert(data != nil)
	view.doc_reset(&data.doc)
	root, _ := view.doc_add_keyed(
		&data.doc,
		view.VIEW_NODE_NONE,
		.Panel,
		"root",
		"",
		view.View_Node{gap = .MD, padding = .MD},
	)
	view.doc_add_keyed(&data.doc, root, .Section_Header, "", "Settings")
	view.doc_add_keyed(&data.doc, root, .Label, "", "Fit-only document editor")
	view.doc_add_keyed(&data.doc, root, .Button, "save", "Save", view.View_Node{style = .Primary})
	data.selected = root
}

add_label :: proc(data: ^State) {
	assert(data != nil)
	parent := i32(0)
	if data.doc.count == 0 {
		seed_document(data)
		return
	}
	_, err := view.doc_add_keyed(
		&data.doc,
		parent,
		.Label,
		"",
		fmt.tprintf("Label %d", data.doc.count),
	)
	data.status = "document full" if err != .None else "label added"
}

delete_last :: proc(data: ^State) {
	assert(data != nil)
	if data.doc.count <= 1 {
		data.status = "root retained"
		return
	}
	rebuilt: view.View_Doc
	source := view.view_of(&data.doc)
	for index in 0 ..< data.doc.count - 1 {
		node := data.doc.nodes[index]
		parent := node.parent
		key := view.view_text(source, node.key_offset, node.key_length)
		label := view.view_text(source, node.label_offset, node.label_length)
		value := view.view_text(source, node.value_offset, node.value_length)
		node.key_offset, node.key_length, _ = view.doc_intern(&rebuilt, key)
		node.label_offset, node.label_length, _ = view.doc_intern(&rebuilt, label)
		node.value_offset, node.value_length, _ = view.doc_intern(&rebuilt, value)
		_, _ = view.doc_add(&rebuilt, parent, node)
	}
	data.doc = rebuilt
	data.status = "last node deleted"
}
