// The one tree walk.
//
// Goal: view_play, view_validate and the generator are all walks over the same
// tree. Recursion is banned without exception, so writing three iterative walks
// would give a bounds bug three places to hide.
//
// Method: one iterator with an explicit depth stack and an asserted exit
// invariant. Callers differ only in what they do at each step, which they
// express by reading the step's kind. The iterator itself never touches node
// payloads, so it cannot be wrong about anything except structure.
package view

// Walk_Event distinguishes the two moments a container is visited. Leaves
// produce only .Enter, so a caller that ignores .Exit still sees every node
// exactly once.
Walk_Event :: enum u8 {
	Enter,
	Exit,
}

Walk_Step :: struct {
	node:  i32,
	depth: i32,
	event: Walk_Event,
}

// Walk_Fault records why iteration stopped. The walk knows the reason exactly;
// making callers infer it from an unbalanced end state would turn a depth
// overflow and a cycle into the same indistinguishable failure.
Walk_Fault :: enum u8 {
	None, // reached the end of the tree
	Depth,
	Bad_Link,
	Budget,
}

// Walk holds iteration state. It borrows nodes; the caller owns the view.
Walk :: struct {
	nodes: []View_Node,
	stack: [VIEW_DEPTH_MAX]i32,
	depth: i32,
	next:  i32,
	fault: Walk_Fault,
	// steps counts every step produced. Each node yields at most two steps, so
	// this bounds the loop independently of link structure: a cycle that slipped
	// past validation terminates the walk rather than hanging it.
	steps: i64,
}

WALK_STEPS_MAX :: i64(VIEW_NODES_MAX) * 2

walk_begin :: proc(view: View) -> Walk {
	assert(len(view.nodes) <= VIEW_NODES_MAX, "walk_begin: too many nodes")
	return Walk{nodes = view.nodes, next = len(view.nodes) > 0 ? 0 : VIEW_NODE_NONE}
}

// walk_next advances one step. It returns ok = false at the end of the tree and
// on any structural fault, so a caller cannot loop forever on a malformed
// document even if it skipped validation.
//
// The traversal is the usual preorder with an explicit stack: descend into
// first_child, else move to next_sibling, else unwind emitting .Exit for each
// container left behind.
walk_next :: proc(w: ^Walk) -> (step: Walk_Step, ok: bool) {
	assert(w != nil, "walk_next: nil walk")
	assert(w.depth >= 0 && w.depth <= VIEW_DEPTH_MAX, "walk_next: depth out of range")
	if w.steps >= WALK_STEPS_MAX {
		w.fault = .Budget
		return {}, false
	}
	w.steps += 1
	if w.next != VIEW_NODE_NONE {
		index := w.next
		if index < 0 || int(index) >= len(w.nodes) {
			w.fault = .Bad_Link
			return {}, false
		}
		node := w.nodes[index]
		result := Walk_Step {
			node  = index,
			depth = w.depth,
			event = .Enter,
		}
		if view_kind_is_container(node.kind) {
			if w.depth >= VIEW_DEPTH_MAX {
				w.fault = .Depth
				return {}, false
			}
			w.stack[w.depth] = index
			w.depth += 1
			w.next = node.first_child
		} else {
			w.next = node.next_sibling
		}
		return result, true
	}
	return walk_unwind(w)
}

// walk_unwind pops one container and emits its .Exit. It is separate so
// walk_next stays a single readable descent, per Tiger Style's preference for
// centralized control flow with the branchy detail pushed down.
@(private = "file")
walk_unwind :: proc(w: ^Walk) -> (step: Walk_Step, ok: bool) {
	assert(w != nil, "walk_unwind: nil walk")
	if w.depth <= 0 do return {}, false
	w.depth -= 1
	index := w.stack[w.depth]
	if index < 0 || int(index) >= len(w.nodes) {
		w.fault = .Bad_Link
		return {}, false
	}
	result := Walk_Step {
		node  = index,
		depth = w.depth,
		event = .Exit,
	}
	w.next = w.nodes[index].next_sibling
	return result, true
}

// walk_balanced reports whether a completed walk closed every container it
// opened. Callers assert this after their loop; an unbalanced walk means the
// caller broke out early or the tree was malformed, and either would leave a
// ui layout or identity scope open.
walk_balanced :: proc(w: ^Walk) -> bool {
	assert(w != nil, "walk_balanced: nil walk")
	return w.depth == 0 && w.next == VIEW_NODE_NONE
}
