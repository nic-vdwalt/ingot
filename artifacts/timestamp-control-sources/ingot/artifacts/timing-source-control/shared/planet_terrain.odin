package shared

import "core:math"
import "core:sys/info"
import "core:thread"
import procgen "ingot:procgen"

Planet_Foundation :: struct {
	seed:              u64,
	sea_level:         i16,
	snow_level:        i16,
	lithosphere:       Lithosphere,
	base_height:       []i16,
	landform_height:   []i16,
	moisture:          []u8,
	temperature:       []u8,
	continentalness:   []u8,
	ruggedness:        []u8,
	slope:             []u16,
	plate_id:          []u8,
	plate_crust:       []Plate_Crust,
	plate_boundary:    []Plate_Boundary,
	boundary_strength: []u8,
	tectonic_delta:    []i16,
	tectonic_revision: u64,
	primary_biome:     []Biome_Id,
	secondary_biome:   []Biome_Id,
	primary_weight:    []u8,
	river_strength:    []u8,
	chasm_strength:    []u8,
	buildable:         []bool,
	relaxation_delta:  []i32,
}

planet_foundation_init :: proc(field: ^Planet_Foundation, allocator := context.allocator) {
	assert(field != nil, "planet_foundation_init: nil field")
	field^ = {}
	field.base_height = make([]i16, PLANET_FIELD_CELLS, allocator)
	field.landform_height = make([]i16, PLANET_FIELD_CELLS, allocator)
	field.moisture = make([]u8, PLANET_FIELD_CELLS, allocator)
	field.temperature = make([]u8, PLANET_FIELD_CELLS, allocator)
	field.continentalness = make([]u8, PLANET_FIELD_CELLS, allocator)
	field.ruggedness = make([]u8, PLANET_FIELD_CELLS, allocator)
	field.slope = make([]u16, PLANET_FIELD_CELLS, allocator)
	field.plate_id = make([]u8, PLANET_FIELD_CELLS, allocator)
	field.plate_crust = make([]Plate_Crust, PLANET_FIELD_CELLS, allocator)
	field.plate_boundary = make([]Plate_Boundary, PLANET_FIELD_CELLS, allocator)
	field.boundary_strength = make([]u8, PLANET_FIELD_CELLS, allocator)
	field.tectonic_delta = make([]i16, PLANET_FIELD_CELLS, allocator)
	field.primary_biome = make([]Biome_Id, PLANET_FIELD_CELLS, allocator)
	field.secondary_biome = make([]Biome_Id, PLANET_FIELD_CELLS, allocator)
	field.primary_weight = make([]u8, PLANET_FIELD_CELLS, allocator)
	field.river_strength = make([]u8, PLANET_FIELD_CELLS, allocator)
	field.chasm_strength = make([]u8, PLANET_FIELD_CELLS, allocator)
	field.buildable = make([]bool, PLANET_FIELD_CELLS, allocator)
	field.relaxation_delta = make([]i32, PLANET_FIELD_CELLS, allocator)
}

planet_foundation_deinit :: proc(field: ^Planet_Foundation, allocator := context.allocator) {
	assert(field != nil, "planet_foundation_deinit: nil field")
	delete(field.relaxation_delta, allocator)
	delete(field.buildable, allocator)
	delete(field.chasm_strength, allocator)
	delete(field.river_strength, allocator)
	delete(field.primary_weight, allocator)
	delete(field.secondary_biome, allocator)
	delete(field.primary_biome, allocator)
	delete(field.tectonic_delta, allocator)
	delete(field.boundary_strength, allocator)
	delete(field.plate_boundary, allocator)
	delete(field.plate_crust, allocator)
	delete(field.plate_id, allocator)
	delete(field.slope, allocator)
	delete(field.ruggedness, allocator)
	delete(field.continentalness, allocator)
	delete(field.temperature, allocator)
	delete(field.moisture, allocator)
	delete(field.landform_height, allocator)
	delete(field.base_height, allocator)
	field^ = {}
}

