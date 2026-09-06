package shared

import "core:math"
import "core:mem"
import procgen "ingot:procgen"

TERRAIN_SEED :: u64(0x7E44A_F0463)
TERRAIN_RECIPE_VERSION :: procgen.TERRAIN_RECIPE_VERSION_V3
// The archetype makes an appropriate spawn likely rather than rare, so a
// large rejection budget no longer buys diversity. The old 16384 bought the
// opposite: it selected hard on one narrow condition -- the centre cell's
// biome -- while leaving every other property of the world identical.
TERRAIN_SEED_SEARCH_LIMIT :: 512
// Sixty chunks, a 3840-unit world. Province-scale biomes need somewhere to
// be: at the previous 2560 units an 800-unit landmass touched three edges, so
// growing the noise wavelengths alone would have produced one province and a
// rim of ocean rather than several places to travel between.
WORLD_CHUNKS :: 60
WORLD_CHUNK_SIZE :: 64
WORLD_CHUNK_MIN :: i32(-WORLD_CHUNKS / 2)
WORLD_CHUNK_MAX :: i32(WORLD_CHUNKS / 2 - 1)
WORLD_HALF_SIZE :: f32(WORLD_CHUNKS * WORLD_CHUNK_SIZE) / 2
WORLD_SIZE :: 2 * WORLD_HALF_SIZE
PLACEMENT_MAX_SLOPE :: f32(0.55)
TERRAIN_FIELD_CELLS :: HEIGHTFIELD_RESOLUTION * HEIGHTFIELD_RESOLUTION
// A province, not a hamlet. At GRID_CELL_SIZE this is roughly a 350-unit
// patch: large enough that walking across one is a journey, and large enough
// that the merge pass genuinely enforces provinces instead of only erasing
// specks. The former 1600 was an 80-unit patch -- a tenth of a percent of the
// world -- which is why biomes read as a mottle however good the noise was.
TERRAIN_BIOME_MINIMUM_CELLS :: 24_000
// Probes around the world center used to confirm the seed's biome owns a
// patch that survives region merging. Eight covers the diagonals, which is
// where a wedge-shaped sliver would otherwise slip through.
TERRAIN_CENTER_PROBE_COUNT :: 8
TERRAIN_SLOPE_SCALE :: f32(256)
TERRAIN_MOUNTAIN_TERRACE_STRENGTH :: f32(0)
// The default lapse rate costs a peak more than half its temperature range,
// which turns every highland into tundra and starves the hot biomes. A gentler
// rate still cools mountains without erasing the archetype's climate centre.
TERRAIN_ELEVATION_LAPSE :: f32(0.006)
// Basins carve inland depressions below sea level; waterfield_initialize then
// floods them, which is the whole of the lake feature. The threshold, depth
// and wavelength come from the archetype; the fade is shared because it only
// controls how abrupt the shoreline is.
TERRAIN_BASIN_FADE :: f32(0.1)
TERRAIN_COAST_FADE :: f32(0.1)

// Ordered from water through open ground to high rock. Ocean and Lake are
// distinguished only by continentalness, which is why the profile table needs
// that axis at all.
Biome_Id :: enum u8 {
	Ocean,
	Lake,
	Coast,
	Wetland,
	Grassland,
	Savannah,
	Forest,
	Taiga,
	Desert,
	Tundra,
	Snowlands,
	Mountain,
}

Terrain_Sample :: struct {
	height:          f32,
	moisture:        f32,
	temperature:     f32,
	continentalness: f32,
	ruggedness:      f32,
	slope:           f32,
	primary_biome:   Biome_Id,
	secondary_biome: Biome_Id,
	primary_weight:  f32,
}

Foundation_Field :: struct {
	version:         u32,
	profile_id:      u32,
	seed:            u64,
	sea_level:       i16,
	snow_level:      i16,
	base_height:     []i16,
	moisture:        []u8,
	temperature:     []u8,
	continentalness: []u8,
	ruggedness:      []u8,
	slope:           []u16,
	primary_biome:   []Biome_Id,
	secondary_biome: []Biome_Id,
	primary_weight:  []u8,
	biome_patch_id:  []u32,
	buildable:       []bool,
}

Foundation_Biome_Scratch :: struct {
	raw:               []procgen.Terrain_Biome_Blend_V2,
	resolved:          []procgen.Terrain_Biome_Blend_V2,
	labels:            []u32,
	queue:             []u32,
	component_sizes:   []u32,
	component_ids:     []u16,
	merge_targets:     []u32,
	component_offsets: []u32,
	component_cells:   []u32,
}

