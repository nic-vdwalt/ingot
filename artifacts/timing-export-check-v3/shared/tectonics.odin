package shared

import "core:mem"
import "core:math"

TECTONIC_NORMAL_YEARS_PER_STEP :: u32(1)
TECTONIC_TIMELAPSE_YEARS_PER_STEP :: u32(25_000)
TECTONIC_DIRTY_TILE_CAPACITY :: PLANET_SIM_CELL_COUNT
TECTONIC_UPLIFT_MAX_FIXED :: i32(384)
TECTONIC_SUBSIDENCE_MAX_FIXED :: i32(384)
TECTONIC_SEDIMENT_MAX_FIXED :: i32(256)
TECTONIC_STRAIN_MAX_MICRO :: i32(1_000_000)

Tectonic_Time_Mode :: enum u8 {
	Normal,
	Time_Lapse,
}

Tectonic_State :: struct {
	config: Tectonic_Model_Config,
	mode:                  Tectonic_Time_Mode,
	epoch:                 u64,
	elapsed_years:         u64,
	created_volume_m3: f64,
	recycled_volume_m3: f64,
	age_remainder_years:   u32,
	material: [][LITHOSPHERE_PLATE_COUNT]Tectonic_Material,
	material_scratch: [][LITHOSPHERE_PLATE_COUNT]Tectonic_Material,
	continental_fraction: []f64,
	normal_speed_mm_yr: []i32,
	shear_speed_mm_yr: []u32,
	isostatic_height_m: []f64,
	genesis_isostatic_height_m: []f64,
	revision:              u64,
	published_revision:    u64,
	plate_id:              []u8,
	crust:                 []Plate_Crust,
	boundary:              []Plate_Boundary,
	role:                  []Plate_Role,
	boundary_strength:     []u8,
	crust_age_ka:          []u32,
	crust_thickness_m:     []u32,
	strain_micro:          []i32,
	strain_residual:       []f64,
	uplift_residual:       []f64,
	subsidence_residual:   []f64,
	uplift_fixed:          []i32,
	subsidence_fixed:      []i32,
	sediment_fixed:        []i32,
	previous_displacement: []i32,
	advection_source:      []u32,
	dirty_tiles:           []u32,
	dirty_marks:           []bool,
	dirty_count:           u32,
}

