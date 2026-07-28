package fuzz_interact

// Widget interaction-sequence fuzzer for ingot:ui - HEADLESS (no window, no
// GPU; part of `fuzz/run.sh all`). Built with -define:INGOT_INPUT_SIM=true
// so gfx's synthetic input seam (gfx/input_sim.odin) replaces the platform
// input layer.
//
// Motivation: widget *state machines* - the one-frame route-claim double
// buffer, form focus, drag latches, modal/menu lifecycles - were only
// covered by fixed unit tests. This harness drives a fixed scene of real
// widgets with random event sequences (mouse moves biased to widget rects,
// press/release, Tab/arrows/Space/Enter/Escape, wheel) and checks the state
// invariants that must hold under ANY ordering:
//
//   - route claims bounded; no residual claims after overlays close
//   - focus slot in range; at most one widget focused
//   - slider clamped; radio valid; dropdown selection in range
//   - modal begin/end balanced; menu selection never on separator/disabled
//   - semantic buffer bounded with unique interactive node ids
//
// Drawing is a no-op headless (no frame recording), so widget calls exercise
// exactly the input/state paths. Seed printed FIRST:
//   fuzz_interact -seed:12345 -iterations:100000

import "core:fmt"
import "core:mem"
import fuzzx "ingot:fuzz/fuzzx"
import rl "ingot:gfx"
import "ingot:ui"

ITERATIONS_DEFAULT :: 100_000
SCREEN_W :: 800
SCREEN_H :: 600
FOCUS_COUNT :: 5 // btn, checkbox, radio a, radio b, slider

Prng :: fuzzx.Prng

Scene :: struct {
	focus:              int,
	checked:            bool,
	radio_sel:          i32,
	slider_val:         f32,
	slider_state:       ui.Slider_State,
	dd_sel:             i32,
	dd_state:           ui.Dropdown_State,
	modal:              ui.Modal_State,
	menu:               ui.Context_Menu_State,
	// Frames remaining during which the slider (a drag-latch owner) is not
	// drawn, mimicking a tab switch or collapsed panel mid-drag.
	hide_slider_frames: int,
	// Consecutive frames the slider has not been drawn, for the invariant
	// that an undrawn owner must not hold the arbitration slot forever.
	slider_gone_frames: int,
	button_activations: u64,
	checkbox_changes:   u64,
	radio_changes:      u64,
	slider_changes:     u64,
	dropdown_changes:   u64,
	menu_choices:       u64,
}

DD_ITEMS := [?]string{"metal", "vulkan", "d3d12", "webgpu"}
MENU_ITEMS := [?]ui.Menu_Item {
	{label = "Copy"},
	{label = "Paste"},
	{separator = true},
	{label = "Disabled", disabled = true},
	{label = "Delete"},
}

// Widget rects (fixed layout; mouse events bias toward these).
R_BTN :: ui.Rect_I32{20, 20, 120, 32}
R_CHECK :: ui.Rect_I32{20, 70, 160, 24}
R_RADIO_A :: ui.Rect_I32{20, 110, 160, 24}
R_RADIO_B :: ui.Rect_I32{20, 140, 160, 24}
R_SLIDER :: ui.Rect_I32{20, 180, 200, 24}
R_DROP :: ui.Rect_I32{20, 220, 180, 28}

RECTS := [?]ui.Rect_I32{R_BTN, R_CHECK, R_RADIO_A, R_RADIO_B, R_SLIDER, R_DROP}
DETERMINISTIC_FRAMES :: 24

inject_scenario :: proc(iteration: int, s: ^Scene) -> bool {
	if iteration >= DETERMINISTIC_FRAMES do return false
	switch iteration {
	case 0:
		rl.SimMouse(40, 35)
		rl.SimButton(.LEFT, true)
	case 1:
		rl.SimMouse(400, 400)
	case 2:
		rl.SimButton(.LEFT, false)
	case 3:
		rl.SimMouse(30, 190)
		rl.SimButton(.LEFT, true)
	case 4:
		rl.SimMouse(215, 190)
	case 5:
		rl.SimMouse(40, 35)
	case 6:
		rl.SimButton(.LEFT, false)
	case 7:
		s.focus = FOCUS_COUNT
		rl.SimKey(.TAB, true)
		rl.SimKey(.TAB, false)
	case 8:
		rl.SimKey(.LEFT_SHIFT, true)
		rl.SimKey(.TAB, true)
		rl.SimKey(.TAB, false)
		rl.SimKey(.LEFT_SHIFT, false)
	case 9:
		ui.context_menu_open(&s.menu, 300, 100)
	case 10, 11, 12:
		rl.SimKey(.DOWN, true)
		rl.SimKey(.DOWN, false)
	case 13:
		rl.SimKey(.ENTER, true)
		rl.SimKey(.ENTER, false)
	case 14:
		rl.SimMouse(40, 230)
		rl.SimButton(.LEFT, true)
	case 15:
		rl.SimButton(.LEFT, false)
	case 16, 17, 18:
		rl.SimKey(.DOWN, true)
		rl.SimKey(.DOWN, false)
	case 19:
		rl.SimKey(.ENTER, true)
		rl.SimKey(.ENTER, false)
	case 20:
		rl.SimMouse(40, 230)
		rl.SimButton(.LEFT, true)
	case 21:
		rl.SimButton(.LEFT, false)
	case 22:
		rl.SimKey(.ENTER, true)
		rl.SimKey(.ENTER, false)
	case 23:
		s.modal.open = true
		rl.SimKey(.ESCAPE, true)
		rl.SimKey(.ESCAPE, false)
	}
	return true
}

