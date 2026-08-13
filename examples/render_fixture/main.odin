package main

import "core:fmt"
import "core:strings"
import rl "ingot:gfx"
import "ingot:ui"
import "ingot:ui_gfx"

FONT_TTF := #load("../../assets/fonts/JetBrainsMono-Regular.ttf")
FIXTURE_CPS := [?]rune {
	' ',
	':',
	'A',
	'B',
	'C',
	'F',
	'G',
	'P',
	'R',
	'T',
	'U',
	'a',
	'c',
	'e',
	'f',
	'g',
	'i',
	'm',
	'n',
	'o',
	'r',
	's',
	't',
	'x',
}

font: rl.Font
font_ready: bool
source_texture: rl.Texture2D
primary_rt: rl.RenderTexture2D
ping_rt: rl.RenderTexture2D
pong_rt: rl.RenderTexture2D
gpu_target: rl.Gpu_3D_Target
gpu_sphere: rl.Gpu_Mesh
gpu_textured_quad: rl.Gpu_Mesh
gpu_overlay_line: rl.Gpu_Mesh
gpu_overlay_points: rl.Gpu_Mesh
resources_ready: bool
ui_session: ui_gfx.Session
ui_frame: ^ui.Ui_Frame
retina_input: ui.Text_Input_State
retina_text: strings.Builder

main :: proc() {
	rl.InitWindow(960, 720, "ingot renderer fixture")
	rl.SetTargetFPS(60)
	ui_gfx.session_init(&ui_session, {semantics_enabled = true})
	retina_text = strings.builder_make()
	strings.write_string(&retina_text, "Runtime text input")
	rl.run(frame)
	when ODIN_OS != .JS {
		ui.text_input_state_destroy(&retina_input)
		strings.builder_destroy(&retina_text)
		ui_gfx.session_destroy(&ui_session)
		rl.CloseWindow()
	}
}

frame :: proc() {
	ensure_resources()
	frame, acquired := ui_gfx.session_acquire_frame(&ui_session)
	if !acquired do return
	ui_frame = frame.ui
	rl.ClearBackground(rl.Color{22, 24, 32, 255})
	if resources_ready {
		draw_render_targets()
		draw_main_fixture()
		draw_stream_lifetime_stress()
		draw_retina_fixture()
	}
	ui_gfx.session_present_frame(&frame)
	ui_frame = nil

	when rl.RENDER_STATS_ENABLED {
		@(static) reported := false
		if !reported {
			stats := rl.renderer_stats()
			if stats.frame_index > 0 {
				fmt.println("renderer fixture baseline:", stats)
				reported = true
			}
		}
	}
}

ensure_resources :: proc() {
	if resources_ready do return
	if !font_ready {
		font = rl.LoadFontFromMemory(
			".ttf",
			raw_data(FONT_TTF),
			i32(len(FONT_TTF)),
			20,
			raw_data(FIXTURE_CPS[:]),
			i32(len(FIXTURE_CPS)),
		)
		font_ready = font.glyphCount > 0
	}

	pixels := [16]u8{255, 255, 255, 255, 255, 80, 80, 255, 80, 220, 120, 255, 80, 120, 255, 255}
	image := rl.Image {
		data    = raw_data(pixels[:]),
		width   = 2,
		height  = 2,
		mipmaps = 1,
		format  = .UNCOMPRESSED_R8G8B8A8,
	}
	source_texture = rl.LoadTextureFromImage(image)
	primary_rt = rl.LoadRenderTexture(256, 160)
	ping_rt = rl.LoadRenderTexture(128, 80)
	pong_rt = rl.LoadRenderTexture(128, 80)
	target_ok, sphere_ok: bool
	gpu_target, target_ok = rl.create_gpu_3d_target(384, 240)
	gpu_sphere, sphere_ok = rl.create_sphere_mesh(1, 16, 24)
	fixture_meshes_ok := ensure_gpu_fixture_meshes()
	resources_ready =
		font_ready &&
		source_texture.id != 0 &&
		primary_rt.texture.id != 0 &&
		ping_rt.texture.id != 0 &&
		pong_rt.texture.id != 0 &&
		target_ok &&
		sphere_ok &&
		fixture_meshes_ok
}

