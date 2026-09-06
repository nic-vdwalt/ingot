package shared

import "core:math"

WAVE_DIRECTION_SCALE :: i32(1_000_000)
WAVE_MAX_VARIANCE :: u64(25_000_000)
WAVE_MAX_HEIGHT_MM :: u32(20_000)
WAVE_STORM_SOURCE_MAX :: 256
WAVE_SWELL_PACKET_MAX :: 128
WAVE_RING_SECTOR_COUNT :: 64
WAVE_RING_BAND_SIGMAS :: f32(2)
WAVE_RING_MIN_CELL_VARIANCE :: u64(16)
WAVE_RING_BLOCK_CELLS :: 8
WAVE_RING_BLOCKS_PER_FACE :: PLANET_SIM_FACE_CELLS / WAVE_RING_BLOCK_CELLS
WAVE_RING_BLOCK_COUNT ::
	PLANET_SIM_FACE_COUNT * WAVE_RING_BLOCKS_PER_FACE * WAVE_RING_BLOCKS_PER_FACE
WAVE_RING_MERGE_RADIUS_BANDS :: u64(4)
WAVE_RING_MAX_ANGLE_MILLI :: u64(3_079)
WAVE_RING_ALL_SECTORS :: max(u64)
#assert(PLANET_SIM_FACE_CELLS % WAVE_RING_BLOCK_CELLS == 0)
#assert(WAVE_RING_SECTOR_COUNT == 64)
WAVE_PACKET_EMISSION_INTERVAL_S :: u32(7_200)
WAVE_PACKET_MAX_AGE_S :: u32(30 * 24 * 60 * 60)
WAVE_STORM_SOURCE_MIN_DEPTH_MM :: u32(100_000)
WAVE_BREAK_DEPTH_RATIO_MILLI :: u64(780)
WAVE_SHOAL_SCALE :: u32(1_000)
WAVE_SHOAL_MAX :: u32(2_400)

Wave_Breaker_Type :: enum u8 {
	None,
	Spilling,
	Plunging,
	Surging,
}

Wave_Storm_Source :: struct {
	active:               bool,
	seen:                 bool,
	id:                   u32,
	cell:                 u32,
	direction_east:       i32,
	direction_north:      i32,
	period_ms:            u32,
	accumulated_variance: u64,
	age_s:                u32,
	emission_elapsed_s:   u32,
}

Wave_Swell_Packet :: struct {
	active:           bool,
	id:               u32,
	source_id:        u32,
	source_cell:      u32,
	period_ms:        u32,
	action:           u64,
	age_s:            u32,
	radius_mm:        u64,
	band_mm:          u64,
	group_speed_mm_s: u32,
	phase_epoch_ms:   u64,
	blocked_sectors:  u64,
	breaking:         u32,
	breaker_type:     Wave_Breaker_Type,
}

Wave_Packet_Body_State :: struct {
	id:                 u32,
	cell:               u32,
	radial:             bool,
	center_direction:   [3]f32,
	travel_direction:   [3]f32,
	period_ms:          u32,
	action:             u64,
	age_s:              u32,
	radius_mm:          u64,
	band_mm:            u64,
	total_travel_mm:    u64,
	envelope_length_mm: u64,
	envelope_width_mm:  u64,
	phase_epoch_ms:     u64,
	simulation_time_ms: u64,
	breaking:           u32,
	breaker_type:       Wave_Breaker_Type,
	depth_mm:           u32,
	phase_speed_mm_s:   u32,
	group_speed_mm_s:   u32,
}

Wave_State :: struct {
	wind_sea_variance:        []u64,
	wind_sea_period_ms:       []u32,
	wind_sea_direction_east:  []i32,
	wind_sea_direction_north: []i32,
	fetch_m:                  []u32,
	swell_variance:           []u64,
	swell_period_ms:          []u32,
	swell_direction_east:     []i32,
	swell_direction_north:    []i32,
	sources:                  [WAVE_STORM_SOURCE_MAX]Wave_Storm_Source,
	packets:                  [WAVE_SWELL_PACKET_MAX]Wave_Swell_Packet,
	source_count:             u16,
	packet_count:             u16,
	next_source_id:           u32,
	next_packet_id:           u32,
	merged_packets:           u32,
	dropped_packets:          u32,
	simulation_time_ms:       u64,
	height_mm:                []u32,
	period_ms:                []u32,
	direction_east:           []i32,
	direction_north:          []i32,
	breaking:                 []u32,
	breaker_type:             []Wave_Breaker_Type,
	runup_mm:                 []u32,
	phase_speed_mm_s:         []u32,
	group_speed_mm_s:         []u32,
	shoal_gain:               []u32,
	depth_gradient_east:      []i32,
	depth_gradient_north:     []i32,
	// Derived-field cache keys: the gradients are pure functions of the
	// bathymetry (tracked by ocean.bathymetry_revision) and the dispersion
	// speeds / shoal gain of (depth, period) per cell. Zero means "never
	// derived", which no valid period (>= 4 s) can collide with.
	bathymetry_revision:      u64,
	dispersion_period_ms:     []u32,
	period_scratch:           []u64,
	direction_east_scratch:   []i64,
	direction_north_scratch:  []i64,
	cell_direction:           [][3]f32,
	cell_east:                [][3]f32,
	cell_north:               [][3]f32,
	block_direction:          [][3]f32,
	block_radius:             []f32,
	ring_cells:               []u32,
	ring_weights:             []f32,
}

