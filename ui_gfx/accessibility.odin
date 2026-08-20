package ui_gfx

import "base:runtime"
import "core:c"
import ak "ingot:accesskit"
import rl "ingot:gfx"
import "ingot:ui"

when ak.ENABLED {

	adapter_a11y_role :: proc(node: ^ui.Sem_Node) -> ak.Role {
		assert(node != nil, "adapter_a11y_role: nil node")
		#partial switch node.role {
		case .Button:
			return .Button
		case .Tab:
			return .Tab
		case .List_Item:
			return .List_Item
		case .Option:
			return .List_Box_Option
		case .List_Box:
			return .List_Box
		case .Checkbox:
			return .Check_Box
		case .Radio:
			return .Radio_Button
		case .Slider:
			return .Slider
		case .Progress:
			return .Progress
		case .Text_Input:
			if .Password in node.state do return .Password_Input
			if .Multiline in node.state do return .Multiline_Input
			return .Text_Input
		case .Dropdown:
			return .Combo_Box
		case .Menu_Item:
			return .Menu_Item
		case .Label:
			return .Label
		case .Status:
			return .Status
		case .Pane:
			return .Pane
		case .Tab_Panel:
			return .Tab_Panel
		case .List:
			return .List
		case .Modal:
			return .Dialog
		case .None:
			return .Unknown
		}
		return .Unknown
	}

	adapter_a11y_actions :: proc(source: ^ui.Sem_Node) -> (click, focus, adjust: bool) {
		assert(source != nil, "adapter_a11y_actions: nil source")
		if .Disabled in source.state do return false, false, false
		#partial switch source.role {
		case .Button, .Tab, .Checkbox, .Radio, .Option, .Dropdown, .Menu_Item:
			return true, true, false
		case .Slider:
			return false, true, .Read_Only not_in source.state
		case .Text_Input:
			return false, true, false
		case:
			return false, false, false
		}
	}

	adapter_a11y_node :: proc(source: ^ui.Sem_Node) -> ak.Node {
		assert(source != nil, "adapter_a11y_node: nil source")
		assert(source.id > ui.SEM_ID_ROOT, "adapter_a11y_node: invalid id")
		node := ak.node_new(adapter_a11y_role(source))
		assert(node != nil, "adapter_a11y_node: allocation failed")
		if source.label_len > 0 {
			ak.node_set_label_with_length(
				node,
				raw_data(source.label[:]),
				c.size_t(source.label_len),
			)
		}
		if source.description_len > 0 {
			ak.node_set_description_with_length(
				node,
				raw_data(source.description[:]),
				c.size_t(source.description_len),
			)
		}
		if source.text_value_len > 0 {
			ak.node_set_value_with_length(
				node,
				raw_data(source.text_value[:]),
				c.size_t(source.text_value_len),
			)
		}
		rect := source.rect
		ak.node_set_bounds(
			node,
			{f64(rect.x), f64(rect.y), f64(rect.x + rect.w), f64(rect.y + rect.h)},
		)
		if .Disabled in source.state do ak.node_set_disabled(node)
		if .Read_Only in source.state do ak.node_set_read_only(node)
		if source.role == .Text_Input && source.selection_start >= 0 && source.selection_end >= 0 {
			ak.node_set_text_selection(
				node,
				{
					anchor = {ak.Node_Id(source.id), c.size_t(source.selection_start)},
					focus = {ak.Node_Id(source.id), c.size_t(source.selection_end)},
				},
			)
		}
		if source.role == .Option || source.role == .Tab {
			ak.node_set_selected(node, .Selected in source.state)
		}
		if source.position_in_set > 0 {
			ak.node_set_position_in_set(node, c.size_t(source.position_in_set))
			ak.node_set_size_of_set(node, c.size_t(source.size_of_set))
		}
		if source.role == .Checkbox || source.role == .Radio {
			toggled := ak.Toggled.True if .Checked in source.state else ak.Toggled.False
			ak.node_set_toggled(node, toggled)
		}
		if source.role == .Dropdown do ak.node_set_expanded(node, .Expanded in source.state)
		if source.role == .Slider || source.role == .Progress {
			ak.node_set_numeric_value(node, f64(source.value))
			ak.node_set_min_numeric_value(node, f64(source.lo))
			ak.node_set_max_numeric_value(node, f64(source.hi))
		}
		click, focus, adjust := adapter_a11y_actions(source)
		if click do ak.node_add_action(node, .Click)
		if focus do ak.node_add_action(node, .Focus)
		if adjust {
			ak.node_add_action(node, .Increment)
			ak.node_add_action(node, .Decrement)
		}
		return node
	}

	adapter_a11y_parent :: proc(frame: ^ui.Sem_Frame, index: int) -> u64 {
		assert(
			frame != nil && index >= 0 && index < frame.count,
			"adapter_a11y_parent: invalid node",
		)
		parent := frame.nodes[index].parent_id
		if parent <= ui.SEM_ID_ROOT do return ui.SEM_ID_ROOT
		current := parent
		for _ in 0 ..< ui.MAX_SEM_NODES {
			found := -1
			for candidate in 0 ..< frame.count {
				if frame.nodes[candidate].id == current {
					found = candidate
					break
				}
			}
			if found < 0 || found == index do return ui.SEM_ID_ROOT
			current = frame.nodes[found].parent_id
			if current <= ui.SEM_ID_ROOT do return parent
		}
		return ui.SEM_ID_ROOT
	}

	adapter_a11y_factory :: proc "c" (userdata: rawptr) -> ak.Tree_Update {
		context = runtime.default_context()
		adapter := (^Adapter)(userdata)
		assert(adapter != nil && adapter.initialized, "adapter_a11y_factory: invalid adapter")
		frame := &adapter.a11y_snapshot
		update := ak.tree_update_with_capacity_and_focus(
			c.size_t(frame.count + 1),
			adapter.a11y_focus,
		)
		root := ak.node_new(.Window)
		for index in 0 ..< frame.count {
			if adapter_a11y_parent(frame, index) == ui.SEM_ID_ROOT {
				ak.node_push_child(root, ak.Node_Id(frame.nodes[index].id))
			}
		}
		ak.tree_update_push_node(update, ak.Node_Id(ui.SEM_ID_ROOT), root)
		for index in 0 ..< frame.count {
			source := &frame.nodes[index]
			node := adapter_a11y_node(source)
			for child_index in 0 ..< frame.count {
				if adapter_a11y_parent(frame, child_index) == source.id {
					ak.node_push_child(node, ak.Node_Id(frame.nodes[child_index].id))
				}
			}
			ak.tree_update_push_node(update, ak.Node_Id(source.id), node)
		}
		tree := ak.tree_new(ak.Node_Id(ui.SEM_ID_ROOT))
		ak.tree_update_set_tree(update, tree)
		ak.tree_update_set_focus(update, adapter.a11y_focus)
		return update
	}

}