tectonics_init :: proc(
	state: ^Tectonic_State,
	foundation: ^Planet_Foundation,
	allocator := context.allocator,
) {
	assert(state != nil && foundation != nil, "tectonics_init: nil input")
	state^ = {}
	state.config = tectonic_model_earthlike()
	assert(tectonic_model_valid(state.config))
	state.material = make([][LITHOSPHERE_PLATE_COUNT]Tectonic_Material, PLANET_SIM_CELL_COUNT, allocator)
	state.material_scratch = make([][LITHOSPHERE_PLATE_COUNT]Tectonic_Material, PLANET_SIM_CELL_COUNT, allocator)
	state.continental_fraction = make([]f64, PLANET_SIM_CELL_COUNT, allocator)
	state.normal_speed_mm_yr = make([]i32, PLANET_SIM_CELL_COUNT, allocator)
	state.shear_speed_mm_yr = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.isostatic_height_m = make([]f64, PLANET_SIM_CELL_COUNT, allocator)
	state.genesis_isostatic_height_m = make([]f64, PLANET_SIM_CELL_COUNT, allocator)
	state.plate_id = make([]u8, PLANET_SIM_CELL_COUNT, allocator)
	state.crust = make([]Plate_Crust, PLANET_SIM_CELL_COUNT, allocator)
	state.boundary = make([]Plate_Boundary, PLANET_SIM_CELL_COUNT, allocator)
	state.role = make([]Plate_Role, PLANET_SIM_CELL_COUNT, allocator)
	state.boundary_strength = make([]u8, PLANET_SIM_CELL_COUNT, allocator)
	state.crust_age_ka = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.crust_thickness_m = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.strain_micro = make([]i32, PLANET_SIM_CELL_COUNT, allocator)
	state.strain_residual = make([]f64, PLANET_SIM_CELL_COUNT, allocator)
	state.uplift_residual = make([]f64, PLANET_SIM_CELL_COUNT, allocator)
	state.subsidence_residual = make([]f64, PLANET_SIM_CELL_COUNT, allocator)
	state.uplift_fixed = make([]i32, PLANET_SIM_CELL_COUNT, allocator)
	state.subsidence_fixed = make([]i32, PLANET_SIM_CELL_COUNT, allocator)
	state.sediment_fixed = make([]i32, PLANET_SIM_CELL_COUNT, allocator)
	state.previous_displacement = make([]i32, PLANET_SIM_CELL_COUNT, allocator)
	state.advection_source = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.dirty_tiles = make([]u32, TECTONIC_DIRTY_TILE_CAPACITY, allocator)
	state.dirty_marks = make([]bool, PLANET_SIM_CELL_COUNT, allocator)
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		sample := lithosphere_sample(
			&foundation.lithosphere,
			planet_sim_direction(planet_sim_coord_for_index(index)),
		)
		fraction := tectonic_genesis_continents(&foundation.lithosphere, planet_sim_direction(planet_sim_coord_for_index(index)))
		state.plate_id[index] = sample.plate_id
		state.crust[index] = sample.crust
		state.boundary[index] = sample.boundary
		state.role[index] = sample.role
		state.boundary_strength[index] = _terrain_unit_to_u8(sample.boundary_strength)
		state.crust_age_ka[index] = tectonic_genesis_ocean_age(sample)
		state.crust_thickness_m[index] = u32(7_000 + fraction * 31_000)
		state.advection_source[index] = u32(index)
		area := planet_sim_cell_solid_angle(planet_sim_coord_for_index(index)) * state.config.radius_m * state.config.radius_m
		volume := area * f64(state.crust_thickness_m[index])
		material := &state.material[index][sample.plate_id]
		material.area_m2 = area
		material.age_volume_years_m3 = volume * f64(state.crust_age_ka[index]) * 1_000
		material.continental_volume_m3 = volume * f64(fraction)
		material.oceanic_volume_m3 = volume * (1 - f64(fraction))
		state.continental_fraction[index] = f64(fraction)
		height := tectonic_isostatic_height(f64(fraction), f64(state.crust_thickness_m[index]), f64(state.crust_age_ka[index]) * 1_000, 0)
		state.isostatic_height_m[index] = height
		state.genesis_isostatic_height_m[index] = height
	}
}

tectonics_deinit :: proc(state: ^Tectonic_State, allocator := context.allocator) {
	assert(state != nil, "tectonics_deinit: nil state")
	delete(state.isostatic_height_m, allocator)
	delete(state.genesis_isostatic_height_m, allocator)
	delete(state.normal_speed_mm_yr, allocator)
	delete(state.shear_speed_mm_yr, allocator)
	delete(state.material, allocator)
	delete(state.material_scratch, allocator)
	delete(state.continental_fraction, allocator)
	delete(state.dirty_marks, allocator)
	delete(state.dirty_tiles, allocator)
	delete(state.advection_source, allocator)
	delete(state.previous_displacement, allocator)
	delete(state.sediment_fixed, allocator)
	delete(state.subsidence_fixed, allocator)
	delete(state.uplift_fixed, allocator)
	delete(state.strain_residual, allocator)
	delete(state.uplift_residual, allocator)
	delete(state.subsidence_residual, allocator)
	delete(state.strain_micro, allocator)
	delete(state.crust_thickness_m, allocator)
	delete(state.crust_age_ka, allocator)
	delete(state.boundary_strength, allocator)
	delete(state.role, allocator)
	delete(state.boundary, allocator)
	delete(state.crust, allocator)
	delete(state.plate_id, allocator)
	state^ = {}
}

