// flora.odin scatters decorative trees, boulders, and scree rocks across the
// world: authored archetypes expanded into deterministic logical variants,
// one instanced draw per variant, a small baked texture atlas shared by all,
// and a deterministic climate-driven placement pass. Flora is cosmetic only -
// the sim never sees it - so placement runs client-side from the same seed
// and terraforming simply hides or re-seats instances.
package main

import shared "../shared"
import "core:math"
import "core:math/linalg"
import asset "ingot:asset"
import ecs "ingot:ecs"
import rl "ingot:gfx"
import procgen "ingot:procgen"

FLORA_LARGE_CELL :: f32(4)
FLORA_GROUND_CELL :: f32(2)
// Grass cluster size: an accepted ground cell in a vegetated biome emits
// this many blades (one primary plus deterministic extras from the same
// cell hash), so forests read as a carpet instead of one blade per 2x2m.
// Sizes the ground pool, so instance memory scales with it (~55 MB total
// across the static arrays at 3).
FLORA_GRASS_CLUSTER :: 3
// Ground-density floor a biome must reach before its grass clusters.
FLORA_GRASS_CLUSTER_DENSITY_MIN :: f32(0.7)
// Streaming window: flora exists for an 11x11 block of 64-unit tiles centred
// on the camera target. Cell hashes stay keyed on absolute world cells, so a
// tile regenerates identically whenever it re-enters the window, while
// instance memory stays bounded regardless of total world area.
FLORA_STREAM_TILE_SIZE :: f32(64)
FLORA_STREAM_RADIUS :: 5
FLORA_STREAM_DIAMETER :: 2 * FLORA_STREAM_RADIUS + 1
FLORA_STREAM_TILE_COUNT :: FLORA_STREAM_DIAMETER * FLORA_STREAM_DIAMETER
FLORA_LARGE_CELLS_PER_TILE :: int(FLORA_STREAM_TILE_SIZE / FLORA_LARGE_CELL)
FLORA_GROUND_CELLS_PER_TILE :: int(FLORA_STREAM_TILE_SIZE / FLORA_GROUND_CELL)
FLORA_LARGE_MAX ::
	FLORA_STREAM_TILE_COUNT * FLORA_LARGE_CELLS_PER_TILE * FLORA_LARGE_CELLS_PER_TILE
FLORA_GROUND_MAX ::
	FLORA_STREAM_TILE_COUNT *
	FLORA_GROUND_CELLS_PER_TILE *
	FLORA_GROUND_CELLS_PER_TILE *
	FLORA_GRASS_CLUSTER
FLORA_MAX :: FLORA_LARGE_MAX + FLORA_GROUND_MAX
// Per-tile instance pool: each stream tile slot owns a fixed-capacity chunk of
// the instance array, so tiles can enter and exit the window without shifting
// any other tile's indices (which would invalidate Box3D proxy user data).
FLORA_TILE_LARGE_CAPACITY :: FLORA_LARGE_CELLS_PER_TILE * FLORA_LARGE_CELLS_PER_TILE
FLORA_TILE_GROUND_CAPACITY ::
	FLORA_GROUND_CELLS_PER_TILE * FLORA_GROUND_CELLS_PER_TILE * FLORA_GRASS_CLUSTER
FLORA_TILE_CAPACITY :: FLORA_TILE_LARGE_CAPACITY + FLORA_TILE_GROUND_CAPACITY
#assert(FLORA_TILE_CAPACITY * FLORA_STREAM_TILE_COUNT == FLORA_MAX)
// Maximum tiles that can enter on a single crossing: one full row or column
// (DIAMETER) plus a corner when moving diagonally (DIAMETER + DIAMETER - 1).
FLORA_MAX_ENTER_TILES :: 2 * FLORA_STREAM_DIAMETER - 1
// Ground shift that uproots an instance instead of re-seating it.
FLORA_UPROOT_DELTA :: f32(0.4)
// Keep flora clear of resource node clusters.
FLORA_NODE_CLEARANCE :: f32(2.6)
FLORA_TREE_SCALE_MIN :: f32(1.15)
FLORA_TREE_SCALE_VARIATION :: f32(0.55)
FLORA_GRASS_SCALE_MIN :: f32(0.38)
FLORA_GRASS_SCALE_VARIATION :: f32(0.30)
// Grass is the bulk of the instance budget and reads as noise at distance, so
// it is dropped beyond this radius from the eye. Sized against the zoom-out
// ceiling (CAMERA_MAX_DISTANCE 320 at a steep pitch) so the cutoff sits
// outside the band the camera normally occupies. Trees, boulders and scree
// are never distance-culled; only the frustum test applies to them.
//
// The range is twice what it was before the LOD chain existed. The old value
// was a hard cut chosen because there was nothing cheaper to fall back to; the
// far band is now carried by the coarsest level, which is a fraction of the
// triangles, so the range grows while total throughput drops.
FLORA_GROUND_DRAW_RANGE :: f32(440)
// Cluster extras are pure close-range filler: the shader's dither fade has
// fully discarded grass by 150 units, so extras drop out of submission much
// earlier than the primaries and the carpet never triples the far band.
FLORA_GROUND_EXTRA_DRAW_RANGE :: f32(200)
// Levels per mesh, level zero being the finest. The levels come from the
// INGMESH2 chain the cook step built, so this is the ceiling the client will
// upload rather than a ladder it derives: four covers the deepest policy any
// flora manifest declares (tree_4), and a mesh cooked with fewer keeps fewer.
FLORA_LOD_COUNT :: 4
// Selection is on apparent size - bounding radius over view depth - rather
// than raw distance, so a baobab and a grass blade switch at the distances
// their own size justifies instead of at one shared radius. Strictly
// decreasing, because two levels qualifying at once would make the choice
// depend on iteration order.
FLORA_LOD_APPARENT_MID :: f32(0.035)
FLORA_LOD_APPARENT_FAR :: f32(0.012)
FLORA_LOD_APPARENT_DISTANT :: f32(0.0055)
// Depth floor for the apparent-size division, well inside any sane near plane.
FLORA_LOD_MIN_DEPTH :: f32(0.01)
// Vertical padding on a stream tile's bounding sphere, covering flora that
// stands proud of the measured anchor extents (the tallest baobab).
FLORA_TILE_BOUNDS_PAD :: f32(12)

FLORA_ATLAS_SIZE :: 256

Flora_Config :: struct {
	tree_moisture_min: f32,
	tree_chance_scale: f32,
	tree_chance_max:   f32,
	grass_chance:      f32,
	boulder_chance:    f32,
	scree_chance:      f32,
}

// flora_default_config is the scatter's chance table. The debug panel's
// density multiplier scales every chance here (clamped to keep probabilities
// sane and the per-tile pools under their asserts); at the default 1.0 the
// values are byte-identical to the authored constants.
flora_default_config :: proc() -> Flora_Config {
	config := Flora_Config {
		tree_moisture_min = 0.45,
		tree_chance_scale = 1.1,
		tree_chance_max = 0.42,
		grass_chance = 0.42,
		boulder_chance = 0.05,
		scree_chance = 0.07,
	}
	scale := debug_tuning.flora_density_scale
	if scale != 1 {
		scale = clamp(scale, 0, DEBUG_FLORA_DENSITY_MAX)
		config.grass_chance = clamp(config.grass_chance * scale, 0, 1)
		config.scree_chance = clamp(config.scree_chance * scale, 0, 1)
	}
	return config
}

Flora_Asset_Id :: enum u8 {
	Conifer_A,
	Conifer_B,
	Baobab,
	Grass_Upright,
	Grass_Crossed,
	Grass_Reed,
	Rock_Gray,
	Rock_Dry,
	Shrub_Rounded,
	Tree_Open,
	Shrub_Upright,
	Grass_Tuft,
}

Flora_Mesh_Id :: enum u8 {
	Conifer_A,
	Conifer_B,
	Baobab,
	Grass_Upright,
	Grass_Crossed,
	Grass_Reed,
	Boulder_A,
	Boulder_B,
	Boulder_C,
	Rock_A,
	Rock_B,
	Shrub_Rounded,
	Tree_Open,
	Grass_Tuft,
	Shrub_Upright,
	Conifer_Wide,
	Conifer_Narrow,
	Baobab_Wide,
	Tree_Open_Tall,
	Shrub_Rounded_Wide,
	Shrub_Upright_Tall,
}

Flora_Mesh_Recipe :: struct {
	asset_id: Flora_Asset_Id,
	deform:   bool,
	recipe:   procgen.Mesh_Deform_Recipe,
}

FLORA_MESH_RECIPES := [Flora_Mesh_Id]Flora_Mesh_Recipe {
	.Shrub_Rounded = {.Shrub_Rounded, false, {scale = {1, 1, 1}}},
	.Conifer_A     = {.Conifer_A, false, {scale = {1, 1, 1}}},
	.Conifer_B     = {.Conifer_B, false, {scale = {1, 1, 1}}},
	.Baobab        = {.Baobab, false, {scale = {1, 1, 1}}},
	.Grass_Upright       = {.Grass_Upright, false, {scale = {1, 1, 1}}},
	.Grass_Crossed       = {.Grass_Crossed, false, {scale = {1, 1, 1}}},
	.Grass_Reed          = {.Grass_Reed, false, {scale = {1, 1, 1}}},
	.Tree_Open           = {.Tree_Open, false, {scale = {1, 1, 1}}},
	.Grass_Tuft          = {.Grass_Tuft, false, {scale = {1, 1, 1}}},
	.Shrub_Upright       = {.Shrub_Upright, false, {scale = {1, 1, 1}}},
	.Conifer_Wide        = {.Conifer_A, false, {scale = {1.22, 1.22, 0.92}}},
	.Conifer_Narrow      = {.Conifer_B, false, {scale = {0.78, 0.78, 1.12}}},
	.Baobab_Wide         = {.Baobab, false, {scale = {1.20, 1.20, 0.94}}},
	.Tree_Open_Tall      = {.Tree_Open, false, {scale = {0.82, 0.82, 1.18}}},
	.Shrub_Rounded_Wide  = {.Shrub_Rounded, false, {scale = {1.22, 1.22, 0.88}}},
	.Shrub_Upright_Tall  = {.Shrub_Upright, false, {scale = {0.82, 0.82, 1.18}}},
	.Boulder_A     = {
		.Rock_Gray,
		true,
		{
			scale = {1, 1, 1},
			seed = 0xB01DA001,
			radial_amplitude = 0.14,
			vertical_amplitude = 0.08,
			frequency = 1.25,
			taper = 0.30,
			preserve_ground = true,
		},
	},
	.Boulder_B     = {
		.Rock_Gray,
		true,
		{
			scale = {1.190, 0.837, 0.840},
			seed = 0xB01DA002,
			radial_amplitude = 0.16,
			vertical_amplitude = 0.09,
			frequency = 1.55,
			taper = 0.35,
			preserve_ground = true,
		},
	},
	.Boulder_C     = {
		.Rock_Dry,
		true,
		{
			scale = {0.876, 0.977, 1.136},
			seed = 0xB01DA003,
			radial_amplitude = 0.13,
			vertical_amplitude = 0.10,
			frequency = 1.10,
			taper = 0.25,
			preserve_ground = true,
		},
	},
	.Rock_A        = {
		.Rock_Gray,
		true,
		{
			scale = {0.476, 0.488, 0.464},
			seed = 0x5C2EE001,
			radial_amplitude = 0.06,
			vertical_amplitude = 0.04,
			frequency = 1.70,
			taper = 0.40,
			preserve_ground = true,
		},
	},
	.Rock_B        = {
		.Rock_Dry,
		true,
		{
			scale = {0.590, 0.395, 0.416},
			seed = 0x5C2EE002,
			radial_amplitude = 0.06,
			vertical_amplitude = 0.04,
			frequency = 1.35,
			taper = 0.35,
			preserve_ground = true,
		},
	},
}

