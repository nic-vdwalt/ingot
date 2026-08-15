package fuzz_interact

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import fuzzx "ingot:fuzz/fuzzx"
import rl "ingot:gfx"
import "ingot:ui"

INTERACT_TAPE_TARGET :: "interact"
INTERACT_OP_FRAME :: u16(1)
INTERACT_FRAME_BYTES :: 48
INTERACT_ACTIONS_MAX :: 5
INTERACT_FAILURE_OPERATION :: u32(100)
INTERACT_FAILURE_ROUTE :: u32(101)
INTERACT_FAILURE_STATE :: u32(102)
INTERACT_FAILURE_SEMANTICS :: u32(103)

Action_Kind :: enum u8 {
	None,
	Mouse,
	Left,
	Right,
	Key,
	Wheel,
}

Frame_Action :: struct {
	kind: Action_Kind,
	a:    i32,
	b:    i32,
}

Frame_Op :: struct {
	actions: [INTERACT_ACTIONS_MAX]Frame_Action,
	count:   int,
	control: Frame_Control,
}

interact_tape_generate :: proc(seed: u64, iterations: int, allocator := context.allocator) -> fuzzx.Tape {
	assert(iterations > 0 && iterations <= fuzzx.TAPE_OPS_MAX, "interact_tape_generate: invalid iterations")
	p := fuzzx.prng_make(seed)
	tape := fuzzx.Tape{version = fuzzx.TAPE_VERSION, target = strings.clone(INTERACT_TAPE_TARGET, allocator), seed = seed}
	tape.ops = make([dynamic]fuzzx.Tape_Op, 0, iterations, allocator)
	state := Scene{slider_val = 40}
	for iteration in 0 ..< iterations {
		frame := frame_generate(&p, iteration, &state)
		payload := frame_encode(frame, allocator)
		append(&tape.ops, fuzzx.Tape_Op{tag = INTERACT_OP_FRAME, payload = payload})
	}
	return tape
}

frame_generate :: proc(p: ^Prng, iteration: int, state: ^Scene) -> Frame_Op {
	assert(p != nil && state != nil, "frame_generate: nil argument")
	frame: Frame_Op
	if iteration < DETERMINISTIC_FRAMES {
		frame_scenario(&frame, iteration, state)
		return frame
	}
	frame.count = fuzzx.int_range(p, 0, INTERACT_ACTIONS_MAX + 1)
	for index in 0 ..< frame.count {
		action := &frame.actions[index]
		switch fuzzx.int_range(p, 0, 10) {
		case 0, 1, 2:
			action.kind = .Mouse
			if fuzzx.int_range(p, 0, 3) != 0 {
				rect := RECTS[fuzzx.int_range(p, 0, len(RECTS))]
				action.a = i32(fuzzx.int_range(p, int(rect.x) - 4, int(rect.x + rect.w) + 4))
				action.b = i32(fuzzx.int_range(p, int(rect.y) - 4, int(rect.y + rect.h) + 4))
			} else {
				action.a = i32(fuzzx.int_range(p, 0, SCREEN_W))
				action.b = i32(fuzzx.int_range(p, 0, SCREEN_H))
			}
		case 3, 4:
			action.kind = .Left
			action.a = i32(fuzzx.int_range(p, 0, 2))
		case 5:
			action.kind = .Key
			action.a = i32(rl.KeyboardKey.TAB)
			action.b = i32(fuzzx.int_range(p, 0, 2))
		case 6:
			action.kind = .Key
			keys := [?]rl.KeyboardKey{.SPACE, .ENTER, .ESCAPE}
			action.a = i32(keys[fuzzx.int_range(p, 0, len(keys))])
		case 7:
			action.kind = .Key
			keys := [?]rl.KeyboardKey{.LEFT, .RIGHT, .UP, .DOWN}
			action.a = i32(keys[fuzzx.int_range(p, 0, len(keys))])
		case 8:
			action.kind = .Wheel
			action.a = i32(fuzzx.int_range(p, -300, 301))
		case 9:
			action.kind = .Right
			action.a = i32(fuzzx.int_range(p, 0, 2))
		}
	}
	frame.control = frame_control_random(p, state, true)
	return frame
}