// The archetype table authors relief for the flat demo, where the V3
// mountain transform roughly doubles a peak after sampling. The V4 planet
// skin applies no such transform, so raw archetype heights (~35 units on a
// radius-1080 sphere) read as gentle swells. The boosts recover the relief
// the transform used to provide: peaks reach ~72 units and hills ~9.
PLANET_MOUNTAIN_BOOST :: f32(1.45)
PLANET_HILL_BOOST :: f32(1.8)

planet_terrain_recipe :: proc(seed: u64) -> procgen.Terrain_Recipe_V4 {
	recipe := procgen.terrain_normal_recipe_v4(seed)
	recipe.parameters.radius = PLANET_RADIUS
	recipe.parameters.minimum_radius = PLANET_RADIUS - 56
	// The ceiling leaves room for boosted summits plus the terraform delta so
	// a raised peak stays inside the buildability window.
	recipe.parameters.maximum_radius = PLANET_RADIUS + 96
	recipe.parameters.derivative_step = f32(math.PI) * PLANET_RADIUS / (2 * PLANET_FACE_CELLS)
	recipe.surface = terrain_surface_recipe(seed)
	recipe.surface.mountain_height *= PLANET_MOUNTAIN_BOOST
	recipe.surface.hill_height *= PLANET_HILL_BOOST
	recipe.surface.snow_level += 8
	forest := &recipe.surface.biome_profiles[int(Biome_Id.Forest)]
	forest.height.maximum = 24
	forest.temperature.minimum = 0.34
	forest.slope.maximum = 0.38
	snowlands := &recipe.surface.biome_profiles[int(Biome_Id.Snowlands)]
	snowlands.height.minimum = 20
	snowlands.temperature.maximum = 0.24
	mountain := &recipe.surface.biome_profiles[int(Biome_Id.Mountain)]
	mountain.height.minimum = 14
	mountain.slope.minimum = 0.15
	mountain.weight = 2.05
	recipe.surface.latitude_offset = 0
	recipe.parameters.latitude_offset_radians = 0
	recipe.parameters.latitude_half_extent_radians = math.PI / 2
	return recipe
}

Planet_Foundation_Job :: struct {
	field:       ^Planet_Foundation,
	recipe:      ^procgen.Terrain_Recipe_V4,
	lithosphere: ^Lithosphere,
	start:       int,
	end:         int,
	ok:          bool,
}

PLANET_FOUNDATION_MAX_WORKERS :: 16

@(private)
_planet_foundation_range :: proc(job: ^Planet_Foundation_Job) {
	job.ok = true
	face_cells := PLANET_FACE_RESOLUTION * PLANET_FACE_RESOLUTION
	for index in job.start ..< job.end {
		face := procgen.Terrain_Face_V4(index / face_cells)
		local := index % face_cells
		coord := Planet_Coord{face, i32(local % PLANET_FACE_RESOLUTION), i32(local / PLANET_FACE_RESOLUTION)}
		sample, ok := procgen.terrain_primary_surface_prevalidated_v4(job.recipe, planet_direction(coord))
		if !ok {
			job.ok = false
			return
		}
		lithosphere := lithosphere_sample(job.lithosphere, planet_direction(coord))
		fraction := tectonic_genesis_continents(job.lithosphere, planet_direction(coord))
		physical_height := tectonic_isostatic_height(f64(fraction), f64(7_000 + fraction * 31_000), f64(tectonic_genesis_ocean_age(lithosphere)) * 1_000, 0)
		initial_tectonics := f32(physical_height / 250) + lithosphere.tectonic_relief
		height := sample.height + initial_tectonics
		landform := sample.landform + initial_tectonics
		job.field.base_height[index] = height_to_fixed(height)
		job.field.landform_height[index] = height_to_fixed(landform)
		job.field.moisture[index] = _terrain_unit_to_u8(sample.moisture)
		job.field.temperature[index] = _terrain_unit_to_u8(sample.temperature)
		job.field.continentalness[index] = _terrain_unit_to_u8(fraction)
		job.field.ruggedness[index] = _terrain_unit_to_u8(clamp(sample.ruggedness + lithosphere.shear * 0.35, 0, 1))
		job.field.plate_id[index] = lithosphere.plate_id
		job.field.plate_crust[index] = lithosphere.crust
		job.field.plate_boundary[index] = lithosphere.boundary
		job.field.boundary_strength[index] = _terrain_unit_to_u8(lithosphere.boundary_strength)
	}
}

