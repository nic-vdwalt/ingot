package main

import "core:math"
import "core:math/linalg"
import "ingot:examples/gallery/imsh"
import fit "ingot:fit"
import gfx "ingot:gfx"

// The planet is cooked once by tools/meshcook (assets/README.md) and embedded,
// so native and web load the identical bounded bytes with no file I/O.
PLANET_MESH :: #load("assets/planet.imsh")
PLANET_ALBEDO :: #load("assets/planet_albedo.jpg")

// Render-target edge cap in device pixels. A 4K window at 200% would
// otherwise ask for a target larger than the viewport is worth.
SHOWCASE_TARGET_EDGE_MAX :: 2048
SHOWCASE_SPEED_DEFAULT :: f32(0.12)
SHOWCASE_SPEED_MAX :: f32(0.6)
// Earth's axial tilt reads as "planet" at a glance without explanation.
SHOWCASE_AXIAL_TILT :: f32(23.4 * math.PI / 180)
SHOWCASE_PITCH_LIMIT :: f32(1.2)
SHOWCASE_ZOOM_MIN :: f32(0.55)
SHOWCASE_ZOOM_MAX :: f32(1.8)
SHOWCASE_ORBIT_RADIANS_PER_PX :: f32(0.008)
SHOWCASE_RESUME_DELAY :: f64(1.5)
SHOWCASE_DOUBLE_CLICK :: f64(0.35)
SHOWCASE_FOVY :: f32(32)

Showcase_Load_Error :: enum u8 {
	None,
	Disabled,
	Decode,
	Mesh,
	Texture,
	Target,
}

SHOWCASE_LOAD_ERROR_NAMES := [Showcase_Load_Error]string {
	.None     = "ready",
	.Disabled = "GPU preview disabled in this build",
	.Decode   = "model asset failed validation",
	.Mesh     = "GPU mesh upload failed",
	.Texture  = "albedo texture failed to load",
	.Target   = "render target unavailable",
}

Lighting_Preset :: enum i32 {
	Day,
	Dusk,
	Studio,
}

LIGHTING_PRESET_NAMES := []string{"Day", "Dusk", "Studio"}

Lighting :: struct {
	key, rim: gfx.Gpu_3D_Light,
}

// Directions are ROS world space (+X forward, +Y left, +Z up) toward the
// light; the camera looks along +X, so a negative X component lights the
// visible hemisphere.
LIGHTING_PRESETS := [Lighting_Preset]Lighting {
	.Day = {
		key = {direction = {-0.55, 0.6, 0.45}, ambient = 0.18, diffuse = 0.95},
		rim = {direction = {0.7, -0.5, 0.2}, ambient = 0, diffuse = 0.35},
	},
	.Dusk = {
		key = {direction = {-0.2, 0.95, -0.05}, ambient = 0.08, diffuse = 0.9},
		rim = {direction = {0.4, -0.7, 0.4}, ambient = 0, diffuse = 0.25},
	},
	.Studio = {
		key = {direction = {-0.6, 0.3, 0.7}, ambient = 0.35, diffuse = 0.7},
		rim = {direction = {-0.3, -0.8, 0.1}, ambient = 0, diffuse = 0.3},
	},
}

Showcase_State :: struct {
	// Only main() and the capture harness enable the GPU path; unit tests use
	// fit.Test_Driver, which has no renderer, and draw the placeholder.
	gpu_enabled:   bool,
	attempted:     bool,
	load_error:    Showcase_Load_Error,
	target:        gfx.Gpu_3D_Target,
	mesh:          gfx.Gpu_Mesh,
	albedo:        gfx.Texture2D,
	info:          imsh.Info,
	center:        [3]f32,
	radius:        f32,
	yaw:           f32,
	pitch:         f32,
	zoom:          f32,
	auto_rotate:   bool,
	speed:         f32,
	lighting:      i32,
	resume_at:     f64,
	last_click_at: f64,
	// Capture builds pin the yaw so stills and sequences are reproducible.
	fixed_yaw:     Maybe(f32),
	target_w:      i32,
	target_h:      i32,
	speed_slider:  fit.Slider_State,
	toggle_motion: fit.Control_Motion_State,
	tabs_motion:   fit.Control_Motion_State,
}

showcase := Showcase_State {
	pitch       = 0.18,
	zoom        = 1,
	auto_rotate = true,
	speed       = SHOWCASE_SPEED_DEFAULT,
}

