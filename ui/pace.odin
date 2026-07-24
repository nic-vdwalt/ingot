package ui

Frame_Pacer :: struct {
	target_fps:    i32,
	idle_fps:      i32,
	grace:         f64,
	last_activity: f64,
	current:       i32,
}

pacer_init :: proc(target_fps: i32 = 60, idle_fps: i32 = 15, grace: f64 = 2.5) -> Frame_Pacer {
	assert(target_fps > 0 && idle_fps > 0, "pacer_init: invalid rate")
	return {target_fps = target_fps, idle_fps = idle_fps, grace = grace, current = target_fps}
}

pacer_note_activity :: proc(p: ^Frame_Pacer, now: f64) {
	assert(p != nil, "pacer_note_activity: nil pacer")
	p.last_activity = now
}

pacer_frame :: proc(p: ^Frame_Pacer, input: ^Ui_Input, busy: bool = false) -> i32 {
	assert(p != nil && input != nil, "pacer_frame: invalid argument")
	if busy || pacer_input_active(input) do p.last_activity = input.time
	active_fps := max(input.monitor_refresh, p.target_fps)
	next := active_fps if input.time - p.last_activity < p.grace else p.idle_fps
	p.current = next
	return next
}

pacer_input_active :: proc(input: ^Ui_Input) -> bool {
	assert(input != nil, "pacer_input_active: nil input")
	if input.mouse_delta != {} || input.mouse_wheel != {} do return true
	if input_mouse_down(input, .LEFT) || input_mouse_down(input, .RIGHT) do return true
	for index in 0 ..< INPUT_KEY_COUNT {
		if input.keys_pressed[index] do return true
	}
	return false
}
