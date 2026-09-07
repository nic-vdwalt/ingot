package main

import shared "../shared"
import "core:math"

OCEAN_NEARSHORE_CELLS :: 96
OCEAN_NEARSHORE_EDGE :: OCEAN_NEARSHORE_CELLS + 1
OCEAN_NEARSHORE_COUNT :: OCEAN_NEARSHORE_EDGE * OCEAN_NEARSHORE_EDGE
OCEAN_NEARSHORE_RADIUS :: f32(180)
OCEAN_NEARSHORE_GRAVITY :: f32(9.81)
OCEAN_NEARSHORE_DRY_DEPTH :: f32(0.02)
OCEAN_NEARSHORE_CFL :: f32(0.45)
OCEAN_NEARSHORE_MAX_SUBSTEPS :: 8
OCEAN_NEARSHORE_MOMENTUM_SETTLE_S :: f32(8)
OCEAN_NEARSHORE_BREAK_SEGMENT_MAX :: 256

Ocean_Nearshore_Break_Segment :: struct {
	center:         [3]f32,
	tangent:        [3]f32,
	shallow_normal: [3]f32,
	depth:          f32,
	bed_slope:      f32,
	foam:           f32,
}

Ocean_Nearshore_Cell :: struct {
	depth:      f32,
	momentum_x: f32,
	momentum_y: f32,
}

Ocean_Nearshore_Surface_Sample :: struct {
	displacement: [3]f32,
	normal:       [3]f32,
	velocity:     [3]f32,
	depth:        f32,
	foam:         f32,
	blend:        f32,
}

Ocean_Nearshore :: struct {
	state:               [OCEAN_NEARSHORE_COUNT]Ocean_Nearshore_Cell,
	scratch:             [OCEAN_NEARSHORE_COUNT]Ocean_Nearshore_Cell,
	pending_state:       [OCEAN_NEARSHORE_COUNT]Ocean_Nearshore_Cell,
	pending_foam:        [OCEAN_NEARSHORE_COUNT]f32,
	pending_control:     [2]f32,
	tick_pending:        bool,
	bathymetry:          [OCEAN_NEARSHORE_COUNT]f32,
	still_depth:         [OCEAN_NEARSHORE_COUNT]f32,
	still_scratch:       [OCEAN_NEARSHORE_COUNT]f32,
	foam:                [OCEAN_NEARSHORE_COUNT]f32,
	foam_scratch:        [OCEAN_NEARSHORE_COUNT]f32,
	flux_x:              [OCEAN_NEARSHORE_COUNT]Ocean_Nearshore_Cell,
	flux_y:              [OCEAN_NEARSHORE_COUNT]Ocean_Nearshore_Cell,
	focus:               [3]f32,
	east:                [3]f32,
	north:               [3]f32,
	waterfield_revision: u64,
	last_mass_error:     f64,
	last_boundary_mass:  f64,
	last_source_mass:    f64,
	last_source_momentum: [2]f64,
	last_source_energy: f64,
	last_clamp_mass:     f64,
	last_substeps:       int,
	time_backlog:        f32,
	dropped_time:        f32,
	last_advanced_time:  f32,
	fixture_active:      bool,
	ready:               bool,
}

Ocean_Surf_Fixture :: enum {
	Deep,
	Beach,
	Bank,
	Reef,
}

ocean_surf_fixture_bed :: proc(kind: Ocean_Surf_Fixture, forward, lateral: f32) -> f32 {
	switch kind {
	case .Deep:
		return -12
	case .Beach:
		return forward * 0.04 - 4
	case .Bank:
		return max(forward * 0.25 - 4, f32(-12))
	case .Reef:
		crest := forward - lateral * 0.2
		return -12 + 10 * math.exp(-crest * crest / 400)
	}
	return -12
}

ocean_surf_fixture_depth :: proc(kind: Ocean_Surf_Fixture, forward, lateral: f32) -> f32 {
	return max(-ocean_surf_fixture_bed(kind, forward, lateral), f32(0))
}

ocean_surf_fixture_init :: proc(value: ^Ocean_Nearshore, focus: [3]f32, kind: Ocean_Surf_Fixture) {
	value^ = {}
	value.focus, value.ready = ocean_wave_normalize(focus)
	value.fixture_active = value.ready
	if !value.ready do return
	_, value.east, value.north = shared.planet_basis(value.focus)
	spacing := OCEAN_NEARSHORE_RADIUS * 2 / f32(OCEAN_NEARSHORE_CELLS)
	for row in 0 ..< OCEAN_NEARSHORE_EDGE {
		for column in 0 ..< OCEAN_NEARSHORE_EDGE {
			index := ocean_nearshore_index(column, row)
			forward := (f32(column) - f32(OCEAN_NEARSHORE_CELLS) * 0.5) * spacing
			lateral := (f32(row) - f32(OCEAN_NEARSHORE_CELLS) * 0.5) * spacing
			bed := ocean_surf_fixture_bed(kind, forward, lateral)
			depth := max(-bed, f32(0))
			value.still_depth[index] = depth
			value.bathymetry[index] = bed
			value.state[index].depth = depth
		}
	}
}