waves_init :: proc(state: ^Wave_State, allocator := context.allocator) {
	assert(state != nil, "waves_init: nil state")
	state^ = {}
	state.wind_sea_variance = make([]u64, PLANET_SIM_CELL_COUNT, allocator)
	state.wind_sea_period_ms = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.wind_sea_direction_east = make([]i32, PLANET_SIM_CELL_COUNT, allocator)
	state.wind_sea_direction_north = make([]i32, PLANET_SIM_CELL_COUNT, allocator)
	state.fetch_m = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.swell_variance = make([]u64, PLANET_SIM_CELL_COUNT, allocator)
	state.swell_period_ms = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.swell_direction_east = make([]i32, PLANET_SIM_CELL_COUNT, allocator)
	state.swell_direction_north = make([]i32, PLANET_SIM_CELL_COUNT, allocator)
	state.next_source_id = 1
	state.next_packet_id = 1
	state.height_mm = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.period_ms = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.direction_east = make([]i32, PLANET_SIM_CELL_COUNT, allocator)
	state.direction_north = make([]i32, PLANET_SIM_CELL_COUNT, allocator)
	state.breaking = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.breaker_type = make([]Wave_Breaker_Type, PLANET_SIM_CELL_COUNT, allocator)
	state.runup_mm = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.phase_speed_mm_s = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.group_speed_mm_s = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.shoal_gain = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.depth_gradient_east = make([]i32, PLANET_SIM_CELL_COUNT, allocator)
	state.depth_gradient_north = make([]i32, PLANET_SIM_CELL_COUNT, allocator)
	state.dispersion_period_ms = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.period_scratch = make([]u64, PLANET_SIM_CELL_COUNT, allocator)
	state.direction_east_scratch = make([]i64, PLANET_SIM_CELL_COUNT, allocator)
	state.direction_north_scratch = make([]i64, PLANET_SIM_CELL_COUNT, allocator)
	state.cell_direction = make([][3]f32, PLANET_SIM_CELL_COUNT, allocator)
	state.cell_east = make([][3]f32, PLANET_SIM_CELL_COUNT, allocator)
	state.cell_north = make([][3]f32, PLANET_SIM_CELL_COUNT, allocator)
	state.block_direction = make([][3]f32, WAVE_RING_BLOCK_COUNT, allocator)
	state.block_radius = make([]f32, WAVE_RING_BLOCK_COUNT, allocator)
	state.ring_cells = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.ring_weights = make([]f32, PLANET_SIM_CELL_COUNT, allocator)
	waves_build_cell_caches(state)
}

waves_build_cell_caches :: proc(state: ^Wave_State) {
	assert(state != nil, "waves_build_cell_caches: nil state")
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		direction := planet_sim_direction(planet_sim_coord_for_index(index))
		_, east, north := planet_basis(direction)
		state.cell_direction[index] = direction
		state.cell_east[index] = east
		state.cell_north[index] = north
	}
	for block in 0 ..< WAVE_RING_BLOCK_COUNT {
		sum: [3]f32
		first, stride := wave_ring_block_cells(block)
		for v in 0 ..< WAVE_RING_BLOCK_CELLS {
			for u in 0 ..< WAVE_RING_BLOCK_CELLS {
				sum += state.cell_direction[first + v * stride + u]
			}
		}
		center, ok := wave_normalize(sum)
		if !ok do center = state.cell_direction[first]
		radius := f32(0)
		for v in 0 ..< WAVE_RING_BLOCK_CELLS {
			for u in 0 ..< WAVE_RING_BLOCK_CELLS {
				radius = max(
					radius,
					wave_angle_between(center, state.cell_direction[first + v * stride + u]),
				)
			}
		}
		state.block_direction[block] = center
		state.block_radius[block] = radius
	}
}

wave_ring_block_cells :: proc(block: int) -> (first, stride: int) {
	assert(block >= 0 && block < WAVE_RING_BLOCK_COUNT, "wave_ring_block_cells: block")
	blocks_per_face := WAVE_RING_BLOCKS_PER_FACE * WAVE_RING_BLOCKS_PER_FACE
	face := block / blocks_per_face
	local := block % blocks_per_face
	block_v := local / WAVE_RING_BLOCKS_PER_FACE
	block_u := local % WAVE_RING_BLOCKS_PER_FACE
	first =
		face * PLANET_SIM_FACE_CELLS * PLANET_SIM_FACE_CELLS +
		block_v * WAVE_RING_BLOCK_CELLS * PLANET_SIM_FACE_CELLS +
		block_u * WAVE_RING_BLOCK_CELLS
	return first, PLANET_SIM_FACE_CELLS
}

wave_normalize :: proc(value: [3]f32) -> ([3]f32, bool) {
	length := math.sqrt(value.x * value.x + value.y * value.y + value.z * value.z)
	if length <= 0.0001 do return {}, false
	return value / length, true
}

wave_angle_between :: proc(a, b: [3]f32) -> f32 {
	delta := a - b
	chord := math.sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
	return 2 * math.asin(clamp(chord * 0.5, f32(0), f32(1)))
}

wave_cell_frame :: proc(state: ^Wave_State, cell: int) -> (direction, east, north: [3]f32) {
	assert(state != nil, "wave_cell_frame: nil state")
	assert(cell >= 0 && cell < PLANET_SIM_CELL_COUNT, "wave_cell_frame: cell")
	if len(state.cell_direction) == PLANET_SIM_CELL_COUNT {
		return state.cell_direction[cell], state.cell_east[cell], state.cell_north[cell]
	}
	direction = planet_sim_direction(planet_sim_coord_for_index(cell))
	_, east, north = planet_basis(direction)
	return
}

