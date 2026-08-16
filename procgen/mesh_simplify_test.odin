
package procgen

import asset "../asset"
import "core:math"
import "core:testing"

// Shared fixture for the simplifier and cluster-builder tests: a flat grid of
// `cells` x `cells` quads on the XY plane. A plane is the sharpest possible
// oracle for a quadric simplifier - every interior collapse is exactly free, so
// any reported error above the floating-point floor is a bug in the metric.
mesh_test_grid :: proc(
	cells: int,
	vertices: []asset.Vertex,
	indices: []u32,
) -> asset.Mesh_View {
	edge := cells + 1
	for row in 0 ..< edge {
		for column in 0 ..< edge {
			vertices[row * edge + column] = {
				position = {f32(column), f32(row), 0},
				normal   = {0, 0, 1},
				scalar   = 0,
				uv       = {f32(column) / f32(cells), f32(row) / f32(cells)},
			}
		}
	}
	write := 0
	for row in 0 ..< cells {
		for column in 0 ..< cells {
			base := u32(row * edge + column)
			corners := [6]u32 {
				base,
				base + 1,
				base + u32(edge),
				base + 1,
				base + u32(edge) + 1,
				base + u32(edge),
			}
			for corner in corners {
				indices[write] = corner
				write += 1
			}
		}
	}
	return asset.Mesh_View {
		id = 1,
		vertices = vertices[:edge * edge],
		indices = indices[:write],
		primitive = .Triangles,
		bounds = {minimum = {0, 0, 0}, maximum = {f32(cells), f32(cells), 0}},
	}
}

mesh_test_scratch :: proc(vertex_count, index_count: int) -> Simplify_Scratch {
	table_vertices := _simplify_table_size(vertex_count)
	table_edges := _simplify_table_size(index_count)
	return Simplify_Scratch {
		quadrics = make([]Quadric, vertex_count),
		group = make([]u32, vertex_count),
		collapse = make([]u32, vertex_count),
		touched = make([]u32, vertex_count),
		compact = make([]u32, vertex_count),
		vertex_table = make([]u32, table_vertices),
		edge_table = make([]u32, table_edges),
		edges = make([]Simplify_Edge, index_count),
		candidates = make([]Simplify_Candidate, index_count),
		flags = make([]u8, vertex_count),
	}
}

mesh_test_scratch_free :: proc(scratch: Simplify_Scratch) {
	delete(scratch.quadrics)
	delete(scratch.group)
	delete(scratch.collapse)
	delete(scratch.touched)
	delete(scratch.compact)
	delete(scratch.vertex_table)
	delete(scratch.edge_table)
	delete(scratch.edges)
	delete(scratch.candidates)
	delete(scratch.flags)
}

@(test)
simplify_halves_a_plane_without_error :: proc(t: ^testing.T) {
	cells := 16
	source_vertices := make([]asset.Vertex, (cells + 1) * (cells + 1))
	source_indices := make([]u32, cells * cells * 6)
	defer delete(source_vertices)
	defer delete(source_indices)
	source := mesh_test_grid(cells, source_vertices, source_indices)
	out_vertices := make([]asset.Vertex, len(source.vertices))
	out_indices := make([]u32, len(source.indices))
	defer delete(out_vertices)
	defer delete(out_indices)
	scratch := mesh_test_scratch(len(source.vertices), len(source.indices))
	defer mesh_test_scratch_free(scratch)
	options := Simplify_Options {
		target_index_count = len(source.indices) / 2,
	}
	result, ok := simplify_mesh(source, options, nil, out_vertices, out_indices, scratch)
	testing.expect(t, ok)
	testing.expect(t, result.index_count <= len(source.indices) / 2)
	testing.expect(t, result.index_count > 0)
	testing.expect(t, result.vertex_count > 0)
	// A plane collapses onto itself, so the quadric error must stay at the
	// arithmetic floor rather than merely "small".
	testing.expect(t, result.error < 1.0e-3)
}

