package meshcook

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "ingot:examples/gallery/imsh"
import stbi "vendor:stb/image"

COOK_TRIANGLE_DEFAULT :: 60_000
COOK_TEXTURE_EDGE_DEFAULT :: 1024
COOK_TEXTURE_EDGE_MAX :: 4096
COOK_TEXTURE_BYTE_MAX :: imsh.FILE_BYTE_MAX
COOK_TEXTURE_ATTEMPT_MAX :: 4
COOK_SOURCE_VERTEX_MAX :: 4 * 1024 * 1024
COOK_GRID_MIN :: 16
COOK_GRID_MAX :: 2047
COOK_SEARCH_STEP_MAX :: 16
JPEG_QUALITY :: 86

Cook_Error :: enum u8 {
	None,
	Glb,
	No_Triangles,
	Too_Many_Submeshes,
	Too_Many_Source_Vertices,
	Budget_Unreachable,
	Encode,
	Texture_Missing,
	Texture_Unsupported,
	Texture_Decode,
	Texture_Too_Large,
}

Source_Submesh :: struct {
	index_offset: int,
	index_count:  int,
	material:     int,
	has_color:    bool,
}

// Source is every triangle primitive of the default scene, flattened into
// ROS world space. Submesh ranges index `indices` in order.
Source :: struct {
	positions:  [dynamic][3]f32,
	normals:    [dynamic][3]f32,
	uvs:        [dynamic][2]f32,
	colors:     [dynamic][3]f32,
	submesh_of: [dynamic]u8,
	indices:    [dynamic]u32,
	submeshes:  [dynamic]Source_Submesh,
	bounds_min: [3]f32,
	bounds_max: [3]f32,
}

Cooked :: struct {
	submeshes:  [dynamic]imsh.Submesh,
	vertices:   [dynamic]imsh.Vertex,
	indices:    [dynamic]u32,
	grid:       int,
	file_bytes: []u8,
}

// gltf_to_ros converts glTF (+Y up, +Z toward the viewer, +X right) into
// ROS (+X forward, +Y left, +Z up). The mapping is a cyclic permutation, so
// its determinant is +1 and triangle winding is preserved.
gltf_to_ros :: proc(value: [3]f32) -> [3]f32 {
	return {value.z, value.x, value.y}
}

@(private)
transform_point :: proc(world: matrix[4, 4]f32, point: [3]f32) -> [3]f32 {
	result := world * [4]f32{point.x, point.y, point.z, 1}
	return result.xyz
}

@(private)
safe_normalize :: proc(value: [3]f32) -> [3]f32 {
	length := linalg.length(value)
	if length <= 1e-12 || math.is_nan(length) do return {0, 0, 1}
	return value / length
}