ocean_nearshore_index :: proc(column, row: int) -> int {
	assert(column >= 0 && column < OCEAN_NEARSHORE_EDGE)
	assert(row >= 0 && row < OCEAN_NEARSHORE_EDGE)
	return row * OCEAN_NEARSHORE_EDGE + column
}

ocean_nearshore_reconstructed_depth :: proc(depth, bed, other_bed: f32) -> f32 {
	return max(depth - max(other_bed - bed, f32(0)), f32(0))
}

ocean_nearshore_hll_flux :: proc(
	left, right: Ocean_Nearshore_Cell,
	bed_left, bed_right: f32,
	axis: int,
) -> Ocean_Nearshore_Cell {
	left_depth := ocean_nearshore_reconstructed_depth(left.depth, bed_left, bed_right)
	right_depth := ocean_nearshore_reconstructed_depth(right.depth, bed_right, bed_left)
	left_normal := left.momentum_x if axis == 0 else left.momentum_y
	right_normal := right.momentum_x if axis == 0 else right.momentum_y
	left_tangent := left.momentum_y if axis == 0 else left.momentum_x
	right_tangent := right.momentum_y if axis == 0 else right.momentum_x
	left_velocity := left_normal / max(left_depth, OCEAN_NEARSHORE_DRY_DEPTH)
	right_velocity := right_normal / max(right_depth, OCEAN_NEARSHORE_DRY_DEPTH)
	left_wave := math.sqrt(OCEAN_NEARSHORE_GRAVITY * left_depth)
	right_wave := math.sqrt(OCEAN_NEARSHORE_GRAVITY * right_depth)
	minimum_speed := min(left_velocity - left_wave, right_velocity - right_wave)
	maximum_speed := max(left_velocity + left_wave, right_velocity + right_wave)
	left_flux := Ocean_Nearshore_Cell {
		depth      = left_normal,
		momentum_x = left_normal *
			left_velocity + 0.5 * OCEAN_NEARSHORE_GRAVITY * left_depth * left_depth,
		momentum_y = left_tangent * left_velocity,
	}
	right_flux := Ocean_Nearshore_Cell {
		depth      = right_normal,
		momentum_x = right_normal *
			right_velocity + 0.5 * OCEAN_NEARSHORE_GRAVITY * right_depth * right_depth,
		momentum_y = right_tangent * right_velocity,
	}
	flux := left_flux
	if maximum_speed <= 0 {
		flux = right_flux
	} else if minimum_speed < 0 {
		inverse := 1 / max(maximum_speed - minimum_speed, f32(0.0001))
		flux.depth =
			(maximum_speed * left_flux.depth -
				minimum_speed * right_flux.depth +
				minimum_speed * maximum_speed * (right_depth - left_depth)) *
			inverse
		flux.momentum_x =
			(maximum_speed * left_flux.momentum_x -
				minimum_speed * right_flux.momentum_x +
				minimum_speed * maximum_speed * (right_normal - left_normal)) *
			inverse
		flux.momentum_y =
			(maximum_speed * left_flux.momentum_y -
				minimum_speed * right_flux.momentum_y +
				minimum_speed * maximum_speed * (right_tangent - left_tangent)) *
			inverse
	}
	if axis == 1 do flux.momentum_x, flux.momentum_y = flux.momentum_y, flux.momentum_x
	return flux
}

ocean_nearshore_mass :: proc(value: ^Ocean_Nearshore) -> f32 {
	mass := f32(0)
	for cell in value.state do mass += cell.depth
	return mass
}