waves_deinit :: proc(state: ^Wave_State, allocator := context.allocator) {
	assert(state != nil, "waves_deinit: nil state")
	delete(state.ring_weights, allocator)
	delete(state.ring_cells, allocator)
	delete(state.block_radius, allocator)
	delete(state.block_direction, allocator)
	delete(state.cell_north, allocator)
	delete(state.cell_east, allocator)
	delete(state.cell_direction, allocator)
	delete(state.direction_north_scratch, allocator)
	delete(state.direction_east_scratch, allocator)
	delete(state.period_scratch, allocator)
	delete(state.dispersion_period_ms, allocator)
	delete(state.depth_gradient_north, allocator)
	delete(state.depth_gradient_east, allocator)
	delete(state.shoal_gain, allocator)
	delete(state.group_speed_mm_s, allocator)
	delete(state.phase_speed_mm_s, allocator)
	delete(state.runup_mm, allocator)
	delete(state.breaker_type, allocator)
	delete(state.breaking, allocator)
	delete(state.direction_north, allocator)
	delete(state.direction_east, allocator)
	delete(state.period_ms, allocator)
	delete(state.height_mm, allocator)
	delete(state.swell_direction_north, allocator)
	delete(state.swell_direction_east, allocator)
	delete(state.swell_period_ms, allocator)
	delete(state.swell_variance, allocator)
	delete(state.fetch_m, allocator)
	delete(state.wind_sea_direction_north, allocator)
	delete(state.wind_sea_direction_east, allocator)
	delete(state.wind_sea_period_ms, allocator)
	delete(state.wind_sea_variance, allocator)
	state^ = {}
}

waves_wind_sea_step :: proc(planet: ^Planetary_State) {
	assert(planet != nil, "waves_wind_sea_step: nil planet")
	state := &planet.waves
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		if planet.ocean.mean_depth_mm[index] == 0 {
			state.wind_sea_variance[index] = 0
			state.fetch_m[index] = 0
			continue
		}
		wind_east := i64(planet.climate.wind_east[index])
		wind_north := i64(planet.climate.wind_north[index])
		wind_speed := integer_sqrt(u64(wind_east * wind_east + wind_north * wind_north))
		direction_east, direction_north := planet_vector_normalize(wind_east, wind_north)
		if wind_speed > 0 {
			alignment :=
				(i64(state.wind_sea_direction_east[index]) * i64(direction_east) +
					i64(state.wind_sea_direction_north[index]) * i64(direction_north)) /
				i64(WAVE_DIRECTION_SCALE)
			if alignment < i64(WAVE_DIRECTION_SCALE / 2) do state.fetch_m[index] = 0
			downwind_edge := planet_sim_forward_edge(
				&planet.grid,
				index,
				direction_east,
				direction_north,
			)
			state.fetch_m[index] = u32(
				min(
					u64(state.fetch_m[index]) +
					u64(planet.grid.edge_length_m[index][downwind_edge]),
					u64(2_000_000),
				),
			)
		}
		fetch_factor := max(u64(state.fetch_m[index]) / 10_000, u64(1))
		target_variance := min(wind_speed * wind_speed * fetch_factor / 64, WAVE_MAX_VARIANCE)
		state.wind_sea_variance[index] =
			(state.wind_sea_variance[index] * 31 + target_variance) / 32
		ice_cover := u32(0)
		if len(planet.climate.sea_ice) == PLANET_SIM_CELL_COUNT {
			ice_cover = planet.climate.sea_ice[index]
		}
		state.wind_sea_variance[index] = sea_ice_damp_wave_variance(
			state.wind_sea_variance[index],
			ice_cover,
		)
		state.wind_sea_period_ms[index] = u32(
			clamp(
				i64(2_000 + integer_sqrt(state.wind_sea_variance[index]) * 5),
				i64(2_000),
				i64(20_000),
			),
		)
		if wind_speed > 0 {
			state.wind_sea_direction_east[index] = i32(
				(i64(state.wind_sea_direction_east[index]) * 7 + i64(direction_east)) / 8,
			)
			state.wind_sea_direction_north[index] = i32(
				(i64(state.wind_sea_direction_north[index]) * 7 + i64(direction_north)) / 8,
			)
		}
	}
}

wave_source_find :: proc(state: ^Wave_State, cell: u32) -> int {
	for &source, index in state.sources {
		if source.active && source.cell == cell do return index
	}
	return -1
}

wave_source_allocate :: proc(state: ^Wave_State) -> int {
	for &source, index in state.sources {
		if !source.active do return index
	}
	oldest := 0
	for index in 1 ..< WAVE_STORM_SOURCE_MAX {
		if state.sources[index].age_s > state.sources[oldest].age_s do oldest = index
	}
	return oldest
}

waves_detect_storm_sources :: proc(planet: ^Planetary_State) {
	assert(planet != nil, "waves_detect_storm_sources: nil planet")
	state := &planet.waves
	elapsed := u32(PLANET_SIM_SECONDS_PER_TICK * PLANET_WAVE_CADENCE_TICKS)
	for &source in state.sources do source.seen = false
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		if planet.ocean.mean_depth_mm[index] < WAVE_STORM_SOURCE_MIN_DEPTH_MM do continue
		offshore := true
		for neighbour in planet.grid.neighbours[index] {
			if planet.ocean.mean_depth_mm[neighbour] < WAVE_STORM_SOURCE_MIN_DEPTH_MM {
				offshore = false
				break
			}
		}
		if !offshore do continue
		east := i64(planet.climate.wind_east[index])
		north := i64(planet.climate.wind_north[index])
		wind_speed := integer_sqrt(u64(east * east + north * north))
		if wind_speed < u64(8 * PLANET_VELOCITY_SCALE) do continue
		local_maximum := true
		for neighbour_value in planet.grid.neighbours[index] {
			neighbour := int(neighbour_value)
			neighbour_east := i64(planet.climate.wind_east[neighbour])
			neighbour_north := i64(planet.climate.wind_north[neighbour])
			neighbour_speed := integer_sqrt(
				u64(neighbour_east * neighbour_east + neighbour_north * neighbour_north),
			)
			if neighbour_speed > wind_speed || neighbour_speed == wind_speed && neighbour < index {
				local_maximum = false
				break
			}
		}
		if !local_maximum do continue
		slot := wave_source_find(state, u32(index))
		if slot < 0 {
			slot = wave_source_allocate(state)
			if !state.sources[slot].active do state.source_count += 1
			state.sources[slot] = {
				active = true,
				id     = state.next_source_id,
				cell   = u32(index),
			}
			state.next_source_id += 1
		}
		source := &state.sources[slot]
		source.seen = true
		source.direction_east, source.direction_north = planet_vector_normalize(east, north)
		source.period_ms = max(state.wind_sea_period_ms[index], u32(4_000))
		source.accumulated_variance = min(
			source.accumulated_variance + state.wind_sea_variance[index] / 32,
			WAVE_MAX_VARIANCE,
		)
		source.age_s = min(source.age_s + elapsed, WAVE_PACKET_MAX_AGE_S)
		source.emission_elapsed_s += elapsed
	}
	for &source in state.sources {
		if !source.active || source.seen do continue
		if source.age_s > elapsed do source.age_s -= elapsed
		else {
			source = {}
			state.source_count -= 1
		}
	}
}