@(private)
source_append_primitive :: proc(
	glb: ^Glb,
	src: ^Source,
	primitive: Gltf_Primitive,
	world: matrix[4, 4]f32,
) -> Glb_Error {
	assert(glb != nil && src != nil, "source_append_primitive: nil argument")
	if (primitive.mode.? or_else GL_TRIANGLES) != GL_TRIANGLES do return .Unsupported_Primitive
	position_index, has_position := primitive.attributes.POSITION.?
	if !has_position do return .Missing_Position
	positions := accessor_view(glb, position_index) or_return
	if positions.components != 3 do return .Unsupported_Accessor
	normals, uvs, colors: Accessor_View
	has_normal, has_uv, has_color: bool
	if index, ok := primitive.attributes.NORMAL.?; ok {
		normals = accessor_view(glb, index) or_return
		has_normal = normals.count == positions.count && normals.components == 3
	}
	if index, ok := primitive.attributes.TEXCOORD_0.?; ok {
		uvs = accessor_view(glb, index) or_return
		has_uv = uvs.count == positions.count && uvs.components == 2
	}
	if index, ok := primitive.attributes.COLOR_0.?; ok {
		colors = accessor_view(glb, index) or_return
		has_color = colors.count == positions.count && colors.components >= 3
	}
	if len(src.submeshes) >= imsh.SUBMESH_MAX do return .Too_Many_Primitives
	if len(src.positions) + positions.count > COOK_SOURCE_VERTEX_MAX do return .Bad_Accessor
	base := len(src.positions)
	submesh_index := u8(len(src.submeshes))
	normal_matrix := linalg.matrix4_inverse_transpose_f32(world)
	for i in 0 ..< positions.count {
		p := [3]f32 {
			accessor_read(positions, i, 0),
			accessor_read(positions, i, 1),
			accessor_read(positions, i, 2),
		}
		append(&src.positions, gltf_to_ros(transform_point(world, p)))
		n := [3]f32{0, 0, 0}
		if has_normal {
			raw := [4]f32 {
				accessor_read(normals, i, 0),
				accessor_read(normals, i, 1),
				accessor_read(normals, i, 2),
				0,
			}
			n = gltf_to_ros(safe_normalize((normal_matrix * raw).xyz))
		}
		append(&src.normals, n)
		uv := [2]f32{0, 0}
		if has_uv do uv = {accessor_read(uvs, i, 0), accessor_read(uvs, i, 1)}
		append(&src.uvs, uv)
		color := [3]f32{1, 1, 1}
		if has_color {
			color = {
				accessor_read(colors, i, 0),
				accessor_read(colors, i, 1),
				accessor_read(colors, i, 2),
			}
		}
		append(&src.colors, color)
		append(&src.submesh_of, submesh_index)
	}
	index_offset := len(src.indices)
	if index, ok := primitive.indices.?; ok {
		view := accessor_view(glb, index) or_return
		if view.components != 1 || view.component == GL_FLOAT || view.count % 3 != 0 {
			return .Unsupported_Accessor
		}
		for i in 0 ..< view.count {
			value := accessor_read_index(view, i)
			if int(value) >= positions.count do return .Bad_Accessor
			append(&src.indices, u32(base) + value)
		}
	} else {
		if positions.count % 3 != 0 do return .Unsupported_Accessor
		for i in 0 ..< positions.count do append(&src.indices, u32(base + i))
	}
	append(
		&src.submeshes,
		Source_Submesh {
			index_offset = index_offset,
			index_count = len(src.indices) - index_offset,
			material = primitive.material.? or_else -1,
			has_color = has_color,
		},
	)
	if !has_normal do source_compute_normals(src, base, index_offset)
	return .None
}

// source_compute_normals fills area-weighted smooth normals for vertices
// appended from `vertex_base` using triangles appended from `index_base`.
source_compute_normals :: proc(src: ^Source, vertex_base, index_base: int) {
	assert(src != nil, "source_compute_normals: nil source")
	assert(len(src.indices) % 3 == 0, "source_compute_normals: partial triangle")
	for v in vertex_base ..< len(src.normals) do src.normals[v] = {0, 0, 0}
	for t := index_base; t < len(src.indices); t += 3 {
		a, b, c := src.indices[t], src.indices[t + 1], src.indices[t + 2]
		face := linalg.cross(
			src.positions[b] - src.positions[a],
			src.positions[c] - src.positions[a],
		)
		src.normals[a] += face
		src.normals[b] += face
		src.normals[c] += face
	}
	for v in vertex_base ..< len(src.normals) do src.normals[v] = safe_normalize(src.normals[v])
}

source_gather :: proc(glb: ^Glb, src: ^Source) -> Glb_Error {
	assert(glb != nil && src != nil, "source_gather: nil argument")
	instances: [GLB_NODE_MAX]Mesh_Instance
	count := glb_mesh_instances(glb, &instances) or_return
	for instance in instances[:count] {
		mesh := glb.doc.meshes[instance.mesh]
		if len(mesh.primitives) > GLB_PRIMITIVE_MAX do return .Too_Many_Primitives
		for primitive in mesh.primitives {
			source_append_primitive(glb, src, primitive, instance.world) or_return
		}
	}
	if len(src.positions) == 0 do return .Missing_Position
	src.bounds_min = src.positions[0]
	src.bounds_max = src.positions[0]
	for p in src.positions {
		src.bounds_min = linalg.min(src.bounds_min, p)
		src.bounds_max = linalg.max(src.bounds_max, p)
	}
	return .None
}