ocean_nearshore_rebuild :: proc(value: ^Ocean_Nearshore, world: ^shared.World, focus: [3]f32) {
	assert(value != nil && world != nil, "ocean_nearshore_rebuild: nil input")
	length := math.sqrt(focus.x * focus.x + focus.y * focus.y + focus.z * focus.z)
	if length <= 0.0001 do return
	preserve := value.ready && value.waterfield_revision == world.waterfield.revision
	old_focus := value.focus
	old_east := value.east
	old_north := value.north
	if preserve {
		value.scratch = value.state
		value.still_scratch = value.still_depth
		value.foam_scratch = value.foam
	}
	value.focus = focus / length
	_, value.east, value.north = shared.planet_basis(value.focus)
	for row in 0 ..< OCEAN_NEARSHORE_EDGE {
		for column in 0 ..< OCEAN_NEARSHORE_EDGE {
			direction, _ := ocean_wave_normalize(ocean_nearshore_boundary_position(value, column, row))
			face, u, v := shared.planet_locate(direction)
			coord := shared.Planet_Coord{face, i32(u), i32(v)}
			ground := shared.terrain_height_at_coord(world, coord)
			depth := max(shared.waterfield_depth_at_coord(world, coord), f32(0))
			index := ocean_nearshore_index(column, row)
			value.state[index] = {
				depth = depth,
			}
			value.still_depth[index] = depth
			value.foam[index] = 0
			if preserve {
				dot := clamp(
					direction.x * old_focus.x +
					direction.y * old_focus.y +
					direction.z * old_focus.z,
					-1,
					1,
				)
				tangent := direction - old_focus * dot
				old_x_distance :=
					(tangent.x * old_east.x + tangent.y * old_east.y + tangent.z * old_east.z) *
					f32(shared.PLANET_RADIUS)
				old_y_distance :=
					(tangent.x * old_north.x + tangent.y * old_north.y + tangent.z * old_north.z) *
					f32(shared.PLANET_RADIUS)
				old_x :=
					(old_x_distance / (OCEAN_NEARSHORE_RADIUS * 2) + 0.5) *
					f32(OCEAN_NEARSHORE_CELLS)
				old_y :=
					(old_y_distance / (OCEAN_NEARSHORE_RADIUS * 2) + 0.5) *
					f32(OCEAN_NEARSHORE_CELLS)
				if old_x >= 0 &&
				   old_x <= f32(OCEAN_NEARSHORE_CELLS) &&
				   old_y >= 0 &&
				   old_y <= f32(OCEAN_NEARSHORE_CELLS) {
					old_depth := ocean_nearshore_cells_bilinear(&value.scratch, old_x, old_y, 0)
					old_still := ocean_nearshore_bilinear(&value.still_scratch, old_x, old_y)
					old_momentum_x := ocean_nearshore_cells_bilinear(
						&value.scratch,
						old_x,
						old_y,
						1,
					)
					old_momentum_y := ocean_nearshore_cells_bilinear(
						&value.scratch,
						old_x,
						old_y,
						2,
					)
					world_momentum := old_east * old_momentum_x + old_north * old_momentum_y
					value.state[index] = {
						depth      = max(depth + old_depth - old_still, f32(0)),
						momentum_x = world_momentum.x *
							value.east.x + world_momentum.y * value.east.y + world_momentum.z * value.east.z,
						momentum_y = world_momentum.x *
							value.north.x + world_momentum.y * value.north.y + world_momentum.z * value.north.z,
					}
					value.foam[index] = ocean_nearshore_bilinear(&value.foam_scratch, old_x, old_y)
				}
			}
			value.bathymetry[index] = ground
		}
	}
	value.waterfield_revision = world.waterfield.revision
	value.ready = true
}

ocean_nearshore_grid_position :: proc(
	value: ^Ocean_Nearshore,
	column, row, height: f32,
) -> [3]f32 {
	spacing := OCEAN_NEARSHORE_RADIUS * 2 / f32(OCEAN_NEARSHORE_CELLS)
	x := (column - f32(OCEAN_NEARSHORE_CELLS) * 0.5) * spacing
	y := (row - f32(OCEAN_NEARSHORE_CELLS) * 0.5) * spacing
	radius := f32(shared.PLANET_RADIUS)
	tangent := (value.east * x + value.north * y) / radius
	radial_scale := math.sqrt(max(1 - (x * x + y * y) / (radius * radius), f32(0)))
	direction := value.focus * radial_scale + tangent
	return shared.planet_position(direction, height)
}

ocean_nearshore_boundary_position :: proc(value: ^Ocean_Nearshore, column, row: int) -> [3]f32 {
	return ocean_nearshore_grid_position(value, f32(column), f32(row), 0)
}

ocean_nearshore_break_crossing :: proc(first, second, break_depth: f32) -> (f32, bool) {
	if first <= OCEAN_NEARSHORE_DRY_DEPTH || second <= OCEAN_NEARSHORE_DRY_DEPTH do return 0, false
	first_delta := first - break_depth
	second_delta := second - break_depth
	if first_delta == 0 do return 0, true
	if second_delta == 0 do return 1, true
	if first_delta * second_delta >= 0 do return 0, false
	return clamp(first_delta / (first_delta - second_delta), f32(0), f32(1)), true
}

