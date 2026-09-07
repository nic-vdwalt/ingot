package shared

import "core:math"
import procgen "ingot:procgen"

PLANET_SIM_FACE_CELLS :: 96
PLANET_SIM_FACE_COUNT :: PLANET_FACE_COUNT
PLANET_SIM_CELL_COUNT :: PLANET_SIM_FACE_COUNT * PLANET_SIM_FACE_CELLS * PLANET_SIM_FACE_CELLS
PLANET_SIM_TERRAIN_STRIDE :: PLANET_FACE_CELLS / PLANET_SIM_FACE_CELLS
PLANET_SIM_EDGE_COUNT :: 4
PLANET_SIM_INCIDENT_EDGE_COUNT :: PLANET_SIM_EDGE_COUNT * 2
#assert(PLANET_FACE_CELLS % PLANET_SIM_FACE_CELLS == 0)

Planet_Sim_Coord :: struct {
	face: procgen.Terrain_Face_V4,
	u:    i32,
	v:    i32,
}

Planet_Sim_Edge :: struct {
	index:      u32,
	neighbour:  u32,
	edge_east:  i32,
	edge_north: i32,
}

Planet_Sim_Incident_Edge :: struct {
	edge: u32,
	sign: i8,
}

Planet_Sim_Grid :: struct {
	directions:            [][3]f32,
	canonical_edges:       []Planet_Sim_Edge,
	scalar_edges:          []Planet_Sim_Edge,
	incident_edges:        [][PLANET_SIM_INCIDENT_EDGE_COUNT]Planet_Sim_Incident_Edge,
	incident_edge_count:   []u8,
	scalar_incident_edges: [][PLANET_SIM_INCIDENT_EDGE_COUNT]Planet_Sim_Incident_Edge,
	scalar_incident_count: []u8,
	latitude_microdegrees: []i32,
	longitude_phase:       []u64,
	coriolis_nano:         []i32,
	cell_area_m2:          []u64,
	neighbours:            [][PLANET_SIM_EDGE_COUNT]u32,
	edge_length_m:         [][PLANET_SIM_EDGE_COUNT]u32,
	interface_length_m:    [][PLANET_SIM_EDGE_COUNT]u32,
	edge_east:             [][PLANET_SIM_EDGE_COUNT]i32,
	edge_north:            [][PLANET_SIM_EDGE_COUNT]i32,
	local_to_neighbour:    [][PLANET_SIM_EDGE_COUNT][4]i32,
	reverse_edge:          [][PLANET_SIM_EDGE_COUNT]u8,
}

planet_sim_coord_valid :: proc(coord: Planet_Sim_Coord) -> bool {
	return(
		coord.u >= 0 &&
		coord.u < PLANET_SIM_FACE_CELLS &&
		coord.v >= 0 &&
		coord.v < PLANET_SIM_FACE_CELLS \
	)
}

planet_sim_index :: proc(coord: Planet_Sim_Coord) -> int {
	assert(planet_sim_coord_valid(coord), "planet_sim_index: invalid coordinate")
	stride := PLANET_SIM_FACE_CELLS * PLANET_SIM_FACE_CELLS
	return int(coord.face) * stride + int(coord.v) * PLANET_SIM_FACE_CELLS + int(coord.u)
}

planet_sim_coord_for_index :: proc(index: int) -> Planet_Sim_Coord {
	assert(
		index >= 0 && index < PLANET_SIM_CELL_COUNT,
		"planet_sim_coord_for_index: invalid index",
	)
	stride := PLANET_SIM_FACE_CELLS * PLANET_SIM_FACE_CELLS
	face := index / stride
	local := index % stride
	return {
		procgen.Terrain_Face_V4(face),
		i32(local % PLANET_SIM_FACE_CELLS),
		i32(local / PLANET_SIM_FACE_CELLS),
	}
}

planet_sim_terrain_coord :: proc(coord: Planet_Sim_Coord) -> Planet_Coord {
	assert(planet_sim_coord_valid(coord), "planet_sim_terrain_coord: invalid coordinate")
	stride := i32(PLANET_SIM_TERRAIN_STRIDE)
	return {coord.face, coord.u * stride + stride / 2, coord.v * stride + stride / 2}
}

planet_sim_direction :: proc(coord: Planet_Sim_Coord) -> [3]f32 {
	return planet_direction(planet_sim_terrain_coord(coord))
}