FLORA_GROUND_MESHES := [4]Flora_Mesh_Id {
	.Grass_Upright, .Grass_Crossed, .Grass_Reed, .Grass_Tuft,
}
FLORA_SHRUB_MESHES := [4]Flora_Mesh_Id {
	.Shrub_Rounded, .Shrub_Upright, .Shrub_Rounded_Wide, .Shrub_Upright_Tall,
}
FLORA_TREE_MESHES := [8]Flora_Mesh_Id {
	.Conifer_A, .Conifer_B, .Baobab, .Tree_Open,
	.Conifer_Wide, .Conifer_Narrow, .Baobab_Wide, .Tree_Open_Tall,
}

Flora_Ecology_Visual :: struct {
	lineage:          u64,
	form:             u8,
	cover:            u16,
	biomass:          u32,
	age_steps:        u32,
	morphology_family: u8,
	stature:          u16,
}

Flora_Instance :: struct {
	position:      [3]f32,
	// Surface frame at the instance's seat. Flat worlds use the constant
	// frame (direction/up {0,0,1}, east {1,0,0}, north {0,1,0}); spherical
	// worlds store the tangent basis so transforms, bounds, and culling
	// rotate the mesh onto the local surface normal.
	direction:     [3]f32,
	up:            [3]f32,
	east:          [3]f32,
	north:         [3]f32,
	spawn_height:  f32,
	yaw:           f32,
	// Baked yaw trig so per-frame culling and transform building never call
	// cos/sin; yaw only changes at scatter time.
	cos_yaw:       f32,
	sin_yaw:       f32,
	scale:         f32,
	target_scale:  f32,
	lineage:       u64,
	// Scatter cell key within the tile (raster cell index times the cluster
	// size, plus the extra index): a rescatter of the same tile emits the
	// same keys in the same order, so growth carries across ecology refreshes.
	cell:          u32,
	emergence:     u16,
	mesh:          Flora_Mesh_Id,
	hidden:        bool,
	// Extra blade of a grass cluster: culled at the shorter
	// FLORA_GROUND_EXTRA_DRAW_RANGE so the carpet stays a close-range cost.
	cluster_extra: bool,
}

// Flora_Tile_Id names one streaming tile in a world-model-agnostic way: flat
// worlds use face -1 with tile_u/tile_v as the flat grid index; cube-sphere
// worlds use the cube face plus face-local tile coordinates. Only the seam
// procs (flora_world_tile, flora_stream_window, flora_scatter_position, ...)
// interpret the fields; forgecore treats the id as opaque.
Flora_Tile_Id :: struct {
	face:   i32,
	tile_u: i32,
	tile_v: i32,
}

// Flora_Seat_Mode selects the height source flora_seat_position reads:
// Cached is the analytic grid (thread-safe, used by the background scatter),
// Probe is the physics seat raycast used at scatter time on the main thread,
// Surface is the rendered-surface probe the reseat sweep uses.
Flora_Seat_Mode :: enum {
	Cached,
	Probe,
	Surface,
}

// Flora_View caches the camera-derived constants of the visibility test so
// the per-instance loop does no redundant trig, sqrt, or screen queries.
Flora_View :: struct {
	position:         [3]f32,
	forward:          [3]f32,
	near_plane:       f32,
	far_plane:        f32,
	projection_scale: f32,
	// tan(fovy/2) * sqrt(1 + aspect^2): the lateral half-extent per unit of
	// depth of the smallest cone containing the frustum. See _view_tan_limit.
	tan_limit:        f32,
}

Flora_Counts :: struct {
	conifers:  u32,
	broadleaf: u32,
	grass:     u32,
	boulders:  u32,
	scree:     u32,
	hidden:    u32,
}

// Flora_Tile_Span records where one stream tile's instances live in the
// instance array. Scatter runs a large pass and then a ground pass across
// every tile, so a tile owns two contiguous ranges rather than one. Nothing
// ever compacts the instance array, so these stay valid until the next
// scatter. The visibility scan culls a tile's bounding sphere once instead of
// testing each of its instances, which is what keeps a full-window flora set
// off the per-frame critical path.
Flora_Tile_Span :: struct {
	tile:             Flora_Tile_Id,
	ecology_revision: u64,
	large_begin:      i32,
	large_end:        i32,
	ground_begin:     i32,
	ground_end:       i32,
	// World-space AABB of the instances the span owns, measured after every
	// scatter and reseat; the cull derives a bounding sphere from it. On a
	// flat world this degenerates to the tile rectangle plus height range.
	bounds_min:   [3]f32,
	bounds_max:   [3]f32,
	// occupied marks a slot whose instance ranges are live; evicted slots
	// keep stale ranges until an entering tile reuses them.
	occupied:     bool,
	// reseated flips once the sweep has re-probed this tile's physics
	// heights; freshly scattered tiles start false.
	reseated:     bool,
}

Flora_Scatter_State :: enum u8 {
	Idle,
	Scattering,
	Ready,
	Committing,
}

Flora :: struct {
	instances:       [FLORA_MAX]Flora_Instance,
	count:           int,
	transforms:      [FLORA_MAX]rl.Matrix,
	candidates:      [FLORA_MAX]int,
	candidate_count: int,
	draw_visits:       u64,
	draw_submitted:    u64,
	ecology_revision: u64,
	ecology_cursor:   int,
	growth_cursor:    int,
	// Level chosen for each entry of `candidates`, filled by the same scan.
	// Kept alongside rather than inside Flora_Instance because it is a
	// per-frame view property, not a property of the instance.
	candidate_lods:  [FLORA_MAX]u8,
	// Per-tile instance spans for the coarse visibility cull; tile_count is
	// the number of populated slots after the last scatter.
	tiles:           [FLORA_STREAM_TILE_COUNT]Flora_Tile_Span,
	tile_count:      int,
	// Stack of tile slots not currently occupied; entering tiles pop a slot
	// and exiting tiles push theirs back.
	free_slots:      [FLORA_STREAM_TILE_COUNT]i32,
	free_slot_count: int,
	meshes:          [Flora_Mesh_Id][FLORA_LOD_COUNT]rl.Gpu_Mesh,
	// Populated levels per mesh; always at least one once upload succeeds.
	mesh_lods:       [Flora_Mesh_Id]int,
	mesh_bounds:     [Flora_Mesh_Id]asset.Bounds_3D,
	atlas:           rl.Texture2D,
	shader:          rl.Gpu_3D_Shader,
	// Centre tile of the resident streaming window; instances regenerate
	// when the camera target crosses into a different tile.
	stream_tile:     Flora_Tile_Id,
	stream_valid:    bool,
	stream_pending:  bool,
	ready:           bool,
	query_camera_pos: [3]f32,
	scatter_load:    ^Flora_Scatter_Load,
}

flora_init :: proc(
	value: ^Flora,
	terrain: ^Terrain,
	world: ^shared.World,
	ruins: ^Ruins,
	focus_direction: [3]f32,
) -> bool {
	assert(value != nil, "flora_init: nil flora")
	assert(terrain != nil, "flora_init: nil terrain")
	assert(world != nil, "flora_init: nil world")
	assert(ruins != nil, "flora_init: nil ruins")
	assert(terrain.ready, "flora_init: terrain not ready")
	if value.ready do return true
	if !_flora_atlas_build(value) do return false
	if !_flora_assets_upload(value) do return false
	if value.shader.id == 0 {
		shader_ok: bool
		value.shader, shader_ok = rl.create_gpu_3d_shader(FLORA_SHADER)
		if !shader_ok {
			for id in Flora_Mesh_Id {
				_flora_mesh_chain_destroy(&value.meshes[id])
			}
			return false
		}
	}
	value.stream_tile = flora_world_tile(focus_direction)
	value.stream_valid = true
	value.scatter_load = new(Flora_Scatter_Load)
	_flora_scatter_pooled(value, terrain, world, ruins, value.stream_tile)
	value.ready = true
	return true
}

// flora_stream_update shifts the resident window when the camera target
// crosses a tile boundary. Only the entering tiles are scattered — on a
// background thread — while retained tiles keep their instances untouched.
// Regeneration is deterministic per absolute cell, so revisited tiles look
// identical.
flora_stream_update :: proc(
	value: ^Flora,
	terrain: ^Terrain,
	world: ^shared.World,
	ruins: ^Ruins,
	focus_direction: [3]f32,
) {
	assert(value != nil, "flora_stream_update: nil flora")
	assert(terrain != nil, "flora_stream_update: nil terrain")
	assert(world != nil, "flora_stream_update: nil world")
	assert(ruins != nil, "flora_stream_update: nil ruins")
	if !value.ready do return
	value.ecology_revision = flora_ecology_revision(world)
	tile := flora_world_tile(focus_direction)
	if !value.stream_valid || !flora_tile_eq(tile, value.stream_tile) {
		value.stream_tile = tile
		value.stream_valid = true
		value.stream_pending = true
	}
	load := value.scatter_load
	if flora_scatter_load_active(load) {
		if flora_scatter_load_poll(load) && load.state == .Ready {
			flora_scatter_load_commit_begin(load)
		}
		if load.state == .Committing && _flora_scatter_swap_incremental_step(value) {
			flora_scatter_load_commit_complete(load)
		}
		return
	}
	stale_slot := _flora_ecology_stale_slot(value)
	if stale_slot >= 0 {
		_flora_rescatter_slot(value, terrain, world, ruins, stale_slot)
		value.ecology_cursor = (stale_slot + 1) % value.tile_count
	}
	if !value.stream_pending do return
	enter_tiles: [FLORA_MAX_ENTER_TILES]Flora_Tile_Id
	enter_count: int
	exit_slots: [FLORA_STREAM_TILE_COUNT]i32
	exit_count: int
	value.stream_pending = _flora_compute_enter_exit(
		value,
		value.stream_tile,
		&enter_tiles,
		&enter_count,
		&exit_slots,
		&exit_count,
	)
	load.enter_tile_count = enter_count
	for i in 0 ..< enter_count {
		load.enter_tiles[i] = {
			tile = enter_tiles[i],
		}
	}
	load.exit_count = exit_count
	for i in 0 ..< exit_count {
		load.exit_slots[i] = exit_slots[i]
	}
	if enter_count == 0 && exit_count == 0 {
		value.stream_pending = false
		return
	}
	if enter_count == 0 {
		load.state = .Ready
		flora_scatter_load_commit_begin(load)
		return
	}
	flora_scatter_load_begin(load, terrain, world, ruins, value.stream_tile)
}