// ensure_gpu_fixture_meshes creates the smallest geometry that exercises
// textured triangles plus coplanar line/point overlays. Keeping the fixture
// tiny makes backend validation failures attributable to pipeline state, not
// geometry volume.
ensure_gpu_fixture_meshes :: proc() -> bool {
	vertices := [?]rl.Gpu_3D_Vertex {
		{position = {0, -1, -1}, normal = {1, 0, 0}, uv = {0, 0}},
		{position = {0, 1, -1}, normal = {1, 0, 0}, uv = {1, 0}},
		{position = {0, -1, 1}, normal = {1, 0, 0}, uv = {0, 1}},
		{position = {0, 1, 1}, normal = {1, 0, 0}, uv = {1, 1}},
	}
	triangles := [?]u32{0, 1, 2, 1, 3, 2}
	lines := [?]u32{0, 3, 1, 2}
	points := [?]u32{0, 1, 2, 3}
	quad_ok, line_ok, point_ok: bool
	gpu_textured_quad, quad_ok = rl.create_gpu_mesh(vertices[:], triangles[:], .Triangles)
	gpu_overlay_line, line_ok = rl.create_gpu_mesh(vertices[:], lines[:], .Lines)
	gpu_overlay_points, point_ok = rl.create_gpu_mesh(vertices[:], points[:], .Points)
	return quad_ok && line_ok && point_ok
}

draw_render_targets :: proc() {
	camera := rl.Camera3D {
		position   = {-5, 0, 0},
		target     = {0, 0, 0},
		up         = rl.CAMERA_WORLD_UP,
		fovy       = 45,
		projection = .PERSPECTIVE,
	}
	gpu_pass, ok := rl.begin_gpu_3d(&gpu_target, camera)
	if ok {
		// Non-default side light proves pass-level lighting reaches the shader;
		// the direction remains fixed in ROS world space across model transforms.
		rl.set_gpu_3d_light(
			&gpu_pass,
			{direction = {-0.2, 0.8, 0.5}, ambient = 0.35, diffuse = 0.65},
		)
		// ROS basis: +X forward, +Y left, +Z up. The blue sphere at x=0
		// must occlude the orange sphere at x=1 where they overlap.
		rl.draw_gpu_mesh(
			&gpu_pass,
			gpu_sphere,
			rl.MatrixTranslate(0, 0.65, 0),
			{color = rl.Color{80, 160, 255, 255}},
		)
		rl.draw_gpu_mesh(
			&gpu_pass,
			gpu_sphere,
			rl.MatrixTranslate(1, -0.65, 0),
			{color = rl.Color{255, 120, 80, 255}},
		)
		// Cull proof: a sphere behind the camera (x=-7, camera at x=-5
		// looking toward +X) must contribute no pixels - validates clip-
		// space rejection. If green appears anywhere the projection broke.
		rl.draw_gpu_mesh(
			&gpu_pass,
			gpu_sphere,
			rl.MatrixTranslate(-7, 0, 0),
			{color = rl.Color{80, 255, 120, 255}},
		)
		// A real texture bind on a UV mesh validates group(1). Coplanar line
		// and point draws use shader depth nudge because WebGPU pipeline
		// depthBias cannot cover their topologies.
		fixture_model := rl.MatrixTranslate(2.4, 0, 0)
		rl.draw_gpu_mesh(
			&gpu_pass,
			gpu_textured_quad,
			fixture_model,
			{color = rl.WHITE, texture = source_texture},
		)
		rl.draw_gpu_mesh(
			&gpu_pass,
			gpu_overlay_line,
			fixture_model,
			{color = rl.Color{255, 240, 80, 255}, depth_nudge = 0.0005},
		)
		rl.draw_gpu_mesh(
			&gpu_pass,
			gpu_overlay_points,
			fixture_model,
			{color = rl.Color{255, 80, 220, 255}, depth_nudge = 0.001},
		)
		// 300 instances cross the 256-transform uniform chunk boundary. Their
		// small scale keeps the complete grid inside the fixture viewport.
		transforms: [300]rl.Matrix
		for &transform, index in transforms {
			row := index / 20
			column := index % 20
			transform =
				rl.MatrixTranslate(0.8, (f32(column) - 9.5) * 0.08, (f32(row) - 7) * 0.08) *
				rl.MatrixScale(0.025, 0.025, 0.025)
		}
		rl.draw_gpu_mesh_instanced(
			&gpu_pass,
			gpu_sphere,
			transforms[:],
			{color = rl.Color{180, 235, 255, 255}},
		)
		rl.end_gpu_3d(&gpu_pass)
	}

	rl.BeginTextureMode(primary_rt)
	rl.ClearBackground(rl.Color{12, 16, 28, 255})
	rl.DrawRectangle(8, 8, 240, 144, rl.Color{38, 50, 82, 255})
	rl.DrawTriangle({24, 136}, {128, 20}, {232, 136}, rl.Color{250, 175, 65, 255})
	rl.BeginScissorMode(96, 48, 64, 64)
	rl.DrawCircle(128, 80, 54, rl.Color{90, 210, 150, 220})
	rl.EndScissorMode()
	rl.DrawTexturePro(source_texture, {0, 0, 2, 2}, {176, 16, 64, 64}, {0, 0}, 0, rl.WHITE)
	rl.EndTextureMode()

	rl.BeginTextureMode(ping_rt)
	rl.ClearBackground(rl.BLANK)
	rl.DrawTexturePro(primary_rt.texture, {0, 0, 256, 160}, {0, 0, 128, 80}, {0, 0}, 0, rl.WHITE)
	rl.EndTextureMode()

	rl.BeginTextureMode(pong_rt)
	rl.ClearBackground(rl.BLANK)
	rl.DrawTexturePro(ping_rt.texture, {0, 0, 128, 80}, {0, 0, 128, 80}, {0, 0}, 0, rl.WHITE)
	rl.EndTextureMode()
}