// cluster_key packs (cell xyz, uv cell, submesh) into 58 bits. Including the
// uv cell keeps vertices on opposite sides of a texture seam apart, so
// decimation cannot smear one atlas chart into another.
@(private)
cluster_key :: proc(src: ^Source, vertex: int, grid: int) -> u64 {
	assert(grid >= COOK_GRID_MIN && grid <= COOK_GRID_MAX, "cluster_key: grid out of range")
	extent := linalg.max(src.bounds_max - src.bounds_min, [3]f32{1e-9, 1e-9, 1e-9})
	extent_max := max(extent.x, extent.y, extent.z)
	t := (src.positions[vertex] - src.bounds_min) / extent_max
	cell := [3]u64{}
	for axis in 0 ..< 3 {
		cell[axis] = u64(clamp(int(t[axis] * f32(grid)), 0, grid))
	}
	uv := src.uvs[vertex]
	uv_cell := [2]u64 {
		u64(clamp(int(uv.x * f32(grid)), 0, COOK_GRID_MAX)),
		u64(clamp(int(uv.y * f32(grid)), 0, COOK_GRID_MAX)),
	}
	key := cell.x | cell.y << 11 | cell.z << 22 | uv_cell.x << 33 | uv_cell.y << 44
	return key | u64(src.submesh_of[vertex]) << 55
}

@(private)
cluster_assign :: proc(
	src: ^Source,
	grid: int,
	cluster_of: []u32,
	keys: ^map[u64]u32,
) -> (
	vertices: int,
	triangles: int,
) {
	assert(len(cluster_of) == len(src.positions), "cluster_assign: map length mismatch")
	assert(keys != nil, "cluster_assign: nil keys")
	clear(keys)
	for v in 0 ..< len(src.positions) {
		key := cluster_key(src, v, grid)
		id, found := keys[key]
		if !found {
			id = u32(len(keys))
			keys[key] = id
		}
		cluster_of[v] = id
	}
	for t := 0; t < len(src.indices); t += 3 {
		a := cluster_of[src.indices[t]]
		b := cluster_of[src.indices[t + 1]]
		c := cluster_of[src.indices[t + 2]]
		if a != b && b != c && a != c do triangles += 1
	}
	return len(keys), triangles
}

@(private)
grid_fits :: proc(vertices, triangles, budget, submesh_count: int) -> bool {
	if vertices > imsh.VERTEX_MAX || triangles == 0 || triangles > budget do return false
	return imsh.file_size(submesh_count, vertices, triangles * 3) <= imsh.FILE_BYTE_MAX
}

// cook_choose_grid binary-searches the largest grid resolution whose output
// fits every budget. Clustered counts are close to monotonic in the grid, and
// the search keeps the best passing grid it saw, so a local inversion costs
// detail rather than correctness.
cook_choose_grid :: proc(
	src: ^Source,
	budget: int,
	cluster_of: []u32,
	keys: ^map[u64]u32,
) -> (
	int,
	bool,
) {
	assert(budget > 0, "cook_choose_grid: empty budget")
	low, high := COOK_GRID_MIN, COOK_GRID_MAX
	best := 0
	for step := 0; low <= high && step < COOK_SEARCH_STEP_MAX; step += 1 {
		middle := (low + high) / 2
		vertices, triangles := cluster_assign(src, middle, cluster_of, keys)
		if grid_fits(vertices, triangles, budget, len(src.submeshes)) {
			best = middle
			low = middle + 1
		} else {
			high = middle - 1
		}
	}
	return best, best != 0
}

@(private)
cluster_accumulate :: proc(src: ^Source, cluster_of: []u32, cluster_count: int) -> []imsh.Vertex {
	assert(len(cluster_of) == len(src.positions), "cluster_accumulate: map length mismatch")
	assert(cluster_count > 0, "cluster_accumulate: no clusters")
	sums := make([]imsh.Vertex, cluster_count)
	weights := make([]f32, cluster_count, context.temp_allocator)
	for v in 0 ..< len(src.positions) {
		id := cluster_of[v]
		sums[id].position += src.positions[v]
		sums[id].normal += src.normals[v]
		sums[id].uv += src.uvs[v]
		color := src.colors[v]
		if src.submeshes[src.submesh_of[v]].has_color {
			sums[id].uv += {color.x, color.y} - src.uvs[v]
			sums[id].scalar += color.z
		}
		weights[id] += 1
	}
	for &vertex, id in sums {
		weight := max(weights[id], 1)
		vertex.position /= weight
		vertex.uv /= weight
		vertex.scalar /= weight
		vertex.normal = safe_normalize(vertex.normal)
	}
	return sums
}