_flora_ecology_stale_slot :: proc(value: ^Flora) -> int {
	assert(value != nil, "_flora_ecology_stale_slot: nil flora")
	for offset in 0 ..< value.tile_count {
		slot := (value.ecology_cursor + offset) % value.tile_count
		span := &value.tiles[slot]
		if span.occupied && span.ecology_revision != value.ecology_revision do return slot
	}
	return -1
}

flora_deinit :: proc(value: ^Flora) {
	assert(value != nil, "flora_deinit: nil flora")
	if value.scatter_load != nil {
		flora_scatter_load_finish(value.scatter_load)
		free(value.scatter_load)
		value.scatter_load = nil
	}
	for id in Flora_Mesh_Id {
		_flora_mesh_chain_destroy(&value.meshes[id])
	}
	value.mesh_lods = {}
	value.mesh_bounds = {}
	if value.atlas.id != 0 do rl.UnloadTexture(value.atlas)
	value.atlas = {}
	rl.destroy_gpu_3d_shader(&value.shader)
	value.count = 0
	value.tiles = {}
	value.tile_count = 0
	value.free_slot_count = 0
	value.ready = false
}

// flora_mark_dirty restarts the per-tile revalidation sweep; called whenever
// terraforming (or placement flattening) changes the heightfield.
flora_mark_dirty :: proc(value: ^Flora) {
	assert(value != nil, "flora_mark_dirty: nil flora")
	for slot in 0 ..< value.tile_count {
		if value.tiles[slot].occupied do value.tiles[slot].reseated = false
	}
}

flora_clear_trees :: proc(value: ^Flora) -> u32 {
	assert(value != nil, "flora_clear_trees: nil flora")
	if !value.ready do return 0
	cleared := u32(0)
	ranges: [2 * FLORA_STREAM_TILE_COUNT + 1][2]i32
	range_count := _flora_index_ranges(value, &ranges)
	for r in 0 ..< range_count {
		for index in int(ranges[r][0]) ..< int(ranges[r][1]) {
			instance := &value.instances[index]
			if instance.hidden do continue
			if !_flora_is_tree(instance.mesh) do continue
			instance.hidden = true
			cleared += 1
		}
	}
	value.candidate_count = 0
	return cleared
}

flora_counts :: proc(value: ^Flora) -> Flora_Counts {
	assert(value != nil, "flora_counts: nil flora")
	counts: Flora_Counts
	ranges: [2 * FLORA_STREAM_TILE_COUNT + 1][2]i32
	range_count := _flora_index_ranges(value, &ranges)
	for r in 0 ..< range_count {
		for index in int(ranges[r][0]) ..< int(ranges[r][1]) {
			instance := &value.instances[index]
			if instance.hidden {
				counts.hidden += 1
				continue
			}
			if _flora_is_grass(instance.mesh) {
				counts.grass += 1
			} else if _flora_is_tree(instance.mesh) {
				if instance.mesh == .Conifer_A || instance.mesh == .Conifer_B || instance.mesh == .Conifer_Wide || instance.mesh == .Conifer_Narrow {
					counts.conifers += 1
				} else {
					counts.broadleaf += 1
				}
			} else if _flora_is_shrub(instance.mesh) {
				counts.broadleaf += 1
			} else if instance.mesh == .Boulder_A || instance.mesh == .Boulder_B || instance.mesh == .Boulder_C {
				counts.boulders += 1
			} else if instance.mesh == .Rock_A || instance.mesh == .Rock_B {
				counts.scree += 1
			}
		}
	}
	return counts
}

flora_regenerate :: proc(value: ^Flora, terrain: ^Terrain, world: ^shared.World, ruins: ^Ruins) {
	assert(value != nil, "flora_regenerate: nil flora")
	assert(terrain != nil, "flora_regenerate: nil terrain")
	assert(world != nil, "flora_regenerate: nil world")
	assert(ruins != nil, "flora_regenerate: nil ruins")
	if !value.ready do return
	if flora_scatter_load_active(value.scatter_load) {
		flora_scatter_load_finish(value.scatter_load)
	}
	if !value.stream_valid {
		value.stream_tile = flora_world_tile({0, 0, 0})
		value.stream_valid = true
	}
	_flora_scatter_pooled(value, terrain, world, ruins, value.stream_tile)
}

// flora_clear_footprint hides instances overlapping a building footprint
// rectangle. The rectangle is given in world space — centre plus the two
// tangent axes and half extents — so the same test covers flat grids and
// sphere-surface footprints; callers derive it from the placed building's
// anchor.
flora_clear_footprint :: proc(
	value: ^Flora,
	center: [3]f32,
	east, north: [3]f32,
	half_width, half_height: f32,
) -> u32 {
	assert(value != nil, "flora_clear_footprint: nil flora")
	cleared := u32(0)
	ranges: [2 * FLORA_STREAM_TILE_COUNT + 1][2]i32
	range_count := _flora_index_ranges(value, &ranges)
	for r in 0 ..< range_count {
		for index in int(ranges[r][0]) ..< int(ranges[r][1]) {
			instance := &value.instances[index]
			if instance.hidden do continue
			radius := _flora_patch_radius(instance.mesh) * instance.scale
			delta := instance.position - center
			local_x := linalg.dot(delta, east)
			local_y := linalg.dot(delta, north)
			delta_x := local_x - clamp(local_x, -half_width, half_width)
			delta_y := local_y - clamp(local_y, -half_height, half_height)
			if delta_x * delta_x + delta_y * delta_y > radius * radius do continue
			instance.hidden = true
			cleared += 1
		}
	}
	value.candidate_count = 0
	return cleared
}

_flora_patch_radius :: proc(id: Flora_Mesh_Id) -> f32 {
	if _flora_is_grass(id) do return 1.1
	if _flora_is_shrub(id) do return 1.4
	if _flora_is_tree(id) do return 2.2
	if id == .Rock_A || id == .Rock_B do return 0.45
	return 0
}

// flora_update re-seats or uproots one tile's instances per frame, visiting
// tiles whose reseated flag is down (freshly scattered on the worker thread,
// or dirtied by terraforming). It waits for the terrain height cache to
// settle (no dirty chunks) so the checks read post-terraform heights, not
// stale ones.
flora_update :: proc(value: ^Flora, terrain: ^Terrain) {
	assert(value != nil, "flora_update: nil flora")
	assert(terrain != nil, "flora_update: nil terrain")
	if !value.ready do return
	growth_end := min(value.growth_cursor + 4096, FLORA_MAX)
	for index in value.growth_cursor ..< growth_end {
		instance := &value.instances[index]
		if instance.target_scale <= 0 do continue
		delta := instance.target_scale - instance.scale
		if abs(delta) <= 0.01 {
			instance.scale = instance.target_scale
		} else {
			instance.scale += delta * 0.2
		}
	}
	value.growth_cursor = growth_end if growth_end < FLORA_MAX else 0
	reseat_slot := -1
	for slot in 0 ..< value.tile_count {
		span := &value.tiles[slot]
		if span.occupied && !span.reseated {
			reseat_slot = slot
			break
		}
	}
	if reseat_slot < 0 do return
	for dirty in terrain.dirty do if dirty do return
	span := &value.tiles[reseat_slot]
	_flora_reseat_range(value, terrain, span.large_begin, span.large_end)
	_flora_reseat_range(value, terrain, span.ground_begin, span.ground_end)
	span.reseated = true
	// Reseating moved Z values, so refresh the span's cull bounds.
	_flora_span_bounds(value, span)
}

_flora_reseat_range :: proc(value: ^Flora, terrain: ^Terrain, begin, end: i32) {
	sea := terrain.sea_level
	for index in int(begin) ..< int(end) {
		instance := &value.instances[index]
		if instance.hidden do continue
		seated, height := flora_seat_position(
			terrain,
			instance.position,
			instance.mesh,
			instance.scale,
			.Surface,
		)
		slope := flora_surface_slope(terrain, instance.position)
		if abs(height - instance.spawn_height) > FLORA_UPROOT_DELTA ||
		   height < sea + 0.3 ||
		   slope > 1.3 {
			instance.hidden = true
			continue
		}
		instance.position = seated
	}
}

flora_draw :: proc(value: ^Flora, pass: ^rl.Gpu_3D_Pass, camera: rl.Camera3D) {
	assert(value != nil, "flora_draw: nil flora")
	assert(pass != nil, "flora_draw: nil pass")
	value.draw_visits = 0
	value.draw_submitted = 0
	if !value.ready || value.count == 0 do return
	_flora_visible_scan(value, camera, pass.target)
	_flora_draw_candidates(value, pass)
}

_flora_visible_scan :: proc(value: ^Flora, camera: rl.Camera3D, target: ^rl.Gpu_3D_Target = nil) {
	assert(value != nil, "_flora_visible_scan: nil flora")
	value.candidate_count = 0
	view, view_ok := _flora_view_make(camera, target)
	centers: [Flora_Mesh_Id][3]f32
	radii: [Flora_Mesh_Id]f32
	for id in Flora_Mesh_Id {
		bounds := value.mesh_bounds[id]
		diagonal := bounds.maximum - bounds.minimum
		centers[id] = (bounds.minimum + bounds.maximum) * 0.5
		radii[id] = math.sqrt(linalg.dot(diagonal, diagonal)) * 0.5
	}
	// No spans recorded (a scatter has not run yet): fall back to the flat
	// scan so behaviour never depends on span bookkeeping being present.
	if value.tile_count == 0 {
		_flora_visible_scan_range(value, view, view_ok, centers, radii, 0, i32(value.count))
		return
	}
	for slot in 0 ..< value.tile_count {
		span := &value.tiles[slot]
		// Evicted and never-occupied slots hold zeroed spans, so the empty
		// range check below also skips them.
		if span.large_begin >= span.large_end && span.ground_begin >= span.ground_end do continue
		if view_ok && !_flora_tile_visible(span^, view) do continue
		_flora_visible_scan_range(
			value,
			view,
			view_ok,
			centers,
			radii,
			span.large_begin,
			span.large_end,
		)
		_flora_visible_scan_range(
			value,
			view,
			view_ok,
			centers,
			radii,
			span.ground_begin,
			span.ground_end,
		)
	}
}