foundation_init :: proc(field: ^Foundation_Field, allocator := context.allocator) {
	assert(field != nil, "foundation_init: nil field")
	field^ = {}
	field.base_height = make([]i16, TERRAIN_FIELD_CELLS, allocator)
	field.moisture = make([]u8, TERRAIN_FIELD_CELLS, allocator)
	field.temperature = make([]u8, TERRAIN_FIELD_CELLS, allocator)
	field.continentalness = make([]u8, TERRAIN_FIELD_CELLS, allocator)
	field.ruggedness = make([]u8, TERRAIN_FIELD_CELLS, allocator)
	field.slope = make([]u16, TERRAIN_FIELD_CELLS, allocator)
	field.primary_biome = make([]Biome_Id, TERRAIN_FIELD_CELLS, allocator)
	field.secondary_biome = make([]Biome_Id, TERRAIN_FIELD_CELLS, allocator)
	field.primary_weight = make([]u8, TERRAIN_FIELD_CELLS, allocator)
	field.biome_patch_id = make([]u32, TERRAIN_FIELD_CELLS, allocator)
	field.buildable = make([]bool, TERRAIN_FIELD_CELLS, allocator)
}

foundation_reset :: proc(field: ^Foundation_Field) {
	assert(field != nil, "foundation_reset: nil field")
	field.version = 0
	field.profile_id = 0
	field.seed = 0
	field.sea_level = 0
	field.snow_level = 0
	mem.zero_slice(field.base_height)
	mem.zero_slice(field.moisture)
	mem.zero_slice(field.temperature)
	mem.zero_slice(field.continentalness)
	mem.zero_slice(field.ruggedness)
	mem.zero_slice(field.slope)
	mem.zero_slice(field.primary_biome)
	mem.zero_slice(field.secondary_biome)
	mem.zero_slice(field.primary_weight)
	mem.zero_slice(field.biome_patch_id)
	mem.zero_slice(field.buildable)
}

foundation_deinit :: proc(field: ^Foundation_Field, allocator := context.allocator) {
	assert(field != nil, "foundation_deinit: nil field")
	delete(field.buildable, allocator)
	delete(field.biome_patch_id, allocator)
	delete(field.primary_weight, allocator)
	delete(field.secondary_biome, allocator)
	delete(field.primary_biome, allocator)
	delete(field.slope, allocator)
	delete(field.ruggedness, allocator)
	delete(field.continentalness, allocator)
	delete(field.temperature, allocator)
	delete(field.moisture, allocator)
	delete(field.base_height, allocator)
	field^ = {}
}

terrain_surface_recipe :: proc(seed: u64) -> procgen.Terrain_Recipe_V2 {
	return terrain_surface_recipe_for(terrain_archetype(seed), seed)
}

// terrain_surface_recipe_for builds a surface of a named kind from a layout
// seed. The split exists for the spawn search, which needs many layouts of one
// archetype rather than many archetypes.
terrain_surface_recipe_for :: proc(
	archetype: Terrain_Archetype,
	layout_seed: u64,
) -> procgen.Terrain_Recipe_V2 {
	recipe := procgen.terrain_default_recipe_v2(layout_seed)
	recipe.latitude_half_extent = WORLD_HALF_SIZE
	recipe.elevation_lapse = TERRAIN_ELEVATION_LAPSE
	recipe.coast_fade = TERRAIN_COAST_FADE
	recipe.basin_fade = TERRAIN_BASIN_FADE
	// The archetype owns everything that describes what kind of world this
	// is, so it runs after the shared constants and overrides them. The biome
	// table reads none of what it writes, so ordering between them is free --
	// but authoring the table first would read as if it did.
	terrain_archetype_apply(&recipe, archetype, layout_seed)
	recipe.biome_profile_count = u8(len(Biome_Id))
	recipe.fallback_profile_index = u8(Biome_Id.Grassland)
	_terrain_biome_profiles(&recipe)
	return recipe
}

