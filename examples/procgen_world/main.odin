package main

import "core:fmt"
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
	config:         procgen.Terrain_Config,
	terrain_preset: procgen.Terrain_Preset_V3,
	chunks:         [WORLD_CHUNK_COUNT]procgen.Terrain_Chunk,
	vertices:       [WORLD_CHUNK_COUNT][procgen.TERRAIN_CHUNK_VERTICES]asset.Vertex,
	indices:        [WORLD_CHUNK_COUNT][procgen.TERRAIN_CHUNK_INDICES]u32,
	world:          scene.Scene,
	draws:          scene.Draw_List,
	bridge:         scene_gfx.Bridge,
	target:         rl.Gpu_3D_Target,
	camera:         rl.Camera3D,
	orbit:          rl.Orbit_Camera_State,
	orbit_config:   rl.Orbit_Camera_Config,
	orbit_bindings: rl.Orbit_Camera_Bindings,
	ready:          bool,
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
	state.terrain_preset = .Normal
	state.camera = {
		position   = {-90, 0, 55},
		target     = {96, 96, 0},
		up         = rl.CAMERA_WORLD_UP,
		fovy       = 55,
		projection = .PERSPECTIVE,
	}
	state.orbit, _ = rl.orbit_camera_from_camera(state.camera)
	state.orbit_config = rl.orbit_camera_config_default()
	state.orbit_config.zoom_speed = 80
	state.orbit_config.scroll_distance = 8
	state.orbit_config.min_distance = 90
	state.orbit_config.max_distance = 420
	state.orbit_bindings = rl.orbit_camera_bindings_default()
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
	if rl.IsKeyPressed(.T) {
		state.terrain_preset = .Abstract if state.terrain_preset == .Normal else .Normal
	}
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
		rl.draw_gpu_3d_target(
			&state.target,
			{0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())},
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
		preset_label := fmt.ctprintf("V3 preset %v (T toggles recipe)", state.terrain_preset)
		rl.DrawText(preset_label, 16, 44, 18, rl.LIGHTGRAY)
		rl.DrawText("A/D or left-drag orbit, W/S or wheel zoom", 16, 68, 18, rl.LIGHTGRAY)
	}
	rl.EndDrawing()
}

update_camera :: proc() {
	input := rl.orbit_camera_input_poll(state.orbit_bindings)
	rl.update_orbit_camera(&state.orbit, input, state.orbit_config, rl.GetFrameTime())
	rl.orbit_camera_apply(state.orbit, &state.camera)
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