planet_foundation_finalize :: proc(field: ^Planet_Foundation, recipe: ^procgen.Terrain_Recipe_V4) -> bool {
	assert(field != nil && recipe != nil, "planet_foundation_finalize: nil input")
	step := recipe.parameters.derivative_step
	for index in 0 ..< PLANET_FIELD_CELLS {
		face_cells := PLANET_FACE_RESOLUTION * PLANET_FACE_RESOLUTION
		face := procgen.Terrain_Face_V4(index / face_cells)
		local := index % face_cells
		coord := Planet_Coord{face, i32(local % PLANET_FACE_RESOLUTION), i32(local / PLANET_FACE_RESOLUTION)}
		left := planet_index(planet_neighbour(coord, -1, 0))
		right := planet_index(planet_neighbour(coord, 1, 0))
		down := planet_index(planet_neighbour(coord, 0, -1))
		up := planet_index(planet_neighbour(coord, 0, 1))
		dx := f32(i32(field.base_height[right]) - i32(field.base_height[left])) /
			(f32(HEIGHT_DELTA_SCALE) * 2 * step)
		dy := f32(i32(field.base_height[up]) - i32(field.base_height[down])) /
			(f32(HEIGHT_DELTA_SCALE) * 2 * step)
		landform_dx := f32(i32(field.landform_height[right]) - i32(field.landform_height[left])) /
			(f32(HEIGHT_DELTA_SCALE) * 2 * step)
		landform_dy := f32(i32(field.landform_height[up]) - i32(field.landform_height[down])) /
			(f32(HEIGHT_DELTA_SCALE) * 2 * step)
		slope := math.sqrt(dx * dx + dy * dy)
		landform_slope := math.sqrt(landform_dx * landform_dx + landform_dy * landform_dy)
		field.slope[index] = u16(clamp(slope * TERRAIN_SLOPE_SCALE, 0, f32(max(u16))))
		height := f32(field.base_height[index]) / f32(HEIGHT_DELTA_SCALE)
		landform := f32(field.landform_height[index]) / f32(HEIGHT_DELTA_SCALE)
		continentalness := f32(field.continentalness[index]) / 255
		moisture := f32(field.moisture[index]) / 255
		temperature := clamp(
			f32(field.temperature[index]) / 255 -
			max(height - recipe.surface.sea_level, f32(0)) * recipe.surface.elevation_lapse,
			0,
			1,
		)
		field.temperature[index] = _terrain_unit_to_u8(temperature)
		biomes, ok := procgen.terrain_biome_blend_prevalidated_v2(
			&recipe.surface,
			landform / recipe.parameters.height_scale,
			continentalness,
			moisture,
			temperature,
			landform_slope,
		)
		if !ok do return false
		field.primary_biome[index] = Biome_Id(biomes.primary_id)
		field.secondary_biome[index] = Biome_Id(biomes.secondary_id)
		field.primary_weight[index] = _terrain_unit_to_u8(biomes.primary_weight)
		radius := PLANET_RADIUS + height
		upward := 1 / math.sqrt(1 + slope * slope)
		field.buildable[index] = radius >= recipe.parameters.minimum_radius &&
			radius <= recipe.parameters.maximum_radius &&
			upward >= recipe.parameters.minimum_upward_normal
	}
	return true
}