// _terrain_biome_profiles authors the twelve-biome table. Axis order is
// landform height, continentalness, moisture, temperature, landform slope.
// Priority breaks ties between profiles that score equally, so water and rock
// outrank open ground.
//
// The windows are authored against the landform surface, which is the whole
// reason they can be narrow. On the full height a flat plain carried +/-6
// units of hill noise and a slope near 0.44, so every window had to be wide
// enough to swallow that -- which is what let a montane profile claim a bump
// in the middle of a prairie. On landform an interior plain sits within a unit
// or two of land_height with a slope near zero, so height genuinely means
// elevation again.
@(private)
_terrain_biome_profiles :: proc(recipe: ^procgen.Terrain_Recipe_V2) {
	assert(recipe != nil, "_terrain_biome_profiles: nil recipe")
	assert(int(recipe.biome_profile_count) == len(Biome_Id), "biome profile count mismatch")
	wide := procgen.Terrain_Range_V2{-10000, 10000, 1}
	unit := procgen.Terrain_Range_V2{0, 1, 0.2}
	// Ocean and Lake share a height window and split on continentalness
	// alone, so their fade is tight enough to make the choice decisive.
	recipe.biome_profiles[int(Biome_Id.Ocean)] = {
		u16(Biome_Id.Ocean),
		9,
		4,
		{-10000, -2, 1.5},
		{0, 0.6, 0.06},
		unit,
		unit,
		wide,
	}
	recipe.biome_profiles[int(Biome_Id.Lake)] = {
		u16(Biome_Id.Lake),
		9,
		4,
		{-10000, -2, 1.5},
		{0.58, 1, 0.06},
		unit,
		unit,
		wide,
	}
	recipe.biome_profiles[int(Biome_Id.Coast)] = {
		u16(Biome_Id.Coast),
		8,
		2.5,
		{-2, 2, 1.5},
		wide,
		unit,
		{0.15, 1, 0.12},
		{0, 0.4, 0.2},
	}
	// Marshland, not merely damp ground. The moisture floor is high and the
	// weight modest because a wet *world* should read as forest with marshes
	// in its hollows, not as one continuous swamp.
	recipe.biome_profiles[int(Biome_Id.Wetland)] = {
		u16(Biome_Id.Wetland),
		6,
		1.25,
		{-1, 6, 2},
		wide,
		{0.8, 1, 0.07},
		{0.3, 0.9, 0.12},
		{0, 0.1, 0.08},
	}
	// The default ground cover, so it carries the widest climate windows and
	// a weight that lets it actually win them. Authored narrow and light, it
	// lost every mid-range cell to a specialised profile with a heavier
	// weight, and a world with no plains reads as a collection of extremes.
	recipe.biome_profiles[int(Biome_Id.Grassland)] = {
		u16(Biome_Id.Grassland),
		1,
		1.3,
		{0, 16, 4},
		wide,
		{0.3, 0.74, 0.16},
		{0.32, 0.76, 0.16},
		{0, 0.3, 0.2},
	}
	recipe.biome_profiles[int(Biome_Id.Savannah)] = {
		u16(Biome_Id.Savannah),
		2,
		1.25,
		{0, 15, 4},
		wide,
		{0.15, 0.44, 0.12},
		{0.62, 1, 0.14},
		{0, 0.3, 0.2},
	}
	recipe.biome_profiles[int(Biome_Id.Forest)] = {
		u16(Biome_Id.Forest),
		2,
		1.35,
		{0, 18, 4},
		wide,
		{0.52, 1, 0.14},
		{0.4, 0.86, 0.14},
		{0, 0.3, 0.2},
	}
	recipe.biome_profiles[int(Biome_Id.Taiga)] = {
		u16(Biome_Id.Taiga),
		3,
		1.35,
		{1, 22, 5},
		wide,
		{0.42, 1, 0.14},
		{0.14, 0.44, 0.12},
		{0, 0.32, 0.2},
	}
	// True sand sea. The window is deliberately tight: authored wide and
	// heavy it claimed every merely dry cell, so temperate worlds grew
	// deserts and the archetype that is supposed to own them lost its
	// signature.
	recipe.biome_profiles[int(Biome_Id.Desert)] = {
		u16(Biome_Id.Desert),
		3,
		1.2,
		{-1, 15, 4},
		wide,
		{0, 0.2, 0.09},
		{0.5, 1, 0.14},
		{0, 0.32, 0.2},
	}
	recipe.biome_profiles[int(Biome_Id.Tundra)] = {
		u16(Biome_Id.Tundra),
		3,
		1.3,
		{0, 18, 4},
		wide,
		{0, 0.5, 0.16},
		{0.08, 0.34, 0.12},
		{0, 0.32, 0.2},
	}
	// Cold high ground. The height floor is what stops a cold *world* from
	// classifying its plains as snowfield: on landform an interior plain
	// sits near land_height, so a floor above that is unreachable without
	// real uplift under it.
	recipe.biome_profiles[int(Biome_Id.Snowlands)] = {
		u16(Biome_Id.Snowlands),
		5,
		1.9,
		{15, 10000, 5},
		wide,
		unit,
		{0, 0.3, 0.12},
		wide,
	}
	// Bare rock, not merely high ground: the slope floor is what keeps
	// Mountain from swallowing every highland, and Snowlands owns the
	// cold-and-high role above. The floor is far below the old 0.62 because
	// landform slope no longer carries hill noise -- on the full height a
	// single 71-unit bump already reached 0.44, so that threshold was
	// measuring roughness rather than relief.
	recipe.biome_profiles[int(Biome_Id.Mountain)] = {
		u16(Biome_Id.Mountain),
		7,
		1.9,
		{21, 10000, 5},
		wide,
		unit,
		unit,
		{0.26, 10000, 0.16},
	}
}

