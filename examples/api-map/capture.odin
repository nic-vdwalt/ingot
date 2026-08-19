#+build !js
// api-map capture mode (-define:INGOT_MAP_CAPTURE=true): a self-driving media
// harness modeled on examples/gallery/capture.odin. It renders the map into a
// fixed-size offscreen render target and writes PNGs so the visual design can
// be reviewed and iterated deterministically instead of eyeballing a live
// window. Two passes exist:
//   - stills (default): each shot pins map_state every frame, so easing can
//     never drift a "mid-animation" shot toward completion between frames.
//   - sequence (INGOT_CAPTURE_SEQUENCE=1): applies the play state once and
//     samples numbered frames while the animation runs free; byte-comparing
//     consecutive frames proves the playback path animates end-to-end.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import fit "ingot:fit"
import rl "ingot:gfx"

// Imports are used only under `when MAP_CAPTURE`; anchor them for normal builds.
_ :: fmt
_ :: os
_ :: strings
_ :: rl
_ :: fit

when MAP_CAPTURE {
	// Fixed output geometry: identical PNGs regardless of host display.
	CAPTURE_WIDTH :: 1600
	CAPTURE_HEIGHT :: 1000
	CAPTURE_WINDOW_WIDTH :: 1280
	CAPTURE_WINDOW_HEIGHT :: 800
	// Stills settle fast because state is re-pinned every frame; the hold only
	// needs to cover font-atlas warmup on the first shot.
	CAPTURE_SETTLE_FRAMES :: 20
	// The narrow and medium shots render into a left strip of the full-size
	// target so one render target serves every shot.
	CAPTURE_NARROW_WIDTH :: 520
	CAPTURE_MEDIUM_WIDTH :: 780
	// Sequence pass: every 5th frame for 150 frames covers several complete
	// stage transitions (progress rate 3.5/s plus the 0.7 s autoplay hold).
	CAPTURE_SEQUENCE_STRIDE :: 5
	CAPTURE_SEQUENCE_FRAMES :: 150
	// Park the cursor where it cannot hover a card or control, so shots do not
	// depend on wherever the operator left the mouse.
	CAPTURE_MOUSE_X :: 4
	CAPTURE_MOUSE_Y :: CAPTURE_HEIGHT - 4

	Map_Shot :: struct {
		file:  string,
		state: Map_State,
		width: i32,
	}

	// One shot per visually distinct playback state, both themes, plus the
	// narrow responsive variant.
	CAPTURE_SHOTS := [?]Map_Shot {
		{"map-idle-dark.png", {dark = true, hovered_node = -1, progress = 1}, CAPTURE_WIDTH},
		{
			"map-stage3-mid.png",
			{
				dark = true,
				hovered_node = -1,
				selected_stage = 2,
				target_stage = 3,
				progress = 0.5,
				playing = true,
			},
			CAPTURE_WIDTH,
		},
		{
			"map-complete-dark.png",
			{
				dark = true,
				hovered_node = -1,
				selected_stage = STAGE_COUNT,
				target_stage = STAGE_COUNT,
				progress = 1,
			},
			CAPTURE_WIDTH,
		},
		{"map-idle-light.png", {dark = false, hovered_node = -1, progress = 1}, CAPTURE_WIDTH},
		{
			"map-narrow-dark.png",
			{dark = true, hovered_node = -1, selected_stage = 4, target_stage = 4, progress = 1},
			CAPTURE_NARROW_WIDTH,
		},
		{
			"map-medium-dark.png",
			{dark = true, hovered_node = -1, selected_stage = 5, target_stage = 5, progress = 1},
			CAPTURE_MEDIUM_WIDTH,
		},
	}

	capture_session: fit.Session
	capture_target: rl.RenderTexture2D
	capture_dir: string
	capture_sequence: bool
	capture_shot_index: int
	capture_shot_frame: int
	capture_tick: int
	capture_written: int

	// capture_apply pins the shot state. Stills re-pin every frame because
	// map_animate advances progress on each rendered frame and would otherwise
	// turn a mid-transition shot into a settled one during the hold.
	capture_apply :: proc() {
		rl.SetMousePosition(CAPTURE_MOUSE_X, CAPTURE_MOUSE_Y)
		if capture_sequence {
			if capture_tick == 0 {
				map_state = {
					dark         = true,
					hovered_node = -1,
					target_stage = 1,
					playing      = true,
				}
				capture_apply_theme()
			}
			return
		}
		assert(capture_shot_index < len(CAPTURE_SHOTS), "capture_apply: shot overrun")
		map_state = CAPTURE_SHOTS[capture_shot_index].state
		capture_apply_theme()
	}

	capture_apply_theme :: proc() {
		assert(capture_session.inner.initialized, "capture theme: session not ready")
		theme := fit.Theme_Dark() if map_state.dark else fit.Theme_Light()
		fit.Session_Set_Theme(&capture_session, theme)
	}

	// capture_write saves the settled target and advances the script; the
	// sequence pass instead samples numbered frames on a fixed stride.
	capture_write :: proc() {
		assert(capture_target.texture.id != 0, "capture_write: no render target")
		if capture_sequence {
			if capture_tick % CAPTURE_SEQUENCE_STRIDE == 0 {
				path := fmt.tprintf("%s/frame_%05d.png", capture_dir, capture_written)
				if !rl.SaveRenderTexturePng(capture_target, path) {
					fmt.eprintfln("capture: failed to write %s", path)
					os.exit(1)
				}
				capture_written += 1
			}
			capture_tick += 1
			if capture_tick >= CAPTURE_SEQUENCE_FRAMES do capture_finish()
			return
		}
		capture_shot_frame += 1
		if capture_shot_frame < CAPTURE_SETTLE_FRAMES do return
		shot := CAPTURE_SHOTS[capture_shot_index]
		path := fmt.tprintf("%s/%s", capture_dir, shot.file)
		if !rl.SaveRenderTexturePng(capture_target, path) {
			fmt.eprintfln("capture: failed to write %s", path)
			os.exit(1)
		}
		fmt.printfln("capture: wrote %s", path)
		capture_written += 1
		capture_shot_index += 1
		capture_shot_frame = 0
		if capture_shot_index >= len(CAPTURE_SHOTS) do capture_finish()
	}

	capture_finish :: proc() {
		assert(capture_dir != "", "capture_finish: no output directory")
		if capture_target.texture.id != 0 do rl.UnloadRenderTexture(capture_target)
		fit.Session_Destroy(&capture_session)
		rl.CloseWindow()
		fmt.printfln("capture: ok (%d files)", capture_written)
		os.exit(0)
	}

	capture_frame :: proc() {
		capture_apply()
		if !fit.Session_Draw(&capture_session, capture_draw) do return
		capture_write()
	}

	capture_draw :: proc(builder: ^fit.Builder, userdata: rawptr) {
		assert(builder != nil, "capture_draw: nil builder")
		_ = userdata
		theme := fit.Theme_Dark() if map_state.dark else fit.Theme_Light()
		background := rl.Color(fit.Theme_Background(theme))
		background.a = 255
		rl.ClearBackground(background)

		width := CAPTURE_WIDTH if capture_sequence else CAPTURE_SHOTS[capture_shot_index].width
		rl.BeginTextureMode(capture_target)
		rl.ClearBackground(background)
		map_build(builder, nil)
		_ = fit.Measure(builder)
		fit.Render_At(builder, {0, 0, width, CAPTURE_HEIGHT})
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

	// map_capture_main replaces the fit.Run entry point under -define, exactly
	// like the gallery harness, so captures never depend on a human closing
	// the window.
	map_capture_main :: proc() {
		capture_dir = os.get_env("INGOT_CAPTURE_DIR", context.allocator)
		if capture_dir == "" do capture_dir = strings.clone("/tmp/api-map-shots")
		sequence_flag := os.get_env("INGOT_CAPTURE_SEQUENCE", context.allocator)
		defer delete(sequence_flag)
		capture_sequence = sequence_flag != ""

		flags: rl.ConfigFlags = {.WINDOW_RESIZABLE, .VSYNC_HINT}
		when ODIN_OS == .Darwin do flags += {.WINDOW_HIGHDPI}
		rl.SetConfigFlags(flags)
		rl.InitWindow(CAPTURE_WINDOW_WIDTH, CAPTURE_WINDOW_HEIGHT, "ingot API map (capture)")
		rl.SetTargetFPS(60)
		fit.Session_Init(&capture_session, {user_scale = 1.0, semantics_enabled = true})
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
