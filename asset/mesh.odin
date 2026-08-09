package asset

import "core:math"

Vec2 :: [2]f32
Vec3 :: [3]f32

Bounds_3D :: struct {
	minimum: Vec3,
	maximum: Vec3,
}

Vertex :: struct {
	position: Vec3,
	normal:   Vec3,
	scalar:   f32,
	uv:       Vec2,
}

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

#assert(size_of(Vertex) == 36)