showcase_ready :: proc(state: ^Showcase_State) -> bool {
	assert(state != nil, "showcase_ready: nil state")
	return state.attempted && state.load_error == .None
}

// showcase_decode validates and de-quantizes the embedded asset into caller
// buffers. Kept separate from GPU upload so tests can prove the committed
// bytes are well formed without a renderer.
showcase_decode :: proc(
	data: []u8,
	allocator := context.allocator,
) -> (
	vertices: []gfx.Gpu_3D_Vertex,
	indices: []u32,
	info: imsh.Info,
	err: imsh.Error,
) {
	info = imsh.decode_info(data) or_return
	assert(info.vertex_count <= imsh.VERTEX_MAX, "showcase_decode: unchecked vertex count")
	cooked := make([]imsh.Vertex, info.vertex_count, context.temp_allocator)
	imsh.decode_vertices(data, info, cooked) or_return
	indices = make([]u32, info.index_count, allocator)
	if index_err := imsh.decode_indices(data, info, indices); index_err != .None {
		delete(indices, allocator)
		return nil, nil, {}, index_err
	}
	vertices = make([]gfx.Gpu_3D_Vertex, info.vertex_count, allocator)
	for vertex, index in cooked {
		vertices[index] = {
			position = vertex.position,
			normal   = vertex.normal,
			scalar   = vertex.scalar,
			uv       = vertex.uv,
		}
	}
	return vertices, indices, info, .None
}

@(private = "file")
showcase_load_texture :: proc(state: ^Showcase_State) -> bool {
	assert(state != nil, "showcase_load_texture: nil state")
	assert(len(PLANET_ALBEDO) > 0, "showcase_load_texture: empty embedded texture")
	image := gfx.LoadImageFromMemory(".jpg", raw_data(PLANET_ALBEDO), i32(len(PLANET_ALBEDO)))
	if image.data == nil do return false
	defer gfx.UnloadImage(image)
	state.albedo = gfx.LoadTextureFromImage(image)
	if state.albedo.id == 0 do return false
	gfx.SetTextureFilter(state.albedo, .BILINEAR)
	return true
}

// showcase_init runs once, lazily, on the first Showcase frame. Any failure
// is an operating error recorded in load_error; the section then shows the
// placeholder instead of a broken viewport.
showcase_init :: proc(state: ^Showcase_State) {
	assert(state != nil, "showcase_init: nil state")
	if state.attempted do return
	state.attempted = true
	if !state.gpu_enabled {
		state.load_error = .Disabled
		return
	}
	vertices, indices, info, decode_err := showcase_decode(PLANET_MESH)
	if decode_err != .None {
		state.load_error = .Decode
		return
	}
	defer delete(vertices)
	defer delete(indices)
	state.info = info
	state.center = (info.bounds_min + info.bounds_max) * 0.5
	state.radius = max(linalg.length(info.bounds_max - info.bounds_min) * 0.5, 1e-3)
	mesh, mesh_ok := gfx.create_gpu_mesh(vertices, indices, .Triangles)
	if !mesh_ok {
		state.load_error = .Mesh
		return
	}
	state.mesh = mesh
	if !showcase_load_texture(state) {
		state.load_error = .Texture
		return
	}
	antialiasing := gfx.Gpu_3D_Antialiasing.MSAA_4X
	// Matches box3d_advanced: the web build keeps single-sample targets.
	when ODIN_OS == .JS do antialiasing = .None
	target, target_ok := gfx.create_gpu_3d_target(64, 64, antialiasing)
	if !target_ok {
		state.load_error = .Target
		return
	}
	state.target = target
	state.target_w, state.target_h = 64, 64
}

showcase_destroy :: proc(state: ^Showcase_State) {
	assert(state != nil, "showcase_destroy: nil state")
	if !state.attempted do return
	if state.mesh.id != 0 do gfx.destroy_gpu_mesh(&state.mesh)
	if state.albedo.id != 0 do gfx.UnloadTexture(state.albedo)
	if state.target.texture.texture.id != 0 do gfx.destroy_gpu_3d_target(&state.target)
	state.albedo = {}
	state.attempted = false
}