_flora_visible_scan_range :: proc(
	value: ^Flora,
	view: Flora_View,
	view_ok: bool,
	centers: [Flora_Mesh_Id][3]f32,
	radii: [Flora_Mesh_Id]f32,
	begin, end: i32,
) {
	assert(value != nil, "_flora_visible_scan_range: nil flora")
	assert(begin <= end, "_flora_visible_scan_range: bad range")
	assert(int(end) <= FLORA_MAX, "_flora_visible_scan_range: range past instance array")
	for index in int(begin) ..< int(end) {
		instance := &value.instances[index]
		if instance.hidden do continue
		// Grass is the bulk of the instance budget and reads as noise past a
		// short range, so it is dropped before the frustum test. Scree from
		// the same scatter pass is larger and keeps its full draw range.
		if _flora_is_grass(instance.mesh) {
			range :=
				instance.cluster_extra ? FLORA_GROUND_EXTRA_DRAW_RANGE : FLORA_GROUND_DRAW_RANGE
			to_instance := instance.position - view.position
			if linalg.dot(to_instance, to_instance) > range * range {
				continue
			}
		}
		if view_ok &&
		   !_flora_instance_visible(instance, view, centers[instance.mesh], radii[instance.mesh]) {
			continue
		}
		assert(value.candidate_count < FLORA_MAX, "_flora_visible_scan: candidate overflow")
		value.candidates[value.candidate_count] = index
		level: u8 = 0
		if view_ok {
			level = _flora_instance_lod(value, instance, view, radii[instance.mesh])
		}
		value.candidate_lods[value.candidate_count] = level
		value.candidate_count += 1
	}
}

// _flora_instance_lod picks a level from apparent size: the instance's world
// bounding radius divided by its depth along the view axis, which is the same
// projected-error rule ../ingot/docs/cluster-lod.md describes, minus the
// projection constants that cancel out of a comparison against a threshold.
//
// Depth rather than distance keeps the choice stable as an instance crosses the
// screen. The depth floor keeps the division finite for anything level with or
// behind the eye, where the frustum test has already decided nothing is visible.
_flora_instance_lod :: proc(
	value: ^Flora,
	instance: ^Flora_Instance,
	view: Flora_View,
	base_radius: f32,
) -> u8 {
	assert(value != nil, "_flora_instance_lod: nil flora")
	assert(instance != nil, "_flora_instance_lod: nil instance")
	levels := value.mesh_lods[instance.mesh]
	if levels <= 1 || base_radius <= 0 do return 0
	to_instance := instance.position - view.position
	depth := max(linalg.dot(to_instance, view.forward), view.near_plane, FLORA_LOD_MIN_DEPTH)
	projection_scale := view.projection_scale
	if projection_scale <= 0 do projection_scale = 1
	apparent := base_radius * instance.scale * projection_scale / depth
	level := 0
	if apparent < FLORA_LOD_APPARENT_MID do level = 1
	if apparent < FLORA_LOD_APPARENT_FAR do level = 2
	if apparent < FLORA_LOD_APPARENT_DISTANT do level = 3
	return u8(min(level, levels - 1))
}

// _flora_tile_visible tests a stream tile's bounding sphere against the same
// conservative frustum approximation the per-instance test and terrain chunk
// culling use, so a rejected tile cannot contain a visible instance. The
// sphere derives from the span's measured world-space AABB, which works on
// both flat tiles and curved sphere-surface tiles.
_flora_tile_visible :: proc(span: Flora_Tile_Span, view: Flora_View) -> bool {
	center := (span.bounds_min + span.bounds_max) * 0.5
	half := (span.bounds_max - span.bounds_min) * 0.5
	// Pad by the tallest flora so an instance standing proud of the measured
	// anchor extent is never culled with its tile.
	radius := math.sqrt(linalg.dot(half, half)) + FLORA_TILE_BOUNDS_PAD
	to_center := center - view.position
	depth := linalg.dot(to_center, view.forward)
	if depth + radius < view.near_plane || depth - radius > view.far_plane do return false
	distance_squared := linalg.dot(to_center, to_center)
	lateral_squared := max(0, distance_squared - depth * depth)
	limit := max(depth, 0) * view.tan_limit + radius
	return lateral_squared <= limit * limit
}

_flora_draw_scan :: proc(value: ^Flora, pass: ^rl.Gpu_3D_Pass) {
	for id in Flora_Mesh_Id {
		// The flat fallback path draws level zero only. It exists for the
		// case where no visibility scan has run, which is also the case where
		// there is no view to select a level from.
		mesh := value.meshes[id][0]
		if mesh.id == 0 do continue
		count := 0
		for index in 0 ..< value.count {
			value.draw_visits += 1
			instance := &value.instances[index]
			if instance.mesh != id || instance.hidden do continue
			value.transforms[count] = flora_instance_transform(instance)
			count += 1
			value.draw_submitted += 1
		}
		if count == 0 do continue
		rl.draw_gpu_mesh_instanced(
			&pass^,
			mesh,
			value.transforms[:count],
			{
				color = _flora_draw_color(id),
				style = .Opaque,
				texture = value.atlas,
				shader = value.shader,
			},
		)
	}
}

flora_debug_outline_lod :: proc(value: ^Flora, instance_index: int) -> int {
	assert(value != nil, "flora debug outline lod: nil flora")
	if instance_index < 0 || instance_index >= value.count do return 0
	for candidate_index in 0 ..< value.candidate_count {
		if value.candidates[candidate_index] == instance_index {
			return min(int(value.candidate_lods[candidate_index]), max(value.mesh_lods[value.instances[instance_index].mesh] - 1, 0))
		}
	}
	return 0
}

flora_debug_outline_draw :: proc(
	value: ^Flora,
	pass: ^rl.Gpu_3D_Pass,
	instance_index: int,
	scale: f32,
	color: rl.Color,
) -> bool {
	assert(value != nil && pass != nil, "flora debug outline: nil input")
	if !value.ready || instance_index < 0 || instance_index >= value.count do return false
	instance := &value.instances[instance_index]
	if instance.hidden do return false
	level := flora_debug_outline_lod(value, instance_index)
	mesh := value.meshes[instance.mesh][level]
	if mesh.id == 0 {
		mesh = value.meshes[instance.mesh][0]
		if mesh.id == 0 do return false
	}
	transform := flora_instance_transform(instance) * rl.MatrixScale(scale, scale, scale)
	rl.draw_gpu_mesh(pass, mesh, transform, {color = color, style = .Silhouette_Outline})
	return true
}

_flora_candidate_visible :: proc(
	value: ^Flora,
	instance: ^Flora_Instance,
	camera: rl.Camera3D,
	target: ^rl.Gpu_3D_Target = nil,
) -> bool {
	assert(value != nil, "_flora_candidate_visible: nil flora")
	view, view_ok := _flora_view_make(camera, target)
	if !view_ok do return true
	bounds := value.mesh_bounds[instance.mesh]
	local_center := (bounds.minimum + bounds.maximum) * 0.5
	diagonal := bounds.maximum - bounds.minimum
	radius := math.sqrt(linalg.dot(diagonal, diagonal)) * 0.5
	prepared := instance^
	prepared.cos_yaw = math.cos(instance.yaw)
	prepared.sin_yaw = math.sin(instance.yaw)
	return _flora_instance_visible(&prepared, view, local_center, radius)
}

_flora_view_make :: proc(
	camera: rl.Camera3D,
	target: ^rl.Gpu_3D_Target = nil,
) -> (
	view: Flora_View,
	ok: bool,
) {
	forward := camera.target - camera.position
	forward_length := math.sqrt(linalg.dot(forward, forward))
	if forward_length <= 0 do return {}, false
	return {
			position = camera.position,
			forward = forward / forward_length,
			near_plane = camera.near_plane,
			far_plane = camera.far_plane,
			projection_scale = 1 / max(2 * math.tan(camera.fovy * math.PI / 360), 0.001),
			tan_limit = _view_tan_limit(camera.fovy, _view_aspect(target)),
		},
		true
}

// _view_aspect reports the width/height ratio of the surface the pass actually
// projects onto. The 3D target is the authority - it is what begin_gpu_3d
// builds the projection from - and the screen query is only a fallback for
// callers that have no target to hand.
_view_aspect :: proc(target: ^rl.Gpu_3D_Target) -> f32 {
	if target != nil {
		if width, height, size_ok := rl.gpu_3d_target_size(target); size_ok {
			return f32(max(width, 1)) / f32(max(height, 1))
		}
	}
	return f32(max(rl.GetScreenWidth(), 1)) / f32(max(rl.GetScreenHeight(), 1))
}

// _view_tan_limit is the lateral half-extent per unit of depth of the smallest
// cone containing the frustum.
//
// The widest in-frustum direction is a frustum corner, not an edge midpoint: at
// depth d a visible point satisfies |y| <= d*tan(fovy/2) and
// |x| <= d*tan(fovy/2)*aspect, so the largest lateral distance is the corner at
// d*tan(fovy/2)*sqrt(1 + aspect^2). Using aspect alone makes the cone narrower
// than the frustum, and every caller here culls on it - a cone that is too
// narrow drops visible terrain chunks in the screen corners, which reads as sky
// punched through the ground.
_view_tan_limit :: proc(fovy, aspect: f32) -> f32 {
	assert(fovy > 0, "_view_tan_limit: non-positive fovy")
	assert(fovy < 180, "_view_tan_limit: fovy outside range")
	assert(aspect > 0, "_view_tan_limit: non-positive aspect")
	return math.tan(fovy * math.PI / 360) * math.sqrt(1 + aspect * aspect)
}

_flora_instance_visible :: proc(
	instance: ^Flora_Instance,
	view: Flora_View,
	local_center: [3]f32,
	base_radius: f32,
) -> bool {
	rotated := [3]f32 {
		instance.cos_yaw * local_center.x - instance.sin_yaw * local_center.y,
		instance.sin_yaw * local_center.x + instance.cos_yaw * local_center.y,
		local_center.z,
	}
	center :=
		instance.position +
		instance.scale *
			(instance.east * rotated.x + instance.north * rotated.y + instance.up * rotated.z)
	to_center := center - view.position
	depth := linalg.dot(to_center, view.forward)
	radius := base_radius * instance.scale
	if depth + radius < view.near_plane || depth - radius > view.far_plane do return false
	distance_squared := linalg.dot(to_center, to_center)
	lateral_squared := max(0, distance_squared - depth * depth)
	limit := max(depth, 0) * view.tan_limit + radius
	return lateral_squared <= limit * limit
}

// _flora_draw_candidates buckets the visible candidates by mesh id and level in
// one pass (count, prefix-sum, fill) and submits one instanced draw per
// populated bucket, so per-frame work is proportional to the visible count
// instead of bucket_count * candidate_count.
_flora_draw_candidates :: proc(value: ^Flora, pass: ^rl.Gpu_3D_Pass) {
	counts: [Flora_Mesh_Id][FLORA_LOD_COUNT]int
	for candidate in 0 ..< value.candidate_count {
		instance := &value.instances[value.candidates[candidate]]
		if instance.hidden do continue
		counts[instance.mesh][value.candidate_lods[candidate]] += 1
	}
	offsets: [Flora_Mesh_Id][FLORA_LOD_COUNT]int
	total := 0
	for id in Flora_Mesh_Id {
		for level in 0 ..< FLORA_LOD_COUNT {
			offsets[id][level] = total
			total += counts[id][level]
		}
	}
	cursors := offsets
	for candidate in 0 ..< value.candidate_count {
		value.draw_visits += 1
		instance := &value.instances[value.candidates[candidate]]
		if instance.hidden do continue
		level := int(value.candidate_lods[candidate])
		value.transforms[cursors[instance.mesh][level]] = flora_instance_transform(instance)
		cursors[instance.mesh][level] += 1
		value.draw_submitted += 1
	}
	for id in Flora_Mesh_Id {
		for level in 0 ..< FLORA_LOD_COUNT {
			count := counts[id][level]
			mesh := value.meshes[id][level]
			if count == 0 || mesh.id == 0 do continue
			offset := offsets[id][level]
			rl.draw_gpu_mesh_instanced(
				&pass^,
				mesh,
				value.transforms[offset:offset + count],
				{
					color = _flora_draw_color(id),
					style = .Opaque,
					texture = value.atlas,
					shader = value.shader,
				},
			)
		}
	}
}

