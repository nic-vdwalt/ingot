package asset

import "core:math"

Vec2 :: [2]f32
Vec3 :: [3]f32

Bounds_3D :: struct {
	minimum: Vec3,
	maximum: Vec3,
}

Bounds_2D :: struct {
	minimum: Vec2,
	maximum: Vec2,
}

Vertex :: struct {
	position: Vec3,
	normal:   Vec3,
	scalar:   f32,
	uv:       Vec2,
}

// A cooked vertex costs 36 bytes as `Vertex`. `Vertex_Packed` stores the same
// four attributes in 16 bytes: position quantized into the mesh bounds, the
// normal through an octahedral projection, UV quantized into the mesh UV
// bounds, and the scalar channel over its documented 0..2 range. The 2.25x
// reduction applies to file size and vertex-fetch bandwidth alike, which is
// the dominant cost once a mesh carries a full LOD chain rather than one level.
Vertex_Packed :: struct {
	position: [3]u16,
	normal:   [2]i8,
	uv:       [2]u16,
	scalar:   u8,
	_pad:     [3]u8,
}

// Quantization is derived entirely from the mesh's own bounds, so a decoder
// never needs a side table and two encoders of the same mesh cannot disagree.
Vertex_Quantization :: struct {
	bounds:    Bounds_3D,
	uv_bounds: Bounds_2D,
}

VERTEX_PACKED_POSITION_RANGE :: f32(65535)
VERTEX_PACKED_UV_RANGE :: f32(65535)
VERTEX_PACKED_NORMAL_RANGE :: f32(127)
VERTEX_PACKED_SCALAR_RANGE :: f32(255)
// The scalar channel is application-defined but documented as 0..2 (0 rigid,
// 1 wind-driven foliage, 1.5 grass wind plus distance dithering), so one byte
// covers the whole range at steps of 2/255.
VERTEX_PACKED_SCALAR_MAX :: f32(2)

Primitive :: enum u8 {
	Triangles,
	Lines,
	Points,
}

Mesh_Id :: distinct u32
Material_Id :: distinct u16

Mesh_View :: struct {
	id:        Mesh_Id,
	vertices:  []Vertex,
	indices:   []u32,
	primitive: Primitive,
	bounds:    Bounds_3D,
}

Mesh_Buffer :: struct {
	id:           Mesh_Id,
	vertices:     []Vertex,
	indices:      []u32,
	vertex_count: u32,
	index_count:  u32,
	primitive:    Primitive,
	bounds:       Bounds_3D,
}

mesh_reset :: proc(mesh: ^Mesh_Buffer) {
	assert(mesh != nil, "mesh_reset: nil mesh")
	mesh.vertex_count = 0
	mesh.index_count = 0
	mesh.bounds = {}
}

mesh_view :: proc(mesh: ^Mesh_Buffer) -> (Mesh_View, bool) {
	assert(mesh != nil, "mesh_view: nil mesh")
	if mesh.vertex_count == 0 || mesh.index_count == 0 do return {}, false
	if int(mesh.vertex_count) > len(mesh.vertices) do return {}, false
	if int(mesh.index_count) > len(mesh.indices) do return {}, false
	result := Mesh_View {
		id        = mesh.id,
		vertices  = mesh.vertices[:mesh.vertex_count],
		indices   = mesh.indices[:mesh.index_count],
		primitive = mesh.primitive,
		bounds    = mesh.bounds,
	}
	return result, mesh_validate(result)
}

mesh_validate :: proc(mesh: Mesh_View) -> bool {
	if mesh.id == 0 || len(mesh.vertices) == 0 || len(mesh.indices) == 0 do return false
	if mesh.primitive == .Triangles && len(mesh.indices) % 3 != 0 do return false
	if mesh.primitive == .Lines && len(mesh.indices) % 2 != 0 do return false
	if !bounds_valid(mesh.bounds) do return false
	for vertex in mesh.vertices {
		for component in vertex.position {
			if math.is_nan(component) || math.is_inf(component, 0) do return false
		}
		for component in vertex.normal {
			if math.is_nan(component) || math.is_inf(component, 0) do return false
		}
		if math.is_nan(vertex.scalar) || math.is_inf(vertex.scalar, 0) do return false
		for component in vertex.uv {
			if math.is_nan(component) || math.is_inf(component, 0) do return false
		}
		for axis in 0 ..< 3 {
			if vertex.position[axis] < mesh.bounds.minimum[axis] do return false
			if vertex.position[axis] > mesh.bounds.maximum[axis] do return false
		}
	}
	for index in mesh.indices {
		if int(index) >= len(mesh.vertices) do return false
	}
	return true
}