// inject_events stages 0..5 random input events for this frame.
inject_events :: proc(p: ^Prng) {
	n := fuzzx.int_range(p, 0, 6)
	for _ in 0 ..< n {
		switch fuzzx.int_range(p, 0, 10) {
		case 0, 1, 2:
			// Mouse move: 2/3 biased into a widget rect, else anywhere.
			if fuzzx.int_range(p, 0, 3) != 0 {
				r := RECTS[fuzzx.int_range(p, 0, len(RECTS))]
				rl.SimMouse(
					f32(r.x + i32(fuzzx.int_range(p, -4, int(r.w) + 4))),
					f32(r.y + i32(fuzzx.int_range(p, -4, int(r.h) + 4))),
				)
			} else {
				rl.SimMouse(
					f32(fuzzx.int_range(p, 0, SCREEN_W)),
					f32(fuzzx.int_range(p, 0, SCREEN_H)),
				)
			}
		case 3, 4:
			rl.SimButton(.LEFT, fuzzx.int_range(p, 0, 2) == 0)
		case 5:
			// Tab, with or without shift held.
			shift := fuzzx.int_range(p, 0, 2) == 0
			rl.SimKey(.LEFT_SHIFT, shift)
			rl.SimKey(.TAB, true)
			rl.SimKey(.TAB, false)
			rl.SimKey(.LEFT_SHIFT, false)
		case 6:
			acts := [?]rl.KeyboardKey{.SPACE, .ENTER, .ESCAPE}
			k := acts[fuzzx.int_range(p, 0, 3)]
			rl.SimKey(k, true)
			rl.SimKey(k, false)
		case 7:
			arrows := [?]rl.KeyboardKey{.LEFT, .RIGHT, .UP, .DOWN}
			k := arrows[fuzzx.int_range(p, 0, 4)]
			rl.SimKey(k, true)
			rl.SimKey(k, false)
		case 8:
			rl.SimWheel(0, f32(fuzzx.int_range(p, -300, 301)) / 100.0)
		case 9:
			rl.SimButton(.RIGHT, fuzzx.int_range(p, 0, 2) == 0)
		}
	}
}

// capture_sim_input mirrors ui_gfx.capture_input for the headless harness.
// ingot:ui reads one explicit Ui_Input snapshot per frame, so without this
// every widget sees the zeroed input_default and the whole event mix above
// is inert. ui_gfx itself cannot be imported here: it pulls in AccessKit and
// the GPU backend, and this harness must stay windowless.
capture_sim_input :: proc(input: ^ui.Ui_Input) {
	assert(input != nil, "capture_sim_input: nil input")
	input^ = {}
	input.screen_size = {f32(SCREEN_W), f32(SCREEN_H)}
	input.dpi_scale = 1
	mouse := rl.GetMousePosition()
	delta := rl.GetMouseDelta()
	wheel := rl.GetMouseWheelMoveV()
	input.mouse_position = {mouse.x, mouse.y}
	input.mouse_delta = {delta.x, delta.y}
	input.mouse_wheel = {wheel.x, wheel.y}
	input.window_focused = true
	input.cursor_on_screen = true
	for index in 0 ..< ui.INPUT_KEY_COUNT {
		key := rl.KeyboardKey(index)
		input.keys_pressed[index] = rl.IsKeyPressed(key)
		input.keys_repeat[index] = rl.IsKeyPressedRepeat(key)
		input.keys_released[index] = rl.IsKeyReleased(key)
		input.keys_down[index] = rl.IsKeyDown(key)
	}
	for index in 0 ..< ui.INPUT_MOUSE_BUTTON_COUNT {
		button := rl.MouseButton(index)
		input.mouse_pressed[index] = rl.IsMouseButtonPressed(button)
		input.mouse_released[index] = rl.IsMouseButtonReleased(button)
		input.mouse_down[index] = rl.IsMouseButtonDown(button)
	}
}

