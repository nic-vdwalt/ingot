// Authoring a document.
//
// Goal: give the builder, the tests and the decoder one way to populate a
// View_Doc, so the invariants view_validate checks are established at
// construction rather than discovered afterwards.
//
// Method: append-only. A node is added under a parent and linked at the end of
// that parent's child chain; text is interned into the blob. Both operations
// report ok rather than asserting on exhaustion, because running out of a fixed
// capacity is an operating condition of a large document, not a programmer
// error.
package view

doc_reset :: proc(doc: ^View_Doc) {
	assert(doc != nil, "doc_reset: nil doc")
	assert(doc.count >= 0 && doc.count <= VIEW_NODES_MAX, "doc_reset: count out of range")
	assert(doc.text_len <= VIEW_TEXT_BYTES_MAX, "doc_reset: text_len out of range")
	doc.count = 0
	doc.text_len = 0
}

// doc_intern appends text to the blob and returns its range. Identical strings
// are not deduplicated: dedup would make the encoder's output depend on
// insertion order in a way that is invisible in a diff, and the blob is bounded
// anyway.
doc_intern :: proc(doc: ^View_Doc, text: string) -> (offset: u32, length: u16, ok: bool) {
	assert(doc != nil, "doc_intern: nil doc")
	assert(doc.text_len <= VIEW_TEXT_BYTES_MAX, "doc_intern: text_len out of range")
	if text == "" do return 0, 0, true
	if len(text) > int(max(u16)) do return 0, 0, false
	if u64(doc.text_len) + u64(len(text)) > u64(VIEW_TEXT_BYTES_MAX) do return 0, 0, false
	start := doc.text_len
	copy(doc.text[start:], text)
	doc.text_len = start + u32(len(text))
	assert(doc.text_len <= VIEW_TEXT_BYTES_MAX, "doc_intern: overran text blob")
	return start, u16(len(text)), true
}

// doc_add appends a node under parent and returns its index. Pass
// VIEW_NODE_NONE as parent for a root. The node's links are set here and must
// not be assigned by the caller, so the tree stays well-formed by construction.
doc_add :: proc(doc: ^View_Doc, parent: i32, node: View_Node) -> (index: i32, ok: bool) {
	assert(doc != nil, "doc_add: nil doc")
	assert(doc.count >= 0 && doc.count <= VIEW_NODES_MAX, "doc_add: count out of range")
	if doc.count >= VIEW_NODES_MAX do return VIEW_NODE_NONE, false
	if parent != VIEW_NODE_NONE {
		if parent < 0 || parent >= doc.count do return VIEW_NODE_NONE, false
		if !view_kind_is_container(doc.nodes[parent].kind) do return VIEW_NODE_NONE, false
	}
	index = doc.count
	entry := node
	entry.parent = parent
	entry.first_child = VIEW_NODE_NONE
	entry.next_sibling = VIEW_NODE_NONE
	if view_kind_binding(entry.kind) == .None do entry.binding = VIEW_BINDING_NONE
	doc.nodes[index] = entry
	doc.count += 1
	doc_link(doc, parent, index)
	assert(doc.count > index, "doc_add: count did not advance")
	return index, true
}

// doc_link attaches a new node at the end of its sibling chain. Appending
// rather than prepending keeps document order equal to authoring order, which
// is what makes a generated literal readable and a diff meaningful.
@(private = "file")
doc_link :: proc(doc: ^View_Doc, parent: i32, index: i32) {
	assert(doc != nil, "doc_link: nil doc")
	assert(index >= 0 && index < doc.count, "doc_link: index out of range")
	first := doc_chain_head(doc, parent, index)
	if first == VIEW_NODE_NONE do return
	cursor := first
	steps := 0
	for doc.nodes[cursor].next_sibling != VIEW_NODE_NONE {
		cursor = doc.nodes[cursor].next_sibling
		steps += 1
		assert(steps <= VIEW_NODES_MAX, "doc_link: unbounded sibling chain")
	}
	doc.nodes[cursor].next_sibling = index
}

// doc_chain_head returns the head of the chain index joins, after installing
// index as that head if the chain was empty. Returning VIEW_NODE_NONE means the
// caller has nothing left to do.
@(private = "file")
doc_chain_head :: proc(doc: ^View_Doc, parent: i32, index: i32) -> i32 {
	assert(doc != nil, "doc_chain_head: nil doc")
	assert(index >= 0 && index < doc.count, "doc_chain_head: index out of range")
	assert(doc.count <= VIEW_NODES_MAX, "doc_chain_head: count exceeds capacity")
	assert(
		parent == VIEW_NODE_NONE || (parent >= 0 && parent < doc.count),
		"doc_chain_head: parent out of range",
	)
	if parent == VIEW_NODE_NONE {
		if index == 0 do return VIEW_NODE_NONE
		return 0
	}
	if doc.nodes[parent].first_child == VIEW_NODE_NONE {
		doc.nodes[parent].first_child = index
		return VIEW_NODE_NONE
	}
	return doc.nodes[parent].first_child
}