wave_packet_allocate :: proc(
	state: ^Wave_State,
	source_id, source_cell: u32,
	period_ms: u32,
) -> int {
	assert(state != nil, "wave_packet_allocate: nil state")
	for &packet, index in state.packets {
		if !packet.active do continue
		if packet.source_id == source_id &&
		   packet.source_cell == source_cell &&
		   abs(i64(packet.period_ms) - i64(period_ms)) < 500 &&
		   packet.radius_mm < packet.band_mm * WAVE_RING_MERGE_RADIUS_BANDS {
			state.merged_packets += 1
			return index
		}
	}
	for &packet, index in state.packets {
		if !packet.active do return index
	}
	weakest := 0
	weakest_score := max(u64)
	for index in 0 ..< WAVE_SWELL_PACKET_MAX {
		packet := &state.packets[index]
		score := packet.action * 1_000_000 / max(packet.radius_mm + packet.band_mm, u64(1))
		if score < weakest_score ||
		   score == weakest_score && packet.age_s > state.packets[weakest].age_s {
			weakest = index
			weakest_score = score
		}
	}
	state.dropped_packets += 1
	return weakest
}

// The geometric span of a cell measured from the cached directions, so the
// ring band and annulus area follow the real cube-sphere spacing rather than
// the grid's nominal edge length.
wave_cell_span_mm :: proc(planet: ^Planetary_State, cell: u32) -> u64 {
	assert(planet != nil, "wave_cell_span_mm: nil planet")
	assert(int(cell) < PLANET_SIM_CELL_COUNT, "wave_cell_span_mm: cell")
	direction, _, _ := wave_cell_frame(&planet.waves, int(cell))
	span := f32(0)
	for edge in 0 ..< PLANET_SIM_EDGE_COUNT {
		neighbour, _, _ := wave_cell_frame(&planet.waves, int(planet.grid.neighbours[cell][edge]))
		span += wave_angle_between(direction, neighbour)
	}
	span /= f32(PLANET_SIM_EDGE_COUNT)
	return max(u64(f64(span) * f64(planet.physical.radius_m) * 1_000), u64(1))
}

wave_ring_band_mm :: proc(planet: ^Planetary_State, source_cell: u32, period_ms: u32) -> u64 {
	assert(planet != nil, "wave_ring_band_mm: nil planet")
	return max(
		wave_deep_water_wavelength_mm(period_ms) * 8,
		wave_cell_span_mm(planet, source_cell),
	)
}

waves_emit_swell_packets :: proc(planet: ^Planetary_State) {
	assert(planet != nil, "waves_emit_swell_packets: nil planet")
	state := &planet.waves
	for &source in state.sources {
		if !source.active ||
		   source.age_s < WAVE_PACKET_EMISSION_INTERVAL_S ||
		   source.emission_elapsed_s < WAVE_PACKET_EMISSION_INTERVAL_S ||
		   source.accumulated_variance < 1_024 {
			continue
		}
		action := max(source.accumulated_variance, u64(1))
		slot := wave_packet_allocate(state, source.id, source.cell, source.period_ms)
		packet := &state.packets[slot]
		if packet.active && packet.source_id == source.id && packet.source_cell == source.cell {
			packet.action = min(packet.action + action, WAVE_MAX_VARIANCE)
		} else {
			if !packet.active do state.packet_count += 1
			_, group := wave_dispersion_speed_mm_s(
				planet.physical.gravity_milli_m_s2,
				planet.ocean.mean_depth_mm[source.cell],
				source.period_ms,
			)
			packet^ = {
				active           = true,
				id               = state.next_packet_id,
				source_id        = source.id,
				source_cell      = source.cell,
				period_ms        = source.period_ms,
				action           = action,
				band_mm          = wave_ring_band_mm(planet, source.cell, source.period_ms),
				group_speed_mm_s = max(group, u32(1)),
				phase_epoch_ms   = state.simulation_time_ms,
			}
			state.next_packet_id += 1
		}
		source.accumulated_variance /= 2
		source.emission_elapsed_s = 0
	}
}

wave_packet_deactivate :: proc(state: ^Wave_State, packet: ^Wave_Swell_Packet) {
	assert(state != nil && packet != nil, "wave_packet_deactivate: nil input")
	if !packet.active do return
	packet^ = {}
	state.packet_count -= 1
}

wave_ring_point :: proc(direction, east, north: [3]f32, azimuth, angle: f32) -> [3]f32 {
	outward := east * math.cos(azimuth) + north * math.sin(azimuth)
	return direction * math.cos(angle) + outward * math.sin(angle)
}

wave_ring_sector_azimuth :: proc(sector: int) -> f32 {
	assert(sector >= 0 && sector < WAVE_RING_SECTOR_COUNT, "wave_ring_sector_azimuth: sector")
	return (f32(sector) + 0.5) * f32(math.TAU) / f32(WAVE_RING_SECTOR_COUNT) - f32(math.PI)
}