// draw_scene runs one frame of the widget scene, mirroring how an app would.
// Returns whether any claiming overlay (modal, menu, dropdown popup) was
// active at any point during the frame - end-of-frame state is not enough
// because a menu can open and be chosen-from (row release) in one frame,
// legitimately registering a claim while ending the frame closed.
draw_scene :: proc(
	frame: ^ui.Ui_Frame,
	s: ^Scene,
	p: ^Prng,
	allow_random_overlays: bool,
) -> (
	overlay_active: bool,
) {
	ui.form_focus_cycle(frame, &s.focus, FOCUS_COUNT)

	if ui.button_at(frame, R_BTN, "Fuzz", focus = ui.Focus_Opt{&s.focus, 1}) {
		s.button_activations += 1
	}
	if ui.checkbox_at(frame, R_CHECK, "Check", &s.checked, ui.Focus_Opt{&s.focus, 2}) {
		s.checkbox_changes += 1
	}
	if ui.radio_at(frame, R_RADIO_A, "Radio A", &s.radio_sel, 0, ui.Focus_Opt{&s.focus, 3}) {
		s.radio_changes += 1
	}
	if ui.radio_at(frame, R_RADIO_B, "Radio B", &s.radio_sel, 1, ui.Focus_Opt{&s.focus, 4}) {
		s.radio_changes += 1
	}
	if allow_random_overlays && s.hide_slider_frames == 0 && fuzzx.int_range(p, 0, 61) == 0 {
		// Stop drawing a latch owner for a few frames, the way switching
		// tabs or collapsing a panel mid-drag does.
		s.hide_slider_frames = fuzzx.int_range(p, 1, 5)
	}
	if s.hide_slider_frames > 0 {
		s.hide_slider_frames -= 1
		s.slider_gone_frames += 1
	} else {
		s.slider_gone_frames = 0
		if ui.slider_at_state(
			frame,
			&s.slider_state,
			R_SLIDER,
			&s.slider_val,
			0,
			100,
			5,
			ui.Focus_Opt{&s.focus, 5},
		) {
			s.slider_changes += 1
		}
	}
	overlay_active |= s.dd_state.menu.open
	if ui.dropdown_at(frame, R_DROP, DD_ITEMS[:], &s.dd_sel, &s.dd_state, SCREEN_W, SCREEN_H) {
		s.dropdown_changes += 1
	}
	overlay_active |= s.dd_state.menu.open

	// Randomly open the modal / context menu the way an app handler would.
	if allow_random_overlays && !s.modal.open && fuzzx.int_range(p, 0, 97) == 0 do s.modal.open = true
	if s.modal.open {
		overlay_active = true
		_ = ui.modal_begin(
			frame,
			&s.modal,
			"Fuzz Modal",
			{size = {400, 300}, screen = {0, 0, SCREEN_W, SCREEN_H}},
		)
		ui.modal_end(&s.modal)
	}
	if allow_random_overlays && !s.menu.open && fuzzx.int_range(p, 0, 89) == 0 {
		ui.context_menu_open(
			&s.menu,
			i32(fuzzx.int_range(p, 0, SCREEN_W)),
			i32(fuzzx.int_range(p, 0, SCREEN_H)),
		)
	}
	overlay_active |= s.menu.open
	if ui.context_menu(frame, &s.menu, MENU_ITEMS[:], {0, 0, SCREEN_W, SCREEN_H}) >= 0 {
		s.menu_choices += 1
	}
	overlay_active |= s.menu.open
	return overlay_active
}

