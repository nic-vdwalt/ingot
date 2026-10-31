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
// Atlas seams jump far across uv space; ordinary variation inside one
// position cell stays well under this, so it merges instead of splitting.
COOK_UV_MERGE_DISTANCE :: f32(0.008)
COOK_UV_CANDIDATE_MAX :: 32
// Below this ratio of |sum of face normals| to summed face area, the faces
// around a vertex disagree so much that their average is meaningless.
COOK_NORMAL_CANCEL_RATIO :: f32(0.2)
// Weight of the pull toward a cluster's mean, relative to its summed plane
// area. Small enough that creases win, large enough to pin flat regions.
COOK_QUADRIC_MEAN_PULL :: f32(0.01)
// Neighbour normals within this angle are smoothed together; wider angles are
// creases and stay sharp.
COOK_NORMAL_SMOOTH_ANGLE :: f32(32 * math.PI / 180)
COOK_NORMAL_SMOOTH_PASSES :: 3
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

// Clustering is two-level. Every source vertex first lands in a position
// cluster (grid cell + submesh); all output vertices of one position cluster
// share its averaged position, so the two sides of a texture seam stay
// welded and decimation cannot open cracks. Inside a position cluster a
// vertex joins the first output vertex whose representative uv lies within
// COOK_UV_MERGE_DISTANCE, so only real atlas seams split a cluster.
Cluster_Map :: struct {
	position_of:      []u32,
	vertex_of:        []u32,
	position_keys:    map[u64]u32,
	// Per position cluster, the head of its output-vertex chain; -1 is empty.
	first_vertex:     []i32,
	next_vertex:      []i32,
	representative:   [][2]f32,
	referenced:       []bool,
	// Per source triangle: survives clustering (not degenerate, not a
	// duplicate of a better-facing triangle on the same three clusters).
	kept:             []bool,
	position_count:   int,
	vertex_count:     int,
	referenced_count: int,
}

cluster_map_make :: proc(src: ^Source) -> Cluster_Map {
	assert(src != nil, "cluster_map_make: nil source")
	count := len(src.positions)
	return {
		position_of = make([]u32, count),
		vertex_of = make([]u32, count),
		position_keys = make(map[u64]u32),
		first_vertex = make([]i32, count),
		next_vertex = make([]i32, count),
		representative = make([][2]f32, count),
		referenced = make([]bool, count),
		kept = make([]bool, len(src.indices) / 3),
	}
}

cluster_map_destroy :: proc(clusters: ^Cluster_Map) {
	assert(clusters != nil, "cluster_map_destroy: nil map")
	delete(clusters.position_of)
	delete(clusters.vertex_of)
	delete(clusters.position_keys)
	delete(clusters.first_vertex)
	delete(clusters.next_vertex)
	delete(clusters.representative)
	delete(clusters.referenced)
	delete(clusters.kept)
	clusters^ = {}
}

@(private)
position_key :: proc(src: ^Source, vertex: int, grid: int) -> u64 {
	assert(grid >= COOK_GRID_MIN && grid <= COOK_GRID_MAX, "position_key: grid out of range")
	extent := linalg.max(src.bounds_max - src.bounds_min, [3]f32{1e-9, 1e-9, 1e-9})
	extent_max := max(extent.x, extent.y, extent.z)
	t := (src.positions[vertex] - src.bounds_min) / extent_max
	cell := [3]u64{}
	for axis in 0 ..< 3 {
		cell[axis] = u64(clamp(int(t[axis] * f32(grid)), 0, grid))
	}
	key := cell.x | cell.y << 11 | cell.z << 22
	return key | u64(src.submesh_of[vertex]) << 33
}

