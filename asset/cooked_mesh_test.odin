#+build !js
package asset

import "core:testing"

_cooked_test_put_u32 :: proc(bytes: []u8, offset: int, value: u32) {
	bytes[offset + 0] = u8(value)
	bytes[offset + 1] = u8(value >> 8)
	bytes[offset + 2] = u8(value >> 16)
	bytes[offset + 3] = u8(value >> 24)
}

_cooked_test_put_f32 :: proc(bytes: []u8, offset: int, value: f32) {
	_cooked_test_put_u32(bytes, offset, transmute(u32)value)
}

_cooked_test_fixture :: proc() -> [280]u8 {
	bytes: [280]u8
	magic := COOKED_MESH_MAGIC
	for index in 0 ..< len(magic) do bytes[index] = magic[index]
	_cooked_test_put_u32(bytes[:], 8, COOKED_MESH_VERSION)
	_cooked_test_put_u32(bytes[:], 12, 2)
	_cooked_test_put_u32(bytes[:], 16, 4)
	_cooked_test_put_u32(bytes[:], 20, 6)
	_cooked_test_record(bytes[:], 24, 1, 0, 3, 0, 3, {0, 0, 0}, {1, 1, 0})
	_cooked_test_record(bytes[:], 68, 2, 3, 1, 3, 3, {2, 0, 0}, {2, 0, 0})
	vertex_offset := 112
	_cooked_test_vertex(bytes[:], vertex_offset + 0 * 36, {0, 0, 0}, 0)
	_cooked_test_vertex(bytes[:], vertex_offset + 1 * 36, {1, 0, 0}, 1)
	_cooked_test_vertex(bytes[:], vertex_offset + 2 * 36, {0, 1, 0}, 1.5)
	_cooked_test_vertex(bytes[:], vertex_offset + 3 * 36, {2, 0, 0}, 0)
	index_offset := vertex_offset + 4 * 36
	indices := [?]u32{0, 1, 2, 0, 0, 0}
	for index in 0 ..< len(indices) {
		_cooked_test_put_u32(bytes[:], index_offset + index * 4, indices[index])
	}
	return bytes
}

_cooked_test_record :: proc(
	bytes: []u8,
	offset: int,
	id, first_vertex, vertex_count, first_index, index_count: u32,
	minimum, maximum: Vec3,
) {
	values := [?]u32{id, first_vertex, vertex_count, first_index, index_count}
	for index in 0 ..< len(values) do _cooked_test_put_u32(bytes, offset + index * 4, values[index])
	for axis in 0 ..< 3 {
		_cooked_test_put_f32(bytes, offset + 20 + axis * 4, minimum[axis])
		_cooked_test_put_f32(bytes, offset + 32 + axis * 4, maximum[axis])
	}
}

_cooked_test_vertex :: proc(bytes: []u8, offset: int, position: Vec3, scalar: f32) {
	for axis in 0 ..< 3 {
		_cooked_test_put_f32(bytes, offset + axis * 4, position[axis])
		normal := f32(0)
		if axis == 2 do normal = 1
		_cooked_test_put_f32(bytes, offset + 12 + axis * 4, normal)
	}
	_cooked_test_put_f32(bytes, offset + 24, scalar)
}

_cooked_test_decode :: proc(bytes: []u8) -> (Cooked_Mesh_Bundle, Cooked_Mesh_Result, bool) {
	meshes: [2]Mesh_View
	vertices: [4]Vertex
	indices: [6]u32
	return cooked_mesh_decode(bytes, {meshes[:], vertices[:], indices[:]})
}

@(test)
cooked_mesh_decodes_multiple_meshes :: proc(t: ^testing.T) {
	bytes := _cooked_test_fixture()
	meshes: [2]Mesh_View
	vertices: [4]Vertex
	indices: [6]u32
	bundle, result, ok := cooked_mesh_decode(bytes[:], {meshes[:], vertices[:], indices[:]})
	testing.expect(t, ok)
	testing.expect_value(t, result.fault, Cooked_Mesh_Fault.None)
	testing.expect_value(t, len(bundle.meshes), 2)
	testing.expect_value(t, bundle.vertex_count, 4)
	mesh, found := cooked_mesh_find(bundle, 2)
	testing.expect(t, found)
	testing.expect_value(t, len(mesh.vertices), 1)
	testing.expect_value(t, mesh.vertices[0].position, Vec3{2, 0, 0})
	_, found = cooked_mesh_find(bundle, 3)
	testing.expect(t, !found)
}

