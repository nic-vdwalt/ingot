package main

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:math/linalg"
import workers "ingot:box3d_workers"
import rl "ingot:gfx"
import b3 "vendor:box3d"

VISUAL_BOX_COUNT :: 25
STRESS_BOX_COUNT :: 1_024
BOX_MAX :: 2_048
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

Simulation_Mode :: enum u32 {
	Visual,
	Stress,
}

Simulation_Command :: enum u32 {
	None,
	Reset,
	Advance,
}

Simulation_State :: struct {
	world:      b3.WorldId,
	bodies:     [BOX_MAX]b3.BodyId,
	body_count: u32,
	mode:       Simulation_Mode,
	ready:      bool,
}

Snapshot :: struct {
	transforms: [BOX_MAX]rl.Matrix,
	body_count: u32,
	mode:       Simulation_Mode,
}

State :: struct {
	snapshots:       [2]Snapshot,
	published_index: u32,
	published_gen:   u32,
	consumed_gen:    u32,
	render_index:    u32,
	command_pending: u32,
	pending_command: Simulation_Command,
	pending_value:   u32,
	requested_mode:  u32,
	reset_requested: u32,
	active_mode:     Simulation_Mode,
	body_count:      u32,
	accumulator:     f32,
	fixed_steps:     u32,
	dropped_steps:   u64,
	physics_micros:  u32,
	worker_count:    u32,
	paused:          bool,
	step_once:       bool,
	ready:           bool,
	worker_failed:   bool,
	target:          rl.Gpu_3D_Target,
	resize_failures: u64,
	cube:            rl.Gpu_Mesh,
	cube_edges:      rl.Gpu_Mesh,
	camera:          rl.Camera3D,
	orbit:           rl.Orbit_Camera_State,
	orbit_config:    rl.Orbit_Camera_Config,
	orbit_bindings:  rl.Orbit_Camera_Bindings,
	graphics_ready:  bool,
}

state: State
simulation: Simulation_State

main :: proc() {
	assert(VISUAL_BOX_COUNT > 0 && VISUAL_BOX_COUNT <= BOX_MAX)
	assert(STRESS_BOX_COUNT > VISUAL_BOX_COUNT && STRESS_BOX_COUNT <= BOX_MAX)
	rl.SetConfigFlags({.VSYNC_HINT, .WINDOW_RESIZABLE})
	rl.InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "ingot + box3d advanced")
	rl.SetTargetFPS(60)
	state.requested_mode = u32(Simulation_Mode.Visual)
	state.worker_count = workers.worker_count()
	when !workers.ENABLED {
		if !simulation_reset(.Visual) do return
		snapshot_publish()
		snapshot_consume()
	}
	rl.run(frame)
	when ODIN_OS != .JS do shutdown(&state)
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
	value.orbit_bindings = rl.orbit_camera_bindings_default()
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

simulation_floor_create :: proc() -> bool {
	assert(b3.World_IsValid(simulation.world))
	body_def := b3.DefaultBodyDef()
	body_def.type = .staticBody
	body_def.position = {0, 0, -10}
	floor := b3.CreateBody(simulation.world, body_def)
	if !b3.Body_IsValid(floor) do return false
	hull := b3.MakeBoxHull(50, 50, 10)
	shape := b3.CreateHullShape(floor, b3.DefaultShapeDef(), &hull.base)
	return b3.Shape_IsValid(shape)
}

simulation_box_create :: proc(index, count: u32, mode: Simulation_Mode) -> bool {
	assert(index < count && count <= BOX_MAX)
	body_def := b3.DefaultBodyDef()
	body_def.type = .dynamicBody
	if mode == .Visual {
		x := f32(i32(index * 37 % 31) - 15)
		y := f32(i32(index * 53 % 31) - 15)
		z := f32(10 + index * 29 % 21)
		body_def.position = {x, y, z}
	} else {
		column := index % 32
		row := index / 32
		body_def.enableSleep = false
		body_def.position = {
			f32(i32(column) - 16) * 2.05 + f32(row % 2) * 0.025,
			f32(i32(row % 8) - 4) * 2.05,
			2 + f32(row / 8) * 2.05,
		}
	}
	body := b3.CreateBody(simulation.world, body_def)
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
	simulation.bodies[index] = body
	simulation.body_count += 1
	return true
}