ocean_nearshore_break_segments :: proc(
	value: ^Ocean_Nearshore,
	break_depth: f32,
	output: []Ocean_Nearshore_Break_Segment,
) -> int {
	assert(value != nil, "ocean nearshore break segments: nil solver")
	if !value.ready || break_depth <= OCEAN_NEARSHORE_DRY_DEPTH || len(output) == 0 do return 0
	spacing := OCEAN_NEARSHORE_RADIUS * 2 / f32(OCEAN_NEARSHORE_CELLS)
	count := 0
	for row in 0 ..< OCEAN_NEARSHORE_EDGE {
		for column in 0 ..< OCEAN_NEARSHORE_CELLS {
			first_index := ocean_nearshore_index(column, row)
			second_index := ocean_nearshore_index(column + 1, row)
			fraction, crosses := ocean_nearshore_break_crossing(
				value.still_depth[first_index],
				value.still_depth[second_index],
				break_depth,
			)
			if !crosses do continue
			bed :=
				value.bathymetry[first_index] * (1 - fraction) +
				value.bathymetry[second_index] * fraction
			foam := value.foam[first_index] * (1 - fraction) + value.foam[second_index] * fraction
			shallow_normal := value.east
			if value.still_depth[second_index] > value.still_depth[first_index] do shallow_normal = -value.east
			output[count] = {
				center         = ocean_nearshore_grid_position(
					value,
					f32(column) + fraction,
					f32(row),
					bed + break_depth,
				),
				tangent        = value.north,
				shallow_normal = shallow_normal,
				depth          = break_depth,
				bed_slope      = abs(
					value.still_depth[second_index] - value.still_depth[first_index],
				) / spacing,
				foam           = foam,
			}
			count += 1
			if count >= len(output) do return count
		}
	}
	for row in 0 ..< OCEAN_NEARSHORE_CELLS {
		for column in 0 ..< OCEAN_NEARSHORE_EDGE {
			first_index := ocean_nearshore_index(column, row)
			second_index := ocean_nearshore_index(column, row + 1)
			fraction, crosses := ocean_nearshore_break_crossing(
				value.still_depth[first_index],
				value.still_depth[second_index],
				break_depth,
			)
			if !crosses do continue
			bed :=
				value.bathymetry[first_index] * (1 - fraction) +
				value.bathymetry[second_index] * fraction
			foam := value.foam[first_index] * (1 - fraction) + value.foam[second_index] * fraction
			shallow_normal := value.north
			if value.still_depth[second_index] > value.still_depth[first_index] do shallow_normal = -value.north
			output[count] = {
				center         = ocean_nearshore_grid_position(
					value,
					f32(column),
					f32(row) + fraction,
					bed + break_depth,
				),
				tangent        = value.east,
				shallow_normal = shallow_normal,
				depth          = break_depth,
				bed_slope      = abs(
					value.still_depth[second_index] - value.still_depth[first_index],
				) / spacing,
				foam           = foam,
			}
			count += 1
			if count >= len(output) do return count
		}
	}
	return count
}

ocean_nearshore_boundary_force :: proc(
	value: ^Ocean_Nearshore,
	field: ^Ocean_Macro_Wave_Field,
	query: ^Ocean_Macro_Wave_Query,
	time: f32,
) {
	assert(
		value != nil && field != nil && query != nil,
		"ocean_nearshore_boundary_force: nil input",
	)
	boundary_query := query^
	if value.fixture_active {
		boundary_query.packet_count = 0
		for packet in query.packets[:query.packet_count] {
			if packet.id == OCEAN_DEBUG_TEST_PULSE_ID do continue
			boundary_query.packets[boundary_query.packet_count] = packet
			boundary_query.packet_count += 1
		}
	}
	for edge_index in 0 ..< OCEAN_NEARSHORE_EDGE {
		for boundary in 0 ..< 4 {
			column := edge_index
			row := 0
			if boundary == 1 do row = OCEAN_NEARSHORE_CELLS
			if boundary == 2 {
				column = 0
				row = edge_index
			}
			if boundary == 3 {
				column = OCEAN_NEARSHORE_CELLS
				row = edge_index
			}
			index := ocean_nearshore_index(column, row)
			position := ocean_nearshore_boundary_position(value, column, row)
			base_depth := value.still_depth[index]
			coverage := ocean_breaker_smoothstep(0.02, 0.4, base_depth)
			sample := ocean_macro_wave_sample(field, &boundary_query, position, base_depth, coverage, time)
			radial, ok := ocean_wave_normalize(position)
			if !ok do continue
			elevation :=
				sample.displacement.x * radial.x +
				sample.displacement.y * radial.y +
				sample.displacement.z * radial.z
			depth := max(base_depth + elevation, f32(0))
			value.last_boundary_mass += f64(depth) - f64(value.state[index].depth)
			value.state[index].depth = depth
			value.state[index].momentum_x =
				(sample.velocity.x * value.east.x +
					sample.velocity.y * value.east.y +
					sample.velocity.z * value.east.z) *
				depth
			value.state[index].momentum_y =
				(sample.velocity.x * value.north.x +
					sample.velocity.y * value.north.y +
					sample.velocity.z * value.north.z) *
				depth
		}
	}
}