@(private)
cook_material :: proc(glb: ^Glb, material: int, has_color, textured: bool) -> imsh.Submesh {
	assert(glb != nil, "cook_material: nil glb")
	submesh := imsh.Submesh {
		base_color   = {255, 255, 255, 255},
		roughness    = 200,
		texture_slot = -1,
	}
	if material >= 0 && material < len(glb.doc.materials) {
		pbr := glb.doc.materials[material].pbrMetallicRoughness
		if len(pbr.baseColorFactor) == 4 {
			for c in 0 ..< 4 {
				submesh.base_color[c] = u8(clamp(pbr.baseColorFactor[c], 0, 1) * 255 + 0.5)
			}
		}
		if roughness, ok := pbr.roughnessFactor.?; ok {
			submesh.roughness = u8(clamp(roughness, 0, 1) * 255 + 0.5)
		}
	}
	if textured {
		submesh.flags += {.Textured}
		submesh.texture_slot = 0
	} else if has_color {
		submesh.flags += {.Vertex_Color}
	}
	return submesh
}

// cook_build clusters at `grid`, drops degenerate triangles, and compacts the
// referenced clusters into the output vertex array, submesh by submesh.
cook_build :: proc(
	glb: ^Glb,
	src: ^Source,
	grid: int,
	textured: bool,
	cooked: ^Cooked,
) -> Cook_Error {
	assert(glb != nil && src != nil && cooked != nil, "cook_build: nil argument")
	cluster_of := make([]u32, len(src.positions))
	defer delete(cluster_of)
	keys := make(map[u64]u32)
	defer delete(keys)
	cluster_count, _ := cluster_assign(src, grid, cluster_of, &keys)
	clusters := cluster_accumulate(src, cluster_of, cluster_count)
	defer delete(clusters)
	remap := make([]i32, cluster_count)
	defer delete(remap)
	for &value in remap do value = -1
	for part in src.submeshes {
		index_offset := len(cooked.indices)
		for t := part.index_offset; t < part.index_offset + part.index_count; t += 3 {
			ids := [3]u32 {
				cluster_of[src.indices[t]],
				cluster_of[src.indices[t + 1]],
				cluster_of[src.indices[t + 2]],
			}
			if ids[0] == ids[1] || ids[1] == ids[2] || ids[0] == ids[2] do continue
			for id in ids {
				if remap[id] < 0 {
					remap[id] = i32(len(cooked.vertices))
					append(&cooked.vertices, clusters[id])
				}
				append(&cooked.indices, u32(remap[id]))
			}
		}
		count := len(cooked.indices) - index_offset
		if count == 0 do continue
		submesh := cook_material(glb, part.material, part.has_color, textured)
		submesh.index_offset = u32(index_offset)
		submesh.index_count = u32(count)
		append(&cooked.submeshes, submesh)
	}
	if len(cooked.indices) == 0 do return .No_Triangles
	cooked.grid = grid
	bytes, err := imsh.encode(cooked.submeshes[:], cooked.vertices[:], cooked.indices[:])
	if err != .None do return .Encode
	cooked.file_bytes = bytes
	return .None
}

cook_mesh :: proc(
	glb: ^Glb,
	src: ^Source,
	budget: int,
	textured: bool,
	cooked: ^Cooked,
) -> Cook_Error {
	assert(glb != nil && src != nil && cooked != nil, "cook_mesh: nil argument")
	assert(budget > 0, "cook_mesh: empty budget")
	if len(src.indices) == 0 do return .No_Triangles
	cluster_of := make([]u32, len(src.positions))
	defer delete(cluster_of)
	keys := make(map[u64]u32)
	defer delete(keys)
	grid, ok := cook_choose_grid(src, budget, cluster_of, &keys)
	if !ok do return .Budget_Unreachable
	return cook_build(glb, src, grid, textured, cooked)
}