simulation_reset :: proc(mode: Simulation_Mode) -> bool {
	assert(mode == .Visual || mode == .Stress)
	if b3.World_IsValid(simulation.world) do b3.DestroyWorld(simulation.world)
	simulation = {}
	world_def := b3.DefaultWorldDef()
	world_def.gravity = {0, 0, -10}
	workers.configure_world(&world_def)
	simulation.world = b3.CreateWorld(world_def)
	if !b3.World_IsValid(simulation.world) do return false
	count := u32(VISUAL_BOX_COUNT if mode == .Visual else STRESS_BOX_COUNT)
	assert(count > 0 && count <= BOX_MAX)
	if !simulation_floor_create() do return false
	for index in 0 ..< count {
		if !simulation_box_create(index, count, mode) do return false
	}
	simulation.mode = mode
	simulation.ready = simulation.body_count == count
	return simulation.ready
}

snapshot_publish :: proc() {
	current := intrinsics.atomic_load_explicit(&state.published_index, .Acquire)
	next := (current + 1) % 2
	snapshot := &state.snapshots[next]
	assert(simulation.body_count <= BOX_MAX)
	for index in 0 ..< simulation.body_count {
		transform := b3.Body_GetTransform(simulation.bodies[index])
		snapshot.transforms[index] = linalg.matrix4_from_trs_f32(
			transform.p,
			transform.q,
			[3]f32{2, 2, 2},
		)
	}
	snapshot.body_count = simulation.body_count
	snapshot.mode = simulation.mode
	intrinsics.atomic_store_explicit(&state.published_index, next, .Release)
	generation := intrinsics.atomic_load_explicit(&state.published_gen, .Acquire)
	intrinsics.atomic_store_explicit(&state.published_gen, generation + 1, .Release)
}

snapshot_consume :: proc() {
	generation := intrinsics.atomic_load_explicit(&state.published_gen, .Acquire)
	if generation == state.consumed_gen do return
	index := intrinsics.atomic_load_explicit(&state.published_index, .Acquire)
	assert(index < 2)
	snapshot := &state.snapshots[index]
	assert(snapshot.body_count <= BOX_MAX)
	state.render_index = index
	state.body_count = snapshot.body_count
	state.active_mode = snapshot.mode
	state.ready = snapshot.body_count > 0
	state.consumed_gen = generation
}

@(export, link_name = "ingot_box3d_worker_command")
simulation_command_execute :: proc "contextless" (command, value: u32) -> bool {
	context = runtime.default_context()
	switch Simulation_Command(command) {
	case .Reset:
		if value > u32(Simulation_Mode.Stress) do return false
		if !simulation_reset(Simulation_Mode(value)) do return false
		snapshot_publish()
		return true
	case .Advance:
		if value == 0 || value > MAX_STEPS_PER_FRAME do return false
		if !simulation.ready do return false
		for _ in 0 ..< value do b3.World_Step(simulation.world, FIXED_DT, PHYSICS_SUBSTEPS)
		snapshot_publish()
		return true
	case .None:
		return false
	}
	return false
}