planet_sim_neighbour :: proc(coord: Planet_Sim_Coord, du, dv: i32) -> Planet_Sim_Coord {
	assert(planet_sim_coord_valid(coord), "planet_sim_neighbour: invalid coordinate")
	assert(abs(du) + abs(dv) == 1, "planet_sim_neighbour: cardinal step required")
	stride := i32(PLANET_SIM_TERRAIN_STRIDE)
	terrain := planet_sim_terrain_coord(coord)
	step_u, step_v := du * stride, dv * stride
	if coord.u + du < 0 || coord.u + du >= PLANET_SIM_FACE_CELLS {
		step_u = du * (stride / 2 + 1)
	}
	if coord.v + dv < 0 || coord.v + dv >= PLANET_SIM_FACE_CELLS {
		step_v = dv * (stride / 2 + 1)
	}
	neighbour := planet_neighbour(terrain, step_u, step_v)
	face, u, v := planet_locate(planet_direction(neighbour))
	return {
		face,
		clamp(i32(u / f32(stride)), 0, i32(PLANET_SIM_FACE_CELLS - 1)),
		clamp(i32(v / f32(stride)), 0, i32(PLANET_SIM_FACE_CELLS - 1)),
	}
}

planet_sim_longitude_phase :: proc(direction: [3]f32) -> u64 {
	angle := math.atan2(direction.y, direction.x)
	if angle < 0 do angle += 2 * math.PI
	return u64(angle * f32(ORBIT_PHASE_SCALE) / f32(2 * math.PI)) % ORBIT_PHASE_SCALE
}

planet_sim_grid_build_edge :: proc(
	grid: ^Planet_Sim_Grid,
	index, edge_index: int,
	du, dv: i32,
	edge_length: u32,
) {
	assert(grid != nil, "planet_sim_grid_build_edge: nil grid")
	assert(
		edge_index >= 0 && edge_index < PLANET_SIM_EDGE_COUNT,
		"planet_sim_grid_build_edge: edge",
	)
	coord := planet_sim_coord_for_index(index)
	neighbour_coord := planet_sim_neighbour(coord, du, dv)
	neighbour_index := planet_sim_index(neighbour_coord)
	radial := planet_sim_direction(coord)
	neighbour_radial := planet_sim_direction(neighbour_coord)
	_, east, north := planet_basis(radial)
	_, neighbour_east, neighbour_north := planet_basis(neighbour_radial)
	delta := neighbour_radial - radial
	delta_length := math.sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
	if delta_length > 0 do delta /= delta_length
	grid.neighbours[index][edge_index] = u32(neighbour_index)
	grid.edge_length_m[index][edge_index] = edge_length
	grid.edge_east[index][edge_index] = i32(
		clamp(delta.x * east.x + delta.y * east.y + delta.z * east.z, f32(-1), f32(1)) *
		f32(PLANET_VECTOR_SCALE),
	)
	grid.edge_north[index][edge_index] = i32(
		clamp(delta.x * north.x + delta.y * north.y + delta.z * north.z, f32(-1), f32(1)) *
		f32(PLANET_VECTOR_SCALE),
	)
	grid.local_to_neighbour[index][edge_index] = {
		i32(
			(neighbour_east.x * east.x + neighbour_east.y * east.y + neighbour_east.z * east.z) *
			f32(PLANET_VECTOR_SCALE),
		),
		i32(
			(neighbour_north.x * east.x +
				neighbour_north.y * east.y +
				neighbour_north.z * east.z) *
			f32(PLANET_VECTOR_SCALE),
		),
		i32(
			(neighbour_east.x * north.x +
				neighbour_east.y * north.y +
				neighbour_east.z * north.z) *
			f32(PLANET_VECTOR_SCALE),
		),
		i32(
			(neighbour_north.x * north.x +
				neighbour_north.y * north.y +
				neighbour_north.z * north.z) *
			f32(PLANET_VECTOR_SCALE),
		),
	}
}

planet_sim_grid_build_edges :: proc(grid: ^Planet_Sim_Grid, index: int, edge_length: u32) {
	assert(grid != nil, "planet_sim_grid_build_edges: nil grid")
	assert(index >= 0 && index < PLANET_SIM_CELL_COUNT, "planet_sim_grid_build_edges: index")
	planet_sim_grid_build_edge(grid, index, 0, -1, 0, edge_length)
	planet_sim_grid_build_edge(grid, index, 1, 1, 0, edge_length)
	planet_sim_grid_build_edge(grid, index, 2, 0, -1, edge_length)
	planet_sim_grid_build_edge(grid, index, 3, 0, 1, edge_length)
}