ocean_nearshore_source_cells :: proc(value: ^Ocean_Nearshore, source: [3]f32, output: ^[36]int) -> int {
	assert(value != nil && output != nil)
	if !value.ready || !value.fixture_active do return 0
	for component in source {
		if math.is_nan(component) || math.is_inf(component, 0) do return 0
	}
	spacing := OCEAN_NEARSHORE_RADIUS * 2 / f32(OCEAN_NEARSHORE_CELLS)
	source_delta := source - value.focus * f32(shared.PLANET_RADIUS)
	source_column := (source_delta.x * value.east.x + source_delta.y * value.east.y + source_delta.z * value.east.z) / spacing + f32(OCEAN_NEARSHORE_CELLS) * 0.5
	source_row := (source_delta.x * value.north.x + source_delta.y * value.north.y + source_delta.z * value.north.z) / spacing + f32(OCEAN_NEARSHORE_CELLS) * 0.5
	if !(source_column >= 1 && source_column <= f32(OCEAN_NEARSHORE_CELLS - 1) && source_row >= 1 && source_row <= f32(OCEAN_NEARSHORE_CELLS - 1)) do return 0
	minimum_column := max(int(math.floor(source_column)) - 2, 1)
	maximum_column := min(int(math.ceil(source_column)) + 2, OCEAN_NEARSHORE_CELLS - 1)
	minimum_row := max(int(math.floor(source_row)) - 2, 1)
	maximum_row := min(int(math.ceil(source_row)) + 2, OCEAN_NEARSHORE_CELLS - 1)
	count := 0
	for row in minimum_row ..= maximum_row {
		for column in minimum_column ..= maximum_column {
			index := ocean_nearshore_index(column, row)
			if !(value.still_depth[index] > OCEAN_NEARSHORE_DRY_DEPTH && value.state[index].depth > OCEAN_NEARSHORE_DRY_DEPTH) do continue
			delta := ocean_nearshore_boundary_position(value, column, row) - source
			if delta.x * delta.x + delta.y * delta.y + delta.z * delta.z > spacing * spacing do continue
			output[count] = index
			count += 1
		}
	}
	return count
}

ocean_nearshore_debug_source_force :: proc(
	value: ^Ocean_Nearshore,
	field: ^Ocean_Macro_Wave_Field,
	query: ^Ocean_Macro_Wave_Query,
	sample_time: f32,
) {
	assert(value != nil && field != nil && query != nil)
	if !value.fixture_active || !value.ready do return
	source_cells: [36]int
	for packet in query.packets[:query.packet_count] {
		if packet.id != OCEAN_DEBUG_TEST_PULSE_ID || sample_time < packet.phase_epoch do continue
		if sample_time - packet.phase_epoch > packet.band * OCEAN_RING_ENVELOPE_SIGMAS / max(packet.front_speed, f32(0.001)) do continue
		source_query := Ocean_Macro_Wave_Query{packet_count = 1, ready = true}
		source_query.packets[0] = packet
		count := ocean_nearshore_source_cells(value, packet.center, &source_cells)
		for index in source_cells[:count] {
			position := ocean_nearshore_boundary_position(value, index % OCEAN_NEARSHORE_EDGE, index / OCEAN_NEARSHORE_EDGE)
			base_depth := value.still_depth[index]
			radial, valid := ocean_wave_normalize(position)
			if !valid do continue
			sample := ocean_macro_wave_sample(field, &source_query, position, base_depth, 1, sample_time)
			elevation := sample.displacement.x * radial.x + sample.displacement.y * radial.y + sample.displacement.z * radial.z
			depth := max(base_depth + elevation, f32(0))
			before := value.state[index]
			value.last_source_mass += f64(depth) - f64(before.depth)
			value.state[index] = {
				depth = depth,
				momentum_x = (sample.velocity.x * value.east.x + sample.velocity.y * value.east.y + sample.velocity.z * value.east.z) * depth,
				momentum_y = (sample.velocity.x * value.north.x + sample.velocity.y * value.north.y + sample.velocity.z * value.north.z) * depth,
			}
			after := value.state[index]
			value.last_source_momentum += [2]f64{f64(after.momentum_x) - f64(before.momentum_x), f64(after.momentum_y) - f64(before.momentum_y)}
			value.last_source_energy += ocean_nearshore_cell_energy(after, value.bathymetry[index]) - ocean_nearshore_cell_energy(before, value.bathymetry[index])
		}
	}
}

ocean_nearshore_cell_energy :: proc(cell: Ocean_Nearshore_Cell, bed: f32) -> f64 {
	depth := f64(cell.depth)
	if depth <= 0 do return 0
	momentum_x, momentum_y := f64(cell.momentum_x), f64(cell.momentum_y)
	return (momentum_x * momentum_x + momentum_y * momentum_y) / (2 * depth) + f64(OCEAN_NEARSHORE_GRAVITY) * depth * (depth * 0.5 + f64(bed))
}

