// Document validation.
//
// Goal: establish, once, every invariant view_play then relies on. Play uses
// ensure at the point of unchecked use; that is defence in depth against a
// hand-constructed View, not the primary check. This file is the primary check.
//
// Method: structural checks first (links, reachability, depth), then payload
// checks (text ranges, bindings, keys). Structure is checked first because the
// payload pass walks the tree, and walking an unvalidated tree is what the
// walk's own step budget exists to survive.
//
// Every fault returns ok = false with a reason. Nothing here asserts on
// document content: a corrupt document is an operating error, and this
// procedure is what handles it.
package view

import "ingot:ui"

Validate_Fault :: enum u8 {
	None,
	Node_Count,
	Text_Length,
	Bad_Link,
	Cycle,
	Depth,
	Unreachable,
	Text_Range,
	Binding_Range,
	Binding_Kind,
	Missing_Binding,
	Duplicate_Key,
	Missing_Key,
	Missing_Label,
	Focusable_Count,
	Leaf_Has_Child,
}

Validate_Result :: struct {
	fault: Validate_Fault,
	node:  i32,
}

// view_validate reports whether a document is safe to play. A caller that
// intends to play a document it did not build itself must call this first.
view_validate :: proc(view: View) -> (result: Validate_Result, ok: bool) {
	if len(view.nodes) > VIEW_NODES_MAX do return {fault = .Node_Count}, false
	if len(view.text) > VIEW_TEXT_BYTES_MAX do return {fault = .Text_Length}, false
	if len(view.nodes) == 0 do return {}, true
	if result = validate_links(view); result.fault != .None do return result, false
	if result = validate_payloads(view); result.fault != .None do return result, false
	if result = validate_keys(view); result.fault != .None do return result, false
	return {}, true
}

// validate_links checks that every index is in range and that the tree is a
// tree: each node reachable exactly once, no leaf with children, depth within
// the stacks ui provides. A cycle shows up as a node reached twice, which is
// why reachability is counted rather than merely tested.
@(private = "file")
validate_links :: proc(view: View) -> Validate_Result {
	count := i32(len(view.nodes))
	for node, index in view.nodes {
		if !link_in_range(node.parent, count) do return {fault = .Bad_Link, node = i32(index)}
		if !link_in_range(node.first_child, count) do return {fault = .Bad_Link, node = i32(index)}
		if !link_in_range(node.next_sibling, count) do return {fault = .Bad_Link, node = i32(index)}
		if node.next_sibling == i32(index) do return {fault = .Cycle, node = i32(index)}
		if node.first_child == i32(index) do return {fault = .Cycle, node = i32(index)}
		leaf := !view_kind_is_container(node.kind)
		if leaf && node.first_child != VIEW_NODE_NONE {
			return {fault = .Leaf_Has_Child, node = i32(index)}
		}
	}
	return validate_reachability(view)
}

@(private = "file")
link_in_range :: proc(link: i32, count: i32) -> bool {
	assert(count >= 0, "link_in_range: negative count")
	return link == VIEW_NODE_NONE || (link >= 0 && link < count)
}

// validate_reachability walks the tree and requires that it visits every node
// exactly once. That single condition rules out cycles, forests and orphans
// together, which is cheaper and harder to get wrong than testing each.
@(private = "file")
validate_reachability :: proc(view: View) -> Validate_Result {
	seen: [VIEW_NODES_MAX]bool
	walk := walk_begin(view)
	for {
		step, more := walk_next(&walk)
		if !more do break
		if step.event != .Enter do continue
		if seen[step.node] do return {fault = .Cycle, node = step.node}
		seen[step.node] = true
	}
	switch walk.fault {
	case .Depth:
		return {fault = .Depth, node = walk.stack[VIEW_DEPTH_MAX - 1]}
	case .Bad_Link:
		return {fault = .Bad_Link, node = VIEW_NODE_NONE}
	case .Budget:
		return {fault = .Cycle, node = VIEW_NODE_NONE}
	case .None:
	}
	if !walk_balanced(&walk) do return {fault = .Cycle, node = VIEW_NODE_NONE}
	for index in 0 ..< len(view.nodes) {
		if !seen[index] do return {fault = .Unreachable, node = i32(index)}
	}
	return {}
}