// cluster_uv_vertex returns the output vertex for `uv` inside a position
// cluster, creating one when no representative is close enough. The chain
// scan is capped so a pathological cluster splits instead of going quadratic.
@(private)
cluster_uv_vertex :: proc(clusters: ^Cluster_Map, position: u32, uv: [2]f32) -> u32 {
	assert(int(position) < clusters.position_count, "cluster_uv_vertex: position out of range")
	candidate := clusters.first_vertex[position]
	for scanned := 0; candidate >= 0 && scanned < COOK_UV_CANDIDATE_MAX; scanned += 1 {
		delta := linalg.abs(clusters.representative[candidate] - uv)
		if max(delta.x, delta.y) <= COOK_UV_MERGE_DISTANCE do return u32(candidate)
		candidate = clusters.next_vertex[candidate]
	}
	id := i32(clusters.vertex_count)
	assert(int(id) < len(clusters.next_vertex), "cluster_uv_vertex: vertex capacity exceeded")
	clusters.representative[id] = uv
	clusters.next_vertex[id] = clusters.first_vertex[position]
	clusters.first_vertex[position] = id
	clusters.vertex_count += 1
	return u32(id)
}

// cluster_assign returns the referenced output vertex count and surviving
// triangle count at `grid`; unreferenced clusters never reach the file.
@(private)
cluster_assign :: proc(
	src: ^Source,
	grid: int,
	clusters: ^Cluster_Map,
) -> (
	vertices: int,
	triangles: int,
) {
	assert(clusters != nil, "cluster_assign: nil clusters")
	assert(len(clusters.position_of) == len(src.positions), "cluster_assign: length mismatch")
	clear(&clusters.position_keys)
	clusters.position_count = 0
	clusters.vertex_count = 0
	clusters.referenced_count = 0
	for v in 0 ..< len(src.positions) {
		key := position_key(src, v, grid)
		position, found := clusters.position_keys[key]
		if !found {
			position = u32(clusters.position_count)
			clusters.position_keys[key] = position
			clusters.first_vertex[position] = -1
			clusters.position_count += 1
		}
		clusters.position_of[v] = position
		clusters.vertex_of[v] = cluster_uv_vertex(clusters, position, src.uvs[v])
	}
	for &flag in clusters.referenced[:clusters.vertex_count] do flag = false
	cluster_select_triangles(src, clusters)
	for t := 0; t < len(src.indices); t += 3 {
		if !clusters.kept[t / 3] do continue
		corners := src.indices[t:t + 3]
		triangles += 1
		for corner in corners {
			id := clusters.vertex_of[corner]
			if !clusters.referenced[id] {
				clusters.referenced[id] = true
				clusters.referenced_count += 1
			}
		}
	}
	return clusters.referenced_count, triangles
}

// cluster_select_triangles fills clusters.kept. Clustering collapses the two
// sides of a thin sheet, and neighbouring source triangles, onto the same
// three clusters; drawing those coincident copies z-fights into patchwork
// and their opposite windings cancel the rebuilt normals. Of the triangles
// sharing one cluster triple, only the one whose winding best agrees with its
// source vertex normals survives; ties keep the earliest, so it is
// deterministic.
@(private)
cluster_select_triangles :: proc(src: ^Source, clusters: ^Cluster_Map) {
	assert(len(clusters.kept) * 3 == len(src.indices), "cluster_select_triangles: length mismatch")
	Choice :: struct {
		triangle: int,
		score:    f32,
	}
	best := make(map[[3]u32]Choice)
	defer delete(best)
	for t := 0; t < len(src.indices); t += 3 {
		corners := src.indices[t:t + 3]
		clusters.kept[t / 3] = false
		if triangle_degenerate(clusters, corners) do continue
		a := src.positions[corners[0]]
		face := safe_normalize(
			linalg.cross(src.positions[corners[1]] - a, src.positions[corners[2]] - a),
		)
		score := linalg.dot(
			face,
			src.normals[corners[0]] + src.normals[corners[1]] + src.normals[corners[2]],
		)
		key := [3]u32 {
			clusters.position_of[corners[0]],
			clusters.position_of[corners[1]],
			clusters.position_of[corners[2]],
		}
		if key.x > key.y do key.x, key.y = key.y, key.x
		if key.y > key.z do key.y, key.z = key.z, key.y
		if key.x > key.y do key.x, key.y = key.y, key.x
		if choice, found := best[key]; !found || score > choice.score {
			best[key] = {t / 3, score}
		}
	}
	for _, choice in best do clusters.kept[choice.triangle] = true
}

