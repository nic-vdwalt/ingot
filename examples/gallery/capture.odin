#+build !js
// Gallery capture mode (scripts/capture-media.sh, -define:INGOT_CAPTURE=true):
// a self-driving media harness, modelled on smoke.odin. It renders the gallery
// into a fixed-size offscreen render target and writes PNGs, so the README
// stills and the demo GIF are reproducible on any machine instead of being
// hand-cropped screenshots.
//
// Why a render target: the swapchain is RenderAttachment-only (gfx/context.odin),
// so gfx.SaveRenderTexturePng can only read a render target. Rendering into a
// fixed CAPTURE_WIDTH x CAPTURE_HEIGHT target also decouples the output from the
// host window size and HiDPI factor.
//
// Why its own loop instead of ui_gfx.app_run: widget paint is replayed in
// session_end_frame_context, after the frame callback returns. Wrapping the
// callback alone would capture the direct gfx draws and none of the widgets, so
// the target has to bracket the whole session frame.
//
// Determinism: capture forces reduced motion, an explicit 1.0 UI scale, and a
// settle delay before each shot. Caret blink and progress easing are wall-clock
// driven (ui/text_input.odin reads frame_input().time), so without those two
// controls the same shot would differ byte-for-byte between runs.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import rl "ingot:gfx"
import "ingot:ui"
import "ingot:ui_gfx"

// Imports are used only under `when CAPTURE`; anchor them for normal builds.
_ :: fmt
_ :: os
_ :: strings
_ :: rl
_ :: ui
_ :: ui_gfx

// CAPTURE is declared in main.odin so the js target, which excludes this file,
// can still compile main.odin's `when CAPTURE` guards.