simulation_command_request :: proc(command: Simulation_Command, value: u32) -> bool {
	assert(command != .None)
	assert(state.pending_command == .None)
	if intrinsics.atomic_load_explicit(&state.command_pending, .Acquire) != 0 do return false
	state.pending_command = command
	state.pending_value = value
	intrinsics.atomic_store_explicit(&state.command_pending, 1, .Release)
	when workers.ENABLED {
		if workers.request_command(u32(command), value) do return true
		state.pending_command = .None
		state.pending_value = 0
		intrinsics.atomic_store_explicit(&state.command_pending, 0, .Release)
		return false
	}
	started := rl.GetTime()
	ok := simulation_command_execute(u32(command), value)
	elapsed := max(f64(0), (rl.GetTime() - started) * 1_000_000)
	state.physics_micros = u32(elapsed)
	if ok && command == .Advance do state.fixed_steps = value
	state.pending_command = .None
	state.pending_value = 0
	intrinsics.atomic_store_explicit(&state.command_pending, 0, .Release)
	snapshot_consume()
	return ok
}

simulation_completion_consume :: proc() {
	when workers.ENABLED {
		if state.worker_failed do return
		if workers.failure_count() != 0 {
			state.worker_failed = true
			return
		}
		if !workers.command_ready() do return
		assert(state.pending_command != .None)
		assert(intrinsics.atomic_load_explicit(&state.command_pending, .Acquire) != 0)
		state.physics_micros = workers.elapsed_micros()
		completed := workers.completed_value()
		if state.pending_command == .Advance {
			assert(completed == state.pending_value)
			state.fixed_steps = completed
		}
		state.pending_command = .None
		state.pending_value = 0
		intrinsics.atomic_store_explicit(&state.command_pending, 0, .Release)
		snapshot_consume()
	}
}

physics_time_accumulate :: proc(value: ^State, frame_dt: f32) {
	assert(value != nil)
	assert(value.accumulator >= 0)
	if value.paused do return
	value.accumulator += clamp(frame_dt, 0, MAX_FRAME_DT)
	maximum := f32(MAX_STEPS_PER_FRAME + 1) * FIXED_DT
	if value.accumulator < maximum do return
	dropped := u64(value.accumulator / FIXED_DT) - u64(MAX_STEPS_PER_FRAME)
	value.accumulator -= f32(dropped) * FIXED_DT
	value.dropped_steps += dropped
}

physics_update :: proc(value: ^State, frame_dt: f32) {
	assert(value != nil)
	assert(value.body_count <= BOX_MAX)
	value.fixed_steps = 0
	simulation_completion_consume()
	if value.worker_failed do return
	physics_time_accumulate(value, frame_dt)
	if intrinsics.atomic_load_explicit(&value.command_pending, .Acquire) != 0 do return
	requested := intrinsics.atomic_load_explicit(&value.requested_mode, .Acquire)
	reset := intrinsics.atomic_load_explicit(&value.reset_requested, .Acquire) != 0
	if !value.ready || requested != u32(value.active_mode) || reset {
		if simulation_command_request(.Reset, requested) {
			value.accumulator = 0
			intrinsics.atomic_store_explicit(&value.reset_requested, 0, .Release)
		}
		return
	}
	if value.paused {
		if value.step_once && simulation_command_request(.Advance, 1) do value.step_once = false
		return
	}
	steps := min(u32(value.accumulator / FIXED_DT), u32(MAX_STEPS_PER_FRAME))
	if steps == 0 do return
	if simulation_command_request(.Advance, steps) {
		value.accumulator -= f32(steps) * FIXED_DT
	}
}

@(export, link_name = "ingot_box3d_advanced_set_stress")
set_stress :: proc "contextless" (enabled: u32) -> bool {
	if enabled > 1 do return false
	intrinsics.atomic_store_explicit(&state.requested_mode, enabled, .Release)
	return true
}

physics_input :: proc(value: ^State) {
	assert(value != nil)
	if rl.IsKeyPressed(.SPACE) do value.paused = !value.paused
	if rl.IsKeyPressed(.N) && value.paused do value.step_once = true
	if rl.IsKeyPressed(.R) do intrinsics.atomic_store_explicit(&value.reset_requested, 1, .Release)
	if rl.IsKeyPressed(.S) {
		requested := intrinsics.atomic_load_explicit(&value.requested_mode, .Acquire)
		intrinsics.atomic_store_explicit(&value.requested_mode, 1 - requested, .Release)
	}
}

