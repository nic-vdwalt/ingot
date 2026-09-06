package shared

import "core:testing"

@(test)
planet_sim_grid_cardinal_neighbours_cross_faces :: proc(t: ^testing.T) {
	coord := Planet_Sim_Coord{.Pos_X, 0, PLANET_SIM_FACE_CELLS / 2}
	across := planet_sim_neighbour(coord, -1, 0)
	testing.expect(t, planet_sim_coord_valid(across))
	testing.expect(t, across.face != coord.face)
}

@(test)
planet_sim_grid_roundtrips_indices :: proc(t: ^testing.T) {
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		coord := planet_sim_coord_for_index(index)
		testing.expect_value(t, planet_sim_index(coord), index)
	}
}

@(test)
planet_sim_grid_precomputes_canonical_topology_and_directions :: proc(t: ^testing.T) {
	grid: Planet_Sim_Grid
	planet_sim_grid_init(&grid, planet_physical_earthlike())
	defer planet_sim_grid_deinit(&grid)
	canonical_cursor := 0
	scalar_cursor := 0
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		testing.expect_value(
			t,
			grid.directions[index],
			planet_sim_direction(planet_sim_coord_for_index(index)),
		)
		for edge_index in 0 ..< PLANET_SIM_EDGE_COUNT {
			neighbour := int(grid.neighbours[index][edge_index])
			if neighbour <= index do continue
			edge := grid.canonical_edges[canonical_cursor]
			testing.expect_value(t, edge.index, u32(index))
			testing.expect_value(t, edge.neighbour, u32(neighbour))
			testing.expect_value(t, edge.edge_east, grid.edge_east[index][edge_index])
			testing.expect_value(t, edge.edge_north, grid.edge_north[index][edge_index])
			canonical_cursor += 1
			if edge_index > 0 {
				testing.expect_value(t, grid.scalar_edges[scalar_cursor], edge)
				scalar_cursor += 1
			}
		}
	}
	testing.expect_value(t, canonical_cursor, len(grid.canonical_edges))
	testing.expect_value(t, scalar_cursor, len(grid.scalar_edges))
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		seen := 0
		for edge, edge_index in grid.canonical_edges {
			if int(edge.index) == index {
				incident := grid.incident_edges[index][seen]
				testing.expect_value(t, incident.edge, u32(edge_index))
				testing.expect_value(t, incident.sign, i8(-1))
				seen += 1
			} else if int(edge.neighbour) == index {
				incident := grid.incident_edges[index][seen]
				testing.expect_value(t, incident.edge, u32(edge_index))
				testing.expect_value(t, incident.sign, i8(1))
				seen += 1
			}
		}
		testing.expect_value(t, seen, int(grid.incident_edge_count[index]))
	}
}

@(test)
planet_sim_heading_crosses_every_face_seam_continuously :: proc(t: ^testing.T) {
	grid: Planet_Sim_Grid
	planet_sim_grid_init(&grid, planet_physical_earthlike())
	defer planet_sim_grid_deinit(&grid)
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		coord := planet_sim_coord_for_index(index)
		if coord.u > 0 &&
		   coord.u < PLANET_SIM_FACE_CELLS - 1 &&
		   coord.v > 0 &&
		   coord.v < PLANET_SIM_FACE_CELLS - 1 {
			continue
		}
		for edge in 0 ..< PLANET_SIM_EDGE_COUNT {
			east, north := planet_sim_rotate_local_to_neighbour(
				&grid,
				index,
				edge,
				707_107,
				707_107,
			)
			length := integer_sqrt(u64(east * east + north * north))
			testing.expect(t, abs(i64(length) - i64(PLANET_VECTOR_SCALE)) < 4_000)
			local_east, local_north := planet_sim_rotate_neighbour_to_local(
				&grid,
				index,
				edge,
				i32(east),
				i32(north),
			)
			testing.expect(t, abs(local_east - 707_107) < 4_000)
			testing.expect(t, abs(local_north - 707_107) < 4_000)
		}
	}
}

@(test)
planet_sim_metrics_cover_sphere_without_overflow :: proc(t: ^testing.T) {
	grid: Planet_Sim_Grid
	physical := planet_physical_earthlike()
	planet_sim_grid_init(&grid, physical)
	defer planet_sim_grid_deinit(&grid)
	total := u64(0)
	minimum := max(u64)
	maximum := u64(0)
	for area, index in grid.cell_area_m2 {
		total += area
		minimum = min(minimum, area)
		maximum = max(maximum, area)
		for edge in 0 ..< PLANET_SIM_EDGE_COUNT {
			testing.expect(t, grid.edge_length_m[index][edge] > 50_000)
			testing.expect(t, grid.interface_length_m[index][edge] > 50_000)
			neighbour := int(grid.neighbours[index][edge])
			found := false
			for reverse in 0 ..< PLANET_SIM_EDGE_COUNT {
				if grid.neighbours[neighbour][reverse] != u32(index) do continue
				found = true
				testing.expect(t, abs(i64(grid.interface_length_m[index][edge]) - i64(grid.interface_length_m[neighbour][reverse])) <= 2)
			}
			testing.expect(t, found)
		}
	}
	expected := 4 * 3.141592653589793 * f64(physical.radius_m) * f64(physical.radius_m)
	testing.expect(t, abs(f64(total) - expected) / expected < 0.001)
	testing.expect(t, maximum > minimum)
}

@(test)
planet_physics_saturation_is_bounded :: proc(t: ^testing.T) {
	testing.expect_value(t, planet_saturating_i32(-10, 0, 4), i32(0))
	testing.expect_value(t, planet_saturating_i32(10, 0, 4), i32(4))
	testing.expect_value(t, planet_saturating_u32(-1, 7), u32(0))
	testing.expect_value(t, planet_saturating_u32(9, 7), u32(7))
}
