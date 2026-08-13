// Playing a view.
//
// Goal: this is the only implementation of what a node means. Generated code
// emits a View literal and calls straight into here, so there is no second
// emitter to drift from this one.
//
// Method: view_play owns the walk and the switch and nothing else. Every kind
// is one pure emit_* leaf below, taking primitives rather than the document or
// the walk state, so a leaf cannot depend on where in the tree it was reached
// and the hot path stays inspectable.
//
// The ensure calls here are deliberate and are not duplicating view_validate.
// Validation is the primary check and runs at decode; these guard the case
// where a caller hand-built a View and skipped it. A binding index and its kind
// are document-derived values about to be used unchecked, which is exactly what
// ensure is for.
package view

import "ingot:fit"
import "ingot:ui"

// view_play walks the view and emits it into u. bindings supplies the state the
// document cannot own; pass nil only for a view with no interactive nodes.
//
// The caller owns everything: u, the bindings, and the storage view borrows.
// Nothing is retained past this call, which is what keeps a saved view
// compatible with immediate mode rather than a retained tree in disguise.
view_play :: proc(u: ^ui.Ui, view: View, bindings: ^Bindings) {
	view_play_traced(u, view, bindings, nil)
}

play_fit :: proc(u: ^fit.Ui, view: View, bindings: ^Bindings) {
	assert(u != nil, "play_fit: nil Fit UI")
	view_play(u, view, bindings)
}

play_fit_traced :: proc(u: ^fit.Ui, view: View, bindings: ^Bindings, trace: ^Play_Trace) {
	assert(u != nil, "play_fit_traced: nil Fit UI")
	view_play_traced(u, view, bindings, trace)
}

// view_play_traced is view_play with an optional per-node rect recording, for
// tools that need to hit-test the played frame (see trace.odin). One walk, one
// implementation: view_play delegates here, and a nil trace makes every tap a
// no-op, so playing and tracing cannot disagree about what a node means.
view_play_traced :: proc(u: ^ui.Ui, view: View, bindings: ^Bindings, trace: ^Play_Trace) {
	assert(u != nil, "view_play: nil Ui")
	assert(len(view.nodes) <= VIEW_NODES_MAX, "view_play: too many nodes")
	if bindings != nil && bindings.events != nil do sink_reset(bindings.events)
	depth_at_entry := u.ids.depth
	// The document cannot know what container the caller opened around this
	// call, so depth-0 nodes take their axis from the live layout.
	root_horizontal := ui.layout_kind(&u.layout) == .Row
	tap: Trace_Tap
	tap_begin(&tap, trace, view)

	walk := walk_begin(view)
	for _ in 0 ..< WALK_STEPS_MAX {
		step, more := walk_next(&walk)
		if !more do break
		node := view.nodes[step.node]
		horizontal := parent_axis_horizontal(view, step.node, root_horizontal)
		if step.event == .Exit {
			close_container(u, node.kind)
			ui.scope_end(u)
			tap_container_exit(&tap, step.node, node.kind, ui.remaining_rect(u), horizontal)
			continue
		}
		if view_kind_is_container(node.kind) {
			tap_container_enter(&tap, ui.remaining_rect(u))
			scope_begin_node(u, view, node, step.node)
			open_container(u, view, node, step.node)
			continue
		}
		before := ui.remaining_rect(u)
		emit_leaf(u, view, node, step.node, bindings)
		tap_leaf(&tap, step.node, before, ui.remaining_rect(u), horizontal)
	}

	assert(walk_balanced(&walk), "view_play: walk did not balance")
	assert(u.ids.depth == depth_at_entry, "view_play: unbalanced id scope")
	assert(tap.depth == 0, "view_play: unbalanced trace stack")
}

// scope_begin_node gives every container a scope. An author key preserves
// identity across document reordering; the one-based node index is the bounded
// fallback for an unkeyed layout wrapper and cannot collide inside one view.
@(private = "package")
scope_begin_node :: proc(u: ^ui.Ui, view: View, node: View_Node, index: i32) {
	assert(u != nil, "scope_begin_node: nil Ui")
	assert(index >= 0 && int(index) < len(view.nodes), "scope_begin_node: index out of range")
	key := text_slice(view, node.key_offset, node.key_length)
	if key != "" {
		ui.scope_begin(u, key)
		return
	}
	ui.scope_begin(u, u64(index) + 1)
}

@(private = "file")
open_container :: proc(u: ^ui.Ui, view: View, node: View_Node, index: i32) {
	assert(u != nil, "open_container: nil Ui")
	#partial switch node.kind {
	case .Row:
		ui.row_begin(u, node.size_main, node.gap, node.align)
	case .Column:
		ui.column_begin(u, node.size_main, node.gap, node.align)
	case .Panel:
		ui.panel_begin(
			u,
			ui.Layout_Style{gap = node.gap, padding = node.padding, align = node.align},
		)
	case .Flex_Row:
		tracks := child_tracks(view, index)
		if len(tracks) == 0 {
			ui.row_begin(u, node.size_main, node.gap, node.align)
		} else {
			ui.flex_row_begin(u, node.size_main, tracks, node.gap, node.align, node.justify)
		}
	case .Flex_Column:
		tracks := child_tracks(view, index)
		if len(tracks) == 0 {
			ui.column_begin(u, node.size_main, node.gap, node.align)
		} else {
			ui.flex_column_begin(u, node.size_main, tracks, node.gap, node.align, node.justify)
		}
	}
}

// close_container needs no knowledge of whether a flex container degraded to a
// plain one, because ui.flex_row_end is row_end and ui.flex_column_end is
// column_end - the flex forms differ only on the way in. If that ever stops
// being true, the assertion inside row_end about the active container kind is
// what will say so.
@(private = "file")
close_container :: proc(u: ^ui.Ui, kind: View_Kind) {
	assert(u != nil, "close_container: nil Ui")
	#partial switch kind {
	case .Row:
		ui.row_end(u)
	case .Column:
		ui.column_end(u)
	case .Panel:
		ui.panel_end(u)
	case .Flex_Row:
		ui.flex_row_end(u)
	case .Flex_Column:
		ui.flex_column_end(u)
	}
}

// child_tracks gathers a flex container's slot-carving children into the slice
// ui.flex_* wants. A flex run must know every sibling's size before the first
// is drawn, so this cannot be done incrementally as the walk reaches each child.
//
// Only carving children get a track, because ui asserts that every declared
// track is consumed and a Separator or Spacer never consumes one.
//
// An empty result is meaningful: a flex container with no carving children must
// not open a flex run at all. That is what the builder holds the instant after
// the user drops a container on the canvas, so it has to render rather than
// abort.
//
// The scratch array is file-scoped rather than per-call because tracks are
// consumed by flex_*_begin immediately; nesting is handled by ui's own track
// stack, not by keeping several of these alive.
@(private = "file")
flex_scratch: [VIEW_FLEX_TRACKS_MAX]ui.Track

@(private = "file")
child_tracks :: proc(view: View, parent: i32) -> []ui.Track {
	assert(parent >= 0 && int(parent) < len(view.nodes), "child_tracks: parent out of range")
	count := 0
	child := view.nodes[parent].first_child
	for child != VIEW_NODE_NONE && count < VIEW_FLEX_TRACKS_MAX {
		if view_kind_carves_slot(view.nodes[child].kind) {
			flex_scratch[count] = view.nodes[child].track
			count += 1
		}
		child = view.nodes[child].next_sibling
	}
	return flex_scratch[:count]
}