terrain_recipe :: proc(seed: u64) -> procgen.Terrain_Recipe_V3 {
	return terrain_recipe_for(terrain_archetype(seed), seed)
}

terrain_recipe_for :: proc(
	archetype: Terrain_Archetype,
	layout_seed: u64,
) -> procgen.Terrain_Recipe_V3 {
	recipe := procgen.terrain_abstract_recipe_v3(layout_seed)
	recipe.surface = terrain_surface_recipe_for(archetype, layout_seed)
	recipe.parameters.mountain_scale = TERRAIN_MOUNTAIN_SCALE
	recipe.parameters.mountain_sharpness = TERRAIN_MOUNTAIN_SHARPNESS
	recipe.parameters.mountain_terrace_strength = TERRAIN_MOUNTAIN_TERRACE_STRENGTH
	recipe.parameters.floating_spacing = TERRAIN_FLOATING_SPACING
	recipe.parameters.floating_radius = TERRAIN_FLOATING_RADIUS
	recipe.parameters.floating_thickness = TERRAIN_FLOATING_THICKNESS
	recipe.parameters.floating_breakup = TERRAIN_FLOATING_BREAKUP
	// Model-specific recipe tuning (cave/volume bands, search windows)
	// lives in each demo's _terrain_recipe_model_tune.
	_terrain_recipe_model_tune(&recipe.parameters)
	recipe.parameters.minimum_upward_normal = 0.42
	return recipe
}

terrain_seed_spawn_biomes :: proc(seed: u64) -> bit_set[Biome_Id] {
	return terrain_archetype_spawn_biomes(terrain_archetype(seed))
}

// _terrain_spawn_province_holds tests whether a province-scale patch of an
// archetype-appropriate biome sits under the world center.
//
// Two things are being checked at once, and both matter. The center must be a
// biome this kind of world can start a player in -- spawning on a glacier in
// a rainforest world is a bug, not variety. And the patch must be large
// enough to survive region resolution: TERRAIN_BIOME_MINIMUM_CELLS merges any
// component below it into a neighbour, so a seed whose center matched but sat
// in a sliver would have its center reassigned by that merge. Probing a ring
// at the patch radius is a cheap proxy for surviving the merge, and costs
// nine samples instead of a full field bake per candidate.
@(private)
_terrain_spawn_province_holds :: proc(
	recipe: ^procgen.Terrain_Recipe_V3,
	allowed: bit_set[Biome_Id],
) -> bool {
	assert(recipe != nil, "_terrain_spawn_province_holds: nil recipe")
	assert(TERRAIN_BIOME_MINIMUM_CELLS > 0, "_terrain_spawn_province_holds: degenerate minimum")
	assert(allowed != {}, "_terrain_spawn_province_holds: empty spawn set")
	center, center_ok := procgen.terrain_primary_surface_prevalidated_v3(
		recipe,
		0,
		0,
		GRID_CELL_SIZE,
	)
	if !center_ok do return false
	target := Biome_Id(center.biomes.primary_id)
	if target not_in allowed do return false
	// A disc holding TERRAIN_BIOME_MINIMUM_CELLS cells, each covering
	// GRID_CELL_SIZE squared, has this radius. Every probe must match the
	// center: a ring that only partly agrees is exactly the sliver the merge
	// pass erases.
	area := f32(TERRAIN_BIOME_MINIMUM_CELLS) * GRID_CELL_SIZE * GRID_CELL_SIZE
	radius := math.sqrt(area / math.PI)
	for index in 0 ..< TERRAIN_CENTER_PROBE_COUNT {
		angle := f32(index) * 2 * math.PI / f32(TERRAIN_CENTER_PROBE_COUNT)
		sample, ok := procgen.terrain_primary_surface_prevalidated_v3(
			recipe,
			math.cos(angle) * radius,
			math.sin(angle) * radius,
			GRID_CELL_SIZE,
		)
		if !ok do return false
		if Biome_Id(sample.biomes.primary_id) != target do return false
	}
	return true
}

