// examples/box3d_water - floating rigid bodies on an analytical wave.
//
// The question this example answers is "can Box3D do water?". It can do the
// half that matters for gameplay: bodies that float, bob, tilt, and settle. It
// cannot do the other half, because Box3D is a constraint solver over rigid
// bodies and has no fluid representation at all. So the water here is a wave
// function the application owns (see water.odin), and the coupling to Box3D is
// one force applied to each floater before every fixed step.
//
// Everything is bounded and caller-owned in the immediate-mode style: fixed
// arrays sized by named constants, one fixed 60 Hz step with a capped catch-up,
// and a wave phase that advances only inside a simulation step so pause and
// single-step freeze the water and the bodies together.
package main

import "core:fmt"
import rl "ingot:gfx"
import b3 "vendor:box3d"

FLOATER_MAX :: 16
FLOATER_COUNT :: 6
FLOATER_HALF_EXTENT :: f32(0.9)
FLOATER_DENSITY :: f32(0.55) // below water density, so the cubes float
FIXED_DT :: f32(1.0 / 60.0)
PHYSICS_SUBSTEPS :: 4
MAX_STEPS_PER_FRAME :: 8
MAX_FRAME_DT :: f32(0.25)
SCREEN_WIDTH :: 1280
SCREEN_HEIGHT :: 720

// The visible pool. The mesh is a static grid over this extent and the floor
// sits far enough below the surface that a sinking body is obvious rather than
// merely off-screen.
POOL_EXTENT :: f32(14)
POOL_CELLS :: 40
POOL_VERTEX_COUNT :: (POOL_CELLS + 1) * (POOL_CELLS + 1)
FLOOR_Z :: f32(-8)

#assert(FLOATER_COUNT <= FLOATER_MAX)
// The grid is checked against the renderer's own caps rather than a round
// number, so raising POOL_CELLS fails at compile time on the limit that
// actually applies instead of being rejected at runtime by create_gpu_mesh.
#assert(POOL_VERTEX_COUNT <= rl.GPU_3D_MAX_VERTICES)
#assert(POOL_CELLS <= rl.GPU_3D_PLANE_MAX_CELLS)

FLOATER_COLORS := [6]rl.Color {
	{247, 213, 105, 255},
	{255, 151, 92, 255},
	{132, 218, 146, 255},
	{223, 126, 214, 255},
	{92, 176, 255, 255},
	{133, 134, 235, 255},
}

Floater :: struct {
	body:      b3.BodyId,
	mass:      f32,
	submerged: f32,
	transform: rl.Matrix,
}

State :: struct {
	world:           b3.WorldId,
	floor:           b3.BodyId,
	floaters:        [FLOATER_MAX]Floater,
	floater_count:   u32,
	phase:           f32,
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
	water:           rl.Gpu_Mesh,
	camera:          rl.Camera3D,
	orbit:           rl.Orbit_Camera_State,
	orbit_config:    rl.Orbit_Camera_Config,
	orbit_bindings:  rl.Orbit_Camera_Bindings,
	graphics_ready:  bool,
}

state: State

main :: proc() {
	rl.SetConfigFlags({.VSYNC_HINT, .WINDOW_RESIZABLE})
	rl.InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "ingot + box3d water")
	rl.SetTargetFPS(60)
	if !physics_create(&state) {
		when ODIN_OS != .JS do shutdown(&state)
		return
	}
	rl.run(frame)
	when ODIN_OS != .JS do shutdown(&state)
}

frame :: proc() {
	if !state.graphics_ready {
		if !graphics_create(&state) do return
	}
	frame_dt := clamp(rl.GetFrameTime(), 0, MAX_FRAME_DT)
	simulation_input(&state)
	camera_update(&state, frame_dt)
	physics_update(&state, frame_dt)
	graphics_target_resize(&state)
	draw_world(&state)
	draw_screen(&state)
}

// The HUD names what the simulation actually is. Someone reading "water" in a
// Box3D example will otherwise assume a fluid solver is running, and the whole
// point of this sample is that a rigid-body engine plus one analytical surface
// buys floating behaviour without one.
draw_screen :: proc(value: ^State) {
	assert(value != nil, "draw_screen: nil state")
	assert(value.floater_count <= FLOATER_MAX, "draw_screen: floater count overflow")
	rl.BeginDrawing()
	rl.ClearBackground({12, 17, 26, 255})
	rl.draw_gpu_3d_target(
		&value.target,
		{0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())},
		rl.WHITE,
	)
	status := "unavailable" if !value.ready else "paused" if value.paused else "running"
	hud := fmt.ctprintf(
		"box3d %s  floaters %d  submerged %.0f%%  phase %.2f  steps %d  dropped %d",
		status,
		value.floater_count,
		f64(floater_submerged_average(value)) * 100,
		f64(value.phase),
		value.fixed_steps,
		value.dropped_steps,
	)
	rl.DrawText(hud, 18, 18, 22, rl.RAYWHITE)
	rl.DrawText("analytical wave + box3d buoyancy - not a fluid solver", 18, 50, 18, rl.SKYBLUE)
	rl.DrawText(
		"R reset  Space pause  N step  A/D or left-drag orbit  W/S or wheel zoom",
		18,
		76,
		18,
		rl.LIGHTGRAY,
	)
	rl.EndDrawing()
}

// The mean immersion is the one number that shows the coupling is working: it
// should settle near WATER_BUOYANCY_GAIN's equilibrium rather than drift to 0
// (bodies flying) or 1 (bodies sinking).
floater_submerged_average :: proc(value: ^State) -> f32 {
	assert(value != nil, "floater_submerged_average: nil state")
	assert(value.floater_count <= FLOATER_MAX, "floater_submerged_average: overflow")
	if value.floater_count == 0 do return 0
	total := f32(0)
	for floater in value.floaters[:value.floater_count] do total += floater.submerged
	return total / f32(value.floater_count)
}

shutdown :: proc(value: ^State) {
	assert(value != nil, "shutdown: nil state")
	assert(value.floater_count <= FLOATER_MAX, "shutdown: floater count overflow")
	physics_destroy(value)
	if value.water.id != 0 do rl.destroy_gpu_mesh(&value.water)
	if value.cube_edges.id != 0 do rl.destroy_gpu_mesh(&value.cube_edges)
	if value.cube.id != 0 do rl.destroy_gpu_mesh(&value.cube)
	_, _, target_ok := rl.gpu_3d_target_size(&value.target)
	if target_ok do rl.destroy_gpu_3d_target(&value.target)
	value.graphics_ready = false
	rl.CloseWindow()
}