planet_foundation_generate :: proc(field: ^Planet_Foundation, seed: u64) -> bool {
	assert(field != nil, "planet_foundation_generate: nil field")
	assert(len(field.base_height) == PLANET_FIELD_CELLS, "planet_foundation_generate: storage")
	recipe := planet_terrain_recipe(seed)
	if !procgen.terrain_recipe_validate_v4(&recipe) do return false
	lithosphere_generate(&field.lithosphere, seed)
	field.sea_level = height_to_fixed(recipe.surface.sea_level)
	field.snow_level = height_to_fixed(recipe.surface.snow_level)
	_, logical, count_ok := info.cpu_core_count()
	if !count_ok do logical = 1
	worker_count := clamp(logical, 1, PLANET_FOUNDATION_MAX_WORKERS)
	jobs: [PLANET_FOUNDATION_MAX_WORKERS]Planet_Foundation_Job
	threads: [PLANET_FOUNDATION_MAX_WORKERS]^thread.Thread
	cells_per_worker := (PLANET_FIELD_CELLS + worker_count - 1) / worker_count
	spawned := 0
	for worker in 0 ..< worker_count {
		start := worker * cells_per_worker
		end := min(start + cells_per_worker, PLANET_FIELD_CELLS)
		if start >= end do break
		jobs[worker] = {
			field       = field,
			recipe      = &recipe,
			lithosphere = &field.lithosphere,
			start       = start,
			end         = end,
		}
		threads[worker] = thread.create_and_start_with_poly_data(&jobs[worker], _planet_foundation_range)
		if threads[worker] == nil do _planet_foundation_range(&jobs[worker])
		spawned = worker + 1
	}
	ok := true
	for worker in 0 ..< spawned {
		if threads[worker] != nil {
			thread.join(threads[worker])
			thread.destroy(threads[worker])
		}
		ok &&= jobs[worker].ok
	}
	if !ok do return false
	planet_foundation_mirror_edges(field)
	if !planet_terrain_relax(field) do return false
	if !planet_drainage_generate(field, seed) do return false
	planet_genesis_sea_level_solve(field)
	recipe.surface.sea_level = f32(field.sea_level) / f32(HEIGHT_DELTA_SCALE)
	planet_foundation_mirror_edges(field)
	if !planet_foundation_finalize(field, &recipe) do return false
	planet_foundation_mirror_edges(field)
	field.seed = seed
	return true
}

planet_foundation_publish_tectonic_tile :: proc(
	world: ^World,
	tectonics: ^Tectonic_State,
	tile: Planet_Sim_Coord,
) {
	assert(world != nil && tectonics != nil, "publish tectonic tile: nil input")
	assert(planet_sim_coord_valid(tile), "publish tectonic tile: invalid tile")
	tile_index := planet_sim_index(tile)
	displacement := tectonics_displacement_fixed(tectonics, tile_index)
	center := planet_sim_terrain_coord(tile)
	half := i32(PLANET_SIM_TERRAIN_STRIDE / 2)
	for offset_v in -half ..< i32(PLANET_SIM_TERRAIN_STRIDE) - half {
		for offset_u in -half ..< i32(PLANET_SIM_TERRAIN_STRIDE) - half {
			coord := planet_neighbour(center, offset_u, offset_v)
			index := planet_index(coord)
			horizontal := planet_sim_neighbour(tile, -1 if offset_u < 0 else 1, 0)
			vertical := planet_sim_neighbour(tile, 0, -1 if offset_v < 0 else 1)
			horizontal_weight := f64(abs(offset_u)) / f64(PLANET_SIM_TERRAIN_STRIDE)
			vertical_weight := f64(abs(offset_v)) / f64(PLANET_SIM_TERRAIN_STRIDE)
			diagonal_coord := planet_neighbour(center, (-1 if offset_u < 0 else 1) * i32(PLANET_SIM_TERRAIN_STRIDE), (-1 if offset_v < 0 else 1) * i32(PLANET_SIM_TERRAIN_STRIDE))
			diagonal := Planet_Sim_Coord{diagonal_coord.face, min(diagonal_coord.u / i32(PLANET_SIM_TERRAIN_STRIDE), PLANET_SIM_FACE_CELLS - 1), min(diagonal_coord.v / i32(PLANET_SIM_TERRAIN_STRIDE), PLANET_SIM_FACE_CELLS - 1)}
			smooth := f64(displacement) * (1 - horizontal_weight) * (1 - vertical_weight) +
				f64(tectonics_displacement_fixed(tectonics, planet_sim_index(horizontal))) * horizontal_weight * (1 - vertical_weight) +
				f64(tectonics_displacement_fixed(tectonics, planet_sim_index(vertical))) * vertical_weight * (1 - horizontal_weight) +
				f64(tectonics_displacement_fixed(tectonics, planet_sim_index(diagonal))) * horizontal_weight * vertical_weight
			world.foundation.tectonic_delta[index] = i16(clamp(i32(math.round(smooth)), i32(min(i16)), i32(max(i16))))
			world.foundation.plate_id[index] = tectonics.plate_id[tile_index]
			world.foundation.plate_crust[index] = tectonics.crust[tile_index]
			world.foundation.plate_boundary[index] = tectonics.boundary[tile_index]
			world.foundation.boundary_strength[index] = tectonics.boundary_strength[tile_index]
			_planet_foundation_mirror_cell(&world.foundation, coord)
		}
	}
}