bounds_valid :: proc(bounds: Bounds_3D) -> bool {
	for axis in 0 ..< 3 {
		minimum := bounds.minimum[axis]
		maximum := bounds.maximum[axis]
		if math.is_nan(minimum) || math.is_inf(minimum, 0) do return false
		if math.is_nan(maximum) || math.is_inf(maximum, 0) do return false
		if minimum > maximum do return false
	}
	return true
}

// quantization_from_mesh derives the packing frame from a validated mesh. UV
// bounds are measured rather than assumed [0,1] so atlas-repacked and tiling
// meshes both round-trip without silent clamping.
quantization_from_mesh :: proc(mesh: Mesh_View) -> (Vertex_Quantization, bool) {
	assert(mesh.id != 0, "quantization_from_mesh: zero mesh id")
	assert(len(mesh.vertices) > 0, "quantization_from_mesh: empty vertices")
	if !bounds_valid(mesh.bounds) do return {}, false
	result := Vertex_Quantization {
		bounds    = mesh.bounds,
		uv_bounds = {minimum = mesh.vertices[0].uv, maximum = mesh.vertices[0].uv},
	}
	for vertex in mesh.vertices[1:] {
		for axis in 0 ..< 2 {
			result.uv_bounds.minimum[axis] = min(result.uv_bounds.minimum[axis], vertex.uv[axis])
			result.uv_bounds.maximum[axis] = max(result.uv_bounds.maximum[axis], vertex.uv[axis])
		}
	}
	if !quantization_valid(result) do return {}, false
	return result, true
}

quantization_valid :: proc(quantization: Vertex_Quantization) -> bool {
	if !bounds_valid(quantization.bounds) do return false
	for axis in 0 ..< 2 {
		minimum := quantization.uv_bounds.minimum[axis]
		maximum := quantization.uv_bounds.maximum[axis]
		if math.is_nan(minimum) || math.is_inf(minimum, 0) do return false
		if math.is_nan(maximum) || math.is_inf(maximum, 0) do return false
		if minimum > maximum do return false
	}
	return true
}

vertex_pack :: proc(vertex: Vertex, quantization: Vertex_Quantization) -> Vertex_Packed {
	assert(quantization_valid(quantization), "vertex_pack: invalid quantization")
	assert(!math.is_nan(vertex.scalar), "vertex_pack: NaN scalar")
	result: Vertex_Packed
	for axis in 0 ..< 3 {
		result.position[axis] = _quantize_channel(
			vertex.position[axis],
			quantization.bounds.minimum[axis],
			quantization.bounds.maximum[axis],
			VERTEX_PACKED_POSITION_RANGE,
		)
	}
	for axis in 0 ..< 2 {
		result.uv[axis] = _quantize_channel(
			vertex.uv[axis],
			quantization.uv_bounds.minimum[axis],
			quantization.uv_bounds.maximum[axis],
			VERTEX_PACKED_UV_RANGE,
		)
	}
	encoded := _octahedral_encode(vertex.normal)
	for axis in 0 ..< 2 {
		clamped := clamp(encoded[axis], -1, 1)
		result.normal[axis] = i8(math.round(clamped * VERTEX_PACKED_NORMAL_RANGE))
	}
	scalar := clamp(vertex.scalar, 0, VERTEX_PACKED_SCALAR_MAX) / VERTEX_PACKED_SCALAR_MAX
	result.scalar = u8(math.round(scalar * VERTEX_PACKED_SCALAR_RANGE))
	return result
}

