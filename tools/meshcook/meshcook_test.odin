package meshcook

import "core:encoding/endian"
import "core:math"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "ingot:examples/gallery/imsh"

// QUAD_JSON describes one two-triangle quad in the glTF XY plane, offset by a
// node translation of +2 along glTF Z. The BIN chunk holds 4 float3
// positions (48 bytes) then 6 u16 indices (12 bytes).
QUAD_JSON ::
	`{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],` +
	`"nodes":[{"mesh":0,"translation":[0,0,2]}],` +
	`"meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1}]}],` +
	`"buffers":[{"byteLength":60}],` +
	`"bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":48},` +
	`{"buffer":0,"byteOffset":48,"byteLength":12}],` +
	`"accessors":[{"bufferView":0,"componentType":5126,"count":4,"type":"VEC3"},` +
	`{"bufferView":1,"componentType":5123,"count":6,"type":"SCALAR"}]}`

@(private = "file")
pad4 :: proc(length: int) -> int {
	return (length + 3) &~ 3
}

// build_glb assembles a GLB container around `json_text` and `bin`, padding
// the JSON chunk with spaces as the spec requires.
@(private = "file")
build_glb :: proc(json_text: string, bin: []u8) -> []u8 {
	json_length := pad4(len(json_text))
	bin_length := pad4(len(bin))
	total := 12 + 8 + json_length + 8 + bin_length
	out := make([]u8, total, context.temp_allocator)
	_ = endian.put_u32(out[0:], .Little, GLB_MAGIC)
	_ = endian.put_u32(out[4:], .Little, 2)
	_ = endian.put_u32(out[8:], .Little, u32(total))
	_ = endian.put_u32(out[12:], .Little, u32(json_length))
	_ = endian.put_u32(out[16:], .Little, GLB_CHUNK_JSON)
	copy(out[20:], json_text)
	for i in len(json_text) ..< json_length do out[20 + i] = ' '
	bin_header := 20 + json_length
	_ = endian.put_u32(out[bin_header:], .Little, u32(bin_length))
	_ = endian.put_u32(out[bin_header + 4:], .Little, GLB_CHUNK_BIN)
	copy(out[bin_header + 8:], bin)
	return out
}

@(private = "file")
quad_bin :: proc() -> []u8 {
	positions := [4][3]f32{{0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 1, 0}}
	indices := [6]u16{0, 1, 2, 0, 2, 3}
	out := make([]u8, 60, context.temp_allocator)
	for p, i in positions {
		for axis in 0 ..< 3 {
			_ = endian.put_u32(out[i * 12 + axis * 4:], .Little, transmute(u32)p[axis])
		}
	}
	for index, i in indices do _ = endian.put_u16(out[48 + i * 2:], .Little, index)
	return out
}

@(private = "file")
quad_glb :: proc() -> []u8 {
	return build_glb(QUAD_JSON, quad_bin())
}

@(private = "file")
with_arena :: proc(arena: ^virtual.Arena) -> bool {
	if virtual.arena_init_growing(arena) != nil do return false
	context.allocator = virtual.arena_allocator(arena)
	return true
}

@(test)
cook_quad_round_trips_into_ros_space :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	glb, err := glb_parse(quad_glb())
	testing.expect_value(t, err, Glb_Error.None)
	src: Source
	testing.expect_value(t, source_gather(&glb, &src), Glb_Error.None)
	testing.expect_value(t, len(src.positions), 4)
	// glTF (x, y, z + 2) maps to ROS (z, x, y): the node offset lands on +X.
	testing.expect_value(t, src.positions[2], [3]f32{2, 1, 1})
	// Missing normals are computed; the glTF +Z face normal becomes ROS +X.
	testing.expect(t, math.abs(src.normals[0].x - 1) < 1e-5, "normal follows ROS +X")

	cooked: Cooked
	testing.expect_value(t, cook_mesh(&glb, &src, 1000, false, &cooked), Cook_Error.None)
	info, info_err := imsh.decode_info(cooked.file_bytes)
	testing.expect_value(t, info_err, imsh.Error.None)
	testing.expect_value(t, info.index_count, 6)
	vertices: [8]imsh.Vertex
	indices: [6]u32
	testing.expect_value(
		t,
		imsh.decode_vertices(cooked.file_bytes, info, vertices[:]),
		imsh.Error.None,
	)
	testing.expect_value(
		t,
		imsh.decode_indices(cooked.file_bytes, info, indices[:]),
		imsh.Error.None,
	)
	a := vertices[indices[0]].position
	b := vertices[indices[1]].position
	c := vertices[indices[2]].position
	// Winding survives the basis change: the face still points along ROS +X.
	normal := [3]f32 {
		(b.y - a.y) * (c.z - a.z) - (b.z - a.z) * (c.y - a.y),
		(b.z - a.z) * (c.x - a.x) - (b.x - a.x) * (c.z - a.z),
		(b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x),
	}
	testing.expect(t, normal.x > 0, "winding preserved")
}

