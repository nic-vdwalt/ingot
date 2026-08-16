package procgen

TERRAIN_BIOME_REGION_MAX_EDGE :: 2048
TERRAIN_BIOME_REGION_MAX_CELLS :: TERRAIN_BIOME_REGION_MAX_EDGE * TERRAIN_BIOME_REGION_MAX_EDGE
TERRAIN_BIOME_REGION_PASS_MAX :: TERRAIN_BIOME_PROFILE_MAX_V2

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
	labels:          []u32,
	queue:           []u32,
	component_sizes: []u32,
	component_ids:   []u16,
	merge_targets:   []u32,
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
		merges := _terrain_biome_region_choose_merges(
			recipe,
			request,
			output.biomes,
			scratch,
			components,
		)
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
	biomes: []Terrain_Biome_Blend_V2,
	scratch: Terrain_Biome_Region_Scratch,
	components: int,
) -> int {
	assert(recipe != nil, "_terrain_biome_region_choose_merges: nil recipe")
	for component in 0 ..< components do scratch.merge_targets[component] = 0
	merges := 0
	for component in 0 ..< components {
		id := scratch.component_ids[component]
		if int(scratch.component_sizes[component]) >= request.minimum_cells do continue
		if _terrain_biome_region_protected(request, id) do continue
		target := _terrain_biome_region_target(
			recipe,
			request,
			biomes,
			scratch,
			component,
			components,
		)
		if target < 0 do continue
		scratch.merge_targets[component] = u32(target + 1)
		merges += 1
	}
	return merges
}

@(private)
_terrain_biome_region_target :: proc(
	recipe: ^Terrain_Recipe_V2,
	request: Terrain_Biome_Region_Request,
	biomes: []Terrain_Biome_Blend_V2,
	scratch: Terrain_Biome_Region_Scratch,
	component, components: int,
) -> int {
	assert(recipe != nil, "_terrain_biome_region_target: nil recipe")
	for component_index in 0 ..< components do scratch.queue[component_index] = 0
	cells := request.width * request.height
	for index in 0 ..< cells {
		if int(scratch.labels[index] - 1) != component do continue
		_terrain_biome_region_count_neighbor(request, scratch, index, -1, 0, component)
		_terrain_biome_region_count_neighbor(request, scratch, index, 1, 0, component)
		_terrain_biome_region_count_neighbor(request, scratch, index, 0, -1, component)
		_terrain_biome_region_count_neighbor(request, scratch, index, 0, 1, component)
	}
	best := -1
	for candidate in 0 ..< components {
		if scratch.queue[candidate] == 0 do continue
		candidate_size := scratch.component_sizes[candidate]
		component_size := scratch.component_sizes[component]
		if candidate_size < component_size do continue
		if candidate_size == component_size && candidate > component do continue
		if _terrain_biome_region_target_better(recipe, scratch, candidate, best) do best = candidate
	}
	return best
}

@(private)
_terrain_biome_region_count_neighbor :: proc(
	request: Terrain_Biome_Region_Request,
	scratch: Terrain_Biome_Region_Scratch,
	index, offset_x, offset_y, component: int,
) {
	x, y := index % request.width, index / request.width
	next_x, next_y := x + offset_x, y + offset_y
	if next_x < 0 || next_x >= request.width || next_y < 0 || next_y >= request.height do return
	next := next_y * request.width + next_x
	candidate := int(scratch.labels[next] - 1)
	if candidate != component do scratch.queue[candidate] += 1
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