draw_main_fixture :: proc() {
	rl.DrawRectangle(24, 24, 280, 180, rl.Color{45, 52, 72, 255})
	rl.DrawTriangle({40, 184}, {164, 40}, {288, 184}, rl.Color{238, 94, 100, 255})
	rl.DrawCircle(164, 120, 48, rl.Color{70, 185, 230, 210})

	rl.BeginScissorMode(332, 24, 280, 180)
	rl.DrawRectangle(300, 0, 360, 240, rl.Color{60, 72, 108, 255})
	rl.DrawCircle(470, 114, 120, rl.Color{235, 168, 72, 255})
	rl.EndScissorMode()

	rl.DrawTexturePro(
		primary_rt.texture,
		{0, 0, 256, -160},
		{24, 236, 384, 240},
		{0, 0},
		0,
		rl.WHITE,
	)
	rl.draw_gpu_3d_target(&gpu_target, {432, 236, 384, 240}, rl.WHITE)

	if font_ready {
		rl.DrawTextEx(font, "FIXTURE: 2D / RT / SCISSOR", {24, 504}, 20, 1, rl.RAYWHITE)
	}
}

draw_retina_fixture :: proc() {
	style := ui.ui_frame_theme(ui_frame)
	metrics := ui.ui_frame_metrics(ui_frame)
	label: cstring = "RETINA 1x/2x RUNTIME TEXT"
	width := ui.measure_text_frame(ui_frame, label, metrics.FONT_SIZE_BODY)
	x, y := i32(632), i32(506)
	ui.draw_text_frame(ui_frame, label, x, y, metrics.FONT_SIZE_BODY, style.fg_primary)
	rl.DrawRectangleLines(
		x - 2,
		y - 2,
		width + 4,
		metrics.LINE_HEIGHT,
		ui_gfx.color_to_gfx(style.fg_accent),
	)
	ui.draw_text_truncated_frame(
		ui_frame,
		"Truncation uses the same runtime atlas and measurement cache",
		x,
		y + metrics.LINE_HEIGHT,
		280,
		metrics.FONT_SIZE_NOTE,
		style.fg_secondary,
	)
	ui.text_input_box(
		ui_frame,
		{rect = {x, y + metrics.LINE_HEIGHT * 2, 280, 32}, active = false},
		&retina_text,
		&retina_input,
	)
}

draw_stream_lifetime_stress :: proc() {
	for _ in 0 ..< 70 {
		rl.BeginTextureMode(ping_rt)
		rl.DrawRectangle(0, 0, 1, 1, rl.WHITE)
		rl.EndTextureMode()
	}

	// Living documentation for ui.Layout: the 12x4 chip grid below is laid
	// out with rows carved from a column instead of hand-computed offsets.
	// Cell geometry matches the original arithmetic exactly:
	// x = 24 + col*74, y = 548 + row*34, chip 24px + label 44px, 10px gap.
	l: ui.Layout
	ui.layout_begin(&l, 24, 548, 12 * 74, 4 * 34, gap = 10)
	for _ in 0 ..< 4 {
		ui.push_row(&l, 24, gap = 2)
		for _ in 0 ..< 12 {
			icon := ui.next(&l, 24)
			label := ui.next(&l, 44)
			ui.spacer(&l, 2) // pad to the 74px cell pitch (24+2+44+2+2)
			rl.DrawTexturePro(
				source_texture,
				{0, 0, 2, 2},
				{f32(icon.x), f32(icon.y), f32(icon.w), f32(icon.h)},
				{0, 0},
				0,
				rl.WHITE,
			)
			rl.DrawRectangle(label.x, label.y, label.w, label.h, rl.Color{48, 58, 82, 210})
			rl.BeginScissorMode(label.x + 2, label.y + 2, label.w - 4, label.h - 4)
			rl.DrawRectangle(label.x, label.y, label.w, label.h, rl.Color{90, 170, 230, 96})
			rl.EndScissorMode()
		}
		ui.layout_pop(&l)
	}
	ui.layout_end(&l)

	rl.DrawRectangle(24, 684, 912, 28, rl.Color{28, 32, 44, 255})
	if font_ready {
		rl.DrawTextEx(font, "STABLE UI OVER STREAM STRESS", {36, 688}, 16, 1, rl.RAYWHITE)
	}
}