terrain_resolved_seed :: proc(seed: u64) -> (resolved: u64, ok: bool) {
	// The archetype comes from the requested seed and is held fixed across
	// the search: rejecting a candidate must move the world's layout, not its
	// kind, or the search would quietly steer every world toward whichever
	// archetypes spawn most easily.
	archetype := terrain_archetype(seed)
	allowed := terrain_archetype_spawn_biomes(archetype)
	for attempt in 0 ..< TERRAIN_SEED_SEARCH_LIMIT {
		candidate := _terrain_seed_hash(seed, u64(attempt))
		recipe := terrain_recipe_for(archetype, candidate)
		if !procgen.terrain_recipe_validate_v3(&recipe) do return 0, false
		if _terrain_spawn_province_holds(&recipe, allowed) do return candidate, true
	}
	return 0, false
}

terrain_resolved_recipe :: proc(seed: u64) -> (recipe: procgen.Terrain_Recipe_V3, ok: bool) {
	resolved, resolved_ok := terrain_resolved_seed(seed)
	if !resolved_ok do return {}, false
	recipe = terrain_recipe_for(terrain_archetype(seed), resolved)
	return recipe, procgen.terrain_recipe_validate_v3(&recipe)
}

terrain_config :: proc() -> procgen.Terrain_Config {
	return procgen.terrain_default_config(TERRAIN_SEED)
}

terrain_base_height :: proc(world_x, world_y: f32) -> f32 {
	recipe := terrain_recipe(TERRAIN_SEED)
	sample, ok := procgen.terrain_primary_surface_v3(&recipe, world_x, world_y, GRID_CELL_SIZE)
	assert(ok, "terrain_base_height: generation failed")
	return sample.height
}

terrain_sample_config :: proc(
	config: procgen.Terrain_Config,
	world_x, world_y: f32,
) -> procgen.Terrain_Sample {
	height := terrain_base_height(world_x, world_y)
	step := GRID_CELL_SIZE
	height_x := terrain_base_height(world_x + step, world_y)
	height_y := terrain_base_height(world_x, world_y + step)
	moisture := clamp(
		procgen.fractal_2d(config.moisture_noise, world_x, world_y) * 0.5 + 0.5,
		0,
		1,
	)
	temperature := clamp(
		procgen.fractal_2d(config.temperature_noise, world_x, world_y) * 0.5 + 0.5,
		0,
		1,
	)
	slope :=
		math.sqrt(
			(height_x - height) * (height_x - height) + (height_y - height) * (height_y - height),
		) /
		step
	return {
		height,
		moisture,
		temperature,
		slope,
		procgen.terrain_biome(config, height, moisture, temperature, slope),
	}
}

foundation_generate :: proc(
	field: ^Foundation_Field,
	seed: u64,
	allocator := context.allocator,
) -> bool {
	assert(field != nil, "foundation_generate: nil field")
	assert(len(field.base_height) == TERRAIN_FIELD_CELLS, "foundation_generate: storage size")
	recipe, recipe_ok := terrain_resolved_recipe(seed)
	if !recipe_ok do return false
	foundation_reset(field)
	biome_scratch := Foundation_Biome_Scratch {
		raw               = make([]procgen.Terrain_Biome_Blend_V2, TERRAIN_FIELD_CELLS, allocator),
		resolved          = make([]procgen.Terrain_Biome_Blend_V2, TERRAIN_FIELD_CELLS, allocator),
		labels            = make([]u32, TERRAIN_FIELD_CELLS, allocator),
		queue             = make([]u32, TERRAIN_FIELD_CELLS, allocator),
		component_sizes   = make([]u32, TERRAIN_FIELD_CELLS, allocator),
		component_ids     = make([]u16, TERRAIN_FIELD_CELLS, allocator),
		merge_targets     = make([]u32, TERRAIN_FIELD_CELLS, allocator),
		// The offset table is a prefix sum over components, so it needs one
		// slot past the last of them.
		component_offsets = make([]u32, TERRAIN_FIELD_CELLS + 1, allocator),
		component_cells   = make([]u32, TERRAIN_FIELD_CELLS, allocator),
	}
	defer delete(biome_scratch.component_cells, allocator)
	defer delete(biome_scratch.component_offsets, allocator)
	defer delete(biome_scratch.merge_targets, allocator)
	defer delete(biome_scratch.component_ids, allocator)
	defer delete(biome_scratch.component_sizes, allocator)
	defer delete(biome_scratch.queue, allocator)
	defer delete(biome_scratch.labels, allocator)
	defer delete(biome_scratch.resolved, allocator)
	defer delete(biome_scratch.raw, allocator)
	if !_foundation_rows_generate(field, &recipe, biome_scratch.raw) do return false
	if !_foundation_biomes_resolve(field, &recipe.surface, &biome_scratch) do return false
	field.version = recipe.version
	field.profile_id = TERRAIN_PROFILE_ID
	field.seed = seed
	field.sea_level = height_to_fixed(recipe.surface.sea_level)
	field.snow_level = height_to_fixed(recipe.surface.snow_level)
	return true
}