@(test)
glb_parse_rejects_malformed_containers :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, with_arena(&arena))
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	good := quad_glb()
	bad_magic := make([]u8, len(good), context.temp_allocator)
	copy(bad_magic, good)
	bad_magic[0] = 'x'
	_, magic_err := glb_parse(bad_magic)
	testing.expect_value(t, magic_err, Glb_Error.Bad_Magic)

	_, short_err := glb_parse(good[:len(good) - 4])
	testing.expect_value(t, short_err, Glb_Error.Bad_Length)

	_, tiny_err := glb_parse(good[:8])
	testing.expect_value(t, tiny_err, Glb_Error.Too_Small)
}

@(test)
accessor_view_rejects_out_of_range_windows :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, with_arena(&arena))
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	oversized, _ := strings.replace(
		QUAD_JSON,
		`"count":4`,
		`"count":40`,
		1,
		context.temp_allocator,
	)
	glb, err := glb_parse(build_glb(oversized, quad_bin()))
	testing.expect_value(t, err, Glb_Error.None)
	src: Source
	testing.expect_value(t, source_gather(&glb, &src), Glb_Error.Bad_Accessor)
}

@(test)
node_cycles_are_rejected_without_recursion :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, with_arena(&arena))
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	cyclic, _ := strings.replace(
		QUAD_JSON,
		`"nodes":[{"mesh":0,"translation":[0,0,2]}]`,
		`"nodes":[{"mesh":0,"children":[1]},{"children":[0]}]`,
		1,
		context.temp_allocator,
	)
	glb, err := glb_parse(build_glb(cyclic, quad_bin()))
	testing.expect_value(t, err, Glb_Error.None)
	src: Source
	testing.expect_value(t, source_gather(&glb, &src), Glb_Error.Node_Cycle)
}

@(test)
cook_is_deterministic_and_respects_budget :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, with_arena(&arena))
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	// A 64 x 64 grid sphere (8,064 triangles) cooked into a 2,000 budget.
	src: Source
	rings, slices := 64, 64
	for ring in 0 ..= rings {
		phi := math.PI * f32(ring) / f32(rings)
		for slice in 0 ..= slices {
			theta := 2 * math.PI * f32(slice) / f32(slices)
			p := [3]f32 {
				math.sin(phi) * math.cos(theta),
				math.sin(phi) * math.sin(theta),
				math.cos(phi),
			}
			append(&src.positions, p)
			append(&src.normals, p)
			append(&src.uvs, [2]f32{f32(slice) / f32(slices), f32(ring) / f32(rings)})
			append(&src.colors, [3]f32{1, 1, 1})
			append(&src.submesh_of, 0)
		}
	}
	for ring in 0 ..< rings {
		for slice in 0 ..< slices {
			a := u32(ring * (slices + 1) + slice)
			b := a + u32(slices + 1)
			append(&src.indices, a, b, a + 1, a + 1, b, b + 1)
		}
	}
	append(
		&src.submeshes,
		Source_Submesh{index_offset = 0, index_count = len(src.indices), material = -1},
	)
	src.bounds_min = {-1, -1, -1}
	src.bounds_max = {1, 1, 1}
	glb: Glb
	first, second: Cooked
	testing.expect_value(t, cook_mesh(&glb, &src, 2000, false, &first), Cook_Error.None)
	testing.expect_value(t, cook_mesh(&glb, &src, 2000, false, &second), Cook_Error.None)
	testing.expect(t, len(first.indices) / 3 <= 2000, "triangle budget respected")
	for index in first.indices do testing.expect(t, int(index) < len(first.vertices))
	testing.expect_value(t, len(first.file_bytes), len(second.file_bytes))
	testing.expect(
		t,
		string(first.file_bytes) == string(second.file_bytes),
		"deterministic output",
	)
}

@(test)
imsh_decode_rejects_truncated_and_corrupted_files :: proc(t: ^testing.T) {
	submeshes := [1]imsh.Submesh {
		{index_offset = 0, index_count = 3, base_color = 255, texture_slot = -1},
	}
	vertices := [3]imsh.Vertex {
		{position = {0, 0, 0}, normal = {0, 0, 1}},
		{position = {1, 0, 0}, normal = {0, 0, 1}},
		{position = {0, 1, 0}, normal = {0, 0, 1}},
	}
	indices := [3]u32{0, 1, 2}
	bytes, err := imsh.encode(submeshes[:], vertices[:], indices[:], context.temp_allocator)
	testing.expect_value(t, err, imsh.Error.None)
	_, truncated := imsh.decode_info(bytes[:len(bytes) - 1])
	testing.expect_value(t, truncated, imsh.Error.Size_Mismatch)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[0] = 0
	_, magic := imsh.decode_info(corrupt)
	testing.expect_value(t, magic, imsh.Error.Bad_Magic)
	copy(corrupt, bytes)
	_ = endian.put_u16(corrupt[len(corrupt) - 2:], .Little, 9)
	info, info_err := imsh.decode_info(corrupt)
	testing.expect_value(t, info_err, imsh.Error.None)
	out: [3]u32
	testing.expect_value(t, imsh.decode_indices(corrupt, info, out[:]), imsh.Error.Bad_Index)
}
