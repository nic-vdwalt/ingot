#+build !js
// Gallery capture mode (scripts/capture-media.sh, -define:INGOT_CAPTURE=true):
// a self-driving media harness, modelled on smoke.odin. It renders the gallery
// into a fixed-size offscreen render target and writes PNGs, so the README
// stills and the demo GIF are reproducible on any machine instead of being
// hand-cropped screenshots.
//
// Why a render target: the swapchain is RenderAttachment-only (gfx/context.odin),
// so gfx.save_render_texture_png can only read a render target. The target is
// CAPTURE_WIDTH x CAPTURE_HEIGHT layout pixels multiplied by the device pixel
// density (2x on Retina, capped so the UI scale stays within its 3.0 limit), so
// the output matches the display's native resolution while the layout stays
// identical. INGOT_CAPTURE_PIXEL_SCALE=1 forces the old fixed 1x output.
//
// Why its own loop instead of fit.run: Builder paint is replayed by Render.
// Wrapping the draw callback alone would capture direct draws and none of the
// widgets, so the target brackets explicit fit.render in a manual fit.Session.
//
// Determinism: capture forces reduced motion, an explicit 1.0 UI scale, and a
// settle delay before each shot. Caret blink and progress easing are wall-clock
// driven (ui/text_input.odin reads frame_input().time), so without those two
// controls the same shot would differ byte-for-byte between runs.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import fit "ingot:fit"
import rl "ingot:gfx"

