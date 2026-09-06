package main

import "core:testing"

@(test)
selection_grid_segment_count_covers_internal_and_outer_lines :: proc(t: ^testing.T) {
	testing.expect_value(t, selection_grid_segment_count(1, 1), 16)
	testing.expect_value(t, selection_grid_segment_count(2, 2), 48)
	testing.expect_value(t, selection_grid_segment_count(3, 3), 96)
	testing.expect(t, selection_grid_segment_count(3, 3) <= SELECTION_GRID_MAX_SEGMENTS)
}

@(test)
selection_brackets_are_bounded_unit_cube_segments :: proc(t: ^testing.T) {
	vertices := selection_bracket_vertices()
	testing.expect_value(t, vertices, marker_corner_vertices())
	testing.expect_value(t, len(vertices), SELECTION_BRACKET_VERTICES)
	for vertex in vertices {
		testing.expect(t, vertex.position.x >= -0.5 && vertex.position.x <= 0.5)
		testing.expect(t, vertex.position.y >= -0.5 && vertex.position.y <= 0.5)
		testing.expect(t, vertex.position.z >= -0.5 && vertex.position.z <= 0.5)
	}
}
