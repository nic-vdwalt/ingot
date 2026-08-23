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
// Why its own loop instead of fit.Run: Builder paint is replayed by Render.
// Wrapping the draw callback alone would capture direct draws and none of the
// widgets, so the target brackets explicit fit.Render in a manual fit.Session.
//
// Determinism: capture forces reduced motion, an explicit 1.0 UI scale, and a
// settle delay before each shot. Caret blink and progress easing are wall-clock
// driven (ui/text_input.odin reads frame_input().time), so without those two
// controls the same shot would differ byte-for-byte between runs.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import fit "ingot:fit"
import rl "ingot:gfx"

// Imports are used only under `when CAPTURE`; anchor them for normal builds.
_ :: fmt
_ :: os
_ :: strings
_ :: rl
_ :: fit

// CAPTURE is declared in main.odin so the js target, which excludes this file,
// can still compile main.odin's `when CAPTURE` guards.

when CAPTURE {
	// Fixed output geometry: identical PNGs regardless of host display.
	CAPTURE_WIDTH :: #config(INGOT_CAPTURE_WIDTH, 1600)
	CAPTURE_HEIGHT :: #config(INGOT_CAPTURE_HEIGHT, 1000)
	CAPTURE_WINDOW_WIDTH :: 1280
	CAPTURE_WINDOW_HEIGHT :: 800
	// Frames to hold a state before the shot. fit.eased snaps to its target once
	// it is within 0.001, so a long enough hold makes every eased widget land on
	// exactly its target value instead of a frame-timing-dependent one. The
	// slowest easer here is the chart enter animation (rate 6), which needs
	// roughly 70 frames; 90 leaves margin without making the run slow.
	CAPTURE_SETTLE_FRAMES :: 90
	// Explicit UI scale. Fixed rather than auto so HiDPI hosts cannot change
	// the output, and above 1.0 so the gallery's intrinsic content height
	// fills CAPTURE_HEIGHT instead of leaving dead space below the fold.
	CAPTURE_UI_SCALE :: f32(#config(INGOT_CAPTURE_UI_SCALE, 1.5))
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
		{"gallery-theme-terra.png", .Theme, .Terra},
	}

	// The GIF script: every section in order using the default Ingot theme,
	// then Terra so the motion shows both navigation and branded theming.
	CAPTURE_SEQUENCE := [?]Capture_Shot {
		{"", .Buttons, .Ingot},
		{"", .Inputs, .Ingot},
		{"", .Widgets, .Ingot},
		{"", .Charts, .Ingot},
		{"", .Markdown, .Ingot},
		{"", .Layout, .Ingot},
		{"", .Overlay, .Ingot},
		{"", .Stress, .Ingot},
		{"", .Theme, .Terra},
	}

	capture_session: fit.Session
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
			// Stills freeze motion so reruns are byte-identical (see the
			// determinism note at the top of this file). The sequence pass wants
			// the opposite: it is a recording, so it keeps spinners, eased
			// progress, and chart reveals running and replays them per step.
			reduced_motion = !capture_sequence
			apply_gallery_theme()
			apply_scale(CAPTURE_UI_SCALE)
			fit.Pane_Reset(&content_pane)
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
		fit.Chart_Reset(&line_state)
		fit.Chart_Reset(&bar_state)
	}

	// capture_seed_inputs fills the text boxes so the Inputs shot shows real
	// content, selection, and spellcheck rather than three empty placeholders.
	capture_seed_inputs :: proc() {
		if section != .Inputs do return
		fit.Input_Box_Set_Text(&input_state.name, "Ada Lovelace")
		fit.Input_Box_Set_Text(&input_state.pass, "correct horse battery")
		fit.Input_Box_Set_Text(
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
		fit.Session_Destroy(&capture_session)
		rl.CloseWindow()
		shutdown()
		if capture_sequence do fmt.printfln("capture: %d frames", capture_sequence_frame)
		os.exit(0)
	}

	// capture_frame is the whole loop body: it brackets the entire session
	// frame - build and paint replay - with the capture target, then blits the
	// result to the window so the run is visible while it records.
	capture_frame :: proc() {
		if !fit.Session_Draw(&capture_session, capture_draw) do return
		capture_write()
	}

	capture_draw :: proc(builder: ^fit.Builder, user_data: rawptr) {
		assert(builder != nil, "capture_draw: nil builder")
		_ = user_data
		theme := palette_theme(palette)
		background := rl.Color(fit.Theme_Background(theme))
		background.a = 255
		rl.ClearBackground(background)

		rl.BeginTextureMode(capture_target)
		rl.ClearBackground(background)
		gallery_build(builder, nil)
		_ = fit.Measure(builder)
		fit.Render_At(builder, {0, 0, CAPTURE_WIDTH, CAPTURE_HEIGHT})
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
	}

	// capture_main replaces the normal fit.Run entry point under -define.
	capture_main :: proc() {
		capture_dir = os.get_env("INGOT_CAPTURE_DIR", context.allocator)
		if capture_dir == "" do capture_dir = strings.clone("docs/media")
		sequence_flag := os.get_env("INGOT_CAPTURE_SEQUENCE", context.allocator)
		defer delete(sequence_flag)
		capture_sequence = sequence_flag != ""

		flags: rl.ConfigFlags = {.WINDOW_RESIZABLE, .VSYNC_HINT}
		when ODIN_OS == .Darwin do flags += {.WINDOW_HIGHDPI}
		rl.SetConfigFlags(flags)
		rl.InitWindow(
			CAPTURE_WINDOW_WIDTH,
			CAPTURE_WINDOW_HEIGHT,
			"ingot widget gallery (capture)",
		)
		rl.SetTargetFPS(60)
		fit.Session_Init(
			&capture_session,
			{user_scale = CAPTURE_UI_SCALE, semantics_enabled = true},
		)
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