// _flora_mesh_chain_destroy releases every uploaded level of one variant.
_flora_mesh_chain_destroy :: proc(chain: ^[FLORA_LOD_COUNT]rl.Gpu_Mesh) {
	assert(chain != nil, "_flora_mesh_chain_destroy: nil chain")
	for level in 0 ..< FLORA_LOD_COUNT {
		if chain[level].id != 0 do rl.destroy_gpu_mesh(&chain[level])
	}
	chain^ = {}
}

// _flora_instance_transform is provided by the demo seam
// (flora_instance_transform): flat worlds compose translate * rotate_z *
// uniform_scale directly from the baked yaw trig; spherical worlds compose
// the tangent frame with the local yaw so the mesh stands on the surface
// normal.

// _flora_sink is how far a variant's origin sits below the ground line so
// bases never float on slopes.
_flora_sink :: proc(id: Flora_Mesh_Id) -> f32 {
	switch id {
	case .Conifer_A, .Conifer_B, .Baobab, .Shrub_Rounded, .Tree_Open, .Shrub_Upright,
	     .Conifer_Wide, .Conifer_Narrow, .Baobab_Wide, .Tree_Open_Tall,
	     .Shrub_Rounded_Wide, .Shrub_Upright_Tall:
		return 0.12
	case .Grass_Upright, .Grass_Crossed, .Grass_Reed, .Grass_Tuft:
		return 0.03
	case .Boulder_A, .Boulder_B, .Boulder_C:
		return 0.18
	case .Rock_A, .Rock_B:
		return 0.10
	case:
		return 0
	}
}

_flora_is_grass :: proc(id: Flora_Mesh_Id) -> bool {
	return id == .Grass_Upright || id == .Grass_Crossed || id == .Grass_Reed || id == .Grass_Tuft
}

_flora_is_shrub :: proc(id: Flora_Mesh_Id) -> bool {
	return id == .Shrub_Rounded || id == .Shrub_Upright || id == .Shrub_Rounded_Wide || id == .Shrub_Upright_Tall
}

_flora_is_tree :: proc(id: Flora_Mesh_Id) -> bool {
	return id == .Conifer_A || id == .Conifer_B || id == .Baobab || id == .Tree_Open ||
		id == .Conifer_Wide || id == .Conifer_Narrow || id == .Baobab_Wide || id == .Tree_Open_Tall
}

_flora_draw_color :: proc(id: Flora_Mesh_Id) -> rl.Color {
	switch id {
	case .Grass_Upright:
		return {142, 146, 62, 255}
	case .Grass_Crossed:
		return {72, 142, 62, 255}
	case .Grass_Reed:
		return {48, 126, 68, 255}
	case .Grass_Tuft:
		return {65, 136, 58, 255}
	case .Conifer_A, .Conifer_B, .Baobab, .Shrub_Rounded, .Tree_Open, .Shrub_Upright,
	     .Conifer_Wide, .Conifer_Narrow, .Baobab_Wide, .Tree_Open_Tall,
	     .Shrub_Rounded_Wide, .Shrub_Upright_Tall, .Boulder_A, .Boulder_B, .Boulder_C,
	     .Rock_A, .Rock_B:
		return rl.WHITE
	}
	return rl.WHITE
}

// ---------------------------------------------------------------------------
// Scatter
// ---------------------------------------------------------------------------

// The instance array is partitioned into fixed-capacity per-tile pools: slot
// `s` owns instances [s * FLORA_TILE_CAPACITY, (s+1) * FLORA_TILE_CAPACITY),
// large flora at the front of the chunk and ground flora from offset
// FLORA_TILE_LARGE_CAPACITY. Tiles enter and exit the streaming window
// without moving any other tile's instances, so Box3D proxy user data
// (absolute instance indices) stays valid across crossings and retained
// tiles keep their physics-corrected heights.

Flora_Scatter_Pass :: enum {
	Large,
	Ground,
}

// _flora_scatter_tile_into fills one tile's instances from a deterministic
// hash per cell, gated by the same climate the terrain bake reads: moist flat
// lowland grows trees (denser with moisture), steep or high ground sheds
// boulders, and dry flats get sparse scree. Cells near resource nodes stay
// clear so deposits keep their silhouette. Hashes use absolute world cells,
// so a tile regenerates identically whenever it re-enters the window.
//
// probe selects the seat source: the Box3D raycast (main thread only — the
// physics world is not thread-safe) or the cached analytic grid (background
// thread; the reseat sweep corrects the ~0.3 unit divergence afterwards).
// spawn_height always records the cached grid, because that is what the
// uproot test in the sweep compares against.
_flora_scatter_tile_into :: proc(
	buffer: ^[FLORA_TILE_CAPACITY]Flora_Instance,
	count: ^int,
	terrain: ^Terrain,
	world: ^shared.World,
	ruins: ^Ruins,
	tile: Flora_Tile_Id,
	node_positions: [][3]f32,
	sea, snow: f32,
	pass: Flora_Scatter_Pass,
	probe: bool,
) {
	config := flora_default_config()
	cell_size := pass == .Large ? FLORA_LARGE_CELL : FLORA_GROUND_CELL
	cells := pass == .Large ? FLORA_LARGE_CELLS_PER_TILE : FLORA_GROUND_CELLS_PER_TILE
	capacity := pass == .Large ? FLORA_TILE_LARGE_CAPACITY : FLORA_TILE_CAPACITY
	seed := pass == .Large ? world.foundation.seed : world.foundation.seed ~ 0x6A0D_C10D
	// Cube faces reuse the same face-local cell coordinates, so the face is
	// folded into the seed; flat worlds (face -1) keep the original seed and
	// therefore the original scatter, byte for byte.
	if tile.face >= 0 do seed ~= (u64(tile.face) + 1) * 0x9E3779B97F4A7C15
	node_clearance := pass == .Large ? FLORA_NODE_CLEARANCE : FLORA_NODE_CLEARANCE + 1.1
	ruin_clearance := pass == .Large ? RUIN_CLEARANCE : RUIN_CLEARANCE + 1.1
	building_margin := pass == .Large ? f32(0.5) : f32(1.6)
	base_x := tile.tile_u * i32(cells)
	base_y := tile.tile_v * i32(cells)
	for local_y in 0 ..< cells {
		for local_x in 0 ..< cells {
			cell_x := base_x + i32(local_x)
			cell_y := base_y + i32(local_y)
			hash := _flora_hash(seed, cell_x, cell_y)
			jitter_x :=
				pass == .Large ? 0.15 + 0.7 * _flora_hash_unit(hash, 0) : 0.1 + 0.8 * _flora_hash_unit(hash, 0)
			jitter_y :=
				pass == .Large ? 0.15 + 0.7 * _flora_hash_unit(hash, 1) : 0.1 + 0.8 * _flora_hash_unit(hash, 1)
			position, in_world := flora_scatter_position(
				world,
				tile,
				cell_x,
				cell_y,
				jitter_x,
				jitter_y,
				cell_size,
			)
			if !in_world do continue
			blocked := false
			for node_position in node_positions {
				if flora_surface_distance_squared(position, node_position) <
				   node_clearance * node_clearance {
					blocked = true
					break
				}
			}
			if blocked do continue
			if flora_ruins_blocks(ruins, position, ruin_clearance) do continue
			if flora_building_blocks(world, position, building_margin) do continue
			if !flora_placement_allowed(world, position) do continue
			sample, height := flora_scatter_sample(world, position)
			mesh: Flora_Mesh_Id
			scale: f32
			keep: bool
			emergence := u16(_flora_hash_unit(hash, 6) * 10_000)
			visual, biological := flora_ecology_visual(
				world,
				position,
				emergence,
			)
			ecology_enabled := flora_ecology_enabled(world)
			mesh, scale, keep = _flora_pick_ecology(pass, visual, biological)
			// Only ecology picks grow in; hash-deterministic rocks, scree and
			// ecology-disabled placements never change, so they spawn full size.
			grows := keep
			if pass == .Large {
				if !keep {
					logical_sample := flora_collision_sample(world, position)
					logical := shared.flora_logical_solid(seed, hash, logical_sample)
					if !ecology_enabled || logical.kind >= .Boulder_A {
						mesh, scale, keep = _flora_pick_logical(logical)
					}
				}
				if !keep {
					mesh, scale, keep = _flora_pick_scree(config, sample, height, sea, hash)
				}
			} else if !keep && !ecology_enabled {
				mesh, scale, keep = _flora_pick_ground(config, sample, height, sea, snow, hash)
			}
			if !keep do continue
			assert(count^ < capacity, "_flora_scatter_tile_into: tile pool overflow")
			cell := u32(local_y * cells + local_x) * FLORA_GRASS_CLUSTER
			yaw := _flora_hash_unit(hash, 3) * 2 * math.PI
			seated, cached := flora_seat_position(
				terrain,
				position,
				mesh,
				scale,
				probe ? Flora_Seat_Mode.Probe : Flora_Seat_Mode.Cached,
			)
			up, east, north := flora_scatter_basis(position)
			buffer[count^] = {
				position     = seated,
				direction    = up,
				up           = up,
				east         = east,
				north        = north,
				spawn_height = cached,
				yaw          = yaw,
				cos_yaw      = math.cos(yaw),
				sin_yaw      = math.sin(yaw),
				scale        = grows ? 0 : scale,
				target_scale = scale,
				lineage      = visual.lineage,
				cell         = cell,
				emergence    = emergence,
				mesh         = mesh,
			}
			count^ += 1
			// Vegetated ground grows a small blade cluster around the primary:
			// extras hash off the same absolute cell, so revisited tiles stay
			// identical. Extras skip the blocker re-checks — they sit within a
			// unit of the checked primary, inside the ground pass margins.
			if pass == .Ground &&
			   _flora_is_grass(mesh) &&
			   _flora_ground_density(sample.primary_biome) >= FLORA_GRASS_CLUSTER_DENSITY_MIN {
				for extra in 1 ..< FLORA_GRASS_CLUSTER {
					extra_hash := _flora_mix(hash ~ (0x6C05_7E12 + u64(extra)))
					offset_angle := _flora_hash_unit(extra_hash, 0) * 2 * math.PI
					offset_radius :=
						(0.25 + 0.55 * _flora_hash_unit(extra_hash, 1)) * cell_size * 0.5
					// Tangent-frame polar offset: on a flat world east/north
					// are the world X/Y axes, so this reduces to the original
					// cos/sin offsets exactly.
					extra_position :=
						position +
						east * (math.cos(offset_angle) * offset_radius) +
						north * (math.sin(offset_angle) * offset_radius)
					if !flora_position_in_world(extra_position) do continue
					extra_scale := scale * (0.75 + 0.4 * _flora_hash_unit(extra_hash, 2))
					extra_yaw := _flora_hash_unit(extra_hash, 3) * 2 * math.PI
					extra_seated, extra_cached := flora_seat_position(
						terrain,
						extra_position,
						mesh,
						extra_scale,
						probe ? Flora_Seat_Mode.Probe : Flora_Seat_Mode.Cached,
					)
					extra_up, extra_east, extra_north := flora_scatter_basis(extra_position)
					assert(count^ < capacity, "_flora_scatter_tile_into: tile pool overflow")
					buffer[count^] = {
						position      = extra_seated,
						direction     = extra_up,
						up            = extra_up,
						east          = extra_east,
						north         = extra_north,
						spawn_height  = extra_cached,
						yaw           = extra_yaw,
						cos_yaw       = math.cos(extra_yaw),
						sin_yaw       = math.sin(extra_yaw),
						scale         = grows ? 0 : extra_scale,
						target_scale  = extra_scale,
						lineage       = visual.lineage,
						cell          = cell + u32(extra),
						emergence     = emergence,
						mesh          = mesh,
						cluster_extra = true,
					}
					count^ += 1
				}
			}
		}
	}
}