// _foundation_rows_generate fills the analytic per-cell foundation data; the
// implementation lives in terrain_rows_parallel.odin (worker threads on
// native) and terrain_rows_serial.odin (JS). Both produce bit-identical
// output, keeping the sim deterministic.

@(private)
_foundation_row_range :: proc(
	field: ^Foundation_Field,
	recipe: ^procgen.Terrain_Recipe_V3,
	raw_biomes: []procgen.Terrain_Biome_Blend_V2,
	row_start, row_end: int,
) -> bool {
	for row in row_start ..< row_end {
		world_y := -WORLD_HALF_SIZE + f32(row) * GRID_CELL_SIZE
		for column in 0 ..< HEIGHTFIELD_RESOLUTION {
			world_x := -WORLD_HALF_SIZE + f32(column) * GRID_CELL_SIZE
			// The recipe was validated once by terrain_resolved_recipe; the
			// prevalidated sampler skips ~10 redundant full-recipe
			// validations per cell across this 1.6M-cell bake.
			sample, ok := procgen.terrain_primary_surface_prevalidated_v3(
				recipe,
				world_x,
				world_y,
				GRID_CELL_SIZE,
			)
			if !ok do return false
			index := row * HEIGHTFIELD_RESOLUTION + column
			field.base_height[index] = height_to_fixed(sample.height)
			field.moisture[index] = _terrain_unit_to_u8(sample.moisture)
			field.temperature[index] = _terrain_unit_to_u8(sample.temperature)
			field.continentalness[index] = _terrain_unit_to_u8(sample.continentalness)
			field.ruggedness[index] = _terrain_unit_to_u8(sample.ruggedness)
			field.slope[index] = u16(clamp(sample.slope * TERRAIN_SLOPE_SCALE, 0, f32(max(u16))))
			raw_biomes[index] = sample.biomes
			field.buildable[index] = sample.buildable
		}
	}
	return true
}

@(private)
_foundation_biomes_resolve :: proc(
	field: ^Foundation_Field,
	recipe: ^procgen.Terrain_Recipe_V2,
	scratch: ^Foundation_Biome_Scratch,
) -> bool {
	assert(field != nil && recipe != nil, "foundation biome resolve input")
	assert(scratch != nil, "foundation biome resolve scratch")
	protected := [?]u16{u16(Biome_Id.Ocean), u16(Biome_Id.Lake), u16(Biome_Id.Coast)}
	request := procgen.Terrain_Biome_Region_Request {
		HEIGHTFIELD_RESOLUTION,
		HEIGHTFIELD_RESOLUTION,
		TERRAIN_BIOME_MINIMUM_CELLS,
		protected[:],
	}
	output := procgen.Terrain_Biome_Region_Output{scratch.resolved[:], field.biome_patch_id[:]}
	region_scratch := procgen.Terrain_Biome_Region_Scratch {
		scratch.labels[:],
		scratch.queue[:],
		scratch.component_sizes[:],
		scratch.component_ids[:],
		scratch.merge_targets[:],
		scratch.component_offsets[:],
		scratch.component_cells[:],
	}
	if !procgen.terrain_resolve_biome_regions(
		recipe,
		request,
		scratch.raw[:],
		output,
		region_scratch,
	) {
		return false
	}
	for blend, index in scratch.resolved {
		field.primary_biome[index] = Biome_Id(blend.primary_id)
		field.secondary_biome[index] = Biome_Id(blend.primary_id)
		field.primary_weight[index] = 255
	}
	return true
}

