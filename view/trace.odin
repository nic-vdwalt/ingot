// The play trace: where each node landed on screen.
//
// Goal: a builder needs hit-testing - click an element to select it, hover a
// container to target a drop. view_play walks the document and calls widgets
// that carve their own slots; nothing records the rects, so without this there
// is no selection and no drop target.
//
// Method: an optional tap on the one existing walk. Before and after each node,
// capture ui.remaining_rect; the consumed strip between the two, along the
// parent's main axis, is the node's rect. The axis comes from the document
// itself (a Row parent advances horizontally), so no ui internal is read. The
// delta includes the container gap, which is fine for hit-testing: a click in
// the gap selecting the nearer element is what a user expects anyway.
//
// The trace is builder instrumentation, not part of the format. It records
// screen-space pixels for one played frame and is stale the moment the document
// or window changes, which is why it is caller-owned and re-filled per frame
// like every other immediate-mode output.
package view

import "ingot:ui"

Play_Trace :: struct {
	// rects[i] is node i's on-screen rect for the frame just played. A zero
	// rect means the node drew nothing (a Spacer, or a container that received
	// no space).
	rects: [VIEW_NODES_MAX]ui.Rect_I32,
	count: i32,
}

// trace_reset clears a trace for a new frame. Rects are per-frame output; a
// stale rect would hit-test against a layout that no longer exists.
trace_reset :: proc(trace: ^Play_Trace) {
	assert(trace != nil, "trace_reset: nil trace")
	assert(trace.count >= 0 && trace.count <= VIEW_NODES_MAX, "trace_reset: count out of range")
	for index in 0 ..< int(trace.count) do trace.rects[index] = {}
	trace.count = 0
}

// trace_rect reports node's rect, or a zero rect when the node is out of range
// or drew nothing. Total rather than asserting, because the selection a caller
// holds can outlive the document that produced it by a frame.
trace_rect :: proc(trace: ^Play_Trace, node: i32) -> ui.Rect_I32 {
	assert(trace != nil, "trace_rect: nil trace")
	if node < 0 || node >= trace.count do return {}
	return trace.rects[node]
}

// trace_node_at returns the deepest node whose rect contains point, or
// VIEW_NODE_NONE. Depth wins because containers enclose their children: the
// button inside a row is what the user clicked, not the row. Later document
// order breaks depth ties, matching paint order (later paints on top).
trace_node_at :: proc(trace: ^Play_Trace, source: View, point: ui.Vector2) -> i32 {
	return trace_hit(trace, source, point, false)
}

// trace_container_at returns the deepest *container* whose rect contains point,
// or VIEW_NODE_NONE. This is the drop target: a widget dropped on a button
// should land in the button's parent, and skipping leaves entirely is simpler
// and more predictable than special-casing "on a leaf".
trace_container_at :: proc(trace: ^Play_Trace, source: View, point: ui.Vector2) -> i32 {
	return trace_hit(trace, source, point, true)
}

@(private = "file")
trace_hit :: proc(trace: ^Play_Trace, source: View, point: ui.Vector2, containers: bool) -> i32 {
	assert(trace != nil, "trace_hit: nil trace")
	assert(trace.count <= i32(len(source.nodes)), "trace_hit: trace larger than document")
	best := VIEW_NODE_NONE
	best_depth := i32(-1)
	for index in 0 ..< int(trace.count) {
		node := source.nodes[index]
		if containers && !view_kind_is_container(node.kind) do continue
		if !rect_contains(trace.rects[index], point) do continue
		depth := node_depth(source, i32(index))
		// >= so document order breaks ties at equal depth: the later sibling
		// painted on top.
		if depth >= best_depth {
			best = i32(index)
			best_depth = depth
		}
	}
	return best
}

// node_depth walks the parent chain. Bounded by the depth cap plus one so a
// corrupt chain terminates; validation already excluded cycles for any document
// that came through decode.
@(private = "file")
node_depth :: proc(source: View, node: i32) -> i32 {
	depth := i32(0)
	cursor := source.nodes[node].parent
	for cursor != VIEW_NODE_NONE && depth <= VIEW_DEPTH_MAX {
		depth += 1
		if cursor < 0 || int(cursor) >= len(source.nodes) do break
		cursor = source.nodes[cursor].parent
	}
	return depth
}