camera_update :: proc(value: ^State, frame_dt: f32) {
	assert(value != nil, "camera_update: nil state")
	assert(value.orbit.distance > 0, "camera_update: invalid distance")
	input := rl.orbit_camera_input_poll(value.orbit_bindings)
	rl.update_orbit_camera(&value.orbit, input, value.orbit_config, frame_dt)
	rl.orbit_camera_apply(value.orbit, &value.camera)
}

frame :: proc() {
	if !state.graphics_ready {
		if !graphics_create(&state) do return
	}
	frame_dt := clamp(rl.GetFrameTime(), 0, MAX_FRAME_DT)
	physics_input(&state)
	camera_update(&state, frame_dt)
	physics_update(&state, frame_dt)
	graphics_target_resize(&state)
	draw_world(&state)
	draw_screen(&state)
}

draw_world :: proc(value: ^State) {
	assert(value != nil)
	assert(value.body_count <= BOX_MAX)
	pass, ok := rl.begin_gpu_3d(&value.target, value.camera)
	if !ok do return
	rl.set_gpu_3d_light(&pass, {{-0.4, 0.5, 0.8}, 0.15, 0.85})
	floor_transform := rl.MatrixTranslate(0, 0, -2) * rl.MatrixScale(100, 100, 4)
	rl.draw_gpu_mesh(&pass, value.cube, floor_transform, {color = rl.LIGHTGRAY})
	snapshot := &value.snapshots[value.render_index]
	for transform, index in snapshot.transforms[:value.body_count] {
		color := BOX_COLORS[index % len(BOX_COLORS)]
		rl.draw_gpu_mesh_outlined(
			&pass,
			value.cube,
			value.cube_edges,
			transform,
			{color = color},
			{24, 28, 36, 255},
		)
	}
	rl.end_gpu_3d(&pass)
}

draw_screen :: proc(value: ^State) {
	assert(value != nil)
	assert(value.body_count <= BOX_MAX)
	rl.BeginDrawing()
	rl.ClearBackground({15, 20, 28, 255})
	rl.draw_gpu_3d_target(
		&value.target,
		{0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())},
		rl.WHITE,
	)
	status :=
		"failed" if value.worker_failed else "unavailable" if !value.ready else "paused" if value.paused else "running"
	mode := "stress" if value.active_mode == .Stress else "visual"
	hud := fmt.ctprintf(
		"box3d %s  mode %s  bodies %d  workers %d  physics %.3fms  steps %d  dropped %d",
		status,
		mode,
		value.body_count,
		value.worker_count,
		f64(value.physics_micros) / 1000,
		value.fixed_steps,
		value.dropped_steps,
	)
	rl.DrawText(hud, 18, 18, 22, rl.RAYWHITE)
	rl.DrawText(
		"R reset  S stress  Space pause  N step  A/D or left-drag orbit  W/S or wheel zoom",
		18,
		50,
		18,
		rl.LIGHTGRAY,
	)
	rl.EndDrawing()
}

simulation_destroy :: proc "contextless" () {
	if b3.World_IsValid(simulation.world) do b3.DestroyWorld(simulation.world)
	simulation = {}
}

shutdown :: proc(value: ^State) {
	assert(value != nil)
	assert(value.body_count <= BOX_MAX)
	when !workers.ENABLED do simulation_destroy()
	if value.cube_edges.id != 0 do rl.destroy_gpu_mesh(&value.cube_edges)
	if value.cube.id != 0 do rl.destroy_gpu_mesh(&value.cube)
	_, _, target_ok := rl.gpu_3d_target_size(&value.target)
	if target_ok do rl.destroy_gpu_3d_target(&value.target)
	value.graphics_ready = false
	rl.CloseWindow()
}