ocean_nearshore_euler :: proc(value: ^Ocean_Nearshore, dt: f32) {
	spacing := OCEAN_NEARSHORE_RADIUS * 2 / f32(OCEAN_NEARSHORE_CELLS)
	inverse_spacing := 1 / spacing
	for row in 0 ..< OCEAN_NEARSHORE_EDGE {
		for column in 0 ..< OCEAN_NEARSHORE_CELLS {
			index := ocean_nearshore_index(column, row)
			right := ocean_nearshore_index(column + 1, row)
			value.flux_x[index] = ocean_nearshore_hll_flux(
				value.state[index],
				value.state[right],
				value.bathymetry[index],
				value.bathymetry[right],
				0,
			)
		}
	}
	for row in 0 ..< OCEAN_NEARSHORE_CELLS {
		for column in 0 ..< OCEAN_NEARSHORE_EDGE {
			index := ocean_nearshore_index(column, row)
			up := ocean_nearshore_index(column, row + 1)
			value.flux_y[index] = ocean_nearshore_hll_flux(
				value.state[index],
				value.state[up],
				value.bathymetry[index],
				value.bathymetry[up],
				1,
			)
		}
	}
	for edge in 1 ..< OCEAN_NEARSHORE_CELLS {
		value.last_boundary_mass += f64(dt * inverse_spacing) * (
			f64(value.flux_x[ocean_nearshore_index(0, edge)].depth) -
			f64(value.flux_x[ocean_nearshore_index(OCEAN_NEARSHORE_CELLS - 1, edge)].depth) +
			f64(value.flux_y[ocean_nearshore_index(edge, 0)].depth) -
			f64(value.flux_y[ocean_nearshore_index(edge, OCEAN_NEARSHORE_CELLS - 1)].depth))
	}
	for row in 1 ..< OCEAN_NEARSHORE_CELLS {
		for column in 1 ..< OCEAN_NEARSHORE_CELLS {
			index := ocean_nearshore_index(column, row)
			left := ocean_nearshore_index(column - 1, row)
			right := ocean_nearshore_index(column + 1, row)
			down := ocean_nearshore_index(column, row - 1)
			up := ocean_nearshore_index(column, row + 1)
			flux_left := value.flux_x[left]
			flux_right := value.flux_x[index]
			flux_down := value.flux_y[down]
			flux_up := value.flux_y[index]
			cell := value.state[index]
			left_depth := ocean_nearshore_reconstructed_depth(
				cell.depth,
				value.bathymetry[index],
				value.bathymetry[left],
			)
			right_depth := ocean_nearshore_reconstructed_depth(
				cell.depth,
				value.bathymetry[index],
				value.bathymetry[right],
			)
			down_depth := ocean_nearshore_reconstructed_depth(
				cell.depth,
				value.bathymetry[index],
				value.bathymetry[down],
			)
			up_depth := ocean_nearshore_reconstructed_depth(
				cell.depth,
				value.bathymetry[index],
				value.bathymetry[up],
			)
			flux_left.momentum_x +=
				0.5 * OCEAN_NEARSHORE_GRAVITY * (cell.depth * cell.depth - left_depth * left_depth)
			flux_right.momentum_x +=
				0.5 *
				OCEAN_NEARSHORE_GRAVITY *
				(cell.depth * cell.depth - right_depth * right_depth)
			flux_down.momentum_y +=
				0.5 * OCEAN_NEARSHORE_GRAVITY * (cell.depth * cell.depth - down_depth * down_depth)
			flux_up.momentum_y +=
				0.5 * OCEAN_NEARSHORE_GRAVITY * (cell.depth * cell.depth - up_depth * up_depth)
			cell.depth -=
				dt *
				inverse_spacing *
				(flux_right.depth - flux_left.depth + flux_up.depth - flux_down.depth)
			cell.momentum_x -=
				dt *
				inverse_spacing *
				(flux_right.momentum_x -
						flux_left.momentum_x +
						flux_up.momentum_x -
						flux_down.momentum_x)
			cell.momentum_y -=
				dt *
				inverse_spacing *
				(flux_right.momentum_y -
						flux_left.momentum_y +
						flux_up.momentum_y -
						flux_down.momentum_y)
			value.last_clamp_mass += f64(max(-cell.depth, f32(0)))
			cell.depth = max(cell.depth, f32(0))
			if cell.depth < OCEAN_NEARSHORE_DRY_DEPTH {
				cell.momentum_x = 0
				cell.momentum_y = 0
			} else {
				bottom_friction :=
					1 /
					(1 +
							dt *
								0.018 *
								math.sqrt(
									cell.momentum_x * cell.momentum_x +
									cell.momentum_y * cell.momentum_y,
								) /
								max(cell.depth * cell.depth, f32(0.0001)))
				settling := math.exp(-dt / OCEAN_NEARSHORE_MOMENTUM_SETTLE_S)
				cell.momentum_x *= bottom_friction * settling
				cell.momentum_y *= bottom_friction * settling
			}
			value.scratch[index] = cell
			velocity_left :=
				value.state[left].momentum_x /
				max(value.state[left].depth, OCEAN_NEARSHORE_DRY_DEPTH)
			velocity_right :=
				value.state[right].momentum_x /
				max(value.state[right].depth, OCEAN_NEARSHORE_DRY_DEPTH)
			velocity_down :=
				value.state[down].momentum_y /
				max(value.state[down].depth, OCEAN_NEARSHORE_DRY_DEPTH)
			velocity_up :=
				value.state[up].momentum_y / max(value.state[up].depth, OCEAN_NEARSHORE_DRY_DEPTH)
			convergence := max(
				(velocity_left - velocity_right + velocity_down - velocity_up) *
				0.5 *
				inverse_spacing,
				f32(0),
			)
			shallow_break := 1 - ocean_breaker_smoothstep(0.12, 1.2, cell.depth)
			value.foam[index] = clamp(
				max(value.foam[index] * math.exp(-dt * 0.75), convergence * shallow_break),
				f32(0),
				f32(1),
			)
		}
	}
	for row in 1 ..< OCEAN_NEARSHORE_CELLS {
		for column in 1 ..< OCEAN_NEARSHORE_CELLS {
			index := ocean_nearshore_index(column, row)
			value.state[index] = value.scratch[index]
		}
	}
}