@(test)
simplify_preserves_locked_vertices :: proc(t: ^testing.T) {
	cells := 12
	edge := cells + 1
	source_vertices := make([]asset.Vertex, edge * edge)
	source_indices := make([]u32, cells * cells * 6)
	defer delete(source_vertices)
	defer delete(source_indices)
	source := mesh_test_grid(cells, source_vertices, source_indices)
	locked := make([]bool, len(source.vertices))
	defer delete(locked)
	for row in 0 ..< edge {
		for column in 0 ..< edge {
			border := row == 0 || column == 0 || row == edge - 1 || column == edge - 1
			locked[row * edge + column] = border
		}
	}
	out_vertices := make([]asset.Vertex, len(source.vertices))
	out_indices := make([]u32, len(source.indices))
	defer delete(out_vertices)
	defer delete(out_indices)
	scratch := mesh_test_scratch(len(source.vertices), len(source.indices))
	defer mesh_test_scratch_free(scratch)
	options := Simplify_Options {
		target_index_count = 6,
	}
	result, ok := simplify_mesh(source, options, locked, out_vertices, out_indices, scratch)
	testing.expect(t, ok)
	// Every locked position must survive at bit-identical coordinates: that is
	// what makes neighbouring cluster groups meet without a crack.
	for index in 0 ..< len(source.vertices) {
		if !locked[index] do continue
		wanted := source.vertices[index].position
		found := false
		for offset in 0 ..< result.vertex_count {
			if out_vertices[offset].position == wanted {
				found = true
				break
			}
		}
		testing.expectf(t, found, "locked vertex %v was collapsed away", wanted)
	}
}

@(test)
simplify_rejects_undersized_storage :: proc(t: ^testing.T) {
	cells := 4
	source_vertices := make([]asset.Vertex, (cells + 1) * (cells + 1))
	source_indices := make([]u32, cells * cells * 6)
	defer delete(source_vertices)
	defer delete(source_indices)
	source := mesh_test_grid(cells, source_vertices, source_indices)
	scratch := mesh_test_scratch(len(source.vertices), len(source.indices))
	defer mesh_test_scratch_free(scratch)
	short_vertices := make([]asset.Vertex, 1)
	short_indices := make([]u32, 1)
	defer delete(short_vertices)
	defer delete(short_indices)
	_, ok := simplify_mesh(source, {}, nil, short_vertices, short_indices, scratch)
	testing.expect(t, !ok)
}

@(test)
simplify_is_deterministic :: proc(t: ^testing.T) {
	cells := 10
	source_vertices := make([]asset.Vertex, (cells + 1) * (cells + 1))
	source_indices := make([]u32, cells * cells * 6)
	defer delete(source_vertices)
	defer delete(source_indices)
	source := mesh_test_grid(cells, source_vertices, source_indices)
	scratch := mesh_test_scratch(len(source.vertices), len(source.indices))
	defer mesh_test_scratch_free(scratch)
	first_vertices := make([]asset.Vertex, len(source.vertices))
	first_indices := make([]u32, len(source.indices))
	second_vertices := make([]asset.Vertex, len(source.vertices))
	second_indices := make([]u32, len(source.indices))
	defer delete(first_vertices)
	defer delete(first_indices)
	defer delete(second_vertices)
	defer delete(second_indices)
	options := Simplify_Options {
		target_index_count = len(source.indices) / 4,
	}
	first, first_ok := simplify_mesh(source, options, nil, first_vertices, first_indices, scratch)
	second, second_ok := simplify_mesh(
		source,
		options,
		nil,
		second_vertices,
		second_indices,
		scratch,
	)
	testing.expect(t, first_ok && second_ok)
	testing.expect_value(t, first.vertex_count, second.vertex_count)
	testing.expect_value(t, first.index_count, second.index_count)
	testing.expect_value(t, first.error, second.error)
	for index in 0 ..< first.index_count {
		testing.expect_value(t, first_indices[index], second_indices[index])
	}
	for index in 0 ..< first.vertex_count {
		testing.expect_value(t, first_vertices[index].position, second_vertices[index].position)
	}
}

@(test)
simplify_never_reports_negative_error :: proc(t: ^testing.T) {
	cells := 8
	source_vertices := make([]asset.Vertex, (cells + 1) * (cells + 1))
	source_indices := make([]u32, cells * cells * 6)
	defer delete(source_vertices)
	defer delete(source_indices)
	source := mesh_test_grid(cells, source_vertices, source_indices)
	// A ridge makes the plane non-planar so collapses cost something real.
	for index in 0 ..< len(source.vertices) {
		source_vertices[index].position[2] = math.sin(f32(index) * 0.5) * 0.25
	}
	out_vertices := make([]asset.Vertex, len(source.vertices))
	out_indices := make([]u32, len(source.indices))
	defer delete(out_vertices)
	defer delete(out_indices)
	scratch := mesh_test_scratch(len(source.vertices), len(source.indices))
	defer mesh_test_scratch_free(scratch)
	view := source
	view.bounds = {minimum = {0, 0, -1}, maximum = {f32(cells), f32(cells), 1}}
	options := Simplify_Options {
		target_index_count = len(source.indices) / 2,
	}
	result, ok := simplify_mesh(view, options, nil, out_vertices, out_indices, scratch)
	testing.expect(t, ok)
	testing.expect(t, result.error >= 0)
	testing.expect(t, !math.is_nan(result.error))
}
