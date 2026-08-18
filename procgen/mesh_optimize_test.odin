#+build !js
package procgen

import asset "../asset"
import "core:testing"

mesh_test_optimize_scratch :: proc(vertex_count, index_count: int) -> Optimize_Scratch {
	triangles := index_count / 3
	return Optimize_Scratch {
		adjacency_offset = make([]u32, vertex_count + 1),
		adjacency_cursor = make([]u32, vertex_count),
		adjacency = make([]u32, index_count),
		remaining = make([]u32, vertex_count),
		cache_position = make([]i32, vertex_count),
		vertex_scores = make([]f64, vertex_count),
		vertex_mark = make([]u32, vertex_count),
		remap = make([]u32, vertex_count),
		triangle_scores = make([]f64, triangles),
		heap_items = make([]u32, triangles),
		heap_slots = make([]i32, triangles),
		touched = make([]u32, triangles),
		touched_mark = make([]u32, triangles),
		runs = make([]Optimize_Run, triangles),
		order = make([]u32, index_count),
	}
}

mesh_test_optimize_scratch_free :: proc(scratch: Optimize_Scratch) {
	delete(scratch.adjacency_offset)
	delete(scratch.adjacency_cursor)
	delete(scratch.adjacency)
	delete(scratch.remaining)
	delete(scratch.cache_position)
	delete(scratch.vertex_scores)
	delete(scratch.vertex_mark)
	delete(scratch.remap)
	delete(scratch.triangle_scores)
	delete(scratch.heap_items)
	delete(scratch.heap_slots)
	delete(scratch.touched)
	delete(scratch.touched_mark)
	delete(scratch.runs)
	delete(scratch.order)
}

@(private = "file")
Optimize_Fixture :: struct {
	source:       asset.Mesh_View,
	vertices:     []asset.Vertex,
	indices:      []u32,
	out_vertices: []asset.Vertex,
	out_indices:  []u32,
	scratch:      Optimize_Scratch,
}

@(private = "file")
_optimize_fixture :: proc(cells: int) -> Optimize_Fixture {
	vertices := make([]asset.Vertex, (cells + 1) * (cells + 1))
	indices := make([]u32, cells * cells * 6)
	source := mesh_test_grid(cells, vertices, indices)
	return Optimize_Fixture {
		source = source,
		vertices = vertices,
		indices = indices,
		out_vertices = make([]asset.Vertex, len(source.vertices)),
		out_indices = make([]u32, len(source.indices)),
		scratch = mesh_test_optimize_scratch(len(source.vertices), len(source.indices)),
	}
}

@(private = "file")
_optimize_fixture_free :: proc(fixture: Optimize_Fixture) {
	delete(fixture.vertices)
	delete(fixture.indices)
	delete(fixture.out_vertices)
	delete(fixture.out_indices)
	mesh_test_optimize_scratch_free(fixture.scratch)
}

// The contract between this package and `tools/mesh_cook.py`, written out
// literally on both sides. A 4x4 grid is small enough to read and large enough
// that all three passes do real work: 32 triangles fill the modelled cache and
// force evictions, and the run split produces more than one run to sort.
//
// If either implementation changes, the other's test fails. That is the whole
// point of pinning it - the two cooks cannot call each other, so nothing else
// would notice them drifting apart until an asset shipped in two different
// index orders depending on which tool built it.
//
// Regenerate with:
//
//	cd tools && python3 -c "import test_mesh_cook as t, mesh_cook as c; \
//	    v, i = t.grid(4); print(c.optimize(v, i)[1])"
@(private = "file")
OPTIMIZE_GOLDEN_CELLS :: 4

@(private = "file")
OPTIMIZE_GOLDEN_INDICES := [?]u32 {
	0,
	1,
	2,
	0,
	3,
	1,
	2,
	4,
	5,
	1,
	6,
	4,
	4,
	6,
	7,
	1,
	8,
	6,
	9,
	2,
	10,
	9,
	0,
	2,
	10,
	2,
	5,
	3,
	11,
	8,
	3,
	8,
	1,
	11,
	12,
	8,
	6,
	13,
	7,
	8,
	12,
	14,
	8,
	14,
	6,
	15,
	9,
	10,
	16,
	0,
	9,
	16,
	17,
	0,
	6,
	14,
	13,
	12,
	18,
	14,
	14,
	19,
	13,
	2,
	1,
	4,
	5,
	4,
	20,
	4,
	7,
	20,
	17,
	3,
	0,
	17,
	21,
	3,
	21,
	11,
	3,
	22,
	23,
	15,
	23,
	9,
	15,
	23,
	16,
	9,
	14,
	18,
	19,
	18,
	24,
	19,
}