wave_ring_sector_for :: proc(source, east, north, cell: [3]f32) -> int {
	azimuth := math.atan2(
		cell.x * north.x + cell.y * north.y + cell.z * north.z,
		cell.x * east.x + cell.y * east.y + cell.z * east.z,
	)
	sector := int(
		math.floor((azimuth + f32(math.PI)) / f32(math.TAU) * f32(WAVE_RING_SECTOR_COUNT)),
	)
	return clamp(sector, 0, WAVE_RING_SECTOR_COUNT - 1)
}

wave_ring_angle :: proc(planet: ^Planetary_State, distance_mm: u64) -> f32 {
	assert(planet != nil, "wave_ring_angle: nil planet")
	return f32(f64(distance_mm) / (f64(planet.physical.radius_m) * 1_000))
}

wave_ring_annulus_cells :: proc(planet: ^Planetary_State, packet: ^Wave_Swell_Packet) -> u64 {
	assert(planet != nil && packet != nil, "wave_ring_annulus_cells: nil input")
	radius_m := f64(planet.physical.radius_m)
	sigma := f64(packet.band_mm) / 1_000
	small_circle := radius_m * math.sin(f64(packet.radius_mm) / 1_000 / radius_m)
	area :=
		math.PI * sigma * sigma + math.TAU * abs(small_circle) * math.sqrt(f64(math.PI)) * sigma
	span := f64(wave_cell_span_mm(planet, packet.source_cell)) / 1_000
	cell_area := max(span * span, 1)
	return max(u64(area / cell_area), u64(1))
}

wave_ring_retired :: proc(planet: ^Planetary_State, packet: ^Wave_Swell_Packet) -> bool {
	assert(planet != nil && packet != nil, "wave_ring_retired: nil input")
	if packet.action == 0 || packet.age_s >= WAVE_PACKET_MAX_AGE_S do return true
	if packet.blocked_sectors == WAVE_RING_ALL_SECTORS do return true
	limit := planet.physical.radius_m * 1_000 * WAVE_RING_MAX_ANGLE_MILLI / 1_000
	if packet.radius_mm >= limit do return true
	return packet.action / wave_ring_annulus_cells(planet, packet) < WAVE_RING_MIN_CELL_VARIANCE
}

wave_packet_body_state :: proc(
	planet: ^Planetary_State,
	packet: ^Wave_Swell_Packet,
) -> (
	Wave_Packet_Body_State,
	bool,
) {
	assert(planet != nil && packet != nil, "wave_packet_body_state: nil input")
	if !packet.active || packet.action == 0 do return {}, false
	index := int(packet.source_cell)
	if index < 0 || index >= PLANET_SIM_CELL_COUNT do return {}, false
	center, _, _ := wave_cell_frame(&planet.waves, index)
	depth := planet.ocean.mean_depth_mm[index]
	phase, _ := wave_dispersion_speed_mm_s(
		planet.physical.gravity_milli_m_s2,
		depth,
		packet.period_ms,
	)
	return {
			id = packet.id,
			cell = packet.source_cell,
			radial = true,
			center_direction = center,
			travel_direction = center,
			period_ms = packet.period_ms,
			action = packet.action,
			age_s = packet.age_s,
			radius_mm = packet.radius_mm,
			band_mm = packet.band_mm,
			total_travel_mm = packet.radius_mm,
			envelope_length_mm = packet.band_mm,
			envelope_width_mm = packet.band_mm,
			phase_epoch_ms = packet.phase_epoch_ms,
			simulation_time_ms = planet.waves.simulation_time_ms,
			breaking = packet.breaking,
			breaker_type = packet.breaker_type,
			depth_mm = depth,
			phase_speed_mm_s = phase,
			group_speed_mm_s = packet.group_speed_mm_s,
		},
		true
}

waves_query_packets_body :: proc(
	planet: ^Planetary_State,
	body_direction: [3]f32,
	radius_mm: u64,
	results: []Wave_Packet_Body_State,
) -> int {
	assert(planet != nil, "waves_query_packets_body: nil planet")
	if len(results) == 0 || radius_mm == 0 do return 0
	body, body_valid := wave_normalize(body_direction)
	if !body_valid do return 0
	count := 0
	for &packet in planet.waves.packets {
		projected, ok := wave_packet_body_state(planet, &packet)
		if !ok do continue
		distance_mm := u64(
			f64(wave_angle_between(body, projected.center_direction)) *
			f64(planet.physical.radius_m) *
			1_000,
		)
		gap := packet.radius_mm - distance_mm
		if distance_mm >= packet.radius_mm do gap = distance_mm - packet.radius_mm
		if gap > radius_mm + packet.band_mm * u64(WAVE_RING_BAND_SIGMAS) do continue
		insert := count
		for index in 0 ..< count {
			if projected.id < results[index].id {
				insert = index
				break
			}
		}
		if insert >= len(results) do continue
		upper := min(count, len(results) - 1)
		for index := upper; index > insert; index -= 1 {
			results[index] = results[index - 1]
		}
		results[insert] = projected
		count = min(count + 1, len(results))
	}
	return count
}