// _flora_scatter_nodes_collect gathers resource-node anchors inside the
// streaming window around center_tile; scatter candidates keep deposits
// readable and never overlap an existing footprint. The window membership
// test is the demo seam flora_node_window_contains.
_flora_scatter_nodes_collect :: proc(
	world: ^shared.World,
	center_tile: Flora_Tile_Id,
	node_positions: ^[shared.MAX_BUILDINGS][3]f32,
) -> int {
	node_count := 0
	nodes := &world.nodes
	for index in 0 ..< ecs.set_len(nodes) {
		entity := nodes.header.entities[index]
		transform, ok := ecs.get(&world.transforms, entity)
		if !ok do continue
		if !flora_node_window_contains(center_tile, transform.position) do continue
		if node_count >= len(node_positions) do break
		node_positions[node_count] = transform.position
		node_count += 1
	}
	return node_count
}

_flora_rescatter_slot :: proc(
	value: ^Flora,
	terrain: ^Terrain,
	world: ^shared.World,
	ruins: ^Ruins,
	slot: int,
) {
	span := &value.tiles[slot]
	if !span.occupied do return
	base := slot * FLORA_TILE_CAPACITY
	buffer := cast(^[FLORA_TILE_CAPACITY]Flora_Instance)&value.instances[base]
	// Stream updates run on the main thread only, so one scratch tile is
	// enough to keep the previous scatter while the new one is written.
	@(static) previous: [FLORA_TILE_CAPACITY]Flora_Instance
	previous = buffer^
	previous_large_end := int(span.large_end) - base
	previous_ground_end := int(span.ground_end) - base
	node_positions: [shared.MAX_BUILDINGS][3]f32
	node_count := _flora_scatter_nodes_collect(world, value.stream_tile, &node_positions)
	large_count := 0
	_flora_scatter_tile_into(buffer, &large_count, terrain, world, ruins, span.tile, node_positions[:node_count], terrain.sea_level, terrain.snow_level, .Large, true)
	ground_end := FLORA_TILE_LARGE_CAPACITY
	_flora_scatter_tile_into(buffer, &ground_end, terrain, world, ruins, span.tile, node_positions[:node_count], terrain.sea_level, terrain.snow_level, .Ground, true)
	_flora_carry_scale(previous[:previous_large_end], buffer[:large_count])
	_flora_carry_scale(
		previous[FLORA_TILE_LARGE_CAPACITY:max(previous_ground_end, FLORA_TILE_LARGE_CAPACITY)],
		buffer[FLORA_TILE_LARGE_CAPACITY:ground_end],
	)
	span.large_begin = i32(base)
	span.large_end = i32(base + large_count)
	span.ground_begin = i32(base + FLORA_TILE_LARGE_CAPACITY)
	span.ground_end = i32(base + ground_end)
	span.ecology_revision = value.ecology_revision
	span.reseated = true
	_flora_span_bounds(value, span)
	_flora_recount(value)
	value.candidate_count = 0
}

// _flora_carry_scale keeps the current size of every instance that survives
// an ecology rescatter unchanged: both ranges are emitted in raster cell
// order, so a single merge walk pairs old and new by cell key. Only a same-mesh
// match carries; a succession (mesh change) grows in from zero as before.
_flora_carry_scale :: proc(previous, current: []Flora_Instance) {
	previous_index := 0
	for &instance in current {
		for previous_index < len(previous) && previous[previous_index].cell < instance.cell {
			previous_index += 1
		}
		if previous_index >= len(previous) do break
		old := previous[previous_index]
		if old.cell != instance.cell || old.mesh != instance.mesh do continue
		instance.scale = old.scale
	}
}

// _flora_scatter_pooled rebuilds the whole window synchronously into the
// per-tile pool layout, probing the physics surface for seats. Used for the
// initial scatter, flora_regenerate, and the teleport fallback where more
// tiles enter than the incremental path can stage.
_flora_scatter_pooled :: proc(
	value: ^Flora,
	terrain: ^Terrain,
	world: ^shared.World,
	ruins: ^Ruins,
	center_tile: Flora_Tile_Id,
) {
	value.ecology_revision = flora_ecology_revision(world)
	sea := terrain.sea_level
	snow := terrain.snow_level
	window: [FLORA_STREAM_TILE_COUNT]Flora_Tile_Id
	window_count := flora_stream_window(center_tile, &window)
	node_positions: [shared.MAX_BUILDINGS][3]f32
	node_count := _flora_scatter_nodes_collect(world, center_tile, &node_positions)
	value.tiles = {}
	value.tile_count = FLORA_STREAM_TILE_COUNT
	value.free_slot_count = 0
	slot := 0
	for window_index in 0 ..< window_count {
		tile := window[window_index]
		assert(slot < FLORA_STREAM_TILE_COUNT, "_flora_scatter_pooled: tile slot overflow")
		base := slot * FLORA_TILE_CAPACITY
		buffer := cast(^[FLORA_TILE_CAPACITY]Flora_Instance)&value.instances[base]
		large_count := 0
		_flora_scatter_tile_into(
			buffer,
			&large_count,
			terrain,
			world,
			ruins,
			tile,
			node_positions[:node_count],
			sea,
			snow,
			.Large,
			true,
		)
		ground_end := FLORA_TILE_LARGE_CAPACITY
		_flora_scatter_tile_into(
			buffer,
			&ground_end,
			terrain,
			world,
			ruins,
			tile,
			node_positions[:node_count],
			sea,
			snow,
			.Ground,
			true,
		)
		span := &value.tiles[slot]
		span^ = {
			tile             = tile,
			ecology_revision = value.ecology_revision,
			large_begin      = i32(base),
			large_end        = i32(base + large_count),
			ground_begin     = i32(base + FLORA_TILE_LARGE_CAPACITY),
			ground_end       = i32(base + ground_end),
			occupied         = true,
			// The physics probe already seated every instance, so the
			// sweep starts idle; flora_mark_dirty rearms it.
			reseated         = true,
		}
		_flora_span_bounds(value, span)
		slot += 1
	}
	// Slots beyond the clamped window start free for entering tiles.
	for free in slot ..< FLORA_STREAM_TILE_COUNT {
		value.free_slots[value.free_slot_count] = i32(free)
		value.free_slot_count += 1
	}
	_flora_recount(value)
	value.candidate_count = 0
}

// _flora_span_bounds fills one span's world-space AABB from the instances it
// owns; the cull derives a bounding sphere from it.
_flora_span_bounds :: proc(value: ^Flora, span: ^Flora_Tile_Span) {
	bounds_min := [3]f32{max(f32), max(f32), max(f32)}
	bounds_max := [3]f32{-max(f32), -max(f32), -max(f32)}
	for index in span.large_begin ..< span.large_end {
		p := value.instances[index].position
		bounds_min = linalg.min(bounds_min, p)
		bounds_max = linalg.max(bounds_max, p)
	}
	for index in span.ground_begin ..< span.ground_end {
		p := value.instances[index].position
		bounds_min = linalg.min(bounds_min, p)
		bounds_max = linalg.max(bounds_max, p)
	}
	if bounds_min.x > bounds_max.x {
		// Empty tile: a degenerate box the cull rejects cheaply.
		bounds_min, bounds_max = {}, {}
	}
	span.bounds_min = bounds_min
	span.bounds_max = bounds_max
}

_flora_tile_bounds_build :: proc(value: ^Flora) {
	assert(value != nil, "_flora_tile_bounds_build: nil flora")
	for slot in 0 ..< value.tile_count {
		_flora_span_bounds(value, &value.tiles[slot])
	}
}

// _flora_recount sums the instance ranges of every occupied span; count is a
// derived total used for draw stats and the Box3D culling threshold.
_flora_recount :: proc(value: ^Flora) {
	total := 0
	for slot in 0 ..< value.tile_count {
		span := &value.tiles[slot]
		if !span.occupied do continue
		total += int(span.large_end - span.large_begin)
		total += int(span.ground_end - span.ground_begin)
	}
	value.count = total
}

// _flora_index_ranges collects the instance index ranges to visit: one range
// per populated span half when spans exist, else the flat [0, count) range so
// synthetic test flora without span bookkeeping still scans correctly.
_flora_index_ranges :: proc(
	value: ^Flora,
	ranges: ^[2 * FLORA_STREAM_TILE_COUNT + 1][2]i32,
) -> int {
	if value.tile_count == 0 {
		ranges[0] = {0, i32(value.count)}
		return 1
	}
	total := 0
	for slot in 0 ..< value.tile_count {
		span := &value.tiles[slot]
		if !span.occupied do continue
		if span.large_end > span.large_begin {
			ranges[total] = {span.large_begin, span.large_end}
			total += 1
		}
		if span.ground_end > span.ground_begin {
			ranges[total] = {span.ground_begin, span.ground_end}
			total += 1
		}
	}
	return total
}

