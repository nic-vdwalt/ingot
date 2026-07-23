// ui — bridge from the per-frame semantic buffer (semantics.odin) to
// AccessKit tree updates and back from AT-initiated actions.
//
// Wiring (native app frame loop):
//
//	rl.InitWindow(...)
//	ui.a11y_init()                  // once, after the window exists
//	for !rl.WindowShouldClose() {
//	    rl.BeginDrawing()
//	    ui.begin_cursor_frame()
//	    ... draw widgets ...
//	    ui.apply_cursor()
//	    ui.a11y_frame_end()         // push tree + apply AT actions
//	    rl.EndDrawing()
//	}
//
// The tree-update factory runs only while assistive tech consumes the tree
// (AccessKit's update_if_active), so idle cost without AT is one branch per
// frame. The full tree is pushed every frame — AccessKit diffs on its side,
// which is exactly the immediate-mode contract: semantics are an output
// buffer like the draw list, never retained state.
package ui

import "base:runtime"
import ak "ingot:accesskit"
import rl "ingot:gfx"

// a11y_role maps a semantic role onto AccessKit's role enum. Pure.
a11y_role :: proc(role: Sem_Role) -> ak.Role {
	switch role {
	case .Button:
		return .Button
	case .Checkbox:
		return .Check_Box
	case .Radio:
		return .Radio_Button
	case .Slider:
		return .Slider
	case .Text_Input:
		return .Text_Input
	case .Dropdown:
		return .Combo_Box
	case .Menu_Item:
		return .Menu_Item
	case .Label:
		return .Label
	case .Pane:
		return .Pane
	case .Modal:
		return .Dialog
	case .None:
	}
	return .Unknown
}

// Pending AT click, keyed by the focus-link node id; consumed by
// focus_activated as a synthetic activation on the next frame.
@(private = "file") g_a11y_pending_click: u64

// a11y_init enables semantic recording and attaches the platform adapter.
// Call once after InitWindow. On native this registers the AccessKit
// factory; on web the DOM control mirror (driven from a11y_frame_end) is the
// consumer, so this returns true with no adapter. Returns false only when
// accessibility is compiled out (-define:INGOT_ACCESSKIT=false on native).
a11y_init :: proc() -> bool {
	sem_enable(true)
	when rl.A11Y_ENABLED {
		return rl.InitAccessibility(_a11y_factory, nil)
	} else when ODIN_OS == .JS {
		return true
	} else {
		return false
	}
}

// a11y_frame_end pushes this frame's semantic buffer to the platform
// consumer — the web DOM mirror and/or the AccessKit adapter — and applies
// any staged AT actions. Call once at end of frame, after all UI is drawn.
a11y_frame_end :: proc() {
	_a11y_sync_web_controls()
	rl.PushAccessibilityUpdate()
	for {
		action, ok := rl.PollAccessibilityAction()
		if !ok do break
		_a11y_apply(action)
	}
}

// _a11y_sync_web_controls mirrors interactive nodes into real DOM controls
// (no-op on native). Text inputs are skipped — they already have the richer
// autofill-capable mirror (ti_sync_web). AT activations come back as
// synthetic clicks through the same pending path as AccessKit actions.
@(private = "file")
_a11y_sync_web_controls :: proc() {
	if !sem_enabled() do return
	frame := sem_frame()
	for i in 0 ..< frame.count {
		sem := &frame.nodes[i]
		#partial switch sem.role {
		case .Button, .Checkbox, .Radio, .Slider, .Dropdown, .Menu_Item:
		case:
			continue
		}
		res := rl.SyncWebControl(
			i32(sem.role), sem.id, sem_node_label(sem),
			sem.rect.x, sem.rect.y, sem.rect.w, sem.rect.h,
			transmute(u8)sem.state, sem.value, sem.lo, sem.hi,
		)
		if res.activated {
			g_a11y_pending_click = sem.id
			rl.RequestRedraw()
		}
	}
}

// a11y_take_click consumes a pending AT click aimed at this focus link.
// focus_activated calls it so AT activation flows through the same path as
// Space/Enter.
a11y_take_click :: proc(focus: ^int, id: int) -> bool {
	if g_a11y_pending_click == 0 do return false
	if focus == nil || id <= 0 do return false
	if sem_node_id(.Button, {focus, id}, "", 0) != g_a11y_pending_click do return false
	g_a11y_pending_click = 0
	return true
}

// _a11y_apply routes one AT action. Focus writes the caller's focus slot
// directly (the pointer recorded in the semantic node is long-lived caller
// state); Click is staged for the widget's next focus_activated check.
@(private = "file")
_a11y_apply :: proc(action: rl.A11y_Action) {
	frame := sem_frame()
	#partial switch action.action {
	case .Click:
		g_a11y_pending_click = u64(action.node)
		rl.RequestRedraw()
	case .Focus:
		for i in 0 ..< frame.count {
			node := &frame.nodes[i]
			if node.id != u64(action.node) do continue
			if node.focus != nil && node.focus_id > 0 {
				node.focus^ = node.focus_id
				rl.RequestRedraw()
			}
			return
		}
	}
}

// _a11y_factory builds the full tree update AccessKit requested: one window
// root plus this frame's flat node list. Runs on the main thread (AccessKit
// calls the factory synchronously from update_if_active / activation).
@(private = "file")
_a11y_factory :: proc "c" (userdata: rawptr) -> ak.Tree_Update {
	context = runtime.default_context()
	when rl.A11Y_ENABLED {
		frame := sem_frame()
		assert(frame.count >= 0 && frame.count <= MAX_SEM_NODES, "_a11y_factory: corrupt frame")

		focus_id := SEM_ID_ROOT
		for i in 0 ..< frame.count {
			if .Focused in frame.nodes[i].state {
				focus_id = frame.nodes[i].id
				break
			}
		}

		update := ak.tree_update_with_capacity_and_focus(uint(frame.count + 1), focus_id)
		root := ak.node_new(.Window)
		for i in 0 ..< frame.count {
			sem := &frame.nodes[i]
			ak.node_push_child(root, sem.id)
			node := ak.node_new(a11y_role(sem.role))
			label := sem_node_label(sem)
			if len(label) > 0 {
				ak.node_set_label_with_length(node, raw_data(label), len(label))
			}
			ak.node_set_bounds(node, ak.Rect{
				f64(sem.rect.x), f64(sem.rect.y),
				f64(sem.rect.x + sem.rect.w), f64(sem.rect.y + sem.rect.h),
			})
			if sem.role == .Checkbox || sem.role == .Radio {
				ak.node_set_toggled(node, .True if .Checked in sem.state else .False)
			}
			if .Disabled in sem.state do ak.node_set_disabled(node)
			if sem.role == .Dropdown {
				ak.node_set_expanded(node, .Expanded in sem.state)
			}
			if sem.role == .Slider {
				ak.node_set_numeric_value(node, f64(sem.value))
				ak.node_set_min_numeric_value(node, f64(sem.lo))
				ak.node_set_max_numeric_value(node, f64(sem.hi))
			}
			if sem.role != .Label && sem.role != .Pane && sem.role != .Modal {
				ak.node_add_action(node, .Click)
				ak.node_add_action(node, .Focus)
			}
			ak.tree_update_push_node(update, sem.id, node)
		}
		ak.tree_update_push_node(update, SEM_ID_ROOT, root)
		ak.tree_update_set_tree(update, ak.tree_new(SEM_ID_ROOT))
		return update
	} else {
		return nil
	}
}