// --- texture --------------------------------------------------------------

@(private)
Byte_Sink :: struct {
	bytes: [dynamic]u8,
}

@(private)
byte_sink_write :: proc "c" (ctx: rawptr, data: rawptr, size: i32) {
	context = runtime.default_context()
	sink := (^Byte_Sink)(ctx)
	if sink == nil || data == nil || size <= 0 do return
	append(&sink.bytes, ..([^]u8)(data)[:size])
}

// gltf_base_color_image returns the encoded bytes of the material's base
// color image when it is embedded in the BIN chunk.
gltf_base_color_image :: proc(glb: ^Glb, material: int) -> (bytes: []u8, mime: string, ok: bool) {
	assert(glb != nil, "gltf_base_color_image: nil glb")
	if material < 0 || material >= len(glb.doc.materials) do return
	ref := glb.doc.materials[material].pbrMetallicRoughness.baseColorTexture.? or_return
	if ref.index < 0 || ref.index >= len(glb.doc.textures) do return
	texture := glb.doc.textures[ref.index]
	source, has_source := texture.source.?
	if webp, has_webp := texture.extensions.EXT_texture_webp.?; has_webp && !has_source {
		source = webp.source
		has_source = true
	}
	if !has_source || source < 0 || source >= len(glb.doc.images) do return
	image := glb.doc.images[source]
	view_index := image.bufferView.? or_return
	if view_index < 0 || view_index >= len(glb.doc.bufferViews) do return
	view := glb.doc.bufferViews[view_index]
	end := i64(view.byteOffset) + i64(view.byteLength)
	if view.byteOffset < 0 || view.byteLength <= 0 || end > i64(len(glb.bin)) do return
	return glb.bin[view.byteOffset:end], image.mimeType, true
}

// cook_texture decodes an encoded image, box-filters it down to at most
// `max_edge`, and re-encodes it as JPEG, halving the edge until the result is
// under COOK_TEXTURE_BYTE_MAX (bounded by COOK_TEXTURE_ATTEMPT_MAX).
cook_texture :: proc(encoded: []u8, max_edge: int) -> (jpeg: []u8, edge: int, err: Cook_Error) {
	assert(max_edge >= 16 && max_edge <= COOK_TEXTURE_EDGE_MAX, "cook_texture: bad edge")
	if len(encoded) == 0 || len(encoded) > GLB_BYTE_MAX do return nil, 0, .Texture_Decode
	width, height, channels: i32
	pixels := stbi.load_from_memory(
		raw_data(encoded),
		i32(len(encoded)),
		&width,
		&height,
		&channels,
		3,
	)
	if pixels == nil do return nil, 0, .Texture_Decode
	defer stbi.image_free(pixels)
	if width <= 0 || height <= 0 || width > 16384 || height > 16384 do return nil, 0, .Texture_Decode
	target := max_edge
	for attempt in 0 ..< COOK_TEXTURE_ATTEMPT_MAX {
		scale := min(f32(target) / f32(max(width, height)), 1)
		out_w := max(i32(f32(width) * scale + 0.5), 1)
		out_h := max(i32(f32(height) * scale + 0.5), 1)
		resized := make([]u8, int(out_w) * int(out_h) * 3)
		defer delete(resized)
		resize_ok := stbi.resize_uint8_srgb(
			pixels,
			width,
			height,
			0,
			raw_data(resized),
			out_w,
			out_h,
			0,
			3,
			stbi.ALPHA_CHANNEL_NONE,
			0,
		)
		if resize_ok == 0 do return nil, 0, .Texture_Decode
		sink: Byte_Sink
		written := stbi.write_jpg_to_func(
			byte_sink_write,
			&sink,
			out_w,
			out_h,
			3,
			raw_data(resized),
			JPEG_QUALITY,
		)
		if written == 0 {
			delete(sink.bytes)
			return nil, 0, .Texture_Decode
		}
		if len(sink.bytes) < COOK_TEXTURE_BYTE_MAX do return sink.bytes[:], int(max(out_w, out_h)), .None
		delete(sink.bytes)
		_ = attempt
		target /= 2
	}
	return nil, 0, .Texture_Too_Large
}