tectonics_years_per_step :: proc(mode: Tectonic_Time_Mode) -> u32 {
	if mode == .Time_Lapse do return TECTONIC_TIMELAPSE_YEARS_PER_STEP
	return TECTONIC_NORMAL_YEARS_PER_STEP
}

tectonics_displacement_fixed :: proc(state: ^Tectonic_State, index: int) -> i32 {
	assert(state != nil, "tectonics_displacement_fixed: nil state")
	assert(index >= 0 && index < PLANET_SIM_CELL_COUNT, "tectonics_displacement_fixed: index")
	return clamp(
		state.uplift_fixed[index] - state.subsidence_fixed[index] + state.sediment_fixed[index] + tectonic_units_to_height_fixed(state.isostatic_height_m[index] - state.genesis_isostatic_height_m[index]),
		-TECTONIC_SUBSIDENCE_MAX_FIXED,
		TECTONIC_UPLIFT_MAX_FIXED + TECTONIC_SEDIMENT_MAX_FIXED,
	)
}

tectonics_advect_crust :: proc(state: ^Tectonic_State, lithosphere: ^Lithosphere, grid: ^Planet_Sim_Grid, years: u32) {
	tectonic_material_remap(state, lithosphere, grid, years)
}

tectonics_accumulate_strain :: proc(state: ^Tectonic_State, lithosphere: ^Lithosphere, years: u32) {
	assert(state != nil && lithosphere != nil, "tectonics_accumulate_strain: nil input")
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		sample := Lithosphere_Sample{boundary = state.boundary[index], role = state.role[index], normal_speed_mm_yr = state.normal_speed_mm_yr[index], shear_speed_mm_yr = state.shear_speed_mm_yr[index]}
		scale := f64(state.boundary_strength[index]) * f64(years) / (255 * 250)
		shortening := f64(max(-sample.normal_speed_mm_yr, 0)) * scale
		extension := f64(max(sample.normal_speed_mm_yr, 0)) * scale
		state.strain_residual[index] += shortening + f64(sample.shear_speed_mm_yr) * scale / 2
		if sample.boundary == .Intraplate do state.strain_residual[index] -= f64(years) / 1_000
		if sample.role == .Subducting do state.subsidence_residual[index] += shortening / 1_500
		if sample.role == .Overriding do state.uplift_residual[index] += shortening / 2_500
		if sample.role == .Colliding do state.uplift_residual[index] += shortening / 2_000
		state.subsidence_residual[index] -= extension / 4_000
		strain_delta := i32(state.strain_residual[index])
		uplift_delta := i32(state.uplift_residual[index])
		subsidence_delta := i32(state.subsidence_residual[index])
		state.strain_residual[index] -= f64(strain_delta)
		state.uplift_residual[index] -= f64(uplift_delta)
		state.subsidence_residual[index] -= f64(subsidence_delta)
		state.strain_micro[index] = clamp(state.strain_micro[index] + strain_delta, 0, TECTONIC_STRAIN_MAX_MICRO)
		state.uplift_fixed[index] = min(state.uplift_fixed[index] + uplift_delta, TECTONIC_UPLIFT_MAX_FIXED)
		state.subsidence_fixed[index] = clamp(state.subsidence_fixed[index] + subsidence_delta, 0, TECTONIC_SUBSIDENCE_MAX_FIXED)
	}
}

tectonics_apply_isostasy :: proc(state: ^Tectonic_State, years: u32 = TECTONIC_TIMELAPSE_YEARS_PER_STEP) {
	assert(state != nil, "tectonics_apply_isostasy: nil state")
	if years == 0 do return
	response := 1 - math.exp(-f64(years) / 50_000)
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		target := tectonic_isostatic_height(state.continental_fraction[index], f64(state.crust_thickness_m[index]), f64(state.crust_age_ka[index]) * 1_000, f64(state.sediment_fixed[index]) * 250 / f64(HEIGHT_DELTA_SCALE))
		state.isostatic_height_m[index] += (target - state.isostatic_height_m[index]) * response
	}
}