ocean_nearshore_fixed_step :: proc(
	value: ^Ocean_Nearshore,
	world: ^shared.World,
	focus: [3]f32,
	field: ^Ocean_Macro_Wave_Field,
	query: ^Ocean_Macro_Wave_Query,
	dt: f32,
) {
	assert(
		value != nil && world != nil && field != nil && query != nil,
		"ocean_nearshore_fixed_step: nil input",
	)
	if dt < 0 || (dt == 0 && (!value.fixture_active || value.time_backlog <= 0)) do return
	normalized, ok := ocean_wave_normalize(focus)
	if !ok do return
	moved :=
		math.sqrt(
			(normalized.x - value.focus.x) * (normalized.x - value.focus.x) +
			(normalized.y - value.focus.y) * (normalized.y - value.focus.y) +
			(normalized.z - value.focus.z) * (normalized.z - value.focus.z),
		) *
		f32(shared.PLANET_RADIUS)
	if !value.fixture_active && (!value.ready || value.waterfield_revision != world.waterfield.revision || moved > 1.875) {
		ocean_nearshore_rebuild(value, world, normalized)
	}
	before := f64(0)
	for cell in value.state do before += f64(cell.depth)
	value.last_boundary_mass = 0
	value.last_source_mass = 0
	value.last_source_momentum = {}
	value.last_source_energy = 0
	value.last_clamp_mass = 0
	requested := dt + value.time_backlog
	remaining := min(requested, f32(0.5))
	value.dropped_time += requested - remaining
	accepted := remaining
	value.last_substeps = 0
	spacing := OCEAN_NEARSHORE_RADIUS * 2 / f32(OCEAN_NEARSHORE_CELLS)
	for remaining > 0 && value.last_substeps < OCEAN_NEARSHORE_MAX_SUBSTEPS {
		ocean_nearshore_boundary_force(value, field, query, field.time - remaining)
		ocean_nearshore_debug_source_force(value, field, query, field.time - remaining)
		maximum_speed := f32(0.1)
		for cell in value.state {
			if cell.depth < OCEAN_NEARSHORE_DRY_DEPTH do continue
			velocity :=
				math.sqrt(cell.momentum_x * cell.momentum_x + cell.momentum_y * cell.momentum_y) /
				cell.depth
			maximum_speed = max(
				maximum_speed,
				velocity + math.sqrt(OCEAN_NEARSHORE_GRAVITY * cell.depth),
			)
		}
		sub_dt := min(remaining, OCEAN_NEARSHORE_CFL * spacing / maximum_speed)
		ocean_nearshore_euler(value, sub_dt)
		remaining -= sub_dt
		value.last_substeps += 1
	}
	value.time_backlog = remaining
	value.last_advanced_time = accepted - remaining
	after := f64(0)
	for cell in value.state do after += f64(cell.depth)
	value.last_mass_error = after - before - value.last_boundary_mass - value.last_source_mass - value.last_clamp_mass
}

ocean_nearshore_bilinear :: proc(values: ^[OCEAN_NEARSHORE_COUNT]f32, x, y: f32) -> f32 {
	column0 := clamp(int(math.floor(x)), 0, OCEAN_NEARSHORE_CELLS)
	row0 := clamp(int(math.floor(y)), 0, OCEAN_NEARSHORE_CELLS)
	column1 := min(column0 + 1, OCEAN_NEARSHORE_CELLS)
	row1 := min(row0 + 1, OCEAN_NEARSHORE_CELLS)
	fx := clamp(x - f32(column0), f32(0), f32(1))
	fy := clamp(y - f32(row0), f32(0), f32(1))
	low :=
		values[ocean_nearshore_index(column0, row0)] * (1 - fx) +
		values[ocean_nearshore_index(column1, row0)] * fx
	high :=
		values[ocean_nearshore_index(column0, row1)] * (1 - fx) +
		values[ocean_nearshore_index(column1, row1)] * fx
	return low * (1 - fy) + high * fy
}

ocean_nearshore_cells_bilinear :: proc(
	cells: ^[OCEAN_NEARSHORE_COUNT]Ocean_Nearshore_Cell,
	x, y: f32,
	component: int,
) -> f32 {
	column0 := clamp(int(math.floor(x)), 0, OCEAN_NEARSHORE_CELLS)
	row0 := clamp(int(math.floor(y)), 0, OCEAN_NEARSHORE_CELLS)
	column1 := min(column0 + 1, OCEAN_NEARSHORE_CELLS)
	row1 := min(row0 + 1, OCEAN_NEARSHORE_CELLS)
	fx := clamp(x - f32(column0), f32(0), f32(1))
	fy := clamp(y - f32(row0), f32(0), f32(1))
	cell00 := cells[ocean_nearshore_index(column0, row0)]
	cell10 := cells[ocean_nearshore_index(column1, row0)]
	cell01 := cells[ocean_nearshore_index(column0, row1)]
	cell11 := cells[ocean_nearshore_index(column1, row1)]
	values00 := [3]f32{cell00.depth, cell00.momentum_x, cell00.momentum_y}
	values10 := [3]f32{cell10.depth, cell10.momentum_x, cell10.momentum_y}
	values01 := [3]f32{cell01.depth, cell01.momentum_x, cell01.momentum_y}
	values11 := [3]f32{cell11.depth, cell11.momentum_x, cell11.momentum_y}
	low := values00[component] * (1 - fx) + values10[component] * fx
	high := values01[component] * (1 - fx) + values11[component] * fx
	return low * (1 - fy) + high * fy
}