// doc_add_keyed is the common case: a node with a key and a label. It interns
// both before appending so a text-blob overflow cannot leave a node referring
// to a range that was never written.
doc_add_keyed :: proc(
	doc: ^View_Doc,
	parent: i32,
	kind: View_Kind,
	key: string,
	label: string,
	node: View_Node = {},
) -> (
	index: i32,
	ok: bool,
) {
	assert(doc != nil, "doc_add_keyed: nil doc")
	entry := node
	entry.kind = kind
	entry.key_offset, entry.key_length = doc_intern(doc, key) or_return
	entry.label_offset, entry.label_length = doc_intern(doc, label) or_return
	return doc_add(doc, parent, entry)
}

// --- editing text ------------------------------------------------------------
//
// The blob is append-only, so "set" means re-intern: the new text goes at the
// end and the old bytes become garbage. That is the right trade for an editor -
// setting is O(new text) with no index rewriting - but a long session would
// fill the blob with dead bytes, which is what doc_text_compact exists for.

// doc_set_key replaces a node's key. Returns ok = false when the node is out of
// range or the blob cannot hold the new text; a no-op set (same text) returns
// early so per-frame comparison in an editor never grows the blob.
doc_set_key :: proc(doc: ^View_Doc, node: i32, text: string) -> bool {
	assert(doc != nil, "doc_set_key: nil doc")
	if node < 0 || node >= doc.count do return false
	entry := &doc.nodes[node]
	if text_slice(view_of(doc), entry.key_offset, entry.key_length) == text do return true
	offset, length, ok := doc_intern(doc, text)
	if !ok do return false
	entry.key_offset = offset
	entry.key_length = length
	return true
}

// doc_set_label replaces a node's display text. Identity is the key, never the
// label, so this cannot reset widget state - which is the whole reason the two
// are separate fields.
doc_set_label :: proc(doc: ^View_Doc, node: i32, text: string) -> bool {
	assert(doc != nil, "doc_set_label: nil doc")
	if node < 0 || node >= doc.count do return false
	entry := &doc.nodes[node]
	if text_slice(view_of(doc), entry.label_offset, entry.label_length) == text do return true
	offset, length, ok := doc_intern(doc, text)
	if !ok do return false
	entry.label_offset = offset
	entry.label_length = length
	return true
}

// doc_set_value replaces a node's secondary text (a kv_row's value, a
// text_input's placeholder).
doc_set_value :: proc(doc: ^View_Doc, node: i32, text: string) -> bool {
	assert(doc != nil, "doc_set_value: nil doc")
	if node < 0 || node >= doc.count do return false
	entry := &doc.nodes[node]
	if text_slice(view_of(doc), entry.value_offset, entry.value_length) == text do return true
	offset, length, ok := doc_intern(doc, text)
	if !ok do return false
	entry.value_offset = offset
	entry.value_length = length
	return true
}

// doc_text_compact rebuilds the blob keeping only the bytes some node still
// references, in one bounded pass over count nodes. Every string survives
// byte-for-byte; only garbage from earlier doc_set_* calls is dropped.
//
// The scratch is a second full-size blob on the stack of whoever calls this,
// via a temp struct - not a global, so two documents can compact concurrently.
// Compaction cannot fail: the live text fit before, so it fits after.
doc_text_compact :: proc(doc: ^View_Doc) {
	assert(doc != nil, "doc_text_compact: nil doc")
	assert(doc.count >= 0 && doc.count <= VIEW_NODES_MAX, "doc_text_compact: count out of range")
	assert(doc.text_len <= VIEW_TEXT_BYTES_MAX, "doc_text_compact: text_len out of range")
	scratch := new(Compact_Scratch, context.temp_allocator)
	source := view_of(doc)
	for index in 0 ..< int(doc.count) {
		node := &doc.nodes[index]
		node.key_offset, node.key_length = compact_move(
			scratch,
			text_slice(source, node.key_offset, node.key_length),
		)
		node.label_offset, node.label_length = compact_move(
			scratch,
			text_slice(source, node.label_offset, node.label_length),
		)
		node.value_offset, node.value_length = compact_move(
			scratch,
			text_slice(source, node.value_offset, node.value_length),
		)
	}
	assert(scratch.len <= doc.text_len, "doc_text_compact: compaction grew the blob")
	copy(doc.text[:scratch.len], scratch.text[:scratch.len])
	doc.text_len = scratch.len
}

@(private = "file")
Compact_Scratch :: struct {
	text: [VIEW_TEXT_BYTES_MAX]u8,
	len:  u32,
}

@(private = "file")
compact_move :: proc(scratch: ^Compact_Scratch, text: string) -> (offset: u32, length: u16) {
	assert(scratch != nil, "compact_move: nil scratch")
	if text == "" do return 0, 0
	assert(
		u64(scratch.len) + u64(len(text)) <= u64(VIEW_TEXT_BYTES_MAX),
		"compact_move: live text exceeds the blob it came from",
	)
	start := scratch.len
	copy(scratch.text[start:], text)
	scratch.len = start + u32(len(text))
	return start, u16(len(text))
}