when CAPTURE {
	// Fixed output geometry: identical PNGs regardless of host display.
	CAPTURE_WIDTH :: 1600
	CAPTURE_HEIGHT :: 1000
	CAPTURE_WINDOW_WIDTH :: 1280
	CAPTURE_WINDOW_HEIGHT :: 800
	// Frames to hold a state before the shot. ui.eased snaps to its target once
	// it is within 0.001, so a long enough hold makes every eased widget land on
	// exactly its target value instead of a frame-timing-dependent one. The
	// slowest easer here is the chart enter animation (rate 6), which needs
	// roughly 70 frames; 90 leaves margin without making the run slow.
	CAPTURE_SETTLE_FRAMES :: 90
	// Explicit UI scale. Fixed rather than auto so HiDPI hosts cannot change
	// the output, and above 1.0 so the gallery's intrinsic content height
	// fills CAPTURE_HEIGHT instead of leaving dead space below the fold.
	CAPTURE_UI_SCALE :: f32(1.5)
	// Where the harness parks the cursor. Hover, tooltips, and pointer-driven
	// focus rings would otherwise depend on wherever the operator left the
	// mouse, so every shot pins it to the same inert spot in the nav gutter.
	CAPTURE_MOUSE_X :: 8
	CAPTURE_MOUSE_Y :: CAPTURE_HEIGHT - 8
	// Frames each sequence step is held. Eight steps x 60 frames = 480 frames,
	// which is 8 s of source at the 60 fps the GIF/MP4 encode assumes.
	CAPTURE_SEQUENCE_FRAMES :: 60
	CAPTURE_MAX_SEQUENCE_FRAMES :: 4096

	Capture_Shot :: struct {
		file:    string,
		section: Section,
		palette: Palette,
	}

	// The README set: one shot per visually distinct area, in both themes so a
	// reader can see the theme system is real rather than a recolour.
	// The README set. Chosen for density: sections whose intrinsic content fills
	// the frame at CAPTURE_UI_SCALE. Layout, Markdown, and Overlay are captured
	// by the sequence pass instead - as stills they leave half the frame empty,
	// which reads as an unfinished framework rather than a focused one.
	CAPTURE_SHOTS := [?]Capture_Shot {
		{"gallery-widgets-dark.png", .Widgets, .Dark},
		{"gallery-charts-dark.png", .Charts, .Dark},
		{"gallery-buttons-light.png", .Buttons, .Light},
		{"gallery-inputs-light.png", .Inputs, .Light},
		{"gallery-stress-dark.png", .Stress, .Dark},
		// The Theme page on paper: the one shot where the substrate, the
		// margin and the hand-drawn accents are all visible at once.
		{"gallery-theme-sketch.png", .Theme, .Sketch_Warm},
	}

	// The GIF script: every section in order, alternating theme so the motion
	// shows both navigation and theming without any synthetic input.
	CAPTURE_SEQUENCE := [?]Capture_Shot {
		{"", .Buttons, .Dark},
		{"", .Inputs, .Dark},
		{"", .Widgets, .Dark},
		{"", .Charts, .Dark},
		{"", .Markdown, .Light},
		{"", .Layout, .Light},
		{"", .Overlay, .Dark},
		{"", .Stress, .Dark},
		// End on paper so the sequence closes on the aesthetic rather than on
		// the stress grid.
		{"", .Theme, .Sketch_Warm},
	}

	capture_target: rl.RenderTexture2D
	capture_dir: string
	capture_sequence: bool
	capture_step_index: int
	capture_state_frame: int
	capture_state_applied: bool
	capture_sequence_frame: int

	// capture_script returns the active shot table for the current pass.
	capture_script :: proc() -> []Capture_Shot {
		if capture_sequence do return CAPTURE_SEQUENCE[:]
		return CAPTURE_SHOTS[:]
	}

	// capture_step applies the current shot's state through the same paths a
	// click would (apply_gallery_theme, apply_scale, pane_reset) and counts
	// settle frames. Called from frame(), exactly like smoke_step.
	capture_step :: proc() {
		script := capture_script()
		assert(capture_step_index >= 0, "capture_step: negative index")
		rl.SetMousePosition(CAPTURE_MOUSE_X, CAPTURE_MOUSE_Y)
		if capture_step_index >= len(script) do return
		if !capture_state_applied {
			shot := script[capture_step_index]
			section = shot.section
			palette = shot.palette
			high_contrast = false
			// Stills freeze motion so reruns are byte-identical (see the
			// determinism note at the top of this file). The sequence pass wants
			// the opposite: it is a recording, so it keeps spinners, eased
			// progress, and chart reveals running and replays them per step.
			reduced_motion = !capture_sequence
			apply_gallery_theme()
			apply_scale(CAPTURE_UI_SCALE)
			ui.pane_reset(&content_pane)
			capture_seed_inputs()
			if capture_sequence do capture_replay_animations()
			capture_state_applied = true
			capture_state_frame = 0
		}
		capture_state_frame += 1
	}

	// capture_replay_animations rewinds the caller-owned animation state so each
	// sequence step shows its widgets entering rather than already settled.
	// Nothing here reaches into the library: these are the same fields the
	// gallery's own "Replay" button resets.
	capture_replay_animations :: proc() {
		progress_anim = 0
		line_state.enter_anim = 0
		bar_state.enter_anim = 0
	}

	// capture_seed_inputs fills the text boxes so the Inputs shot shows real
	// content, selection, and spellcheck rather than three empty placeholders.
	capture_seed_inputs :: proc() {
		if section != .Inputs do return
		ui.input_box_set_text(&input_state.name, "Ada Lovelace")
		ui.input_box_set_text(&input_state.pass, "correct horse battery")
		ui.input_box_set_text(
			&input_state.notes,
			"Immediate mode all the way up: the caller owns this text, undo, and selection.",
		)
	}

	// capture_write saves the settled render target and advances the script.
	// Called after EndTextureMode, when the target holds a complete frame.
	capture_write :: proc() {
		script := capture_script()
		assert(capture_target.texture.id != 0, "capture_write: no render target")
		if capture_step_index >= len(script) {
			fmt.printfln("capture: ok (%d steps)", len(script))
			capture_finish()
		}
		if capture_sequence {
			capture_write_sequence_frame()
			return
		}
		if capture_state_frame < CAPTURE_SETTLE_FRAMES do return
		shot := script[capture_step_index]
		path := fmt.tprintf("%s/%s", capture_dir, shot.file)
		if !rl.SaveRenderTexturePng(capture_target, path) {
			fmt.eprintfln("capture: failed to write %s", path)
			os.exit(1)
		}
		fmt.printfln("capture: wrote %s", path)
		capture_step_index += 1
		capture_state_applied = false
	}

	// capture_write_sequence_frame writes one numbered frame of the GIF source
	// and rolls to the next script step once the hold elapses.
	capture_write_sequence_frame :: proc() {
		assert(capture_sequence, "capture_write_sequence_frame: not a sequence pass")
		if capture_sequence_frame >= CAPTURE_MAX_SEQUENCE_FRAMES {
			fmt.eprintln("capture: sequence frame cap exceeded")
			os.exit(1)
		}
		path := fmt.tprintf("%s/frame_%05d.png", capture_dir, capture_sequence_frame)
		if !rl.SaveRenderTexturePng(capture_target, path) {
			fmt.eprintfln("capture: failed to write %s", path)
			os.exit(1)
		}
		capture_sequence_frame += 1
		if capture_state_frame >= CAPTURE_SEQUENCE_FRAMES {
			capture_step_index += 1
			capture_state_applied = false
		}
	}

	// capture_finish releases the target and exits successfully. The process
	// terminates here rather than returning, so the harness never depends on
	// the window being closed by a human.
	capture_finish :: proc() {
		assert(capture_dir != "", "capture_finish: no output directory")
		if capture_target.texture.id != 0 do rl.UnloadRenderTexture(capture_target)
		if capture_sequence do fmt.printfln("capture: %d frames", capture_sequence_frame)
		os.exit(0)
	}

	// capture_frame is the whole loop body: it brackets the entire session
	// frame - build and paint replay - with the capture target, then blits the
	// result to the window so the run is visible while it records.
	capture_frame :: proc() {
		gfx_frame, acquired := rl.begin_frame()
		if !acquired do return
		frame_state := ui_gfx.session_begin_frame_context(&app.session, &gfx_frame)
		// Window and target share one derived background. This used to be two
		// values - a fixed configured clear behind a theme-derived target
		// clear - which is why a light-theme shot showed the dark configured
		// colour through it. bg_app also carries the vibrancy alpha (dark
		// windowed is alpha 162), so app_clear_color forces it opaque: a
		// translucent clear produced PNGs with 0.74 mean alpha that rendered
		// washed-out grey on any non-white page.
		background := ui_gfx.app_clear_color(&app)
		rl.clear_frame(&gfx_frame, background)

		rl.BeginTextureMode(capture_target)
		rl.ClearBackground(background)
		gallery_frame(&app, frame_state, nil)
		ui_gfx.session_end_frame_context(&app.session, &gfx_frame)
		rl.EndTextureMode()

		// Negative source height blits the bottom-left-origin target upright
		// (docs/rendering.md "Render-target orientation").
		rl.DrawTexturePro(
			capture_target.texture,
			{0, 0, f32(CAPTURE_WIDTH), -f32(CAPTURE_HEIGHT)},
			{0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())},
			{0, 0},
			0,
			rl.WHITE,
		)
		rl.end_frame(&gfx_frame)
		capture_write()
		free_all(context.temp_allocator)
	}

	// capture_main replaces the normal app_run entry point under -define.
	capture_main :: proc() {
		capture_dir = os.get_env("INGOT_CAPTURE_DIR", context.allocator)
		if capture_dir == "" do capture_dir = strings.clone("docs/media")
		sequence_flag := os.get_env("INGOT_CAPTURE_SEQUENCE", context.allocator)
		defer delete(sequence_flag)
		capture_sequence = sequence_flag != ""

		started := ui_gfx.app_init(
			&app,
			{
				width = CAPTURE_WINDOW_WIDTH,
				height = CAPTURE_WINDOW_HEIGHT,
				title = "ingot widget gallery (capture)",
				target_fps = 60,
				event_waiting = false,
				session = {semantics_enabled = true},
			},
			{frame = gallery_frame, shutdown = shutdown},
		)
		if !started {
			fmt.eprintln("capture: window initialisation failed")
			os.exit(1)
		}
		app.state = .Running
		capture_target = rl.LoadRenderTexture(CAPTURE_WIDTH, CAPTURE_HEIGHT)
		if capture_target.texture.id == 0 {
			fmt.eprintln("capture: render target allocation failed")
			os.exit(1)
		}
		fmt.printfln(
			"capture: %s pass into %s",
			"sequence" if capture_sequence else "stills",
			capture_dir,
		)
		rl.run(capture_frame)
	}
}