ocean_nearshore_state_bilinear :: proc(value: ^Ocean_Nearshore, x, y: f32, component: int) -> f32 {
	return ocean_nearshore_cells_bilinear(&value.state, x, y, component)
}

ocean_nearshore_surface_sample :: proc(
	value: ^Ocean_Nearshore,
	position: [3]f32,
) -> (
	Ocean_Nearshore_Surface_Sample,
	bool,
) {
	assert(value != nil, "ocean_nearshore_surface_sample: nil solver")
	if !value.ready do return {}, false
	direction, ok := ocean_wave_normalize(position)
	if !ok do return {}, false
	dot := clamp(
		direction.x * value.focus.x + direction.y * value.focus.y + direction.z * value.focus.z,
		-1,
		1,
	)
	angle := math.acos(dot)
	if value.fixture_active {
		if dot <= 0 do return {}, false
	} else if angle * f32(shared.PLANET_RADIUS) > OCEAN_NEARSHORE_RADIUS {
		return {}, false
	}
	tangent := direction - value.focus * dot
	x_distance :=
		(tangent.x * value.east.x + tangent.y * value.east.y + tangent.z * value.east.z) *
		f32(shared.PLANET_RADIUS)
	y_distance :=
		(tangent.x * value.north.x + tangent.y * value.north.y + tangent.z * value.north.z) *
		f32(shared.PLANET_RADIUS)
	x := (x_distance / (OCEAN_NEARSHORE_RADIUS * 2) + 0.5) * f32(OCEAN_NEARSHORE_CELLS)
	y := (y_distance / (OCEAN_NEARSHORE_RADIUS * 2) + 0.5) * f32(OCEAN_NEARSHORE_CELLS)
	if x < 0 || y < 0 || x > f32(OCEAN_NEARSHORE_CELLS) || y > f32(OCEAN_NEARSHORE_CELLS) do return {}, false
	depth := ocean_nearshore_state_bilinear(value, x, y, 0)
	if depth < OCEAN_NEARSHORE_DRY_DEPTH {
		edge_distance := min(min(x, y), min(f32(OCEAN_NEARSHORE_CELLS) - x, f32(OCEAN_NEARSHORE_CELLS) - y))
		return {depth = depth, blend = ocean_breaker_smoothstep(0, 2, edge_distance)}, false
	}
	bed := ocean_nearshore_bilinear(&value.bathymetry, x, y)
	elevation := depth + bed
	spacing := OCEAN_NEARSHORE_RADIUS * 2 / f32(OCEAN_NEARSHORE_CELLS)
	elevation_left :=
		ocean_nearshore_state_bilinear(value, x - 1, y, 0) +
		ocean_nearshore_bilinear(&value.bathymetry, x - 1, y)
	elevation_right :=
		ocean_nearshore_state_bilinear(value, x + 1, y, 0) +
		ocean_nearshore_bilinear(&value.bathymetry, x + 1, y)
	elevation_down :=
		ocean_nearshore_state_bilinear(value, x, y - 1, 0) +
		ocean_nearshore_bilinear(&value.bathymetry, x, y - 1)
	elevation_up :=
		ocean_nearshore_state_bilinear(value, x, y + 1, 0) +
		ocean_nearshore_bilinear(&value.bathymetry, x, y + 1)
	slope_x := (elevation_right - elevation_left) / (2 * spacing)
	slope_y := (elevation_up - elevation_down) / (2 * spacing)
	normal, _ := ocean_wave_normalize(direction - value.east * slope_x - value.north * slope_y)
	velocity_x := ocean_nearshore_state_bilinear(value, x, y, 1) / depth
	velocity_y := ocean_nearshore_state_bilinear(value, x, y, 2) / depth
	edge_distance := min(
		min(x, y),
		min(f32(OCEAN_NEARSHORE_CELLS) - x, f32(OCEAN_NEARSHORE_CELLS) - y),
	)
	blend := ocean_breaker_smoothstep(0, 2, edge_distance)
	return {
			displacement = direction * elevation,
			normal = normal,
			velocity = value.east * velocity_x + value.north * velocity_y,
			depth = depth,
			foam = ocean_nearshore_bilinear(&value.foam, x, y),
			blend = blend,
		},
		true
}

ocean_nearshore_deinit :: proc(value: ^Ocean_Nearshore) {
	assert(value != nil, "ocean_nearshore_deinit: nil solver")
	value^ = {}
}
