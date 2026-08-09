package main

import "core:fmt"
import "core:math/linalg"
import "core:math/rand"
import rl "ingot:gfx"
import b3 "vendor:box3d"

BOX_MAX :: 64
BOX_COUNT :: 25
FIXED_DT :: f32(1.0 / 60.0)
PHYSICS_SUBSTEPS :: 4
MAX_STEPS_PER_FRAME :: 8
MAX_FRAME_DT :: f32(0.25)
SCREEN_WIDTH :: 1280
SCREEN_HEIGHT :: 720

BOX_COLORS := [6]rl.Color {
	{92, 176, 255, 255},
	{255, 151, 92, 255},
	{132, 218, 146, 255},
	{223, 126, 214, 255},
	{247, 213, 105, 255},
	{133, 134, 235, 255},
}

Box :: struct {
	body:         b3.BodyId,
	half_extents: [3]f32,
	transform:    rl.Matrix,
}

State :: struct {
	world:           b3.WorldId,
	floor:           b3.BodyId,
	boxes:           [BOX_MAX]Box,
	box_count:       u32,
	accumulator:     f32,
	fixed_steps:     u32,
	dropped_steps:   u64,
	paused:          bool,
	step_once:       bool,
	ready:           bool,
	target:          rl.Gpu_3D_Target,
	resize_failures: u64,
	cube:            rl.Gpu_Mesh,
	cube_edges:      rl.Gpu_Mesh,
	camera:          rl.Camera3D,
	orbit:           rl.Orbit_Camera_State,
	orbit_config:    rl.Orbit_Camera_Config,
	graphics_ready:  bool,
}

state: State

main :: proc() {
	rl.SetConfigFlags({.VSYNC_HINT, .WINDOW_RESIZABLE})
	rl.InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "ingot + box3d stack")
	rl.SetTargetFPS(60)
	if !graphics_create(&state) || !physics_create(&state) {
		shutdown(&state)
		return
	}
	rl.run(frame)
	shutdown(&state)
}

graphics_create :: proc(value: ^State) -> bool {
	assert(value != nil, "graphics_create: nil state")
	assert(!value.graphics_ready, "graphics_create: graphics already ready")
	value.camera = {
		position   = {-14, -14, 10},
		target     = {0, 0, 3},
		up         = rl.CAMERA_WORLD_UP,
		fovy       = 42,
		projection = .PERSPECTIVE,
	}
	value.orbit, _ = rl.orbit_camera_from_camera(value.camera)
	value.orbit_config = rl.orbit_camera_config_default()
	value.orbit_config.min_distance = 10
	value.orbit_config.max_distance = 128
	target_ok, cube_ok, edges_ok: bool
	value.target, target_ok = rl.create_gpu_3d_target(
		rl.GetRenderWidth(),
		rl.GetRenderHeight(),
		.MSAA_4X,
	)
	value.cube, cube_ok = rl.create_cube_mesh()
	value.cube_edges, edges_ok = rl.create_cube_edge_mesh()
	value.graphics_ready = target_ok && cube_ok && edges_ok
	return value.graphics_ready
}

graphics_target_resize :: proc(value: ^State) {
	assert(value != nil, "graphics_target_resize: nil state")
	if !value.graphics_ready do return
	result := rl.resize_gpu_3d_target_to_render_size(&value.target)
	if result == .Failed do value.resize_failures += 1
}

physics_create :: proc(value: ^State) -> bool {
	assert(value != nil, "physics_create: nil state")
	assert(BOX_COUNT <= BOX_MAX, "physics_create: box capacity too small")
	world_def := b3.DefaultWorldDef()
	world_def.gravity = {0, 0, -10}
	value.world = b3.CreateWorld(world_def)
	if !b3.World_IsValid(value.world) do return false
	if !floor_create(value) {
		physics_destroy(value)
		return false
	}
	for index in 0 ..< BOX_COUNT {
		if !box_create(value, index) {
			physics_destroy(value)
			return false
		}
	}
	value.ready = true
	box_transforms_sync(value)
	assert(value.box_count == BOX_COUNT, "physics_create: incomplete stack")
	return true
}