// validate_payloads checks text ranges, binding indices and binding kinds, and
// bounds the focusable count. It also rejects a slider or text input without a
// label: both assert on an empty accessible name inside ui, and a document must
// not be able to reach an assertion in another package.
@(private = "file")
validate_payloads :: proc(view: View) -> Validate_Result {
	focusables := 0
	for node, index in view.nodes {
		at := i32(index)
		if !text_range_ok(view, node.key_offset, node.key_length) {
			return {fault = .Text_Range, node = at}
		}
		if !text_range_ok(view, node.label_offset, node.label_length) {
			return {fault = .Text_Range, node = at}
		}
		if !text_range_ok(view, node.value_offset, node.value_length) {
			return {fault = .Text_Range, node = at}
		}
		if result := validate_node_binding(node, at); result.fault != .None do return result
		if view_kind_is_interactive(node.kind) {
			focusables += 1
			if node.key_length == 0 do return {fault = .Missing_Key, node = at}
		}
		if view_kind_needs_label(node.kind) && node.label_length == 0 {
			return {fault = .Missing_Label, node = at}
		}
	}
	if focusables > ui.MAX_FOCUSABLES do return {fault = .Focusable_Count, node = VIEW_NODE_NONE}
	return {}
}

@(private = "file")
validate_node_binding :: proc(node: View_Node, at: i32) -> Validate_Result {
	required := view_kind_binding(node.kind)
	if required == .None {
		if node.binding != VIEW_BINDING_NONE do return {fault = .Binding_Kind, node = at}
		return {}
	}
	if node.binding == VIEW_BINDING_NONE do return {fault = .Missing_Binding, node = at}
	if node.binding < 0 do return {fault = .Binding_Range, node = at}
	return {}
}

@(private = "file")
text_range_ok :: proc(view: View, offset: u32, length: u16) -> bool {
	if length == 0 do return true
	end := u64(offset) + u64(length)
	return end <= u64(len(view.text))
}

// view_bindings_ok checks a document against the binding table it will actually
// be played with. It is separate from view_validate because the table is the
// caller's, not the document's: the same view may be played against different
// tables, and each pairing needs checking.
view_bindings_ok :: proc(view: View, bindings: ^Bindings) -> (result: Validate_Result, ok: bool) {
	assert(bindings != nil, "view_bindings_ok: nil bindings")
	for node, index in view.nodes {
		required := view_kind_binding(node.kind)
		if required == .None do continue
		if node.binding < 0 || int(node.binding) >= len(bindings.slots) {
			return {fault = .Binding_Range, node = i32(index)}, false
		}
		if bindings.slots[node.binding].kind != required {
			return {fault = .Binding_Kind, node = i32(index)}, false
		}
	}
	return {}, true
}

// validate_keys requires sibling keys to be unique. Two siblings with one key
// derive the same Widget_Id and would share focus and interaction state, which
// looks like a widget bug rather than a document bug.
@(private = "file")
validate_keys :: proc(view: View) -> Validate_Result {
	for node, index in view.nodes {
		if !view_kind_is_container(node.kind) && index != 0 do continue
		if result := validate_sibling_keys(view, node.first_child); result.fault != .None {
			return result
		}
	}
	return validate_root_keys(view)
}

// validate_root_keys applies the same rule to the roots themselves, which have
// no parent to have carried their sibling chain.
@(private = "file")
validate_root_keys :: proc(view: View) -> Validate_Result {
	if len(view.nodes) == 0 do return {}
	return validate_sibling_keys(view, 0)
}

// validate_sibling_keys scans one sibling chain. The chain is bounded by the
// node count, and the loop asserts it: a cycle here was already excluded by
// reachability, so exceeding the bound would mean this ran on an unvalidated
// document.
@(private = "file")
validate_sibling_keys :: proc(view: View, first: i32) -> Validate_Result {
	steps := 0
	for outer := first; outer != VIEW_NODE_NONE; outer = view.nodes[outer].next_sibling {
		steps += 1
		assert(steps <= VIEW_NODES_MAX, "validate_sibling_keys: unbounded chain")
		key := text_slice(view, view.nodes[outer].key_offset, view.nodes[outer].key_length)
		if key == "" do continue
		next := view.nodes[outer].next_sibling
		for inner := next; inner != VIEW_NODE_NONE; inner = view.nodes[inner].next_sibling {
			other := text_slice(view, view.nodes[inner].key_offset, view.nodes[inner].key_length)
			if other == key do return {fault = .Duplicate_Key, node = inner}
		}
	}
	return {}
}