wave_packet_advance :: proc(planet: ^Planetary_State, packet: ^Wave_Swell_Packet, elapsed_s: u32) {
	assert(planet != nil && packet != nil, "wave_packet_advance: nil input")
	if !packet.active do return
	if packet.group_speed_mm_s == 0 {
		wave_packet_deactivate(&planet.waves, packet)
		return
	}
	previous_radius := packet.radius_mm
	packet.radius_mm += u64(packet.group_speed_mm_s) * u64(elapsed_s)
	packet.age_s = min(packet.age_s + elapsed_s, WAVE_PACKET_MAX_AGE_S)
	packet.action = packet.action * 4_095 / 4_096
	source, east, north := wave_cell_frame(&planet.waves, int(packet.source_cell))
	front_angle := wave_ring_angle(planet, packet.radius_mm)
	previous_angle := wave_ring_angle(planet, previous_radius)
	cell_variance := packet.action / wave_ring_annulus_cells(planet, packet)
	for sector in 0 ..< WAVE_RING_SECTOR_COUNT {
		bit := u64(1) << u64(sector)
		if packet.blocked_sectors & bit != 0 do continue
		azimuth := wave_ring_sector_azimuth(sector)
		front := wave_ring_point(source, east, north, azimuth, front_angle)
		front_cell := planetary_sample_index(front)
		if planet.ocean.mean_depth_mm[front_cell] != 0 do continue
		packet.blocked_sectors |= bit
		shore := wave_ring_point(source, east, north, azimuth, previous_angle)
		shore_cell := planetary_sample_index(shore)
		if planet.ocean.mean_depth_mm[shore_cell] == 0 do continue
		breaking := u32(min(cell_variance / 64 + 1, u64(CLIMATE_MAX_WATER)))
		waves_deposit_breaker(&planet.waves, u32(shore_cell), breaking, .Surging, cell_variance)
	}
	if wave_ring_retired(planet, packet) do wave_packet_deactivate(&planet.waves, packet)
}

waves_swell_packets_step :: proc(planet: ^Planetary_State) {
	assert(planet != nil, "waves_swell_packets_step: nil planet")
	elapsed := u32(PLANET_SIM_SECONDS_PER_TICK * PLANET_WAVE_CADENCE_TICKS)
	for &packet in planet.waves.packets {
		if !packet.active do continue
		wave_packet_advance(planet, &packet, elapsed)
	}
	planet.waves.simulation_time_ms += u64(elapsed) * 1_000
}

wave_deep_water_wavelength_mm :: proc(period_ms: u32) -> u64 {
	return u64(9_810) * u64(period_ms) * u64(period_ms) / 6_283 / 1_000
}

wave_dispersion_speed_mm_s :: proc(
	gravity_mm_s2: u32,
	depth_mm, period_ms: u32,
) -> (
	phase, group: u32,
) {
	if gravity_mm_s2 == 0 || depth_mm == 0 || period_ms == 0 do return 0, 0
	shallow := integer_sqrt(u64(gravity_mm_s2) * u64(depth_mm))
	deep := u64(gravity_mm_s2) * u64(period_ms) / 6_283
	phase = u32(min(shallow, deep))
	wavelength := max(u64(phase) * u64(period_ms) / 1_000, u64(1))
	depth_ratio := min(u64(depth_mm) * 1_000 / wavelength, u64(1_000))
	group = u32(u64(phase) * (1_000 - depth_ratio / 2) / 1_000)
	return
}

// waves_invalidate_derived forces the next waves_derive_bathymetry to
// recompute every derived field (after a snapshot restore, or a test that
// edits depth or period arrays directly).
waves_invalidate_derived :: proc(state: ^Wave_State) {
	assert(state != nil, "waves_invalidate_derived: nil state")
	state.bathymetry_revision = 0
	for &period in state.dispersion_period_ms do period = 0
}

// waves_derive_bathymetry refreshes the depth gradients when the bathymetry
// revision moved and the dispersion speeds / shoal gain of every cell whose
// (depth, period) key changed. Each derived value is a pure function of its
// key, so skipping unchanged cells is exact.
waves_derive_bathymetry :: proc(planet: ^Planetary_State) {
	assert(planet != nil, "waves_derive_bathymetry: nil planet")
	state := &planet.waves
	// Revision zero is "never derived" on both sides: a bare state without
	// ocean_init recomputes every call, which is exact, just uncached.
	bathymetry_changed :=
		state.bathymetry_revision == 0 ||
		state.bathymetry_revision != planet.ocean.bathymetry_revision
	if bathymetry_changed {
		waves_derive_depth_gradients(planet)
		state.bathymetry_revision = max(planet.ocean.bathymetry_revision, 1)
	}
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		period := max(state.period_ms[index], max(state.swell_period_ms[index], u32(4_000)))
		if !bathymetry_changed && state.dispersion_period_ms[index] == period do continue
		state.dispersion_period_ms[index] = period
		state.phase_speed_mm_s[index], state.group_speed_mm_s[index] = wave_dispersion_speed_mm_s(
			planet.physical.gravity_milli_m_s2,
			planet.ocean.mean_depth_mm[index],
			period,
		)
		group := max(state.group_speed_mm_s[index], u32(1))
		state.shoal_gain[index] = min(WAVE_SHOAL_MAX, u32(31_000 / integer_sqrt(u64(group))))
		state.shoal_gain[index] = max(state.shoal_gain[index], WAVE_SHOAL_SCALE)
	}
}

waves_derive_depth_gradients :: proc(planet: ^Planetary_State) {
	state := &planet.waves
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		west := int(planet.grid.neighbours[index][0])
		east := int(planet.grid.neighbours[index][1])
		south := int(planet.grid.neighbours[index][2])
		north := int(planet.grid.neighbours[index][3])
		east_span := max(
			u64(planet.grid.edge_length_m[index][0]) + u64(planet.grid.edge_length_m[index][1]),
			u64(1),
		)
		north_span := max(
			u64(planet.grid.edge_length_m[index][2]) + u64(planet.grid.edge_length_m[index][3]),
			u64(1),
		)
		state.depth_gradient_east[index] = i32(
			(i64(planet.ocean.mean_depth_mm[east]) - i64(planet.ocean.mean_depth_mm[west])) *
			1_000 /
			i64(east_span),
		)
		state.depth_gradient_north[index] = i32(
			(i64(planet.ocean.mean_depth_mm[north]) - i64(planet.ocean.mean_depth_mm[south])) *
			1_000 /
			i64(north_span),
		)
	}
}