tectonics_mark_changed :: proc(state: ^Tectonic_State) {
	assert(state != nil, "tectonics_mark_changed: nil state")
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		displacement := tectonics_displacement_fixed(state, index)
		if displacement == state.previous_displacement[index] do continue
		if !state.dirty_marks[index] && state.dirty_count < TECTONIC_DIRTY_TILE_CAPACITY {
			state.dirty_tiles[state.dirty_count] = u32(index)
			state.dirty_count += 1
		}
		state.dirty_marks[index] = true
		state.previous_displacement[index] = displacement
	}
}

tectonics_step :: proc(world: ^World, years: u32) -> bool {
	assert(world != nil, "tectonics_step: nil world")
	if years == 0 || years > LITHOSPHERE_STEP_MAX_YEARS do return false
	state := &world.planetary.tectonics
	lithosphere_step(&world.foundation.lithosphere, world.planetary.physical.radius_m, years)
	tectonic_material_remap(state, &world.foundation.lithosphere, &world.planetary.grid, years)
	tectonic_boundary_graph_rebuild(state, &world.foundation.lithosphere, &world.planetary.grid)
	tectonic_material_resolve_interfaces(state, &world.planetary.grid, years)
	tectonic_boundary_graph_rebuild(state, &world.foundation.lithosphere, &world.planetary.grid)
	tectonics_accumulate_strain(state, &world.foundation.lithosphere, years)
	tectonics_apply_isostasy(state, years)
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		coord := planet_sim_terrain_coord(planet_sim_coord_for_index(index))
		fine := planet_index(coord)
		if world.foundation.plate_id[fine] == state.plate_id[index] && world.foundation.plate_crust[fine] == state.crust[index] && world.foundation.plate_boundary[fine] == state.boundary[index] && world.foundation.boundary_strength[fine] == state.boundary_strength[index] do continue
		if state.dirty_marks[index] do continue
		state.dirty_marks[index] = true
		state.dirty_tiles[state.dirty_count] = u32(index)
		state.dirty_count += 1
	}
	state.elapsed_years += u64(years)
	tectonics_mark_changed(state)
	state.epoch += 1
	state.revision += 1
	return true
}

tectonics_snapshot_size :: proc(state: ^Tectonic_State) -> int {
	assert(state != nil, "tectonics_snapshot_size: nil state")
	return size_of(state.config) + size_of(state.mode) + size_of(state.epoch) + size_of(state.elapsed_years) + size_of(state.age_remainder_years) + size_of(state.revision) +
		size_of(state.published_revision) + size_of(state.dirty_count) + 2 * size_of(f64) +
		PLANET_SIM_CELL_COUNT * (size_of([LITHOSPHERE_PLATE_COUNT]Tectonic_Material) + 6 * size_of(f64) + size_of(i32) + size_of(u32)) +
		PLANET_SIM_CELL_COUNT *
		(size_of(u8) * 2 + size_of(Plate_Crust) + size_of(Plate_Boundary) +
		 size_of(Plate_Role) + size_of(u32) * 4 + size_of(i32) * 5 + size_of(bool))
}