// Where each output vertex came from in the source. Pinning this as well as the
// index order catches a fetch pass that renumbered consistently but chose a
// different first-use walk.
@(private = "file")
OPTIMIZE_GOLDEN_SOURCE := [?]u32 {
	7,
	12,
	11,
	8,
	16,
	15,
	17,
	21,
	13,
	6,
	10,
	9,
	14,
	22,
	18,
	5,
	2,
	3,
	19,
	23,
	20,
	4,
	0,
	1,
	24,
}

@(test)
optimize_matches_the_offline_golden_order :: proc(t: ^testing.T) {
	fixture := _optimize_fixture(OPTIMIZE_GOLDEN_CELLS)
	defer _optimize_fixture_free(fixture)
	result, ok := optimize_mesh(
		fixture.source,
		fixture.out_vertices,
		fixture.out_indices,
		fixture.scratch,
	)
	testing.expect(t, ok, "optimize_mesh rejected the golden grid")
	testing.expect_value(t, result.index_count, len(OPTIMIZE_GOLDEN_INDICES))
	testing.expect_value(t, result.vertex_count, len(OPTIMIZE_GOLDEN_SOURCE))
	testing.expect(t, !result.fallback, "golden grid took the fallback path")
	for expected, slot in OPTIMIZE_GOLDEN_INDICES {
		testing.expect_value(t, fixture.out_indices[slot], expected)
	}
	for expected, slot in OPTIMIZE_GOLDEN_SOURCE {
		testing.expect_value(t, fixture.out_vertices[slot], fixture.source.vertices[expected])
	}
}

@(test)
optimize_is_a_permutation_of_the_triangle_set :: proc(t: ^testing.T) {
	cells := 16
	fixture := _optimize_fixture(cells)
	defer _optimize_fixture_free(fixture)
	before := _optimize_test_triangles(fixture.source.vertices, fixture.source.indices)
	defer delete(before)
	result, ok := optimize_mesh(
		fixture.source,
		fixture.out_vertices,
		fixture.out_indices,
		fixture.scratch,
	)
	testing.expect(t, ok, "optimize_mesh rejected a grid")
	testing.expect_value(t, result.index_count, len(fixture.source.indices))
	after := _optimize_test_triangles(
		fixture.out_vertices[:result.vertex_count],
		fixture.out_indices[:result.index_count],
	)
	defer delete(after)
	testing.expect_value(t, len(after), len(before))
	// Triangles are keyed by their sorted vertex positions rather than their
	// indices, so a renumber cannot make a lost triangle look present.
	for slot in 0 ..< len(before) {
		testing.expect(t, before[slot] == after[slot], "triangle set changed")
	}
}

@(test)
optimize_lowers_average_cache_misses :: proc(t: ^testing.T) {
	cells := 16
	fixture := _optimize_fixture(cells)
	defer _optimize_fixture_free(fixture)
	before := _optimize_test_acmr(fixture.source.indices)
	result, ok := optimize_mesh(
		fixture.source,
		fixture.out_vertices,
		fixture.out_indices,
		fixture.scratch,
	)
	testing.expect(t, ok, "optimize_mesh rejected a grid")
	after := _optimize_test_acmr(fixture.out_indices[:result.index_count])
	// A row-major grid re-fetches most of a row every time the walk wraps; the
	// point of the pass is that a locality-aware order does not. The margin is
	// deliberately loose - this asserts the pass works, not how well.
	testing.expect(t, after < before, "reordering did not reduce cache misses")
	testing.expect(t, after < 1.0, "optimised order still misses more than once a triangle")
}

@(test)
optimize_renumbers_into_first_use_order :: proc(t: ^testing.T) {
	cells := 8
	fixture := _optimize_fixture(cells)
	defer _optimize_fixture_free(fixture)
	result, ok := optimize_mesh(
		fixture.source,
		fixture.out_vertices,
		fixture.out_indices,
		fixture.scratch,
	)
	testing.expect(t, ok, "optimize_mesh rejected a grid")
	seen := make([]bool, result.vertex_count)
	defer delete(seen)
	next := u32(0)
	for index in fixture.out_indices[:result.index_count] {
		testing.expect(t, int(index) < result.vertex_count, "index past the vertex count")
		if seen[index] do continue
		// A first appearance must be the next unused slot, which is what makes
		// the vertex fetch walk forward.
		testing.expect_value(t, index, next)
		seen[index] = true
		next += 1
	}
	testing.expect_value(t, int(next), result.vertex_count)
}