floor_create :: proc(value: ^State) -> bool {
	assert(value != nil, "floor_create: nil state")
	assert(b3.World_IsValid(value.world), "floor_create: invalid world")
	body_def := b3.DefaultBodyDef()
	body_def.type = .staticBody
	body_def.position = {0, 0, -10}
	value.floor = b3.CreateBody(value.world, body_def)
	if !b3.Body_IsValid(value.floor) do return false
	shape_def := b3.DefaultShapeDef()
	hull := b3.MakeBoxHull(50, 50, 10)
	shape := b3.CreateHullShape(value.floor, shape_def, &hull.base)
	return b3.Shape_IsValid(shape)
}

box_create :: proc(value: ^State, index: int) -> bool {
	assert(value != nil, "box_create: nil state")
	assert(index >= 0 && index < BOX_COUNT, "box_create: index out of range")
	half_extents := [3]f32{1, 1, 1}
	body_def := b3.DefaultBodyDef()
	body_def.type = .dynamicBody
	body_def.position = {
		rand.float32_range(-15, 15), // random forward position
		rand.float32_range(-15, 15), // random lateral position
		rand.float32_range(10, 30), // random height
	}
	body := b3.CreateBody(value.world, body_def)
	if !b3.Body_IsValid(body) do return false
	shape_def := b3.DefaultShapeDef()
	shape_def.density = 1
	shape_def.baseMaterial.friction = 0.3
	hull := b3.MakeCubeHull(1)
	shape := b3.CreateHullShape(body, shape_def, &hull.base)
	if !b3.Shape_IsValid(shape) {
		b3.DestroyBody(body)
		return false
	}
	value.boxes[index] = {
		body         = body,
		half_extents = half_extents,
	}
	value.box_count += 1
	return true
}

physics_update :: proc(value: ^State, frame_dt: f32) {
	assert(value != nil, "physics_update: nil state")
	assert(value.box_count <= BOX_MAX, "physics_update: box count overflow")
	value.fixed_steps = 0
	if !value.ready do return
	if value.paused && !value.step_once do return
	if value.step_once {
		b3.World_Step(value.world, FIXED_DT, PHYSICS_SUBSTEPS)
		value.fixed_steps = 1
		value.step_once = false
		box_transforms_sync(value)
		return
	}
	value.accumulator += clamp(frame_dt, 0, MAX_FRAME_DT)
	for _ in 0 ..< MAX_STEPS_PER_FRAME {
		if value.accumulator < FIXED_DT do break
		b3.World_Step(value.world, FIXED_DT, PHYSICS_SUBSTEPS)
		value.accumulator -= FIXED_DT
		value.fixed_steps += 1
	}
	if value.accumulator >= FIXED_DT {
		dropped := u64(value.accumulator / FIXED_DT)
		value.accumulator -= f32(dropped) * FIXED_DT
		value.dropped_steps += dropped
	}
	box_transforms_sync(value)
}

box_transforms_sync :: proc(value: ^State) {
	assert(value != nil, "box_transforms_sync: nil state")
	assert(value.box_count <= BOX_MAX, "box_transforms_sync: box count overflow")
	for &box in value.boxes[:value.box_count] {
		if !b3.Body_IsValid(box.body) do continue
		transform := b3.Body_GetTransform(box.body)
		box.transform = linalg.matrix4_from_trs_f32(transform.p, transform.q, box.half_extents * 2)
	}
}

physics_input :: proc(value: ^State) {
	assert(value != nil, "physics_input: nil state")
	assert(value.box_count <= BOX_MAX, "physics_input: box count overflow")
	if rl.IsKeyPressed(.SPACE) do value.paused = !value.paused
	if rl.IsKeyPressed(.N) && value.paused do value.step_once = true
	if rl.IsKeyPressed(.R) {
		paused := value.paused
		physics_destroy(value)
		if !physics_create(value) {
			value.paused = paused
			return
		}
		value.paused = paused
	}
}

