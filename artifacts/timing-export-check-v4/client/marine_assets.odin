package main

import "core:math"
import "core:mem"
import rl "ingot:gfx"

MARINE_RENDER_FAMILIES :: 4
MARINE_RENDER_CLIPS :: 2
MARINE_RENDER_PHASES :: 2
MARINE_RENDER_MAX_VERTICES :: 1024
MARINE_RENDER_MAX_INDICES :: 6144
MARINE_RENDER_FRAMES :: 16

MARINE_ASSET_BYTES := [4][2][]u8{
	{#load("../assets/generated/marine-sessile-rest.inganim", []u8), #load("../assets/generated/marine-sessile-move.inganim", []u8)},
	{#load("../assets/generated/marine-worm-rest.inganim", []u8), #load("../assets/generated/marine-worm-move.inganim", []u8)},
	{#load("../assets/generated/marine-lobopodian-rest.inganim", []u8), #load("../assets/generated/marine-lobopodian-move.inganim", []u8)},
	{#load("../assets/generated/marine-armoured-rest.inganim", []u8), #load("../assets/generated/marine-armoured-move.inganim", []u8)},
}

Marine_Clip_Data :: struct {
	frames: []rl.Gpu_3D_Vertex,
	indices: []u32,
	vertex_count: int,
	bounds: Bounds_3D,
	allocator: mem.Allocator,
}
Marine_Phase_Mesh :: struct {
	mesh: rl.Gpu_Mesh,
	vertices: []rl.Gpu_3D_Vertex,
}
Marine_GPU_Ops :: struct {
	create: proc(vertices: []rl.Gpu_3D_Vertex, indices: []u32) -> (rl.Gpu_Mesh, bool),
	destroy: proc(mesh: ^rl.Gpu_Mesh),
	update: proc(mesh: rl.Gpu_Mesh, vertices: []rl.Gpu_3D_Vertex) -> bool,
}
Marine_Assets :: struct {
	clips: [4][2]Marine_Clip_Data,
	phases: [4][2][2]Marine_Phase_Mesh,
	allocator: mem.Allocator,
	gpu: Marine_GPU_Ops,
	ready: bool,
}
marine_gpu_create :: proc(vertices: []rl.Gpu_3D_Vertex, indices: []u32) -> (rl.Gpu_Mesh, bool) {
	return rl.create_gpu_mesh(vertices, indices, .Triangles)
}
marine_gpu_destroy :: proc(mesh: ^rl.Gpu_Mesh) { rl.destroy_gpu_mesh(mesh) }
marine_gpu_update :: proc(mesh: rl.Gpu_Mesh, vertices: []rl.Gpu_3D_Vertex) -> bool { return rl.update_gpu_mesh_vertices(mesh, vertices) }
marine_float_finite :: proc(value: f32) -> bool { return value == value && math.abs(value) <= 3.402823466e38 }
marine_clip_deinit :: proc(clip: ^Marine_Clip_Data) {
	if clip == nil do return
	if len(clip.frames) > 0 do delete(clip.frames, clip.allocator)
	if len(clip.indices) > 0 do delete(clip.indices, clip.allocator)
	clip^ = {}
}
marine_clip_decode :: proc(destination: ^Marine_Clip_Data, bytes: []u8, allocator := context.allocator) -> bool {
	if destination == nil || len(bytes) < 52 || string(bytes[:8]) != "INGANI01" do return false
	if _fauna_u32(bytes, 8) != 1 || _fauna_u32(bytes, 20) != 16 || _fauna_u32(bytes, 24) != 16 do return false
	vertices, indices := int(_fauna_u32(bytes, 12)), int(_fauna_u32(bytes, 16))
	if vertices <= 0 || vertices > 1024 || indices <= 0 || indices > 6144 || indices % 3 != 0 do return false
	if len(bytes) != 52 + indices * 4 + vertices * 16 * 36 do return false
	temporary := Marine_Clip_Data{allocator = allocator, vertex_count = vertices}
	defer marine_clip_deinit(&temporary)
	for axis in 0 ..< 3 {
		lower, upper := _fauna_f32(bytes, 28 + axis * 4), _fauna_f32(bytes, 40 + axis * 4)
		if !marine_float_finite(lower) || !marine_float_finite(upper) || lower > upper do return false
		temporary.bounds.min[axis], temporary.bounds.max[axis] = lower, upper
	}
	index_bank, index_error := make([]u32, indices, allocator)
	if index_error != nil do return false
	temporary.indices = index_bank
	frame_bank, frame_error := make([]rl.Gpu_3D_Vertex, vertices * 16, allocator)
	if frame_error != nil do return false
	temporary.frames = frame_bank
	cursor := 52
	for &index in temporary.indices {
		index = _fauna_u32(bytes, cursor)
		if int(index) >= vertices do return false
		cursor += 4
	}
	for &vertex in temporary.frames {
		values: [9]f32
		for &value in values {
			value = _fauna_f32(bytes, cursor)
			if !marine_float_finite(value) do return false
			cursor += 4
		}
		vertex.position = {values[0], values[1], values[2]}
		vertex.normal = {values[3], values[4], values[5]}
		vertex.scalar, vertex.uv = values[6], {values[7], values[8]}
		for axis in 0 ..< 3 {
			if vertex.position[axis] < temporary.bounds.min[axis] - 0.000001 || vertex.position[axis] > temporary.bounds.max[axis] + 0.000001 do return false
		}
		length := values[3]*values[3] + values[4]*values[4] + values[5]*values[5]
		if math.abs(length - 1) > 0.0001 do return false
	}
	for frame in 0 ..< 16 {
		ground := f32(3.402823466e38)
		for vertex in temporary.frames[frame*vertices:(frame+1)*vertices] do ground = min(ground, vertex.position.z)
		if math.abs(ground) > 0.00001 do return false
		for triangle := 0; triangle < indices; triangle += 3 {
			first := temporary.frames[frame*vertices+int(temporary.indices[triangle])]
			second := temporary.frames[frame*vertices+int(temporary.indices[triangle+1])]
			third := temporary.frames[frame*vertices+int(temporary.indices[triangle+2])]
			left, right := second.position-first.position, third.position-first.position
			cross := rl.Vector3{left.y*right.z-left.z*right.y, left.z*right.x-left.x*right.z, left.x*right.y-left.y*right.x}
			area := cross.x*cross.x + cross.y*cross.y + cross.z*cross.z
			if !marine_float_finite(area) || area <= 0.000000000001 do return false
			normals := [3]rl.Vector3{first.normal, second.normal, third.normal}
			for normal in normals {
				agreement := cross.x*normal.x + cross.y*normal.y + cross.z*normal.z
				if !marine_float_finite(agreement) || agreement <= 0 do return false
			}
		}
	}
	destination^, temporary = temporary, destination^
	return true
}
marine_assets_deinit :: proc(assets: ^Marine_Assets) {
	if assets == nil do return
	for &family in assets.phases do for &clip in family do for &phase in clip {
		if phase.mesh.id != 0 && assets.gpu.destroy != nil do assets.gpu.destroy(&phase.mesh)
		if len(phase.vertices) > 0 do delete(phase.vertices, assets.allocator)
	}
	for &family in assets.clips do for &clip in family do marine_clip_deinit(&clip)
	assets^ = {}
}
marine_assets_init :: proc(assets: ^Marine_Assets, allocator := context.allocator, gpu := Marine_GPU_Ops{marine_gpu_create, marine_gpu_destroy, marine_gpu_update}) -> bool {
	if assets == nil do return false
	if assets.ready do return true
	if gpu.create == nil || gpu.destroy == nil || gpu.update == nil do return false
	marine_assets_deinit(assets)
	assets.allocator, assets.gpu = allocator, gpu
	success := false
	defer if !success do marine_assets_deinit(assets)
	for family in 0 ..< 4 do for clip in 0 ..< 2 {
		if !marine_clip_decode(&assets.clips[family][clip], MARINE_ASSET_BYTES[family][clip], allocator) do return false
	}
	for family in 0 ..< 4 do for clip in 0 ..< 2 do for bucket in 0 ..< 2 {
		data := &assets.clips[family][clip]
		phase := &assets.phases[family][clip][bucket]
		vertices, error := make([]rl.Gpu_3D_Vertex, data.vertex_count, allocator)
		if error != nil do return false
		phase.vertices = vertices
		copy(vertices, data.frames[:data.vertex_count])
		mesh, ok := gpu.create(vertices, data.indices)
		phase.mesh = mesh
		if !ok || mesh.id == 0 do return false
	}
	assets.ready, success = true, true
	return true
}
marine_clip_sample :: proc(assets: ^Marine_Assets, family, clip, bucket: int, seconds: f32) -> bool {
	if assets == nil || !assets.ready || family < 0 || family >= 4 || clip < 0 || clip >= 2 || bucket < 0 || bucket >= 2 || !marine_float_finite(seconds) do return false
	data := &assets.clips[family][clip]
	phase := &assets.phases[family][clip][bucket]
	time := seconds - math.floor(seconds)
	position := time * 16 + f32(bucket * 8)
	first := int(position) % 16
	second := (first + 1) % 16
	blend := position - math.floor(position)
	for &vertex, index in phase.vertices {
		left, right := data.frames[first*data.vertex_count+index], data.frames[second*data.vertex_count+index]
		vertex = left
		vertex.position = left.position + (right.position-left.position)*blend
		vertex.normal = left.normal + (right.normal-left.normal)*blend
		length := math.sqrt(vertex.normal.x*vertex.normal.x + vertex.normal.y*vertex.normal.y + vertex.normal.z*vertex.normal.z)
		if length > 0.000001 do vertex.normal /= length
		else do vertex.normal = left.normal
	}
	return assets.gpu.update(phase.mesh, phase.vertices)
}
