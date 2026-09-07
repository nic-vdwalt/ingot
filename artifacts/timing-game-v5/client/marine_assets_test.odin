package main

import "core:testing"
import rl "ingot:gfx"

Marine_Test_GPU :: struct {
	created, destroyed, live, updates, fail_at: int,
	fail_update: bool,
}
@(thread_local)
marine_test_gpu: Marine_Test_GPU

marine_test_create :: proc(vertices: []rl.Gpu_3D_Vertex, indices: []u32) -> (rl.Gpu_Mesh, bool) {
	marine_test_gpu.created += 1
	marine_test_gpu.live += 1
	mesh: rl.Gpu_Mesh
	mesh.id = u32(marine_test_gpu.created)
	return mesh, marine_test_gpu.created != marine_test_gpu.fail_at
}
marine_test_destroy :: proc(mesh: ^rl.Gpu_Mesh) {
	assert(mesh.id != 0)
	marine_test_gpu.live -= 1
	marine_test_gpu.destroyed += 1
	mesh^ = {}
}
marine_test_update :: proc(mesh: rl.Gpu_Mesh, vertices: []rl.Gpu_3D_Vertex) -> bool {
	assert(mesh.id != 0 && len(vertices) > 0)
	marine_test_gpu.updates += 1
	return !marine_test_gpu.fail_update
}

@(test)
marine_asset_gpu_lifecycle :: proc(t: ^testing.T) {
	ops := Marine_GPU_Ops{marine_test_create, marine_test_destroy, marine_test_update}
	for failure in 1 ..= 16 {
		marine_test_gpu = {fail_at = failure}
		assets: Marine_Assets
		testing.expect(t, !marine_assets_init(&assets, gpu = ops))
		testing.expect(t, !assets.ready && marine_test_gpu.live == 0)
		testing.expect(t, marine_test_gpu.created == failure && marine_test_gpu.destroyed == failure)
		marine_assets_deinit(&assets)
	}
	marine_test_gpu = {}
	assets: Marine_Assets
	testing.expect(t, marine_assets_init(&assets, gpu = ops))
	testing.expect(t, marine_assets_init(&assets, gpu = ops))
	testing.expect(t, marine_test_gpu.created == 16 && marine_test_gpu.live == 16)
	for family in 0 ..< 4 do for clip in 0 ..< 2 {
		first, second := &assets.phases[family][clip][0], &assets.phases[family][clip][1]
		testing.expect(t, first.mesh.id != second.mesh.id)
		testing.expect(t, raw_data(first.vertices) != raw_data(second.vertices))
		frames := raw_data(assets.clips[family][clip].frames)
		testing.expect(t, marine_clip_sample(&assets, family, clip, 0, 0))
		testing.expect(t, marine_clip_sample(&assets, family, clip, 1, 0))
		testing.expect(t, raw_data(assets.clips[family][clip].frames) == frames)
		for vertex, index in second.vertices {
			testing.expect(t, vertex.position == assets.clips[family][clip].frames[8*len(second.vertices)+index].position)
		}
		testing.expect(t, marine_clip_sample(&assets, family, clip, 0, -0.25))
		position := first.vertices[0].position
		testing.expect(t, marine_clip_sample(&assets, family, clip, 0, 0.75))
		testing.expect(t, position == first.vertices[0].position)
	}
	marine_test_gpu.fail_update = true
	testing.expect(t, !marine_clip_sample(&assets, 0, 0, 0, 0.1))
	testing.expect(t, !marine_clip_sample(&assets, -1, 0, 0, 0))
	marine_assets_deinit(&assets)
	marine_assets_deinit(&assets)
	testing.expect(t, marine_test_gpu.live == 0 && marine_test_gpu.destroyed == 16)
}

@(test)
marine_asset_rejects_degenerate_topology :: proc(t: ^testing.T) {
	original := MARINE_ASSET_BYTES[0][0]
	bytes := make([]u8, len(original))
	defer delete(bytes)
	copy(bytes, original)
	copy(bytes[56:60], bytes[52:56])
	data: Marine_Clip_Data
	testing.expect(t, marine_clip_decode(&data, original))
	defer marine_clip_deinit(&data)
	frames, indices := raw_data(data.frames), raw_data(data.indices)
	testing.expect(t, !marine_clip_decode(&data, bytes))
	testing.expect(t, raw_data(data.frames) == frames && raw_data(data.indices) == indices)
}

@(test)
marine_asset_payloads_decode :: proc(t: ^testing.T) {
	for family in 0 ..< 4 do for clip in 0 ..< 2 {
		data: Marine_Clip_Data
		testing.expect(t, marine_clip_decode(&data, MARINE_ASSET_BYTES[family][clip]))
		testing.expect(t, data.vertex_count > 0 && data.vertex_count <= 1024)
		testing.expect(t, len(data.frames) == data.vertex_count * 16)
		before := raw_data(data.frames)
		bytes := MARINE_ASSET_BYTES[family][clip]
		testing.expect(t, !marine_clip_decode(&data, bytes[:len(bytes)-1]))
		testing.expect(t, raw_data(data.frames) == before)
		marine_clip_deinit(&data)
		marine_clip_deinit(&data)
	}
}

@(test)
marine_asset_malformed_headers :: proc(t: ^testing.T) {
	original := MARINE_ASSET_BYTES[0][0]
	bytes := make([]u8, len(original))
	defer delete(bytes)
	offsets := [7]int{0, 8, 12, 16, 20, 24, 52}
	for offset in offsets {
		copy(bytes, original)
		bytes[offset] = 255
		if offset == 52 do bytes[offset+1] = 255
		data: Marine_Clip_Data
		ok := marine_clip_decode(&data, bytes)
		testing.expect(t, !ok)
		marine_clip_deinit(&data)
	}
}