planet_sim_rotate_local_to_neighbour :: proc(
	grid: ^Planet_Sim_Grid,
	index, edge_index: int,
	east, north: i32,
) -> (
	i64,
	i64,
) {
	assert(grid != nil, "planet_sim_rotate_local_to_neighbour: nil grid")
	assert(
		index >= 0 && index < PLANET_SIM_CELL_COUNT,
		"planet_sim_rotate_local_to_neighbour: index",
	)
	transform := grid.local_to_neighbour[index][edge_index]
	neighbour_east :=
		(i64(east) * i64(transform[0]) + i64(north) * i64(transform[2])) / i64(PLANET_VECTOR_SCALE)
	neighbour_north :=
		(i64(east) * i64(transform[1]) + i64(north) * i64(transform[3])) / i64(PLANET_VECTOR_SCALE)
	return neighbour_east, neighbour_north
}

planet_sim_rotate_neighbour_to_local :: proc(
	grid: ^Planet_Sim_Grid,
	index, edge_index: int,
	east, north: i32,
) -> (
	i64,
	i64,
) {
	assert(grid != nil, "planet_sim_rotate_neighbour_to_local: nil grid")
	assert(
		index >= 0 && index < PLANET_SIM_CELL_COUNT,
		"planet_sim_rotate_neighbour_to_local: index",
	)
	transform := grid.local_to_neighbour[index][edge_index]
	local_east :=
		(i64(east) * i64(transform[0]) + i64(north) * i64(transform[1])) / i64(PLANET_VECTOR_SCALE)
	local_north :=
		(i64(east) * i64(transform[2]) + i64(north) * i64(transform[3])) / i64(PLANET_VECTOR_SCALE)
	return local_east, local_north
}

planet_sim_forward_edge :: proc(grid: ^Planet_Sim_Grid, index: int, east, north: i32) -> int {
	assert(grid != nil, "planet_sim_forward_edge: nil grid")
	assert(index >= 0 && index < PLANET_SIM_CELL_COUNT, "planet_sim_forward_edge: index")
	best_edge := 0
	best_dot := i64(-1 << 62)
	for edge_index in 0 ..< PLANET_SIM_EDGE_COUNT {
		dot :=
			i64(east) * i64(grid.edge_east[index][edge_index]) +
			i64(north) * i64(grid.edge_north[index][edge_index])
		if dot > best_dot {
			best_dot = dot
			best_edge = edge_index
		}
	}
	return best_edge
}

planet_sim_cell_corners :: proc(coord: Planet_Sim_Coord) -> [4][3]f64 {
	stride := i32(PLANET_SIM_TERRAIN_STRIDE)
	corners: [4][3]f64
	offsets := [4][2]i32{{0, 0}, {1, 0}, {1, 1}, {0, 1}}
	for offset, index in offsets {
		direction := planet_direction({coord.face, (coord.u + offset.x) * stride, (coord.v + offset.y) * stride})
		corners[index] = {f64(direction.x), f64(direction.y), f64(direction.z)}
		corners[index] /= math.sqrt(_planet_metric_dot(corners[index], corners[index]))
	}
	return corners
}

_planet_metric_dot :: proc(left, right: [3]f64) -> f64 {
	return left.x * right.x + left.y * right.y + left.z * right.z
}

_planet_metric_triangle :: proc(first, second, third: [3]f64) -> f64 {
	cross := [3]f64{second.y * third.z - second.z * third.y, second.z * third.x - second.x * third.z, second.x * third.y - second.y * third.x}
	return 2 * math.atan2(abs(_planet_metric_dot(first, cross)), 1 + _planet_metric_dot(first, second) + _planet_metric_dot(second, third) + _planet_metric_dot(third, first))
}

planet_sim_cell_solid_angle :: proc(coord: Planet_Sim_Coord) -> f64 {
	corners := planet_sim_cell_corners(coord)
	return _planet_metric_triangle(corners[0], corners[1], corners[2]) + _planet_metric_triangle(corners[0], corners[2], corners[3])
}

_planet_metric_arc :: proc(first, second: [3]f64) -> f64 {
	difference := first - second
	return 2 * math.asin(clamp(math.sqrt(_planet_metric_dot(difference, difference)) * 0.5, f64(0), f64(1)))
}