showcase_reset_view :: proc(state: ^Showcase_State) {
	assert(state != nil, "showcase_reset_view: nil state")
	state.yaw = 0
	state.pitch = 0.18
	state.zoom = 1
	state.resume_at = 0
}

// showcase_animating reports whether the next frame differs from this one,
// which is the only time the event-waiting gallery needs another frame.
showcase_animating :: proc(state: ^Showcase_State) -> bool {
	assert(state != nil, "showcase_animating: nil state")
	_, pinned := state.fixed_yaw.?
	return showcase_ready(state) && state.auto_rotate && !reduced_motion && !pinned
}

@(private = "file")
showcase_input :: proc(surface: ^fit.Surface, state: ^Showcase_State, rect: fit.Rect) -> bool {
	assert(surface != nil && state != nil, "showcase_input: nil argument")
	assert(rect.w > 0 && rect.h > 0, "showcase_input: empty rect")
	area := fit.Float_Rect{f32(rect.x), f32(rect.y), f32(rect.w), f32(rect.h)}
	interaction := fit.interact(surface, area)
	now := fit.surface_timestamp(surface)
	changed := false
	if interaction.held {
		delta := fit.surface_mouse_delta(surface)
		if delta != {} {
			state.yaw += f32(delta.x) * SHOWCASE_ORBIT_RADIANS_PER_PX
			state.pitch += f32(delta.y) * SHOWCASE_ORBIT_RADIANS_PER_PX
			state.resume_at = now + SHOWCASE_RESUME_DELAY
			changed = true
		}
	}
	if interaction.clicked {
		if now - state.last_click_at < SHOWCASE_DOUBLE_CLICK {
			showcase_reset_view(state)
			changed = true
		}
		state.last_click_at = now
	}
	if interaction.hovered {
		wheel := fit.surface_wheel_v(surface)
		if wheel.y != 0 {
			state.zoom *= 1 - f32(wheel.y) * 0.08
			changed = true
		}
		step := f32(0.05)
		if fit.key_pressed(surface, .Left) do state.yaw -= step * 3
		if fit.key_pressed(surface, .Right) do state.yaw += step * 3
		if fit.key_pressed(surface, .Up) do state.pitch -= step
		if fit.key_pressed(surface, .Down) do state.pitch += step
	}
	state.pitch = clamp(state.pitch, -SHOWCASE_PITCH_LIMIT, SHOWCASE_PITCH_LIMIT)
	state.zoom = clamp(state.zoom, SHOWCASE_ZOOM_MIN, SHOWCASE_ZOOM_MAX)
	return changed || interaction.held || now < state.resume_at
}

@(private = "file")
showcase_advance :: proc(surface: ^fit.Surface, state: ^Showcase_State) {
	assert(surface != nil && state != nil, "showcase_advance: nil argument")
	if yaw, pinned := state.fixed_yaw.?; pinned {
		state.yaw = yaw
		return
	}
	if !state.auto_rotate || reduced_motion do return
	if fit.surface_timestamp(surface) < state.resume_at do return
	dt := clamp(fit.surface_frame_time(surface), 0, 0.1)
	state.yaw = math.mod(state.yaw + state.speed * dt, 2 * math.PI)
}

@(private = "file")
showcase_camera :: proc(state: ^Showcase_State) -> gfx.Camera3D {
	assert(state != nil && state.radius > 0, "showcase_camera: model not loaded")
	half := SHOWCASE_FOVY * 0.5 * math.PI / 180
	distance := state.radius / math.sin(half) * 1.08 * state.zoom
	return {
		position = {-distance * math.cos(state.pitch), 0, distance * math.sin(state.pitch)},
		target = {0, 0, 0},
		up = gfx.CAMERA_WORLD_UP,
		fovy = SHOWCASE_FOVY,
		projection = .PERSPECTIVE,
		near_plane = distance * 0.05,
		far_plane = distance * 4,
	}
}

@(private = "file")
showcase_resize :: proc(surface: ^fit.Surface, state: ^Showcase_State, rect: fit.Rect) -> bool {
	assert(surface != nil && state != nil, "showcase_resize: nil argument")
	assert(rect.w > 0 && rect.h > 0, "showcase_resize: empty rect")
	dpi := max(fit.surface_dpi_scale(surface), 1)
	width := clamp(i32(f32(rect.w) * dpi + 0.5), 1, SHOWCASE_TARGET_EDGE_MAX)
	height := clamp(i32(f32(rect.h) * dpi + 0.5), 1, SHOWCASE_TARGET_EDGE_MAX)
	if width == state.target_w && height == state.target_h do return true
	if !gfx.resize_gpu_3d_target(&state.target, width, height) do return false
	state.target_w, state.target_h = width, height
	return true
}