planet_terrain_refresh_derived :: proc(world: ^World, tile: Planet_Sim_Coord) {
	field := &world.foundation
	center := planet_sim_terrain_coord(tile)
	half := i32(PLANET_SIM_TERRAIN_STRIDE / 2)
	recipe := planet_terrain_recipe(field.seed)
	recipe.surface.sea_level = f32(field.sea_level) / f32(HEIGHT_DELTA_SCALE)
	for vertical in -half - 1 ..= half + 1 {
		for horizontal in -half - 1 ..= half + 1 {
			coord := planet_neighbour(center, horizontal, vertical)
			index := planet_index(coord)
			left := planet_index(planet_neighbour(coord, -1, 0))
			right := planet_index(planet_neighbour(coord, 1, 0))
			down := planet_index(planet_neighbour(coord, 0, -1))
			up := planet_index(planet_neighbour(coord, 0, 1))
			dx := f32(i32(field.base_height[right]) + i32(field.tectonic_delta[right]) - i32(field.base_height[left]) - i32(field.tectonic_delta[left])) / (f32(HEIGHT_DELTA_SCALE) * 2 * recipe.parameters.derivative_step)
			dy := f32(i32(field.base_height[up]) + i32(field.tectonic_delta[up]) - i32(field.base_height[down]) - i32(field.tectonic_delta[down])) / (f32(HEIGHT_DELTA_SCALE) * 2 * recipe.parameters.derivative_step)
			slope := math.sqrt(dx * dx + dy * dy)
			field.slope[index] = u16(clamp(slope * TERRAIN_SLOPE_SCALE, f32(0), f32(max(u16))))
			landform := f32(i32(field.landform_height[index]) + i32(field.tectonic_delta[index])) / f32(HEIGHT_DELTA_SCALE)
			biomes, ok := procgen.terrain_biome_blend_prevalidated_v2(&recipe.surface, landform / recipe.parameters.height_scale, f32(field.continentalness[index]) / 255, f32(field.moisture[index]) / 255, f32(field.temperature[index]) / 255, slope)
			if ok {
				field.primary_biome[index] = Biome_Id(biomes.primary_id)
				field.secondary_biome[index] = Biome_Id(biomes.secondary_id)
				field.primary_weight[index] = _terrain_unit_to_u8(biomes.primary_weight)
			}
			radius := PLANET_RADIUS + f32(i32(field.base_height[index]) + i32(field.tectonic_delta[index])) / f32(HEIGHT_DELTA_SCALE)
			field.buildable[index] = radius >= recipe.parameters.minimum_radius && radius <= recipe.parameters.maximum_radius && 1 / math.sqrt(1 + slope * slope) >= recipe.parameters.minimum_upward_normal
			_planet_foundation_mirror_cell(field, coord)
		}
	}
}

tectonics_restore_foundation :: proc(world: ^World) {
	assert(world != nil, "tectonics_restore_foundation: nil world")
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		planet_foundation_publish_tectonic_tile(
			world,
			&world.planetary.tectonics,
			planet_sim_coord_for_index(index),
		)
	}
}