planet_sim_edge_metrics :: proc(coord: Planet_Sim_Coord, edge: int, radius_m: f64) -> (distance, interface_length: u32) {
	offsets := [4][2]i32{{-1, 0}, {1, 0}, {0, -1}, {0, 1}}
	ends := [4][2]int{{0, 3}, {1, 2}, {0, 1}, {3, 2}}
	first := planet_sim_direction(coord)
	second := planet_sim_direction(planet_sim_neighbour(coord, offsets[edge].x, offsets[edge].y))
	first64 := [3]f64{f64(first.x), f64(first.y), f64(first.z)}
	second64 := [3]f64{f64(second.x), f64(second.y), f64(second.z)}
	corners := planet_sim_cell_corners(coord)
	distance = u32(clamp(math.round(_planet_metric_arc(first64, second64) * radius_m), f64(1), f64(max(u32))))
	interface_length = u32(clamp(math.round(_planet_metric_arc(corners[ends[edge].x], corners[ends[edge].y]) * radius_m), f64(1), f64(max(u32))))
	return
}

planet_sim_grid_init :: proc(
	grid: ^Planet_Sim_Grid,
	physical: Planet_Physical_Parameters,
	allocator := context.allocator,
) {
	assert(grid != nil, "planet_sim_grid_init: nil grid")
	assert(physical.radius_m > 0, "planet_sim_grid_init: zero radius")
	grid^ = {}
	grid.directions = make([][3]f32, PLANET_SIM_CELL_COUNT, allocator)
	grid.latitude_microdegrees = make([]i32, PLANET_SIM_CELL_COUNT, allocator)
	grid.longitude_phase = make([]u64, PLANET_SIM_CELL_COUNT, allocator)
	grid.coriolis_nano = make([]i32, PLANET_SIM_CELL_COUNT, allocator)
	grid.cell_area_m2 = make([]u64, PLANET_SIM_CELL_COUNT, allocator)
	grid.neighbours = make([][PLANET_SIM_EDGE_COUNT]u32, PLANET_SIM_CELL_COUNT, allocator)
	grid.edge_length_m = make([][PLANET_SIM_EDGE_COUNT]u32, PLANET_SIM_CELL_COUNT, allocator)
	grid.interface_length_m = make([][PLANET_SIM_EDGE_COUNT]u32, PLANET_SIM_CELL_COUNT, allocator)
	grid.edge_east = make([][PLANET_SIM_EDGE_COUNT]i32, PLANET_SIM_CELL_COUNT, allocator)
	grid.edge_north = make([][PLANET_SIM_EDGE_COUNT]i32, PLANET_SIM_CELL_COUNT, allocator)
	grid.incident_edges = make(
		[][PLANET_SIM_INCIDENT_EDGE_COUNT]Planet_Sim_Incident_Edge,
		PLANET_SIM_CELL_COUNT,
		allocator,
	)
	grid.incident_edge_count = make([]u8, PLANET_SIM_CELL_COUNT, allocator)
	grid.scalar_incident_edges = make(
		[][PLANET_SIM_INCIDENT_EDGE_COUNT]Planet_Sim_Incident_Edge,
		PLANET_SIM_CELL_COUNT,
		allocator,
	)
	grid.scalar_incident_count = make([]u8, PLANET_SIM_CELL_COUNT, allocator)
	grid.local_to_neighbour = make(
		[][PLANET_SIM_EDGE_COUNT][4]i32,
		PLANET_SIM_CELL_COUNT,
		allocator,
	)
	grid.reverse_edge = make([][PLANET_SIM_EDGE_COUNT]u8, PLANET_SIM_CELL_COUNT, allocator)
	radius := f64(physical.radius_m)
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		direction := planet_sim_direction(planet_sim_coord_for_index(index))
		grid.directions[index] = direction
		latitude := math.asin(clamp(direction.z, f32(-1), f32(1)))
		grid.latitude_microdegrees[index] = i32(latitude * f32(180_000_000 / math.PI))
		grid.longitude_phase[index] = planet_sim_longitude_phase(direction)
		grid.coriolis_nano[index] = i32(145_842 * math.sin(latitude))
		coord := planet_sim_coord_for_index(index)
		grid.cell_area_m2[index] = u64(max(f64(1), math.round(planet_sim_cell_solid_angle(coord) * radius * radius)))
		planet_sim_grid_build_edges(grid, index, 1)
		for edge_index in 0 ..< PLANET_SIM_EDGE_COUNT {
			distance, interface_length := planet_sim_edge_metrics(coord, edge_index, radius)
			grid.edge_length_m[index][edge_index] = distance
			grid.interface_length_m[index][edge_index] = interface_length
		}
	}
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		for edge_index in 0 ..< PLANET_SIM_EDGE_COUNT {
			neighbour := int(grid.neighbours[index][edge_index])
			best_reverse := 0
			best_dot := i64(-1 << 62)
			for reverse in 0 ..< PLANET_SIM_EDGE_COUNT {
				dot :=
					-i64(grid.edge_east[index][edge_index]) *
						i64(grid.edge_east[neighbour][reverse]) -
					i64(grid.edge_north[index][edge_index]) *
						i64(grid.edge_north[neighbour][reverse])
				if dot > best_dot {
					best_dot = dot
					best_reverse = reverse
				}
			}
			grid.reverse_edge[index][edge_index] = u8(best_reverse)
		}
	}
	canonical := make([dynamic]Planet_Sim_Edge, 0, PLANET_SIM_CELL_COUNT * 2, allocator)
	scalar := make([dynamic]Planet_Sim_Edge, 0, PLANET_SIM_CELL_COUNT * 2, allocator)
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		for edge_index in 0 ..< PLANET_SIM_EDGE_COUNT {
			neighbour := int(grid.neighbours[index][edge_index])
			if neighbour <= index do continue
			edge := Planet_Sim_Edge {
				index      = u32(index),
				neighbour  = u32(neighbour),
				edge_east  = grid.edge_east[index][edge_index],
				edge_north = grid.edge_north[index][edge_index],
			}
			append(&canonical, edge)
			if edge_index > 0 do append(&scalar, edge)
		}
	}
	grid.canonical_edges = canonical[:]
	grid.scalar_edges = scalar[:]
	for edge, edge_index in grid.canonical_edges {
		index := int(edge.index)
		neighbour := int(edge.neighbour)
		index_slot := int(grid.incident_edge_count[index])
		neighbour_slot := int(grid.incident_edge_count[neighbour])
		assert(
			index_slot < PLANET_SIM_INCIDENT_EDGE_COUNT,
			"planet_sim_grid_init: index incidence",
		)
		assert(
			neighbour_slot < PLANET_SIM_INCIDENT_EDGE_COUNT,
			"planet_sim_grid_init: neighbour incidence",
		)
		grid.incident_edges[index][index_slot] = {u32(edge_index), -1}
		grid.incident_edges[neighbour][neighbour_slot] = {u32(edge_index), 1}
		grid.incident_edge_count[index] += 1
		grid.incident_edge_count[neighbour] += 1
	}
	for edge, edge_index in grid.scalar_edges {
		index := int(edge.index)
		neighbour := int(edge.neighbour)
		index_slot := int(grid.scalar_incident_count[index])
		neighbour_slot := int(grid.scalar_incident_count[neighbour])
		assert(
			index_slot < PLANET_SIM_INCIDENT_EDGE_COUNT,
			"planet_sim_grid_init: scalar index incidence",
		)
		assert(
			neighbour_slot < PLANET_SIM_INCIDENT_EDGE_COUNT,
			"planet_sim_grid_init: scalar neighbour incidence",
		)
		grid.scalar_incident_edges[index][index_slot] = {u32(edge_index), 1}
		grid.scalar_incident_edges[neighbour][neighbour_slot] = {u32(edge_index), -1}
		grid.scalar_incident_count[index] += 1
		grid.scalar_incident_count[neighbour] += 1
	}
}

planet_sim_grid_deinit :: proc(grid: ^Planet_Sim_Grid, allocator := context.allocator) {
	assert(grid != nil, "planet_sim_grid_deinit: nil grid")
	delete(grid.scalar_incident_count, allocator)
	delete(grid.scalar_incident_edges, allocator)
	delete(grid.incident_edge_count, allocator)
	delete(grid.incident_edges, allocator)
	delete(grid.scalar_edges, allocator)
	delete(grid.canonical_edges, allocator)
	delete(grid.directions, allocator)
	delete(grid.reverse_edge, allocator)
	delete(grid.local_to_neighbour, allocator)
	delete(grid.edge_north, allocator)
	delete(grid.edge_east, allocator)
	delete(grid.interface_length_m, allocator)
	delete(grid.edge_length_m, allocator)
	delete(grid.neighbours, allocator)
	delete(grid.cell_area_m2, allocator)
	delete(grid.coriolis_nano, allocator)
	delete(grid.longitude_phase, allocator)
	delete(grid.latitude_microdegrees, allocator)
	grid^ = {}
}
