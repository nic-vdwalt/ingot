package procgen

TERRAIN_BIOME_REGION_MAX_EDGE :: 2048
TERRAIN_BIOME_REGION_MAX_CELLS :: TERRAIN_BIOME_REGION_MAX_EDGE * TERRAIN_BIOME_REGION_MAX_EDGE
TERRAIN_BIOME_REGION_PASS_MAX :: TERRAIN_BIOME_PROFILE_MAX_V2
// Four-connectivity, in the order the flood fill has always visited them, so
// component labels are unchanged by the switch to a table.
TERRAIN_BIOME_REGION_NEIGHBORS :: [4][2]int{{-1, 0}, {1, 0}, {0, -1}, {0, 1}}

Terrain_Biome_Region_Request :: struct {
	width:         int,
	height:        int,
	minimum_cells: int,
	protected_ids: []u16,
}

Terrain_Biome_Region_Output :: struct {
	biomes:    []Terrain_Biome_Blend_V2,
	patch_ids: []u32,
}

Terrain_Biome_Region_Scratch :: struct {
	labels:            []u32,
	queue:             []u32,
	component_sizes:   []u32,
	component_ids:     []u16,
	merge_targets:     []u32,
	component_offsets: []u32,
	component_cells:   []u32,
}

terrain_resolve_biome_regions :: proc(
	recipe: ^Terrain_Recipe_V2,
	request: Terrain_Biome_Region_Request,
	raw: []Terrain_Biome_Blend_V2,
	output: Terrain_Biome_Region_Output,
	scratch: Terrain_Biome_Region_Scratch,
) -> bool {
	assert(recipe != nil, "terrain_resolve_biome_regions: nil recipe")
	cells, ok := _terrain_biome_region_validate(recipe, request, raw, output, scratch)
	if !ok do return false
	for index in 0 ..< cells {
		id := raw[index].primary_id
		output.biomes[index] = {id, id, 1}
	}
	for _ in 0 ..< TERRAIN_BIOME_REGION_PASS_MAX {
		components := _terrain_biome_region_label(request, output.biomes, scratch)
		_terrain_biome_region_bucket(request, scratch, components)
		merges := _terrain_biome_region_choose_merges(recipe, request, scratch, components)
		if merges == 0 do break
		for index in 0 ..< cells {
			component := scratch.labels[index] - 1
			target := scratch.merge_targets[component]
			if target == 0 do continue
			id := scratch.component_ids[target - 1]
			output.biomes[index] = {id, id, 1}
		}
	}
	components := _terrain_biome_region_label(request, output.biomes, scratch)
	assert(components > 0 && components <= cells, "biome region component count")
	for index in 0 ..< cells do output.patch_ids[index] = scratch.labels[index]
	return true
}

@(private)
_terrain_biome_region_validate :: proc(
	recipe: ^Terrain_Recipe_V2,
	request: Terrain_Biome_Region_Request,
	raw: []Terrain_Biome_Blend_V2,
	output: Terrain_Biome_Region_Output,
	scratch: Terrain_Biome_Region_Scratch,
) -> (
	int,
	bool,
) {
	if !terrain_recipe_validate_v2(recipe) do return 0, false
	if request.width < 1 || request.width > TERRAIN_BIOME_REGION_MAX_EDGE do return 0, false
	if request.height < 1 || request.height > TERRAIN_BIOME_REGION_MAX_EDGE do return 0, false
	cells := request.width * request.height
	if cells > TERRAIN_BIOME_REGION_MAX_CELLS do return 0, false
	if request.minimum_cells < 1 || request.minimum_cells > cells do return 0, false
	if len(raw) < cells || len(output.biomes) < cells do return 0, false
	if len(output.patch_ids) < cells do return 0, false
	if len(scratch.labels) < cells || len(scratch.queue) < cells do return 0, false
	if len(scratch.component_sizes) < cells || len(scratch.component_ids) < cells do return 0, false
	if len(scratch.merge_targets) < cells do return 0, false
	// The offset table is a prefix sum over components and needs one slot past
	// the last component, which a cells-long slice always has: a component
	// cannot be empty, so components <= cells.
	if len(scratch.component_offsets) < cells + 1 do return 0, false
	if len(scratch.component_cells) < cells do return 0, false
	for id in request.protected_ids {
		if !_terrain_biome_region_id_valid(recipe, id) do return 0, false
	}
	for index in 0 ..< cells {
		if !_terrain_biome_region_id_valid(recipe, raw[index].primary_id) do return 0, false
	}
	return cells, true
}

