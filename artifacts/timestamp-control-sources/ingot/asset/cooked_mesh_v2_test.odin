#+build !js
package asset

import "core:testing"

// A minimal INGMESH2 writer used only by tests. The production writer lives in
// `ingot/tools/mesh_cook.py`; this exists so the decoder is exercised against
// bytes assembled independently of it, which is the point of a round trip.
_v2_test_writer :: struct {
	bytes:  []u8,
	cursor: int,
}

_v2_put_u32 :: proc(writer: ^_v2_test_writer, value: u32) {
	writer.bytes[writer.cursor + 0] = u8(value)
	writer.bytes[writer.cursor + 1] = u8(value >> 8)
	writer.bytes[writer.cursor + 2] = u8(value >> 16)
	writer.bytes[writer.cursor + 3] = u8(value >> 24)
	writer.cursor += 4
}

_v2_put_f32 :: proc(writer: ^_v2_test_writer, value: f32) {
	_v2_put_u32(writer, transmute(u32)value)
}

_v2_test_lod :: struct {
	first_vertex: u32,
	vertex_count: u32,
	first_index:  u32,
	index_count:  u32,
	error:        f32,
	threshold:    f32,
}

// Two levels of a unit quad: four vertices and two triangles, then three
// vertices and one triangle. Enough to exercise every ordering rule the decoder
// enforces without a fixture large enough to obscure a failure.
_v2_test_bundle :: proc(bytes: []u8, mutate: proc(writer: ^_v2_test_writer)) -> []u8 {
	positions := [7]Vec3 {
		{0, 0, 0},
		{1, 0, 0},
		{0, 1, 0},
		{1, 1, 0},
		{0, 0, 0},
		{1, 0, 0},
		{0, 1, 0},
	}
	indices := [9]u32{0, 1, 2, 1, 3, 2, 0, 1, 2}
	lods := [2]_v2_test_lod{{0, 4, 0, 6, 0, 512}, {4, 3, 6, 3, 0.25, 64}}
	writer := _v2_test_writer{bytes, 0}
	magic := COOKED_MESH_V2_MAGIC
	for value in magic {
		writer.bytes[writer.cursor] = value
		writer.cursor += 1
	}
	_v2_put_u32(&writer, COOKED_MESH_V2_VERSION)
	header := [?]u32{1, 2, 0, 0, 7, 9, 0, 0, 0}
	for value in header do _v2_put_u32(&writer, value)
	mesh := [?]u32{1, 0, 2, 0, 0, 0, 0}
	for value in mesh do _v2_put_u32(&writer, value)
	extents := [?]f32{0, 0, 0, 1, 1, 0, 0, 0, 1, 1}
	for value in extents do _v2_put_f32(&writer, value)
	for lod in lods {
		spans := [?]u32{lod.first_vertex, lod.vertex_count, lod.first_index, lod.index_count}
		for value in spans do _v2_put_u32(&writer, value)
		_v2_put_f32(&writer, lod.error)
		_v2_put_f32(&writer, lod.threshold)
	}
	for position in positions {
		for axis in 0 ..< 3 do _v2_put_f32(&writer, position[axis])
		for axis in 0 ..< 3 do _v2_put_f32(&writer, 1 if axis == 2 else 0)
		_v2_put_f32(&writer, 0)
		_v2_put_f32(&writer, 0)
		_v2_put_f32(&writer, 0)
	}
	for value in indices do _v2_put_u32(&writer, value)
	if mutate != nil do mutate(&writer)
	return bytes[:writer.cursor]
}

_v2_test_size :: proc() -> int {
	return(
		COOKED_MESH_V2_HEADER_SIZE +
		COOKED_MESH_V2_RECORD_SIZE +
		2 * COOKED_MESH_V2_LOD_SIZE +
		7 * size_of(Vertex) +
		9 * size_of(u32) \
	)
}

_v2_test_decode :: proc(bytes: []u8) -> (Cooked_Mesh_V2_Bundle, Cooked_Mesh_Result, bool) {
	@(static) chains: [1]Cooked_Mesh_Chain
	@(static) lods: [2]Mesh_Lod
	@(static) vertices: [7]Vertex
	@(static) indices: [9]u32
	storage := Cooked_Mesh_V2_Storage {
		meshes   = chains[:],
		lods     = lods[:],
		vertices = vertices[:],
		indices  = indices[:],
	}
	return cooked_mesh_v2_decode(bytes, storage)
}

@(test)
cooked_mesh_v2_round_trips_a_lod_chain :: proc(t: ^testing.T) {
	buffer: [512]u8
	bytes := _v2_test_bundle(buffer[:], nil)
	testing.expect_value(t, len(bytes), _v2_test_size())
	bundle, result, ok := _v2_test_decode(bytes)
	testing.expectf(t, ok, "decode failed: %v", result)
	testing.expect_value(t, len(bundle.meshes), 1)
	chain := bundle.meshes[0]
	testing.expect_value(t, chain.id, Mesh_Id(1))
	testing.expect_value(t, len(chain.lods), 2)
	testing.expect_value(t, len(chain.lods[0].view.indices), 6)
	testing.expect_value(t, len(chain.lods[1].view.indices), 3)
	// Coarser levels cost more error and apply at smaller screen heights.
	testing.expect(t, chain.lods[1].error > chain.lods[0].error)
	testing.expect(
		t,
		chain.lods[1].screen_height_threshold < chain.lods[0].screen_height_threshold,
	)
}

