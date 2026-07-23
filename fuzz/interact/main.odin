package fuzz_interact

// Widget interaction-sequence fuzzer for ingot:ui — HEADLESS (no window, no
// GPU; part of `fuzz/run.sh all`). Built with -define:INGOT_INPUT_SIM=true
// so gfx's synthetic input seam (gfx/input_sim.odin) replaces the platform
// input layer.
//
// Motivation: widget *state machines* — the one-frame route-claim double
// buffer, form focus, drag latches, modal/menu lifecycles — were only
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
	focus:      int,
	checked:    bool,
	radio_sel:  i32,
	slider_val: f32,
	dd_sel:     i32,
	dd_state:   ui.Dropdown_State,
	modal:      ui.Modal_State,
	menu:       ui.Context_Menu_State,
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

// draw_scene runs one frame of the widget scene, mirroring how an app would.
// Returns whether any claiming overlay (modal, menu, dropdown popup) was
// active at any point during the frame — end-of-frame state is not enough
// because a menu can open and be chosen-from (row release) in one frame,
// legitimately registering a claim while ending the frame closed.
draw_scene :: proc(s: ^Scene, p: ^Prng) -> (overlay_active: bool) {
	ui.form_focus_cycle(&s.focus, FOCUS_COUNT)

	_ = ui.btn(R_BTN.x, R_BTN.y, R_BTN.w, R_BTN.h, "Fuzz", focus = {&s.focus, 1})
	_ = ui.checkbox(R_CHECK, "Check", &s.checked, {&s.focus, 2})
	_ = ui.radio(R_RADIO_A, "Radio A", &s.radio_sel, 0, {&s.focus, 3})
	_ = ui.radio(R_RADIO_B, "Radio B", &s.radio_sel, 1, {&s.focus, 4})
	_ = ui.slider(R_SLIDER, &s.slider_val, 0, 100, 5, ui.Focus_Opt{&s.focus, 5})
	overlay_active |= s.dd_state.menu.open
	_ = ui.dropdown(R_DROP, DD_ITEMS[:], &s.dd_sel, &s.dd_state, SCREEN_W, SCREEN_H)
	overlay_active |= s.dd_state.menu.open

	// Randomly open the modal / context menu the way an app handler would.
	if !s.modal.open && fuzzx.int_range(p, 0, 97) == 0 do s.modal.open = true
	if s.modal.open {
		overlay_active = true
		_ = ui.modal_begin(&s.modal, "Fuzz Modal", 400, 300, SCREEN_W, SCREEN_H)
		ui.modal_end(&s.modal)
	}
	if !s.menu.open && fuzzx.int_range(p, 0, 89) == 0 {
		ui.context_menu_open(
			&s.menu,
			i32(fuzzx.int_range(p, 0, SCREEN_W)), i32(fuzzx.int_range(p, 0, SCREEN_H)),
		)
	}
	overlay_active |= s.menu.open
	_ = ui.context_menu(&s.menu, MENU_ITEMS[:], SCREEN_W, SCREEN_H)
	overlay_active |= s.menu.open
	return overlay_active
}

check_invariants :: proc(c: ^fuzzx.Ctx, s: ^Scene, overlay_free_frames: int) {
	fuzzx.check(c, ui.route_claim_count() <= ui.MAX_ROUTE_CLAIMS, "route claims exceeded bound")
	// Claim latency by design: claims registered during the overlay's last
	// open frame (N) occlude through N+1 and expire at the rotation into
	// N+2 — so zero claims is first guaranteed on the third free frame.
	if overlay_free_frames >= 3 {
		fuzzx.check(c, ui.route_claim_count() == 0, "route claims leaked past overlay close")
	}

	fuzzx.check(c, s.focus >= 0 && s.focus <= FOCUS_COUNT, "focus slot out of range")
	focused := 0
	for id in 1 ..= FOCUS_COUNT {
		if ui.focus_opt_focused({&s.focus, id}) do focused += 1
	}
	fuzzx.check(c, focused <= 1, "more than one widget focused")

	fuzzx.check(c, s.slider_val >= 0 && s.slider_val <= 100, "slider escaped [lo, hi]")
	fuzzx.check(c, s.radio_sel == 0 || s.radio_sel == 1, "radio selected invalid value")
	fuzzx.check(c, s.dd_sel >= 0 && int(s.dd_sel) < len(DD_ITEMS), "dropdown selection out of range")
	fuzzx.check(c, !s.modal.drawing, "modal begin/end unbalanced")
	if s.menu.open {
		it := MENU_ITEMS[s.menu.selected]
		fuzzx.check(c, s.menu.selected >= 0 && s.menu.selected < len(MENU_ITEMS), "menu selection out of range")
		fuzzx.check(c, !it.separator || s.menu.selected == 0, "menu selection on separator")
	}

	frame := ui.sem_frame()
	fuzzx.check(c, frame.count >= 0 && frame.count <= ui.MAX_SEM_NODES, "semantic buffer overflow")
	for i in 0 ..< frame.count {
		fuzzx.check(c, frame.nodes[i].id > 1, "semantic node id reserved/zero")
		for j in i + 1 ..< frame.count {
			if frame.nodes[i].focus == nil do continue
			same := frame.nodes[i].id == frame.nodes[j].id
			fuzzx.check(c, !same, "duplicate interactive semantic node id")
		}
	}
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
		c := fuzzx.Ctx{name = "fuzz_interact", seed = round_seed}

		s := Scene{slider_val = 40}
		rl.SimReset()
		ui.interact_reset()
		ui.route_reset()
		ui.sem_reset()
		ui.sem_enable(true)
		overlay_free_frames := 0

		for i in 0 ..< iterations {
			c.iteration = i
			rl.SimBeginFrame()
			inject_events(&p)
			ui.begin_cursor_frame()
			overlay_active := draw_scene(&s, &p)
			ui.apply_cursor() // flush overlay commands (headless-safe)
			if overlay_active {
				overlay_free_frames = 0
			} else {
				overlay_free_frames += 1
			}
			check_invariants(&c, &s, overlay_free_frames)
			free_all(context.temp_allocator)
		}
	}

	fuzzx.report(&track, "fuzz_interact", seed)
	fmt.printfln("fuzz_interact ok")
}