frame_scenario :: proc(frame: ^Frame_Op, iteration: int, state: ^Scene) {
	assert(frame != nil && state != nil, "frame_scenario: nil argument")
	add := proc(frame: ^Frame_Op, kind: Action_Kind, a: i32, b: i32 = 0) {
		assert(frame.count < INTERACT_ACTIONS_MAX, "frame_scenario: actions full")
		frame.actions[frame.count] = {kind = kind, a = a, b = b}
		frame.count += 1
	}
	switch iteration {
	case 0: add(frame, .Mouse, 40, 35); add(frame, .Left, 1)
	case 1: add(frame, .Mouse, 400, 400)
	case 2: add(frame, .Left, 0)
	case 3: add(frame, .Mouse, 30, 190); add(frame, .Left, 1)
	case 4: add(frame, .Mouse, 215, 190)
	case 5: add(frame, .Mouse, 40, 35)
	case 6: add(frame, .Left, 0)
	case 7: state.focus = FOCUS_COUNT; add(frame, .Key, i32(rl.KeyboardKey.TAB))
	case 8: add(frame, .Key, i32(rl.KeyboardKey.TAB), 1)
	case 9: frame.control = {open_menu = true, menu_x = 300, menu_y = 100}
	case 10, 11, 12: add(frame, .Key, i32(rl.KeyboardKey.DOWN))
	case 13: add(frame, .Key, i32(rl.KeyboardKey.ENTER))
	case 14: add(frame, .Mouse, 40, 230); add(frame, .Left, 1)
	case 15: add(frame, .Left, 0)
	case 16, 17, 18: add(frame, .Key, i32(rl.KeyboardKey.DOWN))
	case 19: add(frame, .Key, i32(rl.KeyboardKey.ENTER))
	case 20: add(frame, .Mouse, 40, 230); add(frame, .Left, 1)
	case 21: add(frame, .Left, 0)
	case 22: add(frame, .Key, i32(rl.KeyboardKey.ENTER))
	case 23: frame.control.open_modal = true; add(frame, .Key, i32(rl.KeyboardKey.ESCAPE))
	}
}

frame_apply :: proc(frame: Frame_Op) {
	for index in 0 ..< frame.count {
		action := frame.actions[index]
		#partial switch action.kind {
		case .Mouse: rl.SimMouse(f32(action.a), f32(action.b))
		case .Left: rl.SimButton(.LEFT, action.a != 0)
		case .Right: rl.SimButton(.RIGHT, action.a != 0)
		case .Key:
			key := rl.KeyboardKey(action.a)
			if key == .TAB do rl.SimKey(.LEFT_SHIFT, action.b != 0)
			rl.SimKey(key, true)
			rl.SimKey(key, false)
			if key == .TAB do rl.SimKey(.LEFT_SHIFT, false)
		case .Wheel: rl.SimWheel(0, f32(action.a) / 100)
		case: return
		}
	}
}

interact_tape_execute :: proc(tape: ^fuzzx.Tape, userdata: rawptr = nil) -> fuzzx.Failure {
	if tape == nil || tape.target != INTERACT_TAPE_TARGET do return fuzzx.failure_make(INTERACT_FAILURE_OPERATION, -1, "invalid interact tape")
	state := Scene{slider_val = 40}
	runtime: ui.Ui_Runtime
	ui.ui_runtime_init(&runtime)
	defer ui.ui_runtime_destroy(&runtime)
	ui.ui_runtime_set_text_backend(&runtime, {font_for_size = fuzz_text_font, measure = fuzz_text_measure})
	ui.sem_enable(&runtime, true)
	frame: ui.Ui_Frame
	defer ui.ui_frame_destroy(&frame)
	input: ui.Ui_Input
	output := new(ui.Ui_Output)
	defer free(output)
	frame.output = output
	rl.SimReset()
	overlay_free_frames := 0
	for op_index in 0 ..< len(tape.ops) {
		op := tape.ops[op_index]
		if op.tag != INTERACT_OP_FRAME do return fuzzx.failure_make(INTERACT_FAILURE_OPERATION, op_index, "unknown frame operation")
		frame_op, ok := frame_decode(op.payload)
		if !ok do return fuzzx.failure_make(INTERACT_FAILURE_OPERATION, op_index, "malformed frame operation")
		rl.SimBeginFrame()
		frame_apply(frame_op)
		capture_sim_input(&input)
		ui.ui_frame_begin(&frame, &runtime, &input)
		overlay_active := draw_scene(&frame, &state, frame_op.control)
		overlay_free_frames = 0 if overlay_active else overlay_free_frames + 1
		failure := interact_invariants(&frame, &state, overlay_free_frames, op_index)
		ui.ui_frame_end(&frame)
		free_all(context.temp_allocator)
		if failure.failed do return failure
	}
	return {}
}

interact_invariants :: proc(frame: ^ui.Ui_Frame, state: ^Scene, overlay_free_frames, op_index: int) -> fuzzx.Failure {
	if ui.route_claim_count(frame) < 0 || ui.route_claim_count(frame) > ui.MAX_ROUTE_CLAIMS do return fuzzx.failure_make(INTERACT_FAILURE_ROUTE, op_index, "route claims out of range")
	if overlay_free_frames >= 3 && ui.route_claim_count(frame) != 0 do return fuzzx.failure_make(INTERACT_FAILURE_ROUTE, op_index, "route claims leaked")
	if state.focus < 0 || state.focus > FOCUS_COUNT do return fuzzx.failure_make(INTERACT_FAILURE_STATE, op_index, "focus out of range")
	if state.slider_val < 0 || state.slider_val > 100 do return fuzzx.failure_make(INTERACT_FAILURE_STATE, op_index, "slider out of range")
	if state.radio_sel != 0 && state.radio_sel != 1 do return fuzzx.failure_make(INTERACT_FAILURE_STATE, op_index, "radio out of range")
	semantics := ui.sem_frame(frame)
	if semantics.count < 0 || semantics.count > ui.MAX_SEM_NODES do return fuzzx.failure_make(INTERACT_FAILURE_SEMANTICS, op_index, "semantic count out of range")
	for index in 0 ..< semantics.count {
		if semantics.nodes[index].id <= 1 do return fuzzx.failure_make(INTERACT_FAILURE_SEMANTICS, op_index, "reserved semantic id")
	}
	return {}
}