@(test)
cooked_mesh_v2_identifies_both_formats :: proc(t: ^testing.T) {
	buffer: [512]u8
	bytes := _v2_test_bundle(buffer[:], nil)
	testing.expect_value(t, cooked_mesh_format(bytes), Cooked_Mesh_Format.V2)
	v1 := _cooked_test_fixture()
	testing.expect_value(t, cooked_mesh_format(v1[:]), Cooked_Mesh_Format.V1)
	junk := [16]u8{}
	testing.expect_value(t, cooked_mesh_format(junk[:]), Cooked_Mesh_Format.Unknown)
	testing.expect_value(t, cooked_mesh_format(nil), Cooked_Mesh_Format.Unknown)
}

// A caller written before LOD chains existed must keep working against a
// re-cooked bundle, seeing LOD 0 and nothing else.
@(test)
cooked_mesh_decode_projects_v2_onto_lod_zero :: proc(t: ^testing.T) {
	buffer: [512]u8
	bytes := _v2_test_bundle(buffer[:], nil)
	meshes: [1]Mesh_View
	vertices: [7]Vertex
	indices: [9]u32
	chains: [1]Cooked_Mesh_Chain
	lods: [2]Mesh_Lod
	scratch := Cooked_Mesh_V2_Scratch {
		chains = chains[:],
		lods   = lods[:],
	}
	bundle, result, ok := cooked_mesh_decode(bytes, {meshes[:], vertices[:], indices[:]}, scratch)
	testing.expectf(t, ok, "projection failed: %v", result)
	testing.expect_value(t, len(bundle.meshes), 1)
	testing.expect_value(t, len(bundle.meshes[0].indices), 6)
	testing.expect_value(t, bundle.vertex_count, u32(7))
}

// Without version 2 scratch the old entry point must refuse rather than read a
// version 2 bundle as if it were version 1.
@(test)
cooked_mesh_decode_rejects_v2_without_scratch :: proc(t: ^testing.T) {
	buffer: [512]u8
	bytes := _v2_test_bundle(buffer[:], nil)
	meshes: [1]Mesh_View
	vertices: [7]Vertex
	indices: [9]u32
	_, result, ok := cooked_mesh_decode(bytes, {meshes[:], vertices[:], indices[:]})
	testing.expect(t, !ok)
	testing.expect_value(t, result.fault, Cooked_Mesh_Fault.Capacity)
}

@(test)
cooked_mesh_v2_rejects_non_monotonic_error :: proc(t: ^testing.T) {
	buffer: [512]u8
	// LOD 1's error is rewritten to match LOD 0's, which would let both levels
	// qualify at one threshold.
	bytes := _v2_test_bundle(buffer[:], proc(writer: ^_v2_test_writer) {
		offset :=
			COOKED_MESH_V2_HEADER_SIZE + COOKED_MESH_V2_RECORD_SIZE + COOKED_MESH_V2_LOD_SIZE + 16
		local := _v2_test_writer{writer.bytes, offset}
		_v2_put_f32(&local, 0)
	})
	_, result, ok := _v2_test_decode(bytes)
	testing.expect(t, !ok)
	testing.expect_value(t, result.fault, Cooked_Mesh_Fault.Invalid_Lod)
}

@(test)
cooked_mesh_v2_rejects_trailing_and_truncated :: proc(t: ^testing.T) {
	buffer: [512]u8
	bytes := _v2_test_bundle(buffer[:], nil)
	_, truncated, truncated_ok := _v2_test_decode(bytes[:len(bytes) - 4])
	testing.expect(t, !truncated_ok)
	testing.expect_value(t, truncated.fault, Cooked_Mesh_Fault.Truncated)
	longer: [520]u8
	copy(longer[:], bytes)
	_, trailing, trailing_ok := _v2_test_decode(longer[:len(bytes) + 4])
	testing.expect(t, !trailing_ok)
	testing.expect_value(t, trailing.fault, Cooked_Mesh_Fault.Trailing_Data)
}

@(test)
cooked_mesh_v2_rejects_unknown_flags :: proc(t: ^testing.T) {
	buffer: [512]u8
	bytes := _v2_test_bundle(buffer[:], proc(writer: ^_v2_test_writer) {
		local := _v2_test_writer{writer.bytes, 36}
		_v2_put_u32(&local, 0xFFFF_FFFF)
	})
	_, result, ok := _v2_test_decode(bytes)
	testing.expect(t, !ok)
	testing.expect_value(t, result.fault, Cooked_Mesh_Fault.Invalid_Flags)
}

@(test)
cooked_mesh_v2_rejects_non_contiguous_lod_spans :: proc(t: ^testing.T) {
	buffer: [512]u8
	// LOD 1 is moved to start one vertex late, leaving a hole no level owns.
	bytes := _v2_test_bundle(buffer[:], proc(writer: ^_v2_test_writer) {
		offset := COOKED_MESH_V2_HEADER_SIZE + COOKED_MESH_V2_RECORD_SIZE + COOKED_MESH_V2_LOD_SIZE
		local := _v2_test_writer{writer.bytes, offset}
		_v2_put_u32(&local, 5)
	})
	_, result, ok := _v2_test_decode(bytes)
	testing.expect(t, !ok)
	testing.expect_value(t, result.fault, Cooked_Mesh_Fault.Invalid_Lod)
}