tectonics_publish_dirty_tiles :: proc(world: ^World) -> bool {
	assert(world != nil, "tectonics_publish_dirty_tiles: nil world")
	state := &world.planetary.tectonics
	original_count := int(state.dirty_count)
	for dirty_index in 0 ..< original_count {
		tile := planet_sim_coord_for_index(int(state.dirty_tiles[dirty_index]))
		center := planet_sim_terrain_coord(tile)
		for vertical in i32(-1) ..= 1 {
			for horizontal in i32(-1) ..= 1 {
				coord := planet_neighbour(center, horizontal * i32(PLANET_SIM_TERRAIN_STRIDE), vertical * i32(PLANET_SIM_TERRAIN_STRIDE))
				neighbour := planet_sim_index({coord.face, min(coord.u / i32(PLANET_SIM_TERRAIN_STRIDE), PLANET_SIM_FACE_CELLS - 1), min(coord.v / i32(PLANET_SIM_TERRAIN_STRIDE), PLANET_SIM_FACE_CELLS - 1)})
				if state.dirty_marks[neighbour] do continue
				state.dirty_marks[neighbour] = true
				state.dirty_tiles[state.dirty_count] = u32(neighbour)
				state.dirty_count += 1
			}
		}
	}
	for dirty_index in 0 ..< int(state.dirty_count) {
		tile := planet_sim_coord_for_index(int(state.dirty_tiles[dirty_index]))
		planet_foundation_publish_tectonic_tile(world, state, tile)
	}
	for dirty_index in 0 ..< int(state.dirty_count) {
		tile := planet_sim_coord_for_index(int(state.dirty_tiles[dirty_index]))
		planet_terrain_refresh_derived(world, tile)
		waterfield_terrain_changed_rect(
			world,
			planet_sim_terrain_coord(tile),
			i32(PLANET_SIM_TERRAIN_STRIDE),
		)
	}
	if state.dirty_count > 0 {
		world.foundation.tectonic_revision = state.revision
		state.published_revision = state.revision
	}
	for dirty_index in 0 ..< int(state.dirty_count) do state.dirty_marks[state.dirty_tiles[dirty_index]] = false
	state.dirty_count = 0
	return true
}

PLANET_RELAXATION_ITERATIONS :: 2
PLANET_RELAXATION_TALUS_FIXED :: i32(16)
PLANET_RELAXATION_TRANSFER_MAX :: i32(4)

planet_terrain_relax :: proc(field: ^Planet_Foundation) -> bool {
	assert(field != nil, "planet_terrain_relax: nil field")
	if len(field.relaxation_delta) != PLANET_FIELD_CELLS do return false
	for _ in 0 ..< PLANET_RELAXATION_ITERATIONS {
		for &delta in field.relaxation_delta do delta = 0
		for index in 0 ..< PLANET_FIELD_CELLS {
			face_cells := PLANET_FACE_RESOLUTION * PLANET_FACE_RESOLUTION
			face := procgen.Terrain_Face_V4(index / face_cells)
			local := index % face_cells
			coord := Planet_Coord{face, i32(local % PLANET_FACE_RESOLUTION), i32(local / PLANET_FACE_RESOLUTION)}
			if planet_canonical(coord) != coord do continue
			_planet_relax_cell(field, coord)
		}
		for delta, index in field.relaxation_delta {
			if delta == 0 do continue
			field.base_height[index] = i16(clamp(i32(field.base_height[index]) + delta, i32(min(i16)), i32(max(i16))))
			field.landform_height[index] = i16(clamp(i32(field.landform_height[index]) + delta, i32(min(i16)), i32(max(i16))))
		}
		planet_foundation_mirror_edges(field)
	}
	return true
}

@(private)
_planet_relax_cell :: proc(field: ^Planet_Foundation, coord: Planet_Coord) {
	assert(field != nil, "_planet_relax_cell: nil field")
	index := planet_index(coord)
	if field.boundary_strength[index] < 24 do return
	height := i32(field.base_height[index])
	best, best_height := coord, height
	neighbours := [?]Planet_Coord {
		planet_neighbour(coord, -1, 0),
		planet_neighbour(coord, 1, 0),
		planet_neighbour(coord, 0, -1),
		planet_neighbour(coord, 0, 1),
	}
	for neighbour in neighbours {
		candidate := planet_canonical(neighbour)
		candidate_height := i32(field.base_height[planet_index(candidate)])
		if candidate_height < best_height {
			best, best_height = candidate, candidate_height
		}
	}
	excess := height - best_height - PLANET_RELAXATION_TALUS_FIXED
	if excess <= 0 do return
	transfer := min(max(excess / 4, 1), PLANET_RELAXATION_TRANSFER_MAX)
	field.relaxation_delta[index] -= transfer
	field.relaxation_delta[planet_index(best)] += transfer
}