tectonics_snapshot_write :: proc(state: ^Tectonic_State, buffer: []u8) -> (int, bool) {
	assert(state != nil, "tectonics_snapshot_write: nil state")
	if len(buffer) < tectonics_snapshot_size(state) do return 0, false
	cursor := 0
	fields := [][]u8 {
		mem.ptr_to_bytes(&state.config), mem.ptr_to_bytes(&state.mode), mem.ptr_to_bytes(&state.epoch),
		mem.ptr_to_bytes(&state.elapsed_years), mem.ptr_to_bytes(&state.age_remainder_years),
		mem.ptr_to_bytes(&state.created_volume_m3), mem.ptr_to_bytes(&state.recycled_volume_m3),
		mem.slice_to_bytes(state.material), mem.slice_to_bytes(state.continental_fraction),
		mem.slice_to_bytes(state.normal_speed_mm_yr), mem.slice_to_bytes(state.shear_speed_mm_yr),
		mem.slice_to_bytes(state.isostatic_height_m), mem.slice_to_bytes(state.genesis_isostatic_height_m),
		mem.ptr_to_bytes(&state.revision), mem.ptr_to_bytes(&state.published_revision),
		mem.ptr_to_bytes(&state.dirty_count), mem.slice_to_bytes(state.plate_id),
		mem.slice_to_bytes(state.crust), mem.slice_to_bytes(state.boundary),
		mem.slice_to_bytes(state.role), mem.slice_to_bytes(state.boundary_strength),
		mem.slice_to_bytes(state.crust_age_ka), mem.slice_to_bytes(state.crust_thickness_m),
		mem.slice_to_bytes(state.strain_micro), mem.slice_to_bytes(state.uplift_fixed),
		mem.slice_to_bytes(state.strain_residual), mem.slice_to_bytes(state.uplift_residual), mem.slice_to_bytes(state.subsidence_residual),
		mem.slice_to_bytes(state.subsidence_fixed), mem.slice_to_bytes(state.sediment_fixed),
		mem.slice_to_bytes(state.previous_displacement), mem.slice_to_bytes(state.advection_source),
		mem.slice_to_bytes(state.dirty_tiles), mem.slice_to_bytes(state.dirty_marks),
	}
	for field in fields do planetary_snapshot_put(buffer, &cursor, field)
	assert(cursor == tectonics_snapshot_size(state), "tectonics_snapshot_write: size mismatch")
	return cursor, true
}

tectonics_snapshot_read :: proc(state: ^Tectonic_State, buffer: []u8) -> bool {
	assert(state != nil, "tectonics_snapshot_read: nil state")
	if len(buffer) != tectonics_snapshot_size(state) do return false
	cursor := 0
	fields := [][]u8 {
		mem.ptr_to_bytes(&state.config), mem.ptr_to_bytes(&state.mode), mem.ptr_to_bytes(&state.epoch),
		mem.ptr_to_bytes(&state.elapsed_years), mem.ptr_to_bytes(&state.age_remainder_years),
		mem.ptr_to_bytes(&state.created_volume_m3), mem.ptr_to_bytes(&state.recycled_volume_m3),
		mem.slice_to_bytes(state.material), mem.slice_to_bytes(state.continental_fraction),
		mem.slice_to_bytes(state.normal_speed_mm_yr), mem.slice_to_bytes(state.shear_speed_mm_yr),
		mem.slice_to_bytes(state.isostatic_height_m), mem.slice_to_bytes(state.genesis_isostatic_height_m),
		mem.ptr_to_bytes(&state.revision), mem.ptr_to_bytes(&state.published_revision),
		mem.ptr_to_bytes(&state.dirty_count), mem.slice_to_bytes(state.plate_id),
		mem.slice_to_bytes(state.crust), mem.slice_to_bytes(state.boundary),
		mem.slice_to_bytes(state.role), mem.slice_to_bytes(state.boundary_strength),
		mem.slice_to_bytes(state.crust_age_ka), mem.slice_to_bytes(state.crust_thickness_m),
		mem.slice_to_bytes(state.strain_micro), mem.slice_to_bytes(state.uplift_fixed),
		mem.slice_to_bytes(state.strain_residual), mem.slice_to_bytes(state.uplift_residual), mem.slice_to_bytes(state.subsidence_residual),
		mem.slice_to_bytes(state.subsidence_fixed), mem.slice_to_bytes(state.sediment_fixed),
		mem.slice_to_bytes(state.previous_displacement), mem.slice_to_bytes(state.advection_source),
		mem.slice_to_bytes(state.dirty_tiles), mem.slice_to_bytes(state.dirty_marks),
	}
	for field in fields do planetary_snapshot_get(buffer, &cursor, field)
	return tectonic_model_valid(state.config) && state.dirty_count <= TECTONIC_DIRTY_TILE_CAPACITY && cursor == len(buffer)
}
