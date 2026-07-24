package ui

A11y_Action_Kind :: enum u8 { Click, Focus }
A11y_Action :: struct { action: A11y_Action_Kind, node: u64 }
A11y_Pending_Action :: struct { node_id: u64, expires_generation: u64, pending: bool }

a11y_init :: proc(runtime: ^Ui_Runtime) -> bool {
	assert(runtime != nil && runtime.initialized, "a11y_init: invalid runtime")
	sem_enable(runtime, true)
	return true
}

a11y_frame_end :: proc(frame: ^Ui_Frame) {
	assert(frame != nil && frame.open, "a11y_frame_end: invalid frame")
}

a11y_stage_click :: proc(runtime: ^Ui_Runtime, node_id: u64) {
	assert(runtime != nil && runtime.initialized, "a11y_stage_click: invalid runtime")
	assert(node_id > SEM_ID_ROOT, "a11y_stage_click: invalid node id")
	runtime.pending_a11y = {node_id = node_id, expires_generation = runtime.frame_generation + 1, pending = true}
}

a11y_expire_before_frame :: proc(runtime: ^Ui_Runtime) {
	assert(runtime != nil && runtime.initialized, "a11y_expire_before_frame: invalid runtime")
	pending := &runtime.pending_a11y
	if pending.pending && runtime.frame_generation > pending.expires_generation do pending^ = {}
}

a11y_expire_after_frame :: proc(runtime: ^Ui_Runtime) {
	assert(runtime != nil && runtime.initialized, "a11y_expire_after_frame: invalid runtime")
	pending := &runtime.pending_a11y
	if pending.pending && runtime.frame_generation >= pending.expires_generation do pending^ = {}
}

a11y_take_click :: proc(runtime: ^Ui_Runtime, node_id: u64) -> bool {
	assert(runtime != nil && runtime.initialized, "a11y_take_click: invalid runtime")
	pending := &runtime.pending_a11y
	if !pending.pending || runtime.frame_generation != pending.expires_generation do return false
	if node_id != pending.node_id do return false
	pending^ = {}
	return true
}

a11y_apply_action :: proc(frame: ^Ui_Frame, action: A11y_Action) {
	assert(frame != nil && frame.open, "a11y_apply_action: invalid frame")
	#partial switch action.action {
	case .Click:
		if sem_has_interactive_node(frame, action.node) do a11y_stage_click(frame.runtime, action.node)
	case .Focus:
		focus, ok := sem_action_target(frame, action.node)
		if ok { focus_opt_set(focus); request_redraw(frame) }
	}
}