PLANET_DRAINAGE_FACE_CELLS :: 96
PLANET_DRAINAGE_STRIDE :: PLANET_FACE_CELLS / PLANET_DRAINAGE_FACE_CELLS
PLANET_DRAINAGE_CELLS :: PLANET_FACE_COUNT * PLANET_DRAINAGE_FACE_CELLS * PLANET_DRAINAGE_FACE_CELLS
PLANET_RIVER_ACCUMULATION_MIN :: u32(96)
PLANET_CHASM_ACCUMULATION_MIN :: u32(768)
#assert(PLANET_DRAINAGE_STRIDE * PLANET_DRAINAGE_FACE_CELLS == PLANET_FACE_CELLS)

@(private)
_planet_drainage_coord :: proc(index: int) -> Planet_Coord {
	per_face := PLANET_DRAINAGE_FACE_CELLS * PLANET_DRAINAGE_FACE_CELLS
	face := procgen.Terrain_Face_V4(index / per_face)
	local := index % per_face
	u := local % PLANET_DRAINAGE_FACE_CELLS
	v := local / PLANET_DRAINAGE_FACE_CELLS
	return {face, i32(u * PLANET_DRAINAGE_STRIDE + PLANET_DRAINAGE_STRIDE / 2), i32(v * PLANET_DRAINAGE_STRIDE + PLANET_DRAINAGE_STRIDE / 2)}
}

@(private)
_planet_drainage_index :: proc(coord: Planet_Coord) -> int {
	face, u, v := planet_locate(planet_direction(coord))
	column := clamp(int(u) / PLANET_DRAINAGE_STRIDE, 0, PLANET_DRAINAGE_FACE_CELLS - 1)
	row := clamp(int(v) / PLANET_DRAINAGE_STRIDE, 0, PLANET_DRAINAGE_FACE_CELLS - 1)
	per_face := PLANET_DRAINAGE_FACE_CELLS * PLANET_DRAINAGE_FACE_CELLS
	return int(face) * per_face + row * PLANET_DRAINAGE_FACE_CELLS + column
}

@(private)
_planet_drainage_carve :: proc(field: ^Planet_Foundation, coord: Planet_Coord, strength: u8, chasm: bool) {
	radius := i32(1 + int(strength) / 96)
	depth := i32(1 + int(strength) / 72)
	if chasm {
		radius = 2
		depth += 5
	}
	for dv in -radius ..= radius {
		for du in -radius ..= radius {
			distance := abs(du) + abs(dv)
			if distance > radius do continue
			target := planet_neighbour(coord, du, dv)
			index := planet_index(target)
			carve := max(depth * (radius + 1 - distance) / (radius + 1), 1)
			field.base_height[index] = i16(max(i32(field.base_height[index]) - carve, i32(min(i16))))
			field.river_strength[index] = max(field.river_strength[index], strength)
			if chasm do field.chasm_strength[index] = max(field.chasm_strength[index], strength)
			field.buildable[index] = false
		}
	}
}