vertex_unpack :: proc(packed: Vertex_Packed, quantization: Vertex_Quantization) -> Vertex {
	assert(quantization_valid(quantization), "vertex_unpack: invalid quantization")
	assert(packed._pad == {0, 0, 0}, "vertex_unpack: dirty padding")
	result: Vertex
	for axis in 0 ..< 3 {
		result.position[axis] = _dequantize_channel(
			packed.position[axis],
			quantization.bounds.minimum[axis],
			quantization.bounds.maximum[axis],
			VERTEX_PACKED_POSITION_RANGE,
		)
	}
	for axis in 0 ..< 2 {
		result.uv[axis] = _dequantize_channel(
			packed.uv[axis],
			quantization.uv_bounds.minimum[axis],
			quantization.uv_bounds.maximum[axis],
			VERTEX_PACKED_UV_RANGE,
		)
	}
	encoded := Vec2 {
		f32(packed.normal[0]) / VERTEX_PACKED_NORMAL_RANGE,
		f32(packed.normal[1]) / VERTEX_PACKED_NORMAL_RANGE,
	}
	result.normal = _octahedral_decode(encoded)
	scalar := f32(packed.scalar) / VERTEX_PACKED_SCALAR_RANGE
	result.scalar = scalar * VERTEX_PACKED_SCALAR_MAX
	return result
}

// vertex_position_tolerance is half a quantization step per axis: the largest
// positional error a correct encoder may introduce. Tests and the cook tool
// both compare against this rather than a hand-picked epsilon.
vertex_position_tolerance :: proc(quantization: Vertex_Quantization) -> Vec3 {
	assert(quantization_valid(quantization), "vertex_position_tolerance: invalid quantization")
	result: Vec3
	for axis in 0 ..< 3 {
		extent := quantization.bounds.maximum[axis] - quantization.bounds.minimum[axis]
		assert(extent >= 0, "vertex_position_tolerance: inverted bounds")
		result[axis] = extent / (VERTEX_PACKED_POSITION_RANGE * 2)
	}
	return result
}

@(private)
_quantize_channel :: proc(value, minimum, maximum, range: f32) -> u16 {
	extent := maximum - minimum
	if extent <= 0 do return 0
	normalized := clamp((value - minimum) / extent, 0, 1)
	return u16(math.round(normalized * range))
}

@(private)
_dequantize_channel :: proc(value: u16, minimum, maximum, range: f32) -> f32 {
	extent := maximum - minimum
	if extent <= 0 do return minimum
	return minimum + (f32(value) / range) * extent
}

@(private)
_sign_nonzero :: proc(value: f32) -> f32 {
	if value >= 0 do return 1
	return -1
}

// The octahedral projection maps a unit sphere onto the [-1,1] square. The
// upper hemisphere projects directly; the lower one folds outward across the
// octahedron's diagonals, which is what keeps the two-component form bijective.
@(private)
_octahedral_encode :: proc(normal: Vec3) -> Vec2 {
	sum := abs(normal.x) + abs(normal.y) + abs(normal.z)
	if sum <= 0 do return {0, 0}
	projected := Vec2{normal.x / sum, normal.y / sum}
	if normal.z >= 0 do return projected
	return Vec2 {
		(1 - abs(projected.y)) * _sign_nonzero(projected.x),
		(1 - abs(projected.x)) * _sign_nonzero(projected.y),
	}
}

@(private)
_octahedral_decode :: proc(encoded: Vec2) -> Vec3 {
	result := Vec3{encoded.x, encoded.y, 1 - abs(encoded.x) - abs(encoded.y)}
	if result.z < 0 {
		folded_x := (1 - abs(result.y)) * _sign_nonzero(result.x)
		folded_y := (1 - abs(result.x)) * _sign_nonzero(result.y)
		result.x = folded_x
		result.y = folded_y
	}
	length := math.sqrt(result.x * result.x + result.y * result.y + result.z * result.z)
	// A zero-length normal only reaches here from a degenerate source vertex;
	// +Z is the documented substitute rather than a NaN propagated downstream.
	if length <= 0 do return {0, 0, 1}
	return result / length
}

#assert(size_of(Vertex) == 36)
#assert(size_of(Vertex_Packed) == 16)