@(test)
optimize_is_deterministic :: proc(t: ^testing.T) {
	cells := 12
	first := _optimize_fixture(cells)
	defer _optimize_fixture_free(first)
	second := _optimize_fixture(cells)
	defer _optimize_fixture_free(second)
	left, left_ok := optimize_mesh(
		first.source,
		first.out_vertices,
		first.out_indices,
		first.scratch,
	)
	right, right_ok := optimize_mesh(
		second.source,
		second.out_vertices,
		second.out_indices,
		second.scratch,
	)
	testing.expect(t, left_ok && right_ok, "optimize_mesh rejected a grid")
	testing.expect_value(t, left.index_count, right.index_count)
	testing.expect_value(t, left.vertex_count, right.vertex_count)
	for slot in 0 ..< left.index_count {
		testing.expect_value(t, first.out_indices[slot], second.out_indices[slot])
	}
}

// A single triangle is below the threshold both passes use to bail out, so it
// must survive untouched rather than fall into an empty-heap corner.
@(test)
optimize_passes_a_lone_triangle_through :: proc(t: ^testing.T) {
	vertices := [3]asset.Vertex {
		{position = {0, 0, 0}, normal = {0, 0, 1}},
		{position = {1, 0, 0}, normal = {0, 0, 1}},
		{position = {0, 1, 0}, normal = {0, 0, 1}},
	}
	indices := [3]u32{2, 0, 1}
	source := asset.Mesh_View {
		id = 1,
		vertices = vertices[:],
		indices = indices[:],
		primitive = .Triangles,
		bounds = {minimum = {0, 0, 0}, maximum = {1, 1, 0}},
	}
	out_vertices := [3]asset.Vertex{}
	out_indices := [3]u32{}
	scratch := mesh_test_optimize_scratch(3, 3)
	defer mesh_test_optimize_scratch_free(scratch)
	result, ok := optimize_mesh(source, out_vertices[:], out_indices[:], scratch)
	testing.expect(t, ok, "optimize_mesh rejected a lone triangle")
	testing.expect_value(t, result.index_count, 3)
	testing.expect_value(t, result.vertex_count, 3)
	testing.expect(t, !result.fallback, "a lone triangle is not a starved walk")
	// Fetch still renumbers, so the winding is preserved but the numbering is
	// first-use.
	testing.expect_value(t, out_indices[0], 0)
	testing.expect_value(t, out_vertices[0], vertices[2])
}

@(test)
optimize_rejects_a_malformed_mesh :: proc(t: ^testing.T) {
	cells := 4
	fixture := _optimize_fixture(cells)
	defer _optimize_fixture_free(fixture)
	lines := fixture.source
	lines.primitive = .Lines
	_, lines_ok := optimize_mesh(lines, fixture.out_vertices, fixture.out_indices, fixture.scratch)
	testing.expect(t, !lines_ok, "optimize_mesh accepted a line list")
	partial := fixture.source
	partial.indices = fixture.source.indices[:len(fixture.source.indices) - 1]
	_, partial_ok := optimize_mesh(
		partial,
		fixture.out_vertices,
		fixture.out_indices,
		fixture.scratch,
	)
	testing.expect(t, !partial_ok, "optimize_mesh accepted an incomplete triangle")
	_, short_ok := optimize_mesh(
		fixture.source,
		fixture.out_vertices[:1],
		fixture.out_indices,
		fixture.scratch,
	)
	testing.expect(t, !short_ok, "optimize_mesh accepted undersized vertex storage")
}

@(test)
optimize_accepts_a_terraforger_render_chunk :: proc(t: ^testing.T) {
	fixture := _optimize_fixture(192)
	defer _optimize_fixture_free(fixture)
	before := _optimize_test_triangles(fixture.source.vertices, fixture.source.indices)
	defer delete(before)
	result, ok := optimize_mesh(
		fixture.source,
		fixture.out_vertices,
		fixture.out_indices,
		fixture.scratch,
	)
	testing.expect(t, ok, "optimize_mesh rejected a 192x192 quad grid")
	testing.expect_value(t, result.index_count, 192 * 192 * 6)
	testing.expect_value(t, result.vertex_count, 193 * 193)
	for index, slot in fixture.out_indices[:result.index_count] {
		testing.expect(t, index < u32(result.vertex_count), "optimized index escaped vertex storage")
		if slot < result.vertex_count {
			testing.expect(t, index <= u32(slot), "vertices were not numbered by first use")
		}
	}
	after := _optimize_test_triangles(
		fixture.out_vertices[:result.vertex_count],
		fixture.out_indices[:result.index_count],
	)
	defer delete(after)
	testing.expect_value(t, len(after), len(before))
	for slot in 0 ..< len(before) {
		testing.expect(t, before[slot] == after[slot], "large-grid triangle set changed")
	}
}