@(private)
_terrain_biome_region_label :: proc(
	request: Terrain_Biome_Region_Request,
	biomes: []Terrain_Biome_Blend_V2,
	scratch: Terrain_Biome_Region_Scratch,
) -> int {
	cells := request.width * request.height
	for index in 0 ..< cells do scratch.labels[index] = 0
	component_count := 0
	for origin in 0 ..< cells {
		if scratch.labels[origin] != 0 do continue
		component_count += 1
		label := u32(component_count)
		id := biomes[origin].primary_id
		scratch.component_ids[component_count - 1] = id
		head, tail := 0, 1
		scratch.queue[0] = u32(origin)
		scratch.labels[origin] = label
		for head < tail {
			index := int(scratch.queue[head])
			head += 1
			_terrain_biome_region_enqueue(request, biomes, scratch, index, -1, 0, id, label, &tail)
			_terrain_biome_region_enqueue(request, biomes, scratch, index, 1, 0, id, label, &tail)
			_terrain_biome_region_enqueue(request, biomes, scratch, index, 0, -1, id, label, &tail)
			_terrain_biome_region_enqueue(request, biomes, scratch, index, 0, 1, id, label, &tail)
		}
		scratch.component_sizes[component_count - 1] = u32(tail)
	}
	assert(component_count > 0 && component_count <= cells, "biome region labels bounded")
	return component_count
}

@(private)
_terrain_biome_region_enqueue :: proc(
	request: Terrain_Biome_Region_Request,
	biomes: []Terrain_Biome_Blend_V2,
	scratch: Terrain_Biome_Region_Scratch,
	index, offset_x, offset_y: int,
	id: u16,
	label: u32,
	tail: ^int,
) {
	assert(tail != nil, "_terrain_biome_region_enqueue: nil tail")
	x, y := index % request.width, index / request.width
	next_x, next_y := x + offset_x, y + offset_y
	if next_x < 0 || next_x >= request.width || next_y < 0 || next_y >= request.height do return
	next := next_y * request.width + next_x
	if scratch.labels[next] != 0 || biomes[next].primary_id != id do return
	assert(tail^ < request.width * request.height, "biome region queue overflow")
	scratch.labels[next] = label
	scratch.queue[tail^] = u32(next)
	tail^ += 1
}

@(private)
_terrain_biome_region_choose_merges :: proc(
	recipe: ^Terrain_Recipe_V2,
	request: Terrain_Biome_Region_Request,
	scratch: Terrain_Biome_Region_Scratch,
	components: int,
) -> int {
	assert(recipe != nil, "_terrain_biome_region_choose_merges: nil recipe")
	assert(components > 0, "_terrain_biome_region_choose_merges: no components")
	// The queue doubles as the per-component neighbour counter here, and the
	// label pass left cell indices in it. Clearing it once per pass is enough
	// because every target call restores the entries it touched.
	for component in 0 ..< components {
		scratch.merge_targets[component] = 0
		scratch.queue[component] = 0
	}
	merges := 0
	for component in 0 ..< components {
		id := scratch.component_ids[component]
		if int(scratch.component_sizes[component]) >= request.minimum_cells do continue
		if _terrain_biome_region_protected(request, id) do continue
		target := _terrain_biome_region_target(recipe, request, scratch, component)
		if target < 0 do continue
		scratch.merge_targets[component] = u32(target + 1)
		merges += 1
	}
	return merges
}

// _terrain_biome_region_bucket groups cell indices by component with a
// counting sort, so a component can be walked without sweeping the grid.
// component_offsets holds exclusive prefix sums and is restored to them after
// the fill, which is what lets the cursor live in the same array.
@(private)
_terrain_biome_region_bucket :: proc(
	request: Terrain_Biome_Region_Request,
	scratch: Terrain_Biome_Region_Scratch,
	components: int,
) {
	assert(components > 0, "_terrain_biome_region_bucket: no components")
	cells := request.width * request.height
	assert(components <= cells, "_terrain_biome_region_bucket: component count")
	scratch.component_offsets[0] = 0
	for component in 0 ..< components {
		scratch.component_offsets[component + 1] =
			scratch.component_offsets[component] + scratch.component_sizes[component]
	}
	assert(
		int(scratch.component_offsets[components]) == cells,
		"_terrain_biome_region_bucket: sizes do not cover the grid",
	)
	for index in 0 ..< cells {
		component := scratch.labels[index] - 1
		slot := scratch.component_offsets[component]
		scratch.component_cells[slot] = u32(index)
		scratch.component_offsets[component] = slot + 1
	}
	for component in 0 ..< components {
		scratch.component_offsets[component] -= scratch.component_sizes[component]
	}
	assert(scratch.component_offsets[0] == 0, "_terrain_biome_region_bucket: offsets not restored")
}

