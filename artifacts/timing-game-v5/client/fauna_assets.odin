package main

import "core:math"
import rl "ingot:gfx"

FAUNA_WALK_BYTES := #load("../assets/generated/gazelle.inganim", []u8)
FAUNA_IDLE_BYTES := #load("../assets/generated/gazelle-idle.inganim", []u8)
FAUNA_GRAZE_BYTES := #load("../assets/generated/gazelle-graze.inganim", []u8)
FAUNA_HEADER_BYTES :: 52
FAUNA_VERTEX_FLOATS :: 9
FAUNA_VERTEX_BYTES :: FAUNA_VERTEX_FLOATS * 4
FAUNA_MAX_VERTICES :: 8192
FAUNA_MAX_INDICES :: 24576
FAUNA_MAX_FRAMES :: 32

Fauna_Clip :: struct {
	mesh:         rl.Gpu_Mesh,
	frames:       []rl.Gpu_3D_Vertex,
	indices:      []u32,
	vertices:     []rl.Gpu_3D_Vertex,
	vertex_count: int,
	frame_count:  int,
	fps:          f32,
	bounds:       Bounds_3D,
	ready:        bool,
}

Fauna_Assets :: struct {
	walk:   Fauna_Clip,
	idle:   Fauna_Clip,
	graze:  Fauna_Clip,
	bounds: Bounds_3D,
	ready:  bool,
}

_fauna_u32 :: proc(bytes: []u8, offset: int) -> u32 {
	value: u32
	for index in 0 ..< 4 do value |= u32(bytes[offset + index]) << u32(index * 8)
	return value
}

_fauna_f32 :: proc(bytes: []u8, offset: int) -> f32 {
	return transmute(f32)_fauna_u32(bytes, offset)
}

_fauna_clip_init :: proc(value: ^Fauna_Clip, bytes: []u8) -> bool {
	assert(value != nil, "fauna clip init: nil clip")
	if len(bytes) < FAUNA_HEADER_BYTES || string(bytes[:8]) != "INGANI01" do return false
	if _fauna_u32(bytes, 8) != 1 do return false
	vertex_count := int(_fauna_u32(bytes, 12))
	index_count := int(_fauna_u32(bytes, 16))
	frame_count := int(_fauna_u32(bytes, 20))
	fps := _fauna_u32(bytes, 24)
	if vertex_count <= 0 || vertex_count > FAUNA_MAX_VERTICES do return false
	if index_count <= 0 || index_count > FAUNA_MAX_INDICES || index_count % 3 != 0 do return false
	if frame_count <= 1 || frame_count > FAUNA_MAX_FRAMES || fps == 0 do return false
	expected :=
		FAUNA_HEADER_BYTES + index_count * 4 + frame_count * vertex_count * FAUNA_VERTEX_BYTES
	if len(bytes) != expected do return false
	value.indices = make([]u32, index_count)
	value.frames = make([]rl.Gpu_3D_Vertex, frame_count * vertex_count)
	value.vertices = make([]rl.Gpu_3D_Vertex, vertex_count)
	cursor := FAUNA_HEADER_BYTES
	for &index in value.indices {
		index = _fauna_u32(bytes, cursor)
		if int(index) >= vertex_count do return false
		cursor += 4
	}
	for &vertex in value.frames {
		vertex.position = {
			_fauna_f32(bytes, cursor),
			_fauna_f32(bytes, cursor + 4),
			_fauna_f32(bytes, cursor + 8),
		}
		vertex.normal = {
			_fauna_f32(bytes, cursor + 12),
			_fauna_f32(bytes, cursor + 16),
			_fauna_f32(bytes, cursor + 20),
		}
		vertex.scalar = _fauna_f32(bytes, cursor + 24)
		vertex.uv = {_fauna_f32(bytes, cursor + 28), _fauna_f32(bytes, cursor + 32)}
		cursor += FAUNA_VERTEX_BYTES
	}
	copy(value.vertices, value.frames[:vertex_count])
	value.mesh, value.ready = rl.create_gpu_mesh(value.vertices, value.indices, .Triangles)
	value.vertex_count = vertex_count
	value.frame_count = frame_count
	value.fps = f32(fps)
	value.bounds = {
		min = {_fauna_f32(bytes, 28), _fauna_f32(bytes, 32), _fauna_f32(bytes, 36)},
		max = {_fauna_f32(bytes, 40), _fauna_f32(bytes, 44), _fauna_f32(bytes, 48)},
	}
	return value.ready
}

fauna_assets_init :: proc(value: ^Fauna_Assets) -> bool {
	assert(value != nil, "fauna assets init: nil assets")
	if value.ready do return true
	if !_fauna_clip_init(&value.walk, FAUNA_WALK_BYTES) do return false
	if !_fauna_clip_init(&value.idle, FAUNA_IDLE_BYTES) do return false
	if !_fauna_clip_init(&value.graze, FAUNA_GRAZE_BYTES) do return false
	value.bounds = value.walk.bounds
	bounds := [2]Bounds_3D{value.idle.bounds, value.graze.bounds}
	for candidate in bounds {
		for axis in 0 ..< 3 {
			value.bounds.min[axis] = min(value.bounds.min[axis], candidate.min[axis])
			value.bounds.max[axis] = max(value.bounds.max[axis], candidate.max[axis])
		}
	}
	value.ready = true
	return true
}

_fauna_clip_deinit :: proc(value: ^Fauna_Clip) {
	if value == nil do return
	if value.mesh.id != 0 do rl.destroy_gpu_mesh(&value.mesh)
	delete(value.vertices)
	delete(value.indices)
	delete(value.frames)
	value^ = {}
}

fauna_assets_deinit :: proc(value: ^Fauna_Assets) {
	if value == nil do return
	_fauna_clip_deinit(&value.walk)
	_fauna_clip_deinit(&value.idle)
	_fauna_clip_deinit(&value.graze)
	value^ = {}
}

fauna_clip_sample :: proc(value: ^Fauna_Clip, time_seconds: f32) -> bool {
	assert(value != nil && value.ready, "fauna clip sample: clip not ready")
	phase := time_seconds * value.fps
	first := int(phase) % value.frame_count
	second := (first + 1) % value.frame_count
	blend := phase - f32(int(phase))
	for &vertex, index in value.vertices {
		a := value.frames[first * value.vertex_count + index]
		b := value.frames[second * value.vertex_count + index]
		vertex.position = a.position + (b.position - a.position) * blend
		vertex.normal = a.normal + (b.normal - a.normal) * blend
		length := math.sqrt(
			vertex.normal.x * vertex.normal.x +
			vertex.normal.y * vertex.normal.y +
			vertex.normal.z * vertex.normal.z,
		)
		if length > 0 do vertex.normal /= length
		vertex.scalar = a.scalar
		vertex.uv = a.uv
	}
	return rl.update_gpu_mesh_vertices(value.mesh, value.vertices)
}