@(test)
cooked_mesh_rejects_bad_header_and_version :: proc(t: ^testing.T) {
	bytes := _cooked_test_fixture()
	bytes[0] = 0
	_, result, ok := _cooked_test_decode(bytes[:])
	testing.expect(t, !ok)
	testing.expect_value(t, result.fault, Cooked_Mesh_Fault.Bad_Magic)
	bytes = _cooked_test_fixture()
	_cooked_test_put_u32(bytes[:], 8, 2)
	_, result, ok = _cooked_test_decode(bytes[:])
	testing.expect(t, !ok)
	testing.expect_value(t, result.fault, Cooked_Mesh_Fault.Bad_Version)
}

@(test)
cooked_mesh_rejects_truncation_and_trailing_data :: proc(t: ^testing.T) {
	bytes := _cooked_test_fixture()
	_, result, ok := _cooked_test_decode(bytes[:len(bytes) - 1])
	testing.expect(t, !ok)
	testing.expect_value(t, result.fault, Cooked_Mesh_Fault.Truncated)
	larger: [281]u8
	copy(larger[:], bytes[:])
	_, result, ok = _cooked_test_decode(larger[:])
	testing.expect(t, !ok)
	testing.expect_value(t, result.fault, Cooked_Mesh_Fault.Trailing_Data)
}

@(test)
cooked_mesh_rejects_capacity_and_range_overflow :: proc(t: ^testing.T) {
	bytes := _cooked_test_fixture()
	meshes: [1]Mesh_View
	vertices: [4]Vertex
	indices: [6]u32
	_, result, ok := cooked_mesh_decode(bytes[:], {meshes[:], vertices[:], indices[:]})
	testing.expect(t, !ok)
	testing.expect_value(t, result.fault, Cooked_Mesh_Fault.Capacity)
	bytes = _cooked_test_fixture()
	_cooked_test_put_u32(bytes[:], 24 + 4, 1)
	_, result, ok = _cooked_test_decode(bytes[:])
	testing.expect(t, !ok)
	testing.expect_value(t, result.fault, Cooked_Mesh_Fault.Invalid_Record)
}

@(test)
cooked_mesh_rejects_duplicate_and_unsorted_ids :: proc(t: ^testing.T) {
	bytes := _cooked_test_fixture()
	_cooked_test_put_u32(bytes[:], 68, 1)
	_, result, ok := _cooked_test_decode(bytes[:])
	testing.expect(t, !ok)
	testing.expect_value(t, result.fault, Cooked_Mesh_Fault.Invalid_Record)
	bytes = _cooked_test_fixture()
	_cooked_test_put_u32(bytes[:], 24, 3)
	_, result, ok = _cooked_test_decode(bytes[:])
	testing.expect(t, !ok)
	testing.expect_value(t, result.fault, Cooked_Mesh_Fault.Invalid_Record)
}

@(test)
cooked_mesh_rejects_invalid_vertex_index_and_bounds :: proc(t: ^testing.T) {
	bytes := _cooked_test_fixture()
	_cooked_test_put_u32(bytes[:], 256, 3)
	_, result, ok := _cooked_test_decode(bytes[:])
	testing.expect(t, !ok)
	testing.expect_value(t, result.fault, Cooked_Mesh_Fault.Invalid_Mesh)
	bytes = _cooked_test_fixture()
	_cooked_test_put_f32(bytes[:], 24 + 20, 0.5)
	_, result, ok = _cooked_test_decode(bytes[:])
	testing.expect(t, !ok)
	testing.expect_value(t, result.fault, Cooked_Mesh_Fault.Invalid_Mesh)
}