// Imports are used only under `when CAPTURE`; anchor them for normal builds.
_ :: fmt
_ :: os
_ :: strings
_ :: strconv
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
	// The UI runtime clamps its scale to 3.0, which bounds the pixel density.
	CAPTURE_MAX_UI_SCALE :: f32(3)
	// Where the harness parks the cursor. Hover, tooltips, and pointer-driven
	// focus rings would otherwise depend on wherever the operator left the
	// mouse, so every shot pins it to the same inert spot in the nav gutter.
	CAPTURE_MOUSE_X :: 8
	CAPTURE_MOUSE_INSET :: 8
	// Per-step holds at the 60 fps the GIF/MP4 encode assumes: the Showcase
	// dwells for 2.5 s per palette, other pages flash past in 0.3 s.
	CAPTURE_SHOWCASE_FRAMES :: 150
	CAPTURE_SHUFFLE_FRAMES :: 18
	CAPTURE_CLOSING_FRAMES :: 60
	CAPTURE_MAX_SEQUENCE_FRAMES :: 4096

	Capture_Shot :: struct {
		file:    string,
		section: Section,
		palette: Palette,
		// Sequence hold in frames; stills ignore it and settle instead.
		frames:  int,
	}

	// The README set: one shot per visually distinct area, in both themes so a
	// reader can see the theme system is real rather than a recolour.
	// The README set. Chosen for density: sections whose intrinsic content fills
	// the frame at CAPTURE_UI_SCALE. Layout, Markdown, and Overlay are captured
	// by the sequence pass instead - as stills they leave half the frame empty,
	// which reads as an unfinished framework rather than a focused one.
	CAPTURE_SHOTS := [?]Capture_Shot {
		{"gallery-showcase-dark.png", .Showcase, .Dark, 0},
		{"gallery-showcase-ingot.png", .Showcase, .Ingot, 0},
		{"gallery-widgets-dark.png", .Widgets, .Dark, 0},
		{"gallery-charts-dark.png", .Charts, .Dark, 0},
		{"gallery-buttons-light.png", .Buttons, .Light, 0},
		{"gallery-inputs-light.png", .Inputs, .Light, 0},
		{"gallery-stress-dark.png", .Stress, .Dark, 0},
	}

	// The GIF script: mostly Showcase, moving Dark -> Pixel -> Retro Orange,
	// with a quick shuffle through the other pages between model beats. Every
	// page appears once; the planet's yaw follows the global frame counter, so
	// the spin stays continuous across steps.
	CAPTURE_SEQUENCE := [?]Capture_Shot {
		{"", .Showcase, .Dark, CAPTURE_SHOWCASE_FRAMES},
		{"", .Buttons, .Dark, CAPTURE_SHUFFLE_FRAMES},
		{"", .Inputs, .Dark, CAPTURE_SHUFFLE_FRAMES},
		{"", .Widgets, .Dark, CAPTURE_SHUFFLE_FRAMES},
		{"", .Showcase, .Pixel, CAPTURE_SHOWCASE_FRAMES},
		{"", .Charts, .Pixel, CAPTURE_SHUFFLE_FRAMES},
		{"", .Markdown, .Pixel, CAPTURE_SHUFFLE_FRAMES},
		{"", .Layout, .Pixel, CAPTURE_SHUFFLE_FRAMES},
		{"", .Showcase, .Retro_Orange, CAPTURE_SHOWCASE_FRAMES},
		{"", .Overlay, .Retro_Orange, CAPTURE_SHUFFLE_FRAMES},
		{"", .Stress, .Retro_Orange, CAPTURE_SHUFFLE_FRAMES},
		{"", .Showcase, .Retro_Orange, CAPTURE_CLOSING_FRAMES},
	}

	capture_session: fit.Session
	capture_target: rl.RenderTexture2D
	capture_dir: string
	capture_sequence: bool
	capture_step_index: int
	capture_state_frame: int
	capture_state_applied: bool
	capture_sequence_frame: int
	// Device pixels per layout pixel, fixed at startup.
	capture_pixel_scale: f32 = 1
	capture_width: i32 = CAPTURE_WIDTH
	capture_height: i32 = CAPTURE_HEIGHT

	// capture_pixel_scale_for clamps a display density so the scaled UI scale
	// never exceeds the runtime's limit.
	capture_pixel_scale_for :: proc(dpi: f32) -> f32 {
		return clamp(dpi, 1, CAPTURE_MAX_UI_SCALE / CAPTURE_UI_SCALE)
	}

	// CAPTURE_STILL_YAW frames the planet's most detailed face for stills.
	CAPTURE_STILL_YAW :: f32(0.6)
	// CAPTURE_SEQUENCE_SPEED is the recorded spin in radians per captured
	// frame, derived from the frame count rather than wall time so a slow
	// machine records the same motion as a fast one.
	CAPTURE_SEQUENCE_SPEED :: f32(0.004)

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
		rl.SetMousePosition(CAPTURE_MOUSE_X, capture_height - CAPTURE_MOUSE_INSET)
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
			apply_scale(CAPTURE_UI_SCALE * capture_pixel_scale)
			fit.pane_reset(&content_pane)
			capture_seed_inputs()
			if capture_sequence do capture_replay_animations()
			capture_state_applied = true
			capture_state_frame = 0
		}
		capture_state_frame += 1
		capture_pin_showcase_yaw()
	}

	// capture_pin_showcase_yaw makes the planet deterministic: stills hold one
	// yaw, and the sequence advances it per captured frame.
	capture_pin_showcase_yaw :: proc() {
		assert(capture_state_frame >= 0, "capture_pin_showcase_yaw: negative frame")
		if !capture_sequence {
			showcase.fixed_yaw = CAPTURE_STILL_YAW
			return
		}
		showcase.fixed_yaw = f32(capture_sequence_frame) * CAPTURE_SEQUENCE_SPEED
	}

	// capture_replay_animations rewinds the caller-owned animation state so each
	// sequence step shows its widgets entering rather than already settled.
	// Nothing here reaches into the library: these are the same fields the
	// gallery's own "Replay" button resets.
	capture_replay_animations :: proc() {
		progress_anim = 0
		fit.chart_reset(&line_state)
		fit.chart_reset(&bar_state)
	}

	// capture_seed_inputs fills the text boxes so the Inputs shot shows real
	// content, selection, and spellcheck rather than three empty placeholders.
	capture_seed_inputs :: proc() {
		if section != .Inputs do return
		fit.input_box_set_text(&input_state.name, "Ada Lovelace")
		fit.input_box_set_text(&input_state.pass, "correct horse battery")
		fit.input_box_set_text(
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
		if !rl.save_render_texture_png(capture_target, path) {
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
		if !rl.save_render_texture_png(capture_target, path) {
			fmt.eprintfln("capture: failed to write %s", path)
			os.exit(1)
		}
		capture_sequence_frame += 1
		hold := CAPTURE_SEQUENCE[capture_step_index].frames
		assert(hold > 0, "capture_write_sequence_frame: step without a hold")
		if capture_state_frame >= hold {
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
		fit.session_destroy(&capture_session)
		rl.CloseWindow()
		shutdown()
		if capture_sequence do fmt.printfln("capture: %d frames", capture_sequence_frame)
		os.exit(0)
	}

	// capture_frame is the whole loop body: it brackets the entire session
	// frame - build and paint replay - with the capture target, then blits the
	// result to the window so the run is visible while it records.
	capture_frame :: proc() {
		if !fit.session_draw(&capture_session, capture_draw) do return
		capture_write()
	}

	capture_draw :: proc(builder: ^fit.Builder, user_data: rawptr) {
		assert(builder != nil, "capture_draw: nil builder")
		_ = user_data
		theme := palette_theme(palette)
		background := rl.Color(fit.theme_background(theme))
		background.a = 255
		rl.ClearBackground(background)

		rl.BeginTextureMode(capture_target)
		rl.ClearBackground(background)
		gallery_build(builder, nil)
		_ = fit.measure(builder)
		fit.render_at(builder, {0, 0, capture_width, capture_height})
		rl.EndTextureMode()

		// Negative source height blits the bottom-left-origin target upright
		// (docs/rendering.md "Render-target orientation").
		rl.DrawTexturePro(
			capture_target.texture,
			{0, 0, f32(capture_width), -f32(capture_height)},
			{0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())},
			{0, 0},
			0,
			rl.WHITE,
		)
	}

	// capture_main replaces the normal fit.run entry point under -define.
	capture_main :: proc() {
		capture_dir = os.get_env("INGOT_CAPTURE_DIR", context.allocator)
		if capture_dir == "" do capture_dir = strings.clone("docs/media")
		sequence_flag := os.get_env("INGOT_CAPTURE_SEQUENCE", context.allocator)
		defer delete(sequence_flag)
		capture_sequence = sequence_flag != ""
		// The capture loop owns a real renderer, so the planet renders live.
		showcase.gpu_enabled = true

		flags: rl.ConfigFlags = {.WINDOW_RESIZABLE, .VSYNC_HINT}
		when ODIN_OS == .Darwin do flags += {.WINDOW_HIGHDPI}
		rl.SetConfigFlags(flags)
		rl.InitWindow(
			CAPTURE_WINDOW_WIDTH,
			CAPTURE_WINDOW_HEIGHT,
			"ingot widget gallery (capture)",
		)
		rl.SetTargetFPS(60)
		density := rl.GetWindowScaleDPI().x
		scale_flag := os.get_env("INGOT_CAPTURE_PIXEL_SCALE", context.allocator)
		defer delete(scale_flag)
		if scale_flag != "" {
			parsed, parsed_ok := strconv.parse_f32(scale_flag)
			if !parsed_ok {
				fmt.eprintfln("capture: invalid INGOT_CAPTURE_PIXEL_SCALE %q", scale_flag)
				os.exit(1)
			}
			density = parsed
		}
		capture_pixel_scale = capture_pixel_scale_for(density)
		capture_width = i32(f32(CAPTURE_WIDTH) * capture_pixel_scale + 0.5)
		capture_height = i32(f32(CAPTURE_HEIGHT) * capture_pixel_scale + 0.5)
		fit.session_init(
			&capture_session,
			{user_scale = CAPTURE_UI_SCALE * capture_pixel_scale, semantics_enabled = true},
		)
		capture_target = rl.LoadRenderTexture(capture_width, capture_height)
		if capture_target.texture.id == 0 {
			fmt.eprintln("capture: render target allocation failed")
			os.exit(1)
		}
		fmt.printfln(
			"capture: %s pass into %s at %dx%d px (scale %.2f)",
			"sequence" if capture_sequence else "stills",
			capture_dir,
			capture_width,
			capture_height,
			capture_pixel_scale,
		)
		rl.run(capture_frame)
	}
}