@(private)
_terrain_biome_region_target :: proc(
	recipe: ^Terrain_Recipe_V2,
	request: Terrain_Biome_Region_Request,
	scratch: Terrain_Biome_Region_Scratch,
	component: int,
) -> int {
	assert(recipe != nil, "_terrain_biome_region_target: nil recipe")
	start := int(scratch.component_offsets[component])
	end := int(scratch.component_offsets[component + 1])
	assert(start < end, "_terrain_biome_region_target: empty component")
	assert(end <= request.width * request.height, "_terrain_biome_region_target: component range")
	// Count, select and clear each walk only this component's own cells.
	// Sweeping the whole grid per undersized component -- which is what this
	// did -- is quadratic once most components are below the minimum, and a
	// province-scale minimum makes most of them so.
	for slot in start ..< end {
		index := int(scratch.component_cells[slot])
		for offset in TERRAIN_BIOME_REGION_NEIGHBORS {
			candidate := _terrain_biome_region_neighbor(request, scratch, index, offset, component)
			if candidate >= 0 do scratch.queue[candidate] += 1
		}
	}
	best := -1
	for slot in start ..< end {
		index := int(scratch.component_cells[slot])
		for offset in TERRAIN_BIOME_REGION_NEIGHBORS {
			candidate := _terrain_biome_region_neighbor(request, scratch, index, offset, component)
			if candidate < 0 do continue
			candidate_size := scratch.component_sizes[candidate]
			component_size := scratch.component_sizes[component]
			if candidate_size < component_size do continue
			if candidate_size == component_size && candidate > component do continue
			// The comparison is a total order, so revisiting a candidate
			// through a second shared edge cannot change the winner.
			if _terrain_biome_region_target_better(recipe, scratch, candidate, best) do best = candidate
		}
	}
	for slot in start ..< end {
		index := int(scratch.component_cells[slot])
		for offset in TERRAIN_BIOME_REGION_NEIGHBORS {
			candidate := _terrain_biome_region_neighbor(request, scratch, index, offset, component)
			if candidate >= 0 do scratch.queue[candidate] = 0
		}
	}
	return best
}

@(private)
_terrain_biome_region_neighbor :: proc(
	request: Terrain_Biome_Region_Request,
	scratch: Terrain_Biome_Region_Scratch,
	index: int,
	offset: [2]int,
	component: int,
) -> int {
	x, y := index % request.width, index / request.width
	next_x, next_y := x + offset.x, y + offset.y
	if next_x < 0 || next_x >= request.width do return -1
	if next_y < 0 || next_y >= request.height do return -1
	next := next_y * request.width + next_x
	candidate := int(scratch.labels[next] - 1)
	return -1 if candidate == component else candidate
}

@(private)
_terrain_biome_region_target_better :: proc(
	recipe: ^Terrain_Recipe_V2,
	scratch: Terrain_Biome_Region_Scratch,
	candidate, current: int,
) -> bool {
	assert(recipe != nil, "_terrain_biome_region_target_better: nil recipe")
	if current < 0 do return true
	if scratch.queue[candidate] != scratch.queue[current] {
		return scratch.queue[candidate] > scratch.queue[current]
	}
	if scratch.component_sizes[candidate] != scratch.component_sizes[current] {
		return scratch.component_sizes[candidate] > scratch.component_sizes[current]
	}
	candidate_priority := _terrain_biome_region_priority(recipe, scratch.component_ids[candidate])
	current_priority := _terrain_biome_region_priority(recipe, scratch.component_ids[current])
	if candidate_priority != current_priority do return candidate_priority > current_priority
	if scratch.component_ids[candidate] != scratch.component_ids[current] {
		return scratch.component_ids[candidate] < scratch.component_ids[current]
	}
	return candidate < current
}

@(private)
_terrain_biome_region_priority :: proc(recipe: ^Terrain_Recipe_V2, id: u16) -> u8 {
	assert(recipe != nil, "_terrain_biome_region_priority: nil recipe")
	for index in 0 ..< int(recipe.biome_profile_count) {
		if recipe.biome_profiles[index].id == id do return recipe.biome_profiles[index].priority
	}
	assert(false, "biome region profile missing")
	return 0
}

@(private)
_terrain_biome_region_id_valid :: proc(recipe: ^Terrain_Recipe_V2, id: u16) -> bool {
	assert(recipe != nil, "_terrain_biome_region_id_valid: nil recipe")
	for index in 0 ..< int(recipe.biome_profile_count) {
		if recipe.biome_profiles[index].id == id do return true
	}
	return false
}

@(private)
_terrain_biome_region_protected :: proc(request: Terrain_Biome_Region_Request, id: u16) -> bool {
	for protected in request.protected_ids do if protected == id do return true
	return false
}