camera_update :: proc(value: ^State, frame_dt: f32) {
	assert(value != nil, "camera_update: nil state")
	assert(value.orbit.distance > 0, "camera_update: invalid distance")
	input: rl.Orbit_Camera_Input
	if rl.IsKeyDown(.LEFT) || rl.IsKeyDown(.A) do input.rotate_rate.x += 1
	if rl.IsKeyDown(.RIGHT) || rl.IsKeyDown(.D) do input.rotate_rate.x -= 1
	if rl.IsKeyDown(.UP) || rl.IsKeyDown(.W) do input.zoom_rate -= 1
	if rl.IsKeyDown(.DOWN) || rl.IsKeyDown(.S) do input.zoom_rate += 1
	if rl.IsMouseButtonDown(.LEFT) do input.pointer_drag = -rl.GetMouseDelta()
	input.scroll = rl.GetMouseWheelMoveV().y
	rl.update_orbit_camera(&value.orbit, input, value.orbit_config, frame_dt)
	rl.orbit_camera_apply(value.orbit, &value.camera)
}

frame :: proc() {
	frame_dt := clamp(rl.GetFrameTime(), 0, MAX_FRAME_DT)
	physics_input(&state)
	camera_update(&state, frame_dt)
	physics_update(&state, frame_dt)
	graphics_target_resize(&state)
	draw_world(&state)
	draw_screen(&state)
}

draw_world :: proc(value: ^State) {
	assert(value != nil, "draw_world: nil state")
	assert(value.box_count <= BOX_MAX, "draw_world: box count overflow")
	pass, ok := rl.begin_gpu_3d(&value.target, value.camera)
	if !ok do return
	rl.set_gpu_3d_light(&pass, {{-0.4, 0.5, 0.8}, 0.15, 0.85})
	floor_transform := rl.MatrixTranslate(0, 0, -2) * rl.MatrixScale(100, 100, 4)
	rl.draw_gpu_mesh(&pass, value.cube, floor_transform, {color = rl.LIGHTGRAY})
	for box, index in value.boxes[:value.box_count] {
		color := BOX_COLORS[index % len(BOX_COLORS)]
		rl.draw_gpu_mesh(&pass, value.cube, box.transform, {color = color})
		rl.draw_gpu_mesh(
			&pass,
			value.cube_edges,
			box.transform,
			{color = {24, 28, 36, 255}, style = .Opaque_Overlay, depth_nudge = 0.0005},
		)
	}
	rl.end_gpu_3d(&pass)
}

draw_screen :: proc(value: ^State) {
	assert(value != nil, "draw_screen: nil state")
	assert(value.box_count <= BOX_MAX, "draw_screen: box count overflow")
	rl.BeginDrawing()
	rl.ClearBackground({15, 20, 28, 255})
	rl.draw_gpu_3d_target(
		&value.target,
		{0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())},
		rl.WHITE,
	)
	status := "unavailable" if !value.ready else "paused" if value.paused else "running"
	hud := fmt.ctprintf(
		"box3d %s  bodies %d  steps %d  dropped %d  resize failures %d",
		status,
		value.box_count,
		value.fixed_steps,
		value.dropped_steps,
		value.resize_failures,
	)
	rl.DrawText(hud, 18, 18, 22, rl.RAYWHITE)
	rl.DrawText(
		"R reset  Space pause  N step  A/D or left-drag orbit  W/S or wheel zoom",
		18,
		50,
		18,
		rl.LIGHTGRAY,
	)
	rl.EndDrawing()
}

physics_destroy :: proc(value: ^State) {
	assert(value != nil, "physics_destroy: nil state")
	assert(value.box_count <= BOX_MAX, "physics_destroy: box count overflow")
	if b3.World_IsValid(value.world) do b3.DestroyWorld(value.world)
	value.world = {}
	value.floor = {}
	value.boxes = {}
	value.box_count = 0
	value.accumulator = 0
	value.fixed_steps = 0
	value.step_once = false
	value.ready = false
	assert(value.box_count == 0, "physics_destroy: state not cleared")
}

shutdown :: proc(value: ^State) {
	assert(value != nil, "shutdown: nil state")
	assert(value.box_count <= BOX_MAX, "shutdown: box count overflow")
	physics_destroy(value)
	if value.cube_edges.id != 0 do rl.destroy_gpu_mesh(&value.cube_edges)
	if value.cube.id != 0 do rl.destroy_gpu_mesh(&value.cube)
	_, _, target_ok := rl.gpu_3d_target_size(&value.target)
	if target_ok do rl.destroy_gpu_3d_target(&value.target)
	value.graphics_ready = false
	rl.CloseWindow()
}