// _flora_compute_enter_exit emits one bounded convergence batch. Desired tiles
// keep stream-window order, so revisiting a location remains deterministic.
_flora_compute_enter_exit :: proc(
	value: ^Flora,
	new_center: Flora_Tile_Id,
	enter_tiles: ^[FLORA_MAX_ENTER_TILES]Flora_Tile_Id,
	enter_count: ^int,
	exit_slots: ^[FLORA_STREAM_TILE_COUNT]i32,
	exit_count: ^int,
) -> (more: bool) {
	window: [FLORA_STREAM_TILE_COUNT]Flora_Tile_Id
	window_count := flora_stream_window(new_center, &window)
	enter_count^ = 0
	exit_count^ = 0
	obsolete: [FLORA_STREAM_TILE_COUNT]i32
	obsolete_count := 0
	for slot in 0 ..< value.tile_count {
		span := &value.tiles[slot]
		if !span.occupied do continue
		inside := false
		for window_index in 0 ..< window_count {
			if flora_tile_eq(span.tile, window[window_index]) {
				inside = true
				break
			}
		}
		if inside do continue
		obsolete[obsolete_count] = i32(slot)
		obsolete_count += 1
	}
	missing_count := 0
	for window_index in 0 ..< window_count {
		tile := window[window_index]
		resident := false
		for slot in 0 ..< value.tile_count {
			span := &value.tiles[slot]
			if span.occupied && flora_tile_eq(span.tile, tile) {
				resident = true
				break
			}
		}
		if resident do continue
		missing_count += 1
		if enter_count^ < FLORA_MAX_ENTER_TILES {
			enter_tiles[enter_count^] = tile
			enter_count^ += 1
		}
	}
	required_exits := max(0, enter_count^ - value.free_slot_count)
	if enter_count^ == 0 do required_exits = min(obsolete_count, FLORA_MAX_ENTER_TILES)
	required_exits = min(required_exits, obsolete_count)
	for index in 0 ..< required_exits do exit_slots[index] = obsolete[index]
	exit_count^ = required_exits
	return missing_count > enter_count^ || obsolete_count > exit_count^
}

// _flora_scatter_incremental_staged_range fills a bounded range of entering
// tiles using only thread-safe reads. Native workers use the whole range while
// serial fallback advances one tile per frame.
_flora_scatter_incremental_staged_range :: proc(
	load: ^Flora_Scatter_Load,
	begin, end: int,
) {
	assert(load != nil, "_flora_scatter_incremental_staged_range: nil load")
	assert(begin >= 0 && begin <= end, "_flora_scatter_incremental_staged_range: bad range")
	assert(end <= load.enter_tile_count, "_flora_scatter_incremental_staged_range: range overflow")
	terrain := load.terrain
	world := load.world
	ruins := load.ruins
	sea := terrain.sea_level
	snow := terrain.snow_level
	node_positions: [shared.MAX_BUILDINGS][3]f32
	node_count := _flora_scatter_nodes_collect(world, load.center_tile, &node_positions)
	for i in begin ..< end {
		span := &load.enter_tiles[i]
		span.ecology_revision = flora_ecology_revision(world)
		buffer := &load.enter_instances[i]
		large_count := 0
		_flora_scatter_tile_into(
			buffer,
			&large_count,
			terrain,
			world,
			ruins,
			span.tile,
			node_positions[:node_count],
			sea,
			snow,
			.Large,
			false,
		)
		ground_end := FLORA_TILE_LARGE_CAPACITY
		_flora_scatter_tile_into(
			buffer,
			&ground_end,
			terrain,
			world,
			ruins,
			span.tile,
			node_positions[:node_count],
			sea,
			snow,
			.Ground,
			false,
		)
		span.large_begin = 0
		span.large_end = i32(large_count)
		span.ground_begin = i32(FLORA_TILE_LARGE_CAPACITY)
		span.ground_end = i32(ground_end)
		span.occupied = true
		span.reseated = false
		bounds_min := [3]f32{max(f32), max(f32), max(f32)}
		bounds_max := [3]f32{-max(f32), -max(f32), -max(f32)}
		for index in 0 ..< large_count {
			p := buffer[index].position
			bounds_min = linalg.min(bounds_min, p)
			bounds_max = linalg.max(bounds_max, p)
		}
		for index in FLORA_TILE_LARGE_CAPACITY ..< ground_end {
			p := buffer[index].position
			bounds_min = linalg.min(bounds_min, p)
			bounds_max = linalg.max(bounds_max, p)
		}
		if bounds_min.x > bounds_max.x {
			bounds_min, bounds_max = {}, {}
		}
		span.bounds_min = bounds_min
		span.bounds_max = bounds_max
	}
}

_flora_scatter_incremental_staged :: proc(load: ^Flora_Scatter_Load) {
	assert(load != nil, "_flora_scatter_incremental_staged: nil load")
	_flora_scatter_incremental_staged_range(load, 0, load.enter_tile_count)
}

// _flora_scatter_swap_incremental_step applies at most one exiting and one
// entering tile, keeping the frame-thread commit bounded.
_flora_scatter_swap_incremental_step :: proc(value: ^Flora) -> (finished: bool) {
	assert(value != nil, "_flora_scatter_swap_incremental_step: nil flora")
	load := value.scatter_load
	work_count := max(load.exit_count, load.enter_tile_count)
	if load.commit_index >= work_count do return true
	i := load.commit_index
	if i < load.exit_count {
		slot := int(load.exit_slots[i])
		value.tiles[slot] = {}
		value.free_slots[value.free_slot_count] = i32(slot)
		value.free_slot_count += 1
	}
	if i < load.enter_tile_count {
		assert(value.free_slot_count > 0, "_flora_scatter_swap_incremental_step: no free slots")
		value.free_slot_count -= 1
		slot := int(value.free_slots[value.free_slot_count])
		base := slot * FLORA_TILE_CAPACITY
		staged := &load.enter_tiles[i]
		source := &load.enter_instances[i]
		large_count := int(staged.large_end - staged.large_begin)
		ground_count := int(staged.ground_end - staged.ground_begin)
		for j in 0 ..< large_count do value.instances[base + j] = source[j]
		for j in 0 ..< ground_count {
			value.instances[base + FLORA_TILE_LARGE_CAPACITY + j] =
				source[FLORA_TILE_LARGE_CAPACITY + j]
		}
		value.tiles[slot] = {
			tile             = staged.tile,
			ecology_revision = staged.ecology_revision,
			large_begin      = i32(base),
			large_end        = i32(base + large_count),
			ground_begin     = i32(base + FLORA_TILE_LARGE_CAPACITY),
			ground_end       = i32(base + FLORA_TILE_LARGE_CAPACITY + ground_count),
			bounds_min       = staged.bounds_min,
			bounds_max       = staged.bounds_max,
			occupied         = true,
			reseated         = false,
		}
	}
	load.commit_index += 1
	_flora_recount(value)
	value.candidate_count = 0
	return load.commit_index >= work_count
}

// flora_building_blocks (whether a scatter candidate overlaps a building
// footprint expanded by margin) is provided by the demo seam: flat worlds
// test the grid-aligned AABB, spherical worlds test the footprint rectangle
// in the building's tangent frame.

_flora_pick_ecology :: proc(
	pass: Flora_Scatter_Pass,
	sample: Flora_Ecology_Visual,
	biological: bool,
) -> (Flora_Mesh_Id, f32, bool) {
	if !biological do return .Rock_A, 1, false
	if pass == .Ground {
		if sample.form > u8(3) do return .Rock_A, 1, false
		return _flora_ecology_ground_mesh(sample), _flora_ecology_scale(sample), true
	}
	if sample.form < u8(4) do return .Rock_A, 1, false
	return _flora_ecology_woody_mesh(sample), _flora_ecology_scale(sample), true
}

_flora_ecology_scale :: proc(sample: Flora_Ecology_Visual) -> f32 {
	maturity := clamp(f32(sample.age_steps) / 64, 0.15, 1)
	biomass := clamp(f32(sample.biomass) / 1_000_000, 0.2, 1)
	stature := 0.8 + clamp(f32(sample.stature), 1, 1000) / 2500
	if sample.form <= u8(3) do return (0.25 + biomass * 0.75) * maturity * stature
	if sample.form == u8(4) do return (0.2 + biomass * 0.35) * maturity * stature
	return (0.35 + biomass * 0.65) * maturity * stature
}

_flora_ecology_ground_mesh :: proc(sample: Flora_Ecology_Visual) -> Flora_Mesh_Id {
	return FLORA_GROUND_MESHES[min(int(sample.morphology_family), len(FLORA_GROUND_MESHES) - 1)]
}

_flora_ecology_woody_mesh :: proc(sample: Flora_Ecology_Visual) -> Flora_Mesh_Id {
	if sample.form == u8(4) {
		return FLORA_SHRUB_MESHES[min(int(sample.morphology_family), len(FLORA_SHRUB_MESHES) - 1)]
	}
	return FLORA_TREE_MESHES[min(int(sample.morphology_family), len(FLORA_TREE_MESHES) - 1)]
}

_flora_pick_logical :: proc(result: shared.Flora_Logical_Result) -> (Flora_Mesh_Id, f32, bool) {
	if result.kind == .None do return .Rock_A, 1, false
	mesh: Flora_Mesh_Id
	switch result.kind {
	case .Conifer_A: mesh = .Conifer_A
	case .Conifer_B: mesh = .Conifer_B
	case .Baobab: mesh = .Baobab
	case .Boulder_A: mesh = .Boulder_A
	case .Boulder_B: mesh = .Boulder_B
	case .Boulder_C: mesh = .Boulder_C
	case .None: return .Rock_A, 1, false
	}
	size := f32(result.scale_channel) / 511
	if result.kind >= .Conifer_A && result.kind <= .Baobab {
		return mesh, FLORA_TREE_SCALE_MIN + FLORA_TREE_SCALE_VARIATION * size, true
	}
	return mesh, 0.7 + 0.7 * size, true
}

_flora_pick_scree :: proc(
	config: Flora_Config,
	sample: shared.Terrain_Sample,
	height, sea: f32,
	hash: u64,
) -> (Flora_Mesh_Id, f32, bool) {
	variant := _flora_hash_unit(hash, 4)
	size := _flora_hash_unit(hash, 5)
	scree_roll := _flora_hash_unit(_flora_mix(hash ~ 0x5C2E_E5E1), 0)
	if height > sea + 0.3 && sample.moisture < 0.55 && scree_roll < config.scree_chance {
		mesh := Flora_Mesh_Id.Rock_A if variant < 0.5 else .Rock_B
		return mesh, 0.7 + 0.6 * size, true
	}
	return .Rock_A, 1, false
}