// showcase_render encodes the planet pass into the offscreen target. It runs
// inside the canvas callback: the pass submits on end_gpu_3d, ahead of the
// frame's 2D pass, so the texture command pushed afterwards samples the
// finished image.
@(private = "file")
showcase_render :: proc(state: ^Showcase_State) {
	assert(showcase_ready(state), "showcase_render: not ready")
	assert(state.mesh.id != 0, "showcase_render: missing mesh")
	pass, ok := gfx.begin_gpu_3d(&state.target, showcase_camera(state))
	if !ok do return
	preset := Lighting_Preset(clamp(state.lighting, 0, i32(len(Lighting_Preset)) - 1))
	gfx.set_gpu_3d_light(&pass, LIGHTING_PRESETS[preset].key)
	gfx.set_gpu_3d_secondary_light(&pass, LIGHTING_PRESETS[preset].rim)
	center := state.center
	model :=
		linalg.matrix4_rotate_f32(SHOWCASE_AXIAL_TILT, {1, 0, 0}) *
		linalg.matrix4_rotate_f32(state.yaw, {0, 0, 1}) *
		gfx.MatrixTranslate(-center.x, -center.y, -center.z)
	gfx.draw_gpu_mesh(&pass, state.mesh, model, {color = gfx.WHITE, texture = state.albedo})
	gfx.end_gpu_3d(&pass)
}

// showcase_viewport draws the live planet into `rect`, or the placeholder
// when the GPU path is unavailable. It requests another frame only while the
// model is moving, so the gallery idles when nothing animates.
showcase_viewport :: proc(surface: ^fit.Surface, state: ^Showcase_State, rect: fit.Rect) {
	assert(surface != nil && state != nil, "showcase_viewport: nil argument")
	assert(rect.w >= 0 && rect.h >= 0, "showcase_viewport: negative rect")
	if rect.w <= 0 || rect.h <= 0 do return
	top, bottom := fit.cull_bounds(surface)
	if rect.y + rect.h < top || rect.y > bottom do return
	showcase_init(state)
	if !showcase_ready(state) {
		showcase_placeholder(surface, state, rect)
		return
	}
	interacting := showcase_input(surface, state, rect)
	showcase_advance(surface, state)
	if !showcase_resize(surface, state, rect) {
		state.load_error = .Target
		showcase_placeholder(surface, state, rect)
		return
	}
	showcase_render(state)
	texture := gfx.gpu_3d_target_color_texture(&state.target)
	source := fit.Float_Rect{0, 0, f32(state.target_w), f32(state.target_h)}
	dest := fit.Float_Rect{f32(rect.x), f32(rect.y), f32(rect.w), f32(rect.h)}
	fit.surface_draw_texture(surface, texture.id, source, dest)
	if interacting || showcase_animating(state) do fit.request_redraw_in(surface, 0)
}

showcase_placeholder :: proc(surface: ^fit.Surface, state: ^Showcase_State, rect: fit.Rect) {
	assert(surface != nil && state != nil, "showcase_placeholder: nil argument")
	assert(rect.w > 0 && rect.h > 0, "showcase_placeholder: empty rect")
	side := min(fit.px(surface, 56), rect.w / 2, rect.h / 2)
	line_h := fit.get_metrics(surface).line_height
	block := side + line_h * 2
	icon := fit.Rect{rect.x + (rect.w - side) / 2, rect.y + (rect.h - block) / 2, side, side}
	if side > 0 do fit.surface_icon(surface, .Globe, icon, .Muted)
	text_w := max(rect.w - fit.px(surface, 24), 0)
	text_x := rect.x + fit.px(surface, 12)
	y := icon.y + side + fit.px(surface, 6)
	fit.surface_text_truncated(
		surface,
		"3D preview unavailable",
		text_x,
		y,
		text_w,
		.Body,
		.Secondary,
	)
	reason := SHOWCASE_LOAD_ERROR_NAMES[state.load_error]
	fit.surface_text_truncated(surface, reason, text_x, y + line_h, text_w, .Note, .Muted)
}