@(private)
triangle_degenerate :: proc(clusters: ^Cluster_Map, corners: []u32) -> bool {
	assert(len(corners) == 3, "triangle_degenerate: not a triangle")
	a := clusters.position_of[corners[0]]
	b := clusters.position_of[corners[1]]
	c := clusters.position_of[corners[2]]
	return a == b || b == c || a == c
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
cook_choose_grid :: proc(src: ^Source, budget: int, clusters: ^Cluster_Map) -> (int, bool) {
	assert(budget > 0, "cook_choose_grid: empty budget")
	low, high := COOK_GRID_MIN, COOK_GRID_MAX
	best := 0
	for step := 0; low <= high && step < COOK_SEARCH_STEP_MAX; step += 1 {
		middle := (low + high) / 2
		vertices, triangles := cluster_assign(src, middle, clusters)
		if grid_fits(vertices, triangles, budget, len(src.submeshes)) {
			best = middle
			low = middle + 1
		} else {
			high = middle - 1
		}
	}
	return best, best != 0
}

// cluster_accumulate averages positions and normals per position cluster and
// uvs and scalars per output vertex, then gives every output vertex its
// position cluster's shared position and normal.
@(private)
Quadric_Matrix :: matrix[3, 3]f64

@(private)
Cluster_Quadric :: struct {
	// Symmetric 3x3 sum of area * n n^T, and sum of area * d * n, for the
	// source planes n.x + d = 0 touching the cluster.
	plane: Quadric_Matrix,
	shift: [3]f64,
	low:   [3]f32,
	high:  [3]f32,
}

// cluster_place_quadric moves each position cluster from the mean of its
// source vertices to the point closest (area-weighted, squared distance) to
// the source planes around it. A mean rounds every crease and corner inside
// a cell, which made straight anvil edges wobble; the plane fit keeps them
// on the creases. A small pull toward the mean settles directions the planes
// leave free (a flat region), and the result is clamped to the bounds of the
// cluster's own source vertices so a near-singular fit cannot fly away.
// `positions` holds the means on entry and the placed points on return.
@(private)
cluster_place_quadric :: proc(src: ^Source, clusters: ^Cluster_Map, positions: [][3]f32) {
	assert(len(positions) == clusters.position_count, "cluster_place_quadric: length mismatch")
	quadrics := make([]Cluster_Quadric, clusters.position_count, context.temp_allocator)
	for &quadric in quadrics {
		quadric.low = {max(f32), max(f32), max(f32)}
		quadric.high = {min(f32), min(f32), min(f32)}
	}
	for v in 0 ..< len(src.positions) {
		quadric := &quadrics[clusters.position_of[v]]
		quadric.low = linalg.min(quadric.low, src.positions[v])
		quadric.high = linalg.max(quadric.high, src.positions[v])
	}
	for t := 0; t < len(src.indices); t += 3 {
		if !clusters.kept[t / 3] do continue
		corners := src.indices[t:t + 3]
		a := linalg.array_cast(src.positions[corners[0]], f64)
		b := linalg.array_cast(src.positions[corners[1]], f64)
		c := linalg.array_cast(src.positions[corners[2]], f64)
		face := linalg.cross(b - a, c - a)
		double_area := linalg.length(face)
		if double_area <= 1e-24 do continue
		normal := face / double_area
		distance := -linalg.dot(normal, a)
		area := double_area * 0.5
		outer := linalg.outer_product(normal, normal) * Quadric_Matrix(area)
		for corner in corners {
			quadric := &quadrics[clusters.position_of[corner]]
			quadric.plane += outer
			quadric.shift += normal * (distance * area)
		}
	}
	for &quadric, position in quadrics {
		trace := quadric.plane[0, 0] + quadric.plane[1, 1] + quadric.plane[2, 2]
		if trace <= 0 do continue
		mean := linalg.array_cast(positions[position], f64)
		pull := f64(COOK_QUADRIC_MEAN_PULL) * trace
		system := quadric.plane + Quadric_Matrix(pull)
		if abs(linalg.matrix3x3_determinant(system)) <= 1e-30 do continue
		solved := linalg.matrix3x3_inverse(system) * (mean * pull - quadric.shift)
		placed := linalg.array_cast(solved, f32)
		if math.is_nan(placed.x) || math.is_nan(placed.y) || math.is_nan(placed.z) do continue
		positions[position] = linalg.clamp(placed, quadric.low, quadric.high)
	}
}

@(private)
cluster_accumulate :: proc(src: ^Source, clusters: ^Cluster_Map) -> []imsh.Vertex {
	assert(clusters.vertex_count > 0, "cluster_accumulate: no clusters")
	sums := make([]imsh.Vertex, clusters.vertex_count)
	weights := make([]f32, clusters.vertex_count, context.temp_allocator)
	shared_position := make([][3]f32, clusters.position_count, context.temp_allocator)
	shared_normal := make([][3]f32, clusters.position_count, context.temp_allocator)
	shared_weight := make([]f32, clusters.position_count, context.temp_allocator)
	position_of_vertex := make([]u32, clusters.vertex_count, context.temp_allocator)
	for v in 0 ..< len(src.positions) {
		id := clusters.vertex_of[v]
		position := clusters.position_of[v]
		position_of_vertex[id] = position
		shared_position[position] += src.positions[v]
		shared_normal[position] += src.normals[v]
		shared_weight[position] += 1
		sums[id].uv += src.uvs[v]
		color := src.colors[v]
		if src.submeshes[src.submesh_of[v]].has_color {
			sums[id].uv += {color.x, color.y} - src.uvs[v]
			sums[id].scalar += color.z
		}
		weights[id] += 1
	}
	for &value, position in shared_position {
		value /= max(shared_weight[position], 1)
	}
	cluster_place_quadric(src, clusters, shared_position)
	for &vertex, id in sums {
		weight := max(weights[id], 1)
		position := position_of_vertex[id]
		vertex.position = shared_position[position]
		vertex.normal = safe_normalize(shared_normal[position])
		vertex.uv /= weight
		vertex.scalar /= weight
	}
	return sums
}

// cooked_recompute_normals replaces the cluster-averaged source normals with
// area-weighted normals of the cooked triangles. Clustering merges both sides
// of thin features into one cell, where averaged source normals cancel to an
// arbitrary direction; the cooked faces are what the GPU actually shades.
@(private)
cooked_recompute_normals :: proc(cooked: ^Cooked) {
	assert(cooked != nil && len(cooked.indices) % 3 == 0, "cooked_recompute_normals: bad cooked mesh")
	// Vertices split only by a uv seam share a bit-identical position, so
	// keying by exact position keeps seams smooth.
	slot_of := make(map[[3]f32]int, len(cooked.vertices), context.temp_allocator)
	slot := make([]int, len(cooked.vertices), context.temp_allocator)
	for vertex, i in cooked.vertices {
		if existing, found := slot_of[vertex.position]; found {
			slot[i] = existing
		} else {
			slot[i] = len(slot_of)
			slot_of[vertex.position] = slot[i]
		}
	}
	slot_count := len(slot_of)
	sum := make([][3]f32, slot_count, context.temp_allocator)
	area_sum := make([]f32, slot_count, context.temp_allocator)
	best := make([][3]f32, slot_count, context.temp_allocator)
	best_area := make([]f32, slot_count, context.temp_allocator)
	for t := 0; t < len(cooked.indices); t += 3 {
		a := cooked.indices[t]
		b := cooked.indices[t + 1]
		c := cooked.indices[t + 2]
		pa := cooked.vertices[a].position
		face := linalg.cross(cooked.vertices[b].position - pa, cooked.vertices[c].position - pa)
		face_length := linalg.length(face)
		if face_length <= 1e-20 || math.is_nan(face_length) do continue
		for s in ([3]int{slot[a], slot[b], slot[c]}) {
			sum[s] += face
			area_sum[s] += face_length
			if face_length > best_area[s] {
				best_area[s] = face_length
				best[s] = face / face_length
			}
		}
	}
	slot_normal := make([][3]f32, slot_count, context.temp_allocator)
	for s in 0 ..< slot_count {
		if best_area[s] > 0 && linalg.length(sum[s]) < COOK_NORMAL_CANCEL_RATIO * area_sum[s] {
			slot_normal[s] = best[s]
		} else {
			slot_normal[s] = safe_normalize(sum[s])
		}
	}
	cooked_smooth_normals(cooked, slot, slot_normal)
	for &vertex, i in cooked.vertices do vertex.normal = slot_normal[slot[i]]
}

// cooked_smooth_normals averages each slot's normal with its edge neighbours
// whose normals lie within COOK_NORMAL_SMOOTH_ANGLE, a few times over. Grid
// clustering leaves triangle-scale ripples on flat faces that read as noise
// under specular light; the angle limit keeps real creases sharp. Neighbours
// are visited in triangle order, so the result is deterministic.
@(private)
cooked_smooth_normals :: proc(cooked: ^Cooked, slot: []int, normals: [][3]f32) {
	assert(len(slot) == len(cooked.vertices), "cooked_smooth_normals: slot length mismatch")
	slot_count := len(normals)
	degree := make([]int, slot_count + 1, context.temp_allocator)
	for t := 0; t < len(cooked.indices); t += 3 {
		for corner in 0 ..< 3 do degree[slot[cooked.indices[t + corner]] + 1] += 2
	}
	for s in 0 ..< slot_count do degree[s + 1] += degree[s]
	neighbours := make([]int, degree[slot_count], context.temp_allocator)
	fill := make([]int, slot_count, context.temp_allocator)
	for t := 0; t < len(cooked.indices); t += 3 {
		for corner in 0 ..< 3 {
			s := slot[cooked.indices[t + corner]]
			for other in 1 ..< 3 {
				neighbours[degree[s] + fill[s]] = slot[cooked.indices[t + (corner + other) % 3]]
				fill[s] += 1
			}
		}
	}
	limit := math.cos(COOK_NORMAL_SMOOTH_ANGLE)
	next := make([][3]f32, slot_count, context.temp_allocator)
	for _ in 0 ..< COOK_NORMAL_SMOOTH_PASSES {
		for s in 0 ..< slot_count {
			total := normals[s]
			for other in neighbours[degree[s]:degree[s + 1]] {
				if linalg.dot(normals[s], normals[other]) >= limit do total += normals[other]
			}
			next[s] = safe_normalize(total)
		}
		copy(normals, next)
	}
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
	mapping := cluster_map_make(src)
	defer cluster_map_destroy(&mapping)
	_, _ = cluster_assign(src, grid, &mapping)
	clusters := cluster_accumulate(src, &mapping)
	defer delete(clusters)
	remap := make([]i32, mapping.vertex_count)
	defer delete(remap)
	for &value in remap do value = -1
	for part in src.submeshes {
		index_offset := len(cooked.indices)
		for t := part.index_offset; t < part.index_offset + part.index_count; t += 3 {
			if !mapping.kept[t / 3] do continue
			ids := [3]u32 {
				mapping.vertex_of[src.indices[t]],
				mapping.vertex_of[src.indices[t + 1]],
				mapping.vertex_of[src.indices[t + 2]],
			}
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
	cooked_recompute_normals(cooked)
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
	mapping := cluster_map_make(src)
	defer cluster_map_destroy(&mapping)
	grid, ok := cook_choose_grid(src, budget, &mapping)
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