adapter_a11y_init :: proc(adapter: ^Adapter) -> bool {
	assert(adapter != nil && adapter.initialized, "adapter_a11y_init: invalid adapter")
	when rl.A11Y_ENABLED {
		return rl.context_init_accessibility(adapter.gfx_context, adapter_a11y_factory, adapter)
	}
	return false
}

adapter_a11y_poll :: proc(adapter: ^Adapter, frame: ^ui.Ui_Frame) {
	assert(adapter != nil && adapter.initialized, "adapter_a11y_poll: invalid adapter")
	assert(frame != nil && frame.open, "adapter_a11y_poll: invalid frame")
	when rl.A11Y_ENABLED {
		if !adapter.a11y_initialized do return
		for _ in 0 ..< rl.MAX_A11Y_ACTIONS {
			action, ok := rl.context_poll_accessibility_action(adapter.gfx_context)
			if !ok do return
			kind: ui.A11y_Action_Kind
			#partial switch action.action {
			case .Focus:
				kind = .Focus
			case .Click:
				kind = .Click
			case .Increment:
				kind = .Increment
			case .Decrement:
				kind = .Decrement
			case:
				continue
			}
			ui.a11y_apply_action(frame, {kind, u64(action.node)})
		}
	}
}

// a11y_snapshot_equal reports whether two semantic frames would produce the
// same accessibility tree. semantic_push zero-initializes every node before
// filling it, so whole-struct comparison is deterministic (no stale bytes
// beyond label_len). Used to skip re-publishing an unchanged tree every
// frame; a false negative only costs one redundant publish, never a missed
// update.
a11y_snapshot_equal :: proc(a, b: ^ui.Sem_Frame) -> bool {
	assert(a != nil && b != nil, "a11y_snapshot_equal: nil frame")
	assert(a.count >= 0 && a.count <= len(a.nodes), "a11y_snapshot_equal: corrupt count")
	if a.count != b.count do return false
	for index in 0 ..< a.count {
		if a.nodes[index] != b.nodes[index] do return false
	}
	return true
}

adapter_a11y_publish :: proc(adapter: ^Adapter, frame: ^ui.Ui_Frame) {
	assert(adapter != nil && adapter.initialized, "adapter_a11y_publish: invalid adapter")
	assert(frame != nil && frame.finalized, "adapter_a11y_publish: frame not finalized")
	// The JS loop stays unconditional: SyncWebControl both mirrors the tree
	// into the DOM and harvests activations, so skipping it would drop clicks.
	when ODIN_OS == .JS {
		for index in 0 ..< frame.semantics.cur.count {
			node := &frame.semantics.cur.nodes[index]
			result := rl.SyncWebControl(
				i32(node.role),
				node.id,
				ui.sem_node_label(node),
				node.rect.x,
				node.rect.y,
				node.rect.w,
				node.rect.h,
				transmute(u8)node.state,
				node.value,
				node.lo,
				node.hi,
				i32(node.position_in_set),
				i32(node.size_of_set),
			)
			if result.activated do ui.a11y_stage_click(frame.runtime, node.id)
		}
	}
	if !adapter.a11y_initialized do return
	// Publish only when the tree actually changed. An unconditional per-frame
	// snapshot copy and PushAccessibilityUpdate made every animation frame do
	// accessibility work (and provoked platform-side re-reads) even when the
	// semantics were byte-identical.
	if adapter.a11y_published &&
	   a11y_snapshot_equal(&adapter.a11y_snapshot, &frame.semantics.cur) {
		return
	}
	adapter.a11y_snapshot = frame.semantics.cur
	adapter.a11y_published = true
	adapter.a11y_focus = ak.Node_Id(ui.SEM_ID_ROOT)
	for index in 0 ..< adapter.a11y_snapshot.count {
		if .Focused in adapter.a11y_snapshot.nodes[index].state {
			adapter.a11y_focus = ak.Node_Id(adapter.a11y_snapshot.nodes[index].id)
			break
		}
	}
	when rl.A11Y_ENABLED do rl.context_push_accessibility_update(adapter.gfx_context)
}

adapter_a11y_destroy :: proc(adapter: ^Adapter) {
	assert(adapter != nil && adapter.initialized, "adapter_a11y_destroy: invalid adapter")
	when rl.A11Y_ENABLED {
		if adapter.a11y_initialized do rl.context_close_accessibility(adapter.gfx_context)
	}
	adapter.a11y_initialized = false
	adapter.a11y_published = false
	adapter.a11y_snapshot = {}
}