wave_cell_break_limit :: proc(
	planet: ^Planetary_State,
	cell: int,
	variance: u64,
	period_ms: u32,
) -> (
	limited: u64,
	breaking: u32,
	breaker_type: Wave_Breaker_Type,
) {
	assert(planet != nil, "wave_cell_break_limit: nil planet")
	assert(cell >= 0 && cell < PLANET_SIM_CELL_COUNT, "wave_cell_break_limit: cell")
	depth := planet.ocean.mean_depth_mm[cell]
	if depth == 0 do return 0, 0, .Surging
	if variance == 0 do return 0, 0, .None
	height := integer_sqrt(variance) * 4
	depth_limit := u64(depth) * WAVE_BREAK_DEPTH_RATIO_MILLI / 1_000
	phase, _ := wave_dispersion_speed_mm_s(planet.physical.gravity_milli_m_s2, depth, period_ms)
	wavelength := max(u64(phase) * u64(period_ms) / 1_000, u64(1))
	steepness_limit := max(wavelength * 142 / 1_000, u64(1))
	if height <= depth_limit && height <= steepness_limit do return variance, 0, .None
	allowed_height := min(depth_limit, steepness_limit)
	allowed_action := allowed_height * allowed_height / 16
	excess := variance - min(variance, allowed_action)
	breaking = u32(min(excess / 64 + 1, u64(CLIMATE_MAX_WATER)))
	gradient_east := i64(planet.waves.depth_gradient_east[cell])
	gradient_north := i64(planet.waves.depth_gradient_north[cell])
	gradient_length := integer_sqrt(
		u64(gradient_east * gradient_east + gradient_north * gradient_north),
	)
	slope := min(gradient_length * 1_000 / max(u64(depth), u64(1)), u64(4_000))
	steepness_milli := height * 1_000 / wavelength
	surf_similarity := slope * integer_sqrt(wavelength / max(height, u64(1)))
	breaker_type = .Spilling
	if period_ms >= 5_500 &&
	   steepness_milli >= 18 &&
	   surf_similarity >= 220 &&
	   surf_similarity <= 2_400 {
		breaker_type = .Plunging
	} else if surf_similarity > 2_400 {
		breaker_type = .Surging
	}
	return min(variance, allowed_action), breaking, breaker_type
}

waves_begin_breaker_step :: proc(state: ^Wave_State) {
	assert(state != nil, "waves_begin_breaker_step: nil state")
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		state.breaking[index] = 0
		state.breaker_type[index] = .None
		state.runup_mm[index] = state.runup_mm[index] * 7 / 8
	}
}

waves_deposit_breaker :: proc(
	state: ^Wave_State,
	cell: u32,
	breaking: u32,
	breaker_type: Wave_Breaker_Type,
	action: u64,
) {
	assert(state != nil, "waves_deposit_breaker: nil state")
	index := int(cell)
	assert(index >= 0 && index < PLANET_SIM_CELL_COUNT, "waves_deposit_breaker: cell")
	if breaking <= state.breaking[index] do return
	state.breaking[index] = breaking
	state.breaker_type[index] = breaker_type
	state.runup_mm[index] = u32(
		min(u64(state.runup_mm[index]) + integer_sqrt(action), u64(12_000)),
	)
}

wave_chord_squared :: proc(angle: f32) -> f32 {
	half := math.sin(clamp(angle, f32(0), f32(math.PI)) * 0.5)
	return 4 * half * half
}

wave_ring_collect_cells :: proc(
	planet: ^Planetary_State,
	packet: ^Wave_Swell_Packet,
) -> (
	int,
	f64,
) {
	assert(planet != nil && packet != nil, "wave_ring_collect_cells: nil input")
	state := &planet.waves
	source, _, _ := wave_cell_frame(state, int(packet.source_cell))
	ring_angle := wave_ring_angle(planet, packet.radius_mm)
	sigma := max(wave_ring_angle(planet, packet.band_mm), f32(0.000001))
	reach := sigma * WAVE_RING_BAND_SIGMAS
	cell_min := wave_chord_squared(ring_angle - reach)
	cell_max := wave_chord_squared(ring_angle + reach)
	count := 0
	weight_sum := f64(0)
	for block in 0 ..< WAVE_RING_BLOCK_COUNT {
		block_reach := reach + state.block_radius[block]
		delta := state.block_direction[block] - source
		block_distance := delta.x * delta.x + delta.y * delta.y + delta.z * delta.z
		if block_distance < wave_chord_squared(ring_angle - block_reach) ||
		   block_distance > wave_chord_squared(ring_angle + block_reach) {
			continue
		}
		first, stride := wave_ring_block_cells(block)
		for v in 0 ..< WAVE_RING_BLOCK_CELLS {
			row := first + v * stride
			for u in 0 ..< WAVE_RING_BLOCK_CELLS {
				cell := row + u
				offset := state.cell_direction[cell] - source
				distance := offset.x * offset.x + offset.y * offset.y + offset.z * offset.z
				if distance < cell_min || distance > cell_max do continue
				gap :=
					(wave_angle_between(state.cell_direction[cell], source) - ring_angle) / sigma
				if abs(gap) > WAVE_RING_BAND_SIGMAS do continue
				weight := math.exp(-gap * gap)
				state.ring_cells[count] = u32(cell)
				state.ring_weights[count] = weight
				weight_sum += f64(weight)
				count += 1
			}
		}
	}
	return count, weight_sum
}