_flora_pick_large :: proc(
	config: Flora_Config,
	sample: shared.Terrain_Sample,
	height, sea, snow: f32,
	hash: u64,
) -> (
	mesh: Flora_Mesh_Id,
	scale: f32,
	keep: bool,
) {
	variant := _flora_hash_unit(hash, 4)
	size := _flora_hash_unit(hash, 5)
	tree_roll := _flora_hash_unit(_flora_mix(hash ~ 0x71EE_5EED), 0)
	boulder_roll := _flora_hash_unit(_flora_mix(hash ~ 0xB0A1_DE55), 0)
	scree_roll := _flora_hash_unit(_flora_mix(hash ~ 0x5C2E_E5E1), 0)
	// Trees: moist, flat, above the beach, below the snow line. Density
	// scales with moisture so lush basins read as woods, dry rims stay open,
	// then the biome sets how wooded the region is overall.
	if height > sea + 0.5 &&
	   height < snow - 0.5 &&
	   sample.slope < shared.PLACEMENT_MAX_SLOPE &&
	   sample.moisture > config.tree_moisture_min {
		grove := _flora_grove_mask(hash)
		chance := clamp(
			(sample.moisture - config.tree_moisture_min) * config.tree_chance_scale * grove,
			0,
			config.tree_chance_max,
		)
		chance *= _flora_tree_density(sample.primary_biome)
		if tree_roll < chance {
			altitude := clamp((height - sea) / max(snow - sea, 0.001), 0, 1)
			mesh = _flora_tree_species(sample.primary_biome, variant, altitude)
			return mesh, FLORA_TREE_SCALE_MIN + FLORA_TREE_SCALE_VARIATION * size, true
		}
	}
	// Boulders: steep faces and the snow-line band.
	steep := sample.slope > 0.45 && sample.slope < 1.4
	alpine := height > snow - 2.5
	if (steep || alpine) && height > sea + 0.3 && boulder_roll < config.boulder_chance {
		boulder_pick := int(variant * 3)
		mesh = .Boulder_A
		if boulder_pick == 1 do mesh = .Boulder_B
		if boulder_pick == 2 do mesh = .Boulder_C
		return mesh, 0.7 + 0.7 * size, true
	}
	// Sparse scree on any dry open ground.
	if height > sea + 0.3 && sample.moisture < 0.55 && scree_roll < config.scree_chance {
		mesh = .Rock_A if variant < 0.5 else .Rock_B
		return mesh, 0.7 + 0.6 * size, true
	}
	return .Rock_A, 1, false
}

_flora_pick_ground :: proc(
	config: Flora_Config,
	sample: shared.Terrain_Sample,
	height, sea, snow: f32,
	hash: u64,
) -> (
	mesh: Flora_Mesh_Id,
	scale: f32,
	keep: bool,
) {
	roll := _flora_hash_unit(_flora_mix(hash ~ 0x6A55_5EED), 0)
	variant := _flora_hash_unit(hash, 4)
	size := _flora_hash_unit(hash, 5)
	if height > sea + 0.35 &&
	   height < snow - 0.5 &&
	   sample.slope < 0.5 &&
	   roll < config.grass_chance * _flora_ground_density(sample.primary_biome) {
		mesh = .Grass_Upright
		// Reeds mark standing water, so they follow the wet biomes and the
		// lake margin rather than raw moisture alone.
		wet :=
			sample.primary_biome == .Wetland ||
			sample.primary_biome == .Lake ||
			sample.moisture > 0.68
		if wet {
			mesh = .Grass_Reed
		} else if sample.moisture > 0.48 {
			mesh = .Grass_Crossed
		}
		return mesh, FLORA_GRASS_SCALE_MIN + FLORA_GRASS_SCALE_VARIATION * size, true
	}
	if height > sea + 0.3 && sample.moisture < 0.55 && sample.slope < 1.4 && roll > 0.92 {
		mesh = .Rock_A if variant < 0.5 else .Rock_B
		return mesh, 0.55 + 0.55 * size, true
	}
	return .Rock_A, 1, false
}

// _flora_tree_density scales the moisture-derived tree chance by how wooded a
// biome should read. Water and desert are near-bare; forest and taiga are the
// only regions that should close into canopy.
_flora_tree_density :: proc(biome: shared.Biome_Id) -> f32 {
	switch biome {
	case .Ocean, .Lake:
		return 0
	case .Coast:
		return 0.2
	case .Desert:
		return 0.03
	case .Savannah:
		return 0.25
	case .Snowlands:
		return 0.1
	case .Tundra:
		return 0.15
	case .Mountain:
		return 0.25
	case .Wetland:
		return 0.5
	case .Grassland:
		return 0.45
	case .Taiga:
		return 1.4
	case .Forest:
		return 1.6
	}
	return 0.45
}

// _flora_ground_density keeps grass off bare rock, sand and snow without
// needing a second set of height and slope bands.
_flora_ground_density :: proc(biome: shared.Biome_Id) -> f32 {
	switch biome {
	case .Ocean, .Lake:
		return 0
	case .Desert:
		return 0.12
	case .Coast:
		return 0.3
	case .Snowlands:
		return 0.15
	case .Mountain:
		return 0.25
	case .Tundra:
		return 0.55
	case .Taiga:
		return 0.7
	case .Forest:
		return 1.0
	case .Savannah:
		return 1.25
	case .Wetland, .Grassland:
		return 1.15
	}
	return 1
}

// _flora_tree_species picks a silhouette per biome: conifers for the cold and
// high, baobab for the hot and open, and an altitude blend where both belong.
_flora_tree_species :: proc(biome: shared.Biome_Id, variant, altitude: f32) -> Flora_Mesh_Id {
	switch biome {
	case .Taiga, .Snowlands, .Tundra, .Mountain:
		return .Conifer_A if variant < 0.5 else .Conifer_B
	case .Savannah, .Desert:
		return .Baobab
	case .Ocean, .Lake, .Coast, .Wetland, .Grassland, .Forest:
	// Mixed regions fall through to the altitude blend below.
	}
	// Conifers favor the colder high ground, broadleaf the valleys.
	if variant < 0.35 + altitude * 0.5 {
		return .Conifer_A if variant < 0.5 else .Conifer_B
	}
	return .Baobab
}

_flora_grove_mask :: proc(hash: u64) -> f32 {
	region_x := i32((hash >> 48) & 0xF)
	region_y := i32((hash >> 52) & 0xF)
	region_hash := _flora_hash(shared.TERRAIN_SEED ~ 0x6A0E_5EED, region_x, region_y)
	mask := _flora_hash_unit(region_hash, 1)
	return _smoothstep(0.28, 0.72, mask) * 0.85 + 0.15
}

// _flora_hash is the same splitmix-style avalanche the shared node scatter
// uses, salted so flora and nodes decorrelate.
_flora_hash :: proc(seed: u64, cell_x, cell_y: i32) -> u64 {
	return shared.flora_logical_hash(seed, cell_x, cell_y)
}

_flora_mix :: proc(input: u64) -> u64 {
	return shared.flora_logical_mix(input)
}

// _flora_hash_unit extracts an independent 0..1 channel from a hash.
_flora_hash_unit :: proc(hash: u64, channel: u32) -> f32 {
	shifted := hash >> (channel * 9)
	return f32(shifted & 0x1FF) / 511
}

// ---------------------------------------------------------------------------
// Texture atlas
// ---------------------------------------------------------------------------

// _flora_atlas_build bakes the 256x256 shared atlas: bark, foliage, rock,
// and dry-rock quadrants of layered value noise, same CPU pattern as the
// terrain strata bake.
_flora_atlas_build :: proc(value: ^Flora) -> bool {
	assert(value != nil, "_flora_atlas_build: nil flora")
	if value.atlas.id != 0 do return true
	// Static so the 192KB bake buffer never lands on the frame stack.
	@(static) pixels: [FLORA_ATLAS_SIZE * FLORA_ATLAS_SIZE * 3]u8
	half := FLORA_ATLAS_SIZE / 2
	for row in 0 ..< FLORA_ATLAS_SIZE {
		for column in 0 ..< FLORA_ATLAS_SIZE {
			u := f32(column % half) / f32(half)
			v := f32(row % half) / f32(half)
			color: [3]f32
			switch {
			case column < half && row < half:
				color = _flora_bark_texel(u, v)
			case column >= half && row < half:
				color = _flora_foliage_texel(u, v)
			case column < half && row >= half:
				color = _flora_rock_texel(u, v, false)
			case:
				color = _flora_rock_texel(u, v, true)
			}
			index := (row * FLORA_ATLAS_SIZE + column) * 3
			pixels[index + 0] = u8(clamp(color[0], 0, 255))
			pixels[index + 1] = u8(clamp(color[1], 0, 255))
			pixels[index + 2] = u8(clamp(color[2], 0, 255))
		}
	}
	image := rl.Image {
		data    = raw_data(pixels[:]),
		width   = FLORA_ATLAS_SIZE,
		height  = FLORA_ATLAS_SIZE,
		mipmaps = 1,
		format  = .UNCOMPRESSED_R8G8B8,
	}
	value.atlas = rl.LoadTextureFromImage(image)
	if value.atlas.id != 0 do rl.SetTextureFilter(value.atlas, .POINT)
	return value.atlas.id != 0
}

// Bark: vertical streaks - noise stretched hard along v with fine cracks.
_flora_bark_texel :: proc(u, v: f32) -> [3]f32 {
	streak := _flora_fbm(u * 16, v * 3, 3)
	crack := _flora_fbm(u * 28, v * 7, 2)
	tone := 0.55 + 0.45 * streak
	color := _mix3([3]f32{58, 44, 32}, [3]f32{112, 86, 60}, tone)
	if crack < 0.32 do color *= 0.72
	return color
}

// Foliage: mottled two-green blobs with dark cavities between clumps.
_flora_foliage_texel :: proc(u, v: f32) -> [3]f32 {
	clump := _flora_fbm(u * 7, v * 7, 3)
	fine := _flora_fbm(u * 16, v * 16, 2)
	color := _mix3([3]f32{40, 74, 34}, [3]f32{102, 126, 58}, clump)
	color *= 0.88 + 0.22 * fine
	if clump < 0.30 do color *= 0.62
	return color
}

// Rock: grey fbm with lichen speckles; the dry variant warms toward sand.
_flora_rock_texel :: proc(u, v: f32, dry: bool) -> [3]f32 {
	grain := _flora_fbm(u * 8, v * 8, 3)
	fleck := _flora_fbm(u * 22, v * 22, 2)
	color := _mix3([3]f32{92, 90, 88}, [3]f32{148, 144, 138}, grain)
	if dry do color = _mix3([3]f32{124, 106, 78}, [3]f32{176, 156, 118}, grain)
	color *= 0.88 + 0.24 * fleck
	// Lichen speckle: sparse green-grey dots.
	if !dry && fleck > 0.82 do color = _mix3(color, [3]f32{104, 118, 74}, 0.6)
	return color
}

// _flora_fbm layers wrapped value noise; coordinates are in tile units so
// the atlas quadrants tile without visible seams at whole frequencies.
_flora_fbm :: proc(x, y: f32, octaves: int) -> f32 {
	total := f32(0)
	amplitude := f32(0.5)
	sum := f32(0)
	px := x
	py := y
	for _ in 0 ..< octaves {
		total += amplitude * _flora_value_noise(px, py)
		sum += amplitude
		px = px * 2.03 + 13.7
		py = py * 2.03 + 7.1
		amplitude *= 0.5
	}
	return total / sum
}

_flora_value_noise :: proc(x, y: f32) -> f32 {
	ix := i32(math.floor(x))
	iy := i32(math.floor(y))
	fx := x - math.floor(x)
	fy := y - math.floor(y)
	sx := fx * fx * (3 - 2 * fx)
	sy := fy * fy * (3 - 2 * fy)
	a := _texel_hash01(ix, iy)
	b := _texel_hash01(ix + 1, iy)
	c := _texel_hash01(ix, iy + 1)
	d := _texel_hash01(ix + 1, iy + 1)
	return math.lerp(math.lerp(a, b, sx), math.lerp(c, d, sx), sy)
}