frame_encode :: proc(frame: Frame_Op, allocator: mem.Allocator) -> []u8 {
	payload := make([]u8, INTERACT_FRAME_BYTES, allocator)
	payload[0] = u8(frame.count)
	payload[1] = u8(frame.control.hide_slider)
	payload[2] = frame.control.open_modal ? 1 : 0
	payload[3] = frame.control.open_menu ? 1 : 0
	put_i32(payload, 4, frame.control.menu_x)
	put_i32(payload, 8, frame.control.menu_y)
	for index in 0 ..< frame.count {
		offset := 12 + index * 7
		payload[offset] = u8(frame.actions[index].kind)
		put_i32(payload, offset + 1, frame.actions[index].a)
		payload[offset + 5] = u8(frame.actions[index].b)
		payload[offset + 6] = u8(frame.actions[index].b >> 8)
	}
	return payload
}

frame_decode :: proc(payload: []u8) -> (Frame_Op, bool) {
	if len(payload) != INTERACT_FRAME_BYTES || int(payload[0]) > INTERACT_ACTIONS_MAX do return {}, false
	frame := Frame_Op{count = int(payload[0])}
	frame.control = {hide_slider = i32(payload[1]), open_modal = payload[2] != 0, open_menu = payload[3] != 0, menu_x = get_i32(payload, 4), menu_y = get_i32(payload, 8)}
	for index in 0 ..< frame.count {
		offset := 12 + index * 7
		kind := Action_Kind(payload[offset])
		if kind <= .None || kind > .Wheel do return {}, false
		frame.actions[index] = {kind = kind, a = get_i32(payload, offset + 1), b = i32(payload[offset + 5]) | i32(payload[offset + 6]) << 8}
	}
	return frame, true
}

interact_tape_cli :: proc() -> bool {
	replay, record, shrink, output := "", "", "", ""
	seed: u64 = 1
	iterations := 100
	for arg in os.args[1:] {
		if strings.has_prefix(arg, "-replay:") do replay = arg[len("-replay:"):]
		if strings.has_prefix(arg, "-record:") do record = arg[len("-record:"):]
		if strings.has_prefix(arg, "-shrink:") do shrink = arg[len("-shrink:"):]
		if strings.has_prefix(arg, "-shrink-output:") do output = arg[len("-shrink-output:"):]
		if strings.has_prefix(arg, "-seed:") {if value, ok := strconv.parse_u64(arg[len("-seed:"):]); ok do seed = value}
		if strings.has_prefix(arg, "-iterations:") {if value, ok := strconv.parse_int(arg[len("-iterations:"):]); ok do iterations = value}
	}
	modes := int(replay != "") + int(record != "") + int(shrink != "")
	if modes == 0 do return false
	if modes != 1 do os.exit(2)
	if record != "" {
		tape := interact_tape_generate(seed, iterations)
		defer fuzzx.tape_destroy(&tape)
		if !fuzzx.tape_save(record, &tape) do os.exit(1)
		if failure := interact_tape_execute(&tape); failure.failed do interact_fail(failure)
		fmt.println(fuzzx.tape_summary(&tape))
		return true
	}
	path := replay if replay != "" else shrink
	tape, err := fuzzx.tape_load(path, INTERACT_TAPE_TARGET)
	if err != .None do os.exit(1)
	defer fuzzx.tape_destroy(&tape)
	if replay != "" {
		if failure := interact_tape_execute(&tape); failure.failed do interact_fail(failure)
		fmt.println(fuzzx.tape_summary(&tape))
		return true
	}
	if output == "" do os.exit(2)
	result := fuzzx.tape_shrink(&tape, interact_tape_execute, nil, {maximum_runs = 1024, allow_empty = true})
	defer fuzzx.tape_destroy(&result.tape)
	if !result.reproduced || !fuzzx.tape_save(output, &result.tape) do os.exit(1)
	return true
}

@(private)
interact_fail :: proc(failure: fuzzx.Failure) {
	fmt.eprintfln("fuzz_interact replay FAILED: class=%d operation=%d %s", failure.class, failure.op_index, failure.message)
	os.exit(1)
}

@(private)
put_i32 :: proc(payload: []u8, offset: int, value: i32) {
	for index in 0 ..< 4 do payload[offset + index] = u8(u32(value) >> u32(index * 8))
}

@(private)
get_i32 :: proc(payload: []u8, offset: int) -> i32 {
	value: u32
	for index in 0 ..< 4 do value |= u32(payload[offset + index]) << u32(index * 8)
	return i32(value)
}