@(private = "file")
rect_contains :: proc(rect: ui.Rect_I32, point: ui.Vector2) -> bool {
	if rect.w <= 0 || rect.h <= 0 do return false
	x := i32(point.x)
	y := i32(point.y)
	return x >= rect.x && x < rect.x + rect.w && y >= rect.y && y < rect.y + rect.h
}

// Trace_Tap is the walk-side state. One entry per open container records the
// remaining rect at .Enter, so the container's own consumption can be resolved
// when .Exit closes it.
@(private = "package")
Trace_Tap :: struct {
	trace: ^Play_Trace, // nil = tracing disabled, every tap call is a no-op
	stack: [VIEW_DEPTH_MAX]ui.Rect_I32,
	depth: i32,
}

@(private = "package")
tap_begin :: proc(tap: ^Trace_Tap, trace: ^Play_Trace, source: View) {
	assert(tap != nil, "tap_begin: nil tap")
	assert(len(source.nodes) <= VIEW_NODES_MAX, "tap_begin: too many nodes")
	tap.trace = trace
	tap.depth = 0
	if trace == nil do return
	trace_reset(trace)
	trace.count = i32(len(source.nodes))
}

// tap_leaf records a leaf's consumption from the remaining rects captured
// around its emit call. axis_horizontal is the parent's main axis, taken from
// the document (or from ui.layout_kind for a depth-0 node), never guessed.
@(private = "package")
tap_leaf :: proc(tap: ^Trace_Tap, node: i32, before, after: ui.Rect_I32, horizontal: bool) {
	assert(tap != nil, "tap_leaf: nil tap")
	if tap.trace == nil do return
	assert(node >= 0 && node < tap.trace.count, "tap_leaf: node out of range")
	tap.trace.rects[node] = consumed_strip(before, after, horizontal)
}

@(private = "package")
tap_container_enter :: proc(tap: ^Trace_Tap, before: ui.Rect_I32) {
	assert(tap != nil, "tap_container_enter: nil tap")
	if tap.trace == nil do return
	assert(tap.depth < VIEW_DEPTH_MAX, "tap_container_enter: depth overflow")
	tap.stack[tap.depth] = before
	tap.depth += 1
}

// tap_container_exit resolves the container's rect from the remaining rect its
// parent showed before it opened and after it closed. Panel is the exception:
// it swallows the parent's entire remaining space (push_column), so its rect is
// simply everything that was available.
@(private = "package")
tap_container_exit :: proc(
	tap: ^Trace_Tap,
	node: i32,
	kind: View_Kind,
	after: ui.Rect_I32,
	horizontal: bool,
) {
	assert(tap != nil, "tap_container_exit: nil tap")
	if tap.trace == nil do return
	assert(tap.depth > 0, "tap_container_exit: depth underflow")
	tap.depth -= 1
	before := tap.stack[tap.depth]
	assert(node >= 0 && node < tap.trace.count, "tap_container_exit: node out of range")
	if kind == .Panel {
		tap.trace.rects[node] = before
		return
	}
	tap.trace.rects[node] = consumed_strip(before, after, horizontal)
}

// consumed_strip is the area the cursor advanced over: same cross extent as
// before, main extent equal to the cursor delta. A non-positive delta (a node
// that drew nothing, or a container that took the whole remaining space so
// after shrank to zero in both axes) yields a zero rect rather than nonsense.
@(private = "file")
consumed_strip :: proc(before, after: ui.Rect_I32, horizontal: bool) -> ui.Rect_I32 {
	if horizontal {
		delta := after.x - before.x
		if delta <= 0 do return {}
		return ui.Rect_I32{x = before.x, y = before.y, w = delta, h = before.h}
	}
	delta := after.y - before.y
	if delta <= 0 do return {}
	return ui.Rect_I32{x = before.x, y = before.y, w = before.w, h = delta}
}

// parent_axis_horizontal reports the main axis a node advances along, from the
// document. Depth-0 nodes sit in whatever container the caller opened around
// view_play, which the document cannot know - so the caller-supplied root axis
// is used for those.
@(private = "package")
parent_axis_horizontal :: proc(source: View, node: i32, root_horizontal: bool) -> bool {
	parent := source.nodes[node].parent
	if parent == VIEW_NODE_NONE do return root_horizontal
	#partial switch source.nodes[parent].kind {
	case .Row, .Flex_Row:
		return true
	}
	return false
}