check_invariants :: proc(c: ^fuzzx.Ctx, frame: ^ui.Ui_Frame, s: ^Scene, overlay_free_frames: int) {
	fuzzx.check(
		c,
		ui.route_claim_count(frame) <= ui.MAX_ROUTE_CLAIMS,
		"route claims exceeded bound",
	)
	// Claim latency by design: claims registered during the overlay's last
	// open frame (N) occlude through N+1 and expire at the rotation into
	// N+2 - so zero claims is first guaranteed on the third free frame.
	if overlay_free_frames >= 3 {
		fuzzx.check(c, ui.route_claim_count(frame) == 0, "route claims leaked past overlay close")
	}

	fuzzx.check(c, s.focus >= 0 && s.focus <= FOCUS_COUNT, "focus slot out of range")
	focused := 0
	for id in 1 ..= FOCUS_COUNT {
		if ui.focus_opt_focused({&s.focus, id}) do focused += 1
	}
	fuzzx.check(c, focused <= 1, "more than one widget focused")

	// A latch owner that stops being drawn must lose the arbitration slot.
	// The slot is confirmed during the owner's own interact() call, so a
	// latch stamped in frame N survives frame N+1 by design and must be
	// reclaimed by frame N+2. Holding it any longer makes every widget in
	// the window inert, and the owner's memory may already be gone.
	if s.slider_gone_frames >= 2 {
		fuzzx.check(
			c,
			!ui.interact_latch_is(frame, &s.slider_state.dragging),
			"drag latch outlived an undrawn owner",
		)
	}

	fuzzx.check(c, s.slider_val >= 0 && s.slider_val <= 100, "slider escaped [lo, hi]")
	fuzzx.check(c, s.radio_sel == 0 || s.radio_sel == 1, "radio selected invalid value")
	fuzzx.check(c, s.button_activations <= u64(c.iteration + 1), "duplicate button activation")
	fuzzx.check(c, s.checkbox_changes <= u64(c.iteration + 1), "duplicate checkbox change")
	fuzzx.check(c, s.radio_changes <= u64(c.iteration + 1), "duplicate radio change")
	fuzzx.check(c, s.slider_changes <= u64(c.iteration + 1), "duplicate slider change")
	fuzzx.check(c, s.dropdown_changes <= u64(c.iteration + 1), "duplicate dropdown change")
	fuzzx.check(c, s.menu_choices <= u64(c.iteration + 1), "duplicate menu choice")
	fuzzx.check(
		c,
		s.dd_sel >= 0 && int(s.dd_sel) < len(DD_ITEMS),
		"dropdown selection out of range",
	)
	fuzzx.check(c, !s.modal.drawing, "modal begin/end unbalanced")
	if s.menu.open {
		selected_valid := s.menu.selected >= 0 && s.menu.selected < len(MENU_ITEMS)
		fuzzx.check(c, selected_valid, "menu selection out of range")
		if selected_valid {
			it := MENU_ITEMS[s.menu.selected]
			fuzzx.check(c, !it.separator || s.menu.selected == 0, "menu selection on separator")
		}
	}

	semantics := ui.sem_frame(frame)
	fuzzx.check(
		c,
		semantics.count >= 0 && semantics.count <= ui.MAX_SEM_NODES,
		"semantic buffer overflow",
	)
	for i in 0 ..< semantics.count {
		fuzzx.check(c, semantics.nodes[i].id > 1, "semantic node id reserved/zero")
		for j in i + 1 ..< semantics.count {
			same := semantics.nodes[i].id == semantics.nodes[j].id
			if same {
				_, actionable := ui.sem_action_target(frame, semantics.nodes[i].id)
				fuzzx.check(c, !actionable, "duplicate interactive semantic node id")
			}
		}
	}
}

fuzz_text_font :: proc(data: rawptr, size: i32) -> ui.Font_Id {
	return ui.Font_Id(size)
}

fuzz_text_measure :: proc(
	data: rawptr,
	font: ui.Font_Id,
	text: string,
	size, spacing: f32,
) -> ui.Vec2 {
	return {f32(len(text)) * size * 0.5, size}
}

main :: proc() {
	seed, iterations, rounds := fuzzx.parse_options(ITERATIONS_DEFAULT)
	fmt.printfln("fuzz_interact seed=%d iterations=%d rounds=%d", seed, iterations, rounds)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)

	for round in 0 ..< rounds {
		round_seed := seed + u64(round)
		if rounds > 1 do fmt.printfln("fuzz_interact round %d seed=%d", round, round_seed)
		p := fuzzx.prng_make(round_seed)
		c := fuzzx.Ctx {
			name = "fuzz_interact",
			seed = round_seed,
		}

		s := Scene {
			slider_val = 40,
		}
		runtime: ui.Ui_Runtime
		ui.ui_runtime_init(&runtime)
		ui.ui_runtime_set_text_backend(
			&runtime,
			{font_for_size = fuzz_text_font, measure = fuzz_text_measure},
		)
		ui.sem_enable(&runtime, true)
		frame: ui.Ui_Frame
		input: ui.Ui_Input
		output := new(ui.Ui_Output)
		frame.output = output
		rl.SimReset()
		overlay_free_frames := 0

		for i in 0 ..< iterations {
			c.iteration = i
			rl.SimBeginFrame()
			deterministic := inject_scenario(i, &s)
			if !deterministic do inject_events(&p)
			capture_sim_input(&input)
			ui.ui_frame_begin(&frame, &runtime, &input)
			overlay_active := draw_scene(&frame, &s, &p, !deterministic)
			if overlay_active {
				overlay_free_frames = 0
			} else {
				overlay_free_frames += 1
			}
			check_invariants(&c, &frame, &s, overlay_free_frames)
			ui.ui_frame_end(&frame)
			free_all(context.temp_allocator)
		}
		ui.ui_frame_destroy(&frame)
		free(output)
		ui.ui_runtime_destroy(&runtime)
	}

	fuzzx.report(&track, "fuzz_interact", seed)
	fmt.printfln("fuzz_interact ok")
}