planet_drainage_generate :: proc(field: ^Planet_Foundation, seed: u64) -> bool {
	assert(field != nil, "planet_drainage_generate: nil field")
	if len(field.river_strength) != PLANET_FIELD_CELLS do return false
	for index in 0 ..< PLANET_FIELD_CELLS {
		field.river_strength[index] = 0
		field.chasm_strength[index] = 0
	}
	downstream := make([]i32, PLANET_DRAINAGE_CELLS, context.temp_allocator)
	indegree := make([]u8, PLANET_DRAINAGE_CELLS, context.temp_allocator)
	accumulation := make([]u32, PLANET_DRAINAGE_CELLS, context.temp_allocator)
	queue := make([]i32, PLANET_DRAINAGE_CELLS, context.temp_allocator)
	for index in 0 ..< PLANET_DRAINAGE_CELLS {
		coord := _planet_drainage_coord(index)
		height := field.base_height[planet_index(coord)]
		best := index
		best_height := height
		neighbours := [?]Planet_Coord {
			planet_neighbour(coord, -PLANET_DRAINAGE_STRIDE, 0),
			planet_neighbour(coord, PLANET_DRAINAGE_STRIDE, 0),
			planet_neighbour(coord, 0, -PLANET_DRAINAGE_STRIDE),
			planet_neighbour(coord, 0, PLANET_DRAINAGE_STRIDE),
		}
		for neighbour in neighbours {
			candidate := _planet_drainage_index(neighbour)
			candidate_coord := _planet_drainage_coord(candidate)
			candidate_height := field.base_height[planet_index(candidate_coord)]
			if candidate_height < best_height ||
			   (candidate_height == best_height && candidate < best && ((seed ~ u64(index)) & 1) == 0) {
				best = candidate
				best_height = candidate_height
			}
		}
		downstream[index] = i32(best)
		accumulation[index] = 1
		if best != index do indegree[best] += 1
	}
	head, tail := 0, 0
	for value, index in indegree {
		if value == 0 {
			queue[tail] = i32(index)
			tail += 1
		}
	}
	for head < tail {
		index := int(queue[head])
		head += 1
		target := int(downstream[index])
		if target == index do continue
		accumulation[target] += accumulation[index]
		indegree[target] -= 1
		if indegree[target] == 0 {
			queue[tail] = i32(target)
			tail += 1
		}
	}
	for accumulation_value, index in accumulation {
		coord := _planet_drainage_coord(index)
		terrain_index := planet_index(coord)
		if accumulation_value < PLANET_RIVER_ACCUMULATION_MIN do continue
		if field.base_height[terrain_index] <= field.sea_level do continue
		strength := u8(clamp(i32(accumulation_value / 8), 32, 255))
		chasm := accumulation_value >= PLANET_CHASM_ACCUMULATION_MIN && field.ruggedness[terrain_index] >= 160
		target := _planet_drainage_coord(int(downstream[index]))
		for segment in 0 ..= PLANET_DRAINAGE_STRIDE {
			t := f32(segment) / f32(PLANET_DRAINAGE_STRIDE)
			direction := _planet_normalize(planet_direction(coord) * (1 - t) + planet_direction(target) * t)
			face, u, v := planet_locate(direction)
			point := Planet_Coord{face, i32(clamp(u + 0.5, 0, f32(PLANET_FACE_CELLS))), i32(clamp(v + 0.5, 0, f32(PLANET_FACE_CELLS)))}
			_planet_drainage_carve(field, point, strength, chasm)
		}
	}
	return true
}

planet_foundation_mirror_edges :: proc(field: ^Planet_Foundation) {
	assert(field != nil, "planet_foundation_mirror_edges: nil field")
	last := i32(PLANET_FACE_CELLS)
	for face in procgen.Terrain_Face_V4 {
		for u in i32(0) ..= last {
			_planet_foundation_mirror_cell(field, {face, u, 0})
			_planet_foundation_mirror_cell(field, {face, u, last})
		}
		for v in i32(1) ..< last {
			_planet_foundation_mirror_cell(field, {face, 0, v})
			_planet_foundation_mirror_cell(field, {face, last, v})
		}
	}
}

@(private)
_planet_foundation_mirror_cell :: proc(field: ^Planet_Foundation, coord: Planet_Coord) {
	canonical := planet_canonical(coord)
	if canonical != coord do return
	source := planet_index(coord)
	duplicates, count := planet_duplicates(coord)
	for duplicate_index in 0 ..< count {
		target := planet_index(duplicates[duplicate_index])
		field.base_height[target] = field.base_height[source]
		field.landform_height[target] = field.landform_height[source]
		field.moisture[target] = field.moisture[source]
		field.temperature[target] = field.temperature[source]
		field.continentalness[target] = field.continentalness[source]
		field.ruggedness[target] = field.ruggedness[source]
		field.slope[target] = field.slope[source]
		field.plate_id[target] = field.plate_id[source]
		field.plate_crust[target] = field.plate_crust[source]
		field.plate_boundary[target] = field.plate_boundary[source]
		field.boundary_strength[target] = field.boundary_strength[source]
		field.tectonic_delta[target] = field.tectonic_delta[source]
		field.primary_biome[target] = field.primary_biome[source]
		field.secondary_biome[target] = field.secondary_biome[source]
		field.primary_weight[target] = field.primary_weight[source]
		field.river_strength[target] = field.river_strength[source]
		field.chasm_strength[target] = field.chasm_strength[source]
		field.buildable[target] = field.buildable[source]
	}
}