@(test)
optimize_rejects_inputs_above_its_capacity :: proc(t: ^testing.T) {
	vertices := make([]asset.Vertex, OPTIMIZE_MAX_VERTICES + 1)
	defer delete(vertices)
	indices := [3]u32{0, 1, 2}
	out_vertices := make([]asset.Vertex, len(vertices))
	defer delete(out_vertices)
	out_indices := [3]u32{}
	too_many_vertices := asset.Mesh_View {
		id = 1,
		vertices = vertices,
		indices = indices[:],
		primitive = .Triangles,
	}
	_, vertices_ok := optimize_mesh(too_many_vertices, out_vertices, out_indices[:], {})
	testing.expect(t, !vertices_ok, "optimize_mesh accepted too many vertices")
	large_indices := make([]u32, OPTIMIZE_MAX_INDICES + 3)
	defer delete(large_indices)
	large_out := make([]u32, len(large_indices))
	defer delete(large_out)
	one_vertex := [1]asset.Vertex{}
	too_many_indices := asset.Mesh_View {
		id = 1,
		vertices = one_vertex[:],
		indices = large_indices,
		primitive = .Triangles,
	}
	_, indices_ok := optimize_mesh(too_many_indices, one_vertex[:], large_out, {})
	testing.expect(t, !indices_ok, "optimize_mesh accepted too many indices")
	testing.expect(t, optimize_scratch_size(OPTIMIZE_MAX_VERTICES, OPTIMIZE_MAX_INDICES) > 0)
}

@(test)
optimize_scratch_make_carves_an_unaligned_block :: proc(t: ^testing.T) {
	vertex_count := 25
	index_count := 96
	size := optimize_scratch_size(vertex_count, index_count)
	block := make([]u8, size + OPTIMIZE_SCRATCH_PADDING * 2)
	defer delete(block)
	_, short_ok := optimize_scratch_make(block[:size], vertex_count, index_count)
	testing.expect(t, !short_ok, "optimize_scratch_make accepted a block without padding")
	// Every starting misalignment a caller's static array could land on.
	for offset in 0 ..< OPTIMIZE_SCRATCH_PADDING {
		window := block[offset:][:size + OPTIMIZE_SCRATCH_PADDING]
		scratch, ok := optimize_scratch_make(window, vertex_count, index_count)
		testing.expect(t, ok, "optimize_scratch_make refused a padded block")
		testing.expect_value(t, len(scratch.order), index_count)
		testing.expect_value(t, len(scratch.adjacency_offset), vertex_count + 1)
	}
}

// Average cache misses per triangle under the modelled cache. The absolute
// value depends on the cache size; only the direction of the change matters to
// the test that uses it.
@(private = "file")
_optimize_test_acmr :: proc(indices: []u32) -> f64 {
	assert(len(indices) % 3 == 0, "_optimize_test_acmr: incomplete triangle")
	ring := [OPTIMIZE_CACHE_SIZE]u32{}
	length := 0
	misses := 0
	for index in indices {
		hit := false
		for slot in 0 ..< length {
			if ring[slot] == index {
				hit = true
				break
			}
		}
		if hit do continue
		misses += 1
		if length < OPTIMIZE_CACHE_SIZE do length += 1
		for slot := length - 1; slot > 0; slot -= 1 do ring[slot] = ring[slot - 1]
		ring[0] = index
	}
	return f64(misses) / f64(len(indices) / 3)
}

@(private = "file")
Optimize_Test_Triangle :: struct {
	corners: [3]asset.Vec3,
}

// Triangles keyed by sorted vertex position, so the set can be compared across
// a renumber. Sorted so two runs are comparable elementwise.
@(private = "file")
_optimize_test_triangles :: proc(
	vertices: []asset.Vertex,
	indices: []u32,
) -> []Optimize_Test_Triangle {
	assert(len(indices) % 3 == 0, "_optimize_test_triangles: incomplete triangle")
	triangles := make([]Optimize_Test_Triangle, len(indices) / 3)
	for triangle in 0 ..< len(triangles) {
		corners: [3]asset.Vec3
		for corner in 0 ..< 3 do corners[corner] = vertices[indices[triangle * 3 + corner]].position
		for outer in 0 ..< 3 {
			for inner in outer + 1 ..< 3 {
				if _optimize_test_before(corners[inner], corners[outer]) {
					corners[outer], corners[inner] = corners[inner], corners[outer]
				}
			}
		}
		triangles[triangle] = {
			corners = corners,
		}
	}
	_heap_sort(triangles, _optimize_test_triangle_less)
	return triangles
}

@(private = "file")
_optimize_test_before :: proc(first, second: asset.Vec3) -> bool {
	for axis in 0 ..< 3 {
		if first[axis] != second[axis] do return first[axis] < second[axis]
	}
	return false
}

@(private = "file")
_optimize_test_triangle_less :: proc(first, second: Optimize_Test_Triangle) -> bool {
	for corner in 0 ..< 3 {
		if first.corners[corner] != second.corners[corner] {
			return _optimize_test_before(first.corners[corner], second.corners[corner])
		}
	}
	return false
}
