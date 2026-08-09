package main

import "core:fmt"
import "core:math"
import "ingot:asset"
import rl "ingot:gfx"
import "ingot:procgen"
import "ingot:scene"
import "ingot:scene_gfx"

WORLD_CHUNKS_X :: 4
WORLD_CHUNKS_Y :: 4
WORLD_CHUNK_COUNT :: WORLD_CHUNKS_X * WORLD_CHUNKS_Y
WORLD_WIDTH :: 1280
WORLD_HEIGHT :: 720

State :: struct {
	config:       procgen.Terrain_Config,
	chunks:       [WORLD_CHUNK_COUNT]procgen.Terrain_Chunk,
	vertices:     [WORLD_CHUNK_COUNT][procgen.TERRAIN_CHUNK_VERTICES]asset.Vertex,
	indices:      [WORLD_CHUNK_COUNT][procgen.TERRAIN_CHUNK_INDICES]u32,
	world:        scene.Scene,
	draws:        scene.Draw_List,
	bridge:       scene_gfx.Bridge,
	target:       rl.Gpu_3D_Target,
	camera:       rl.Camera3D,
	orbit_angle:  f32,
	orbit_radius: f32,
	ready:        bool,
}

state: State

main :: proc() {
	rl.InitWindow(WORLD_WIDTH, WORLD_HEIGHT, "ingot procedural world")
	rl.SetTargetFPS(60)
	initialize(0xC0FFEE)
	rl.run(frame)
	when ODIN_OS != .JS {
		scene_gfx.bridge_destroy(&state.bridge)
		rl.destroy_gpu_3d_target(&state.target)
		rl.CloseWindow()
	}
}

initialize :: proc(seed: u64) {
	state.config = procgen.terrain_default_config(seed)
	state.orbit_angle = 3.5
	state.orbit_radius = 210
	state.camera = {
		position   = {-90, 0, 55},
		target     = {96, 96, 0},
		up         = rl.CAMERA_WORLD_UP,
		fovy       = 55,
		projection = .PERSPECTIVE,
	}
	target_ok: bool
	state.target, target_ok = rl.create_gpu_3d_target(WORLD_WIDTH, WORLD_HEIGHT)
	if !target_ok do return
	material, material_ok := scene.scene_add_material(
		&state.world,
		{color_low = {42, 92, 48, 255}, color_high = {238, 242, 246, 255}, use_scalar = true},
	)
	if !material_ok do return
	for &chunk, index in state.chunks {
		chunk.chunk_x = i32(index % WORLD_CHUNKS_X)
		chunk.chunk_y = i32(index / WORLD_CHUNKS_X)
		chunk.mesh = {
			id        = asset.Mesh_Id(index + 1),
			vertices  = state.vertices[index][:],
			indices   = state.indices[index][:],
			primitive = .Triangles,
		}
		if !procgen.terrain_generate_chunk(state.config, &chunk) do return
		mesh, ok := asset.mesh_view(&chunk.mesh)
		if !ok || !scene_gfx.bridge_upload_mesh(&state.bridge, mesh) do return
		object := scene.Object {
			id        = scene.Object_Id(index + 1),
			mesh      = mesh.id,
			material  = material,
			transform = identity_matrix(),
			bounds    = mesh.bounds,
			visible   = true,
		}
		if !scene.scene_add_object(&state.world, object) do return
	}
	state.ready = true
}

frame :: proc() {
	update_camera()
	if state.ready {
		scene_gfx.bridge_begin_frame(&state.bridge)
		frustum := rl.camera_frustum(state.camera, WORLD_WIDTH, WORLD_HEIGHT)
		input := scene.Build_Input {
			frustum         = scene_frustum(frustum),
			camera_position = state.camera.position,
			lod_distances   = {100, 220, 440, 880},
		}
		scene.build_draw_list(&state.world, input, &state.draws)
		pass, ok := rl.begin_gpu_3d(&state.target, state.camera)
		if ok {
			rl.set_gpu_3d_light(&pass, {{-0.4, 0.6, 0.7}, 0.3, 0.7})
			scene_gfx.bridge_replay(&state.bridge, &pass, &state.world, &state.draws)
			rl.end_gpu_3d(&pass)
		}
	}
	rl.BeginDrawing()
	rl.ClearBackground(rl.Color{18, 24, 32, 255})
	if state.ready {
		rl.DrawTexturePro(
			state.target.texture.texture,
			{0, 0, WORLD_WIDTH, WORLD_HEIGHT},
			{0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())},
			{},
			0,
			rl.WHITE,
		)
		label := fmt.ctprintf(
			"seed C0FFEE  chunks %d  draws %d  culled %d  overflow %d  missing %d",
			WORLD_CHUNK_COUNT,
			state.draws.count,
			state.draws.culled_count,
			state.draws.overflow_count,
			state.bridge.missing_draws,
		)
		rl.DrawText(label, 16, 16, 20, rl.RAYWHITE)
		rl.DrawText("A/D or arrows orbit, W/S or wheel zoom", 16, 44, 18, rl.LIGHTGRAY)
	}
	rl.EndDrawing()
}

update_camera :: proc() {
	delta := rl.GetFrameTime()
	if rl.IsKeyDown(.LEFT) || rl.IsKeyDown(.A) do state.orbit_angle += delta
	if rl.IsKeyDown(.RIGHT) || rl.IsKeyDown(.D) do state.orbit_angle -= delta
	if rl.IsKeyDown(.UP) || rl.IsKeyDown(.W) do state.orbit_radius -= 80 * delta
	if rl.IsKeyDown(.DOWN) || rl.IsKeyDown(.S) do state.orbit_radius += 80 * delta
	state.orbit_radius = clamp(state.orbit_radius - rl.GetMouseWheelMove() * 8, 90, 420)
	center := rl.Vector3{96, 96, 0}
	state.camera.target = center
	state.camera.position = {
		center.x + math.cos(state.orbit_angle) * state.orbit_radius,
		center.y + math.sin(state.orbit_angle) * state.orbit_radius,
		70 + state.orbit_radius * 0.22,
	}
}

identity_matrix :: proc() -> scene.Matrix_4 {
	return {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}
}

scene_frustum :: proc(value: rl.Frustum_3D) -> scene.Frustum {
	result: scene.Frustum
	for plane, index in value.planes {
		result.planes[index] = {{plane.normal.x, plane.normal.y, plane.normal.z}, plane.distance}
	}
	return result
}