wave_ring_rasterize :: proc(planet: ^Planetary_State, packet: ^Wave_Swell_Packet) {
	assert(planet != nil && packet != nil, "wave_ring_rasterize: nil input")
	if !packet.active || packet.action == 0 do return
	state := &planet.waves
	count, weight_sum := wave_ring_collect_cells(planet, packet)
	if count == 0 || weight_sum <= 0 do return
	source, east, north := wave_cell_frame(state, int(packet.source_cell))
	has_ice := len(planet.climate.sea_ice) == PLANET_SIM_CELL_COUNT
	packet.breaking = 0
	packet.breaker_type = .None
	for slot in 0 ..< count {
		cell := int(state.ring_cells[slot])
		if planet.ocean.mean_depth_mm[cell] == 0 do continue
		cell_direction := state.cell_direction[cell]
		sector := wave_ring_sector_for(source, east, north, cell_direction)
		if packet.blocked_sectors & (u64(1) << u64(sector)) != 0 do continue
		variance := u64(f64(packet.action) * f64(state.ring_weights[slot]) / weight_sum)
		if has_ice do variance = sea_ice_damp_wave_variance(variance, planet.climate.sea_ice[cell])
		gain := u64(state.shoal_gain[cell])
		if gain > u64(WAVE_SHOAL_SCALE) {
			variance = variance * gain * gain / u64(WAVE_SHOAL_SCALE * WAVE_SHOAL_SCALE)
		}
		breaking: u32
		breaker_type: Wave_Breaker_Type
		variance, breaking, breaker_type = wave_cell_break_limit(
			planet,
			cell,
			variance,
			packet.period_ms,
		)
		if breaking > 0 {
			waves_deposit_breaker(state, u32(cell), breaking, breaker_type, variance)
			if breaking > packet.breaking {
				packet.breaking = breaking
				packet.breaker_type = breaker_type
			}
		}
		if variance == 0 do continue
		variance = min(variance, WAVE_MAX_VARIANCE)
		state.swell_variance[cell] = min(state.swell_variance[cell] + variance, WAVE_MAX_VARIANCE)
		state.period_scratch[cell] += u64(packet.period_ms) * variance
		dot :=
			cell_direction.x * source.x + cell_direction.y * source.y + cell_direction.z * source.z
		outward, valid := wave_normalize(cell_direction * dot - source)
		if !valid do continue
		cell_east := state.cell_east[cell]
		cell_north := state.cell_north[cell]
		direction_east := i64(
			(outward.x * cell_east.x + outward.y * cell_east.y + outward.z * cell_east.z) *
			f32(WAVE_DIRECTION_SCALE),
		)
		direction_north := i64(
			(outward.x * cell_north.x + outward.y * cell_north.y + outward.z * cell_north.z) *
			f32(WAVE_DIRECTION_SCALE),
		)
		state.direction_east_scratch[cell] += direction_east * i64(variance)
		state.direction_north_scratch[cell] += direction_north * i64(variance)
	}
}

waves_rasterize_packets :: proc(planet: ^Planetary_State) {
	assert(planet != nil, "waves_rasterize_packets: nil planet")
	state := &planet.waves
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		state.swell_variance[index] = 0
		state.swell_period_ms[index] = 0
		state.swell_direction_east[index] = 0
		state.swell_direction_north[index] = 0
		state.period_scratch[index] = 0
		state.direction_east_scratch[index] = 0
		state.direction_north_scratch[index] = 0
	}
	for &packet in state.packets {
		if !packet.active || packet.action == 0 do continue
		wave_ring_rasterize(planet, &packet)
	}
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		variance := state.swell_variance[index]
		if variance == 0 do continue
		state.swell_period_ms[index] = u32(state.period_scratch[index] / variance)
		state.swell_direction_east[index], state.swell_direction_north[index] =
			planet_vector_normalize(
				state.direction_east_scratch[index] / i64(variance),
				state.direction_north_scratch[index] / i64(variance),
			)
	}
}

waves_combine_components :: proc(planet: ^Planetary_State) {
	assert(planet != nil, "waves_combine_components: nil planet")
	state := &planet.waves
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		wind_variance := state.wind_sea_variance[index]
		swell_variance := state.swell_variance[index]
		total_variance := wind_variance + swell_variance
		state.height_mm[index] = u32(
			min(integer_sqrt(total_variance) * 4, u64(WAVE_MAX_HEIGHT_MM)),
		)
		if total_variance == 0 {
			state.period_ms[index] = 0
			state.direction_east[index] = 0
			state.direction_north[index] = 0
			continue
		}
		state.period_ms[index] = u32(
			(u64(state.wind_sea_period_ms[index]) * wind_variance +
				u64(state.swell_period_ms[index]) * swell_variance) /
			total_variance,
		)
		state.direction_east[index], state.direction_north[index] = planet_vector_normalize(
			i64(state.wind_sea_direction_east[index]) * i64(wind_variance) +
			i64(state.swell_direction_east[index]) * i64(swell_variance),
			i64(state.wind_sea_direction_north[index]) * i64(wind_variance) +
			i64(state.swell_direction_north[index]) * i64(swell_variance),
		)
	}
}

waves_step :: proc(planet: ^Planetary_State) {
	assert(planet != nil, "waves_step: nil planet")
	waves_wind_sea_step(planet)
	waves_derive_bathymetry(planet)
	waves_detect_storm_sources(planet)
	waves_emit_swell_packets(planet)
	waves_begin_breaker_step(&planet.waves)
	waves_swell_packets_step(planet)
	waves_rasterize_packets(planet)
	waves_combine_components(planet)
}

// integer_sqrt returns floor(sqrt(value)) exactly. The hardware square root
// is a correctly rounded estimate that is within one of the answer for any
// u64; the fix-up loops make the result exact and platform-independent, so
// this equals the Newton iteration it replaced (integer_sqrt_reference in
// the tests) for every input.
integer_sqrt :: proc(value: u64) -> u64 {
	if value == 0 do return 0
	root := u64(math.sqrt(f64(value)))
	if root > 0xFFFF_FFFF do root = 0xFFFF_FFFF
	for root > 0 && root * root > value do root -= 1
	for root < 0xFFFF_FFFF && (root + 1) * (root + 1) <= value do root += 1
	return root
}
