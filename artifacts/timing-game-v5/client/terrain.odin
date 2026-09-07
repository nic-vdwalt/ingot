package main

import shared "../shared"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:sync"
import "core:thread"
import "core:time"
import "ingot:asset"
import rl "ingot:gfx"
import procgen "ingot:procgen"
import b3 "vendor:box3d"

// Planet terrain rendering and picking. The world is a cube-sphere: six
// 769x769 faces, radius 1080, rendered as 384 spherical patches (8x8 per
// face) built straight from the shared foundation tables plus the terraform
// delta grid. Picking ray-casts the Box3D meshes built from the exact same
// patch vertices, so what the player sees, hits, and is allowed to build on
// are one surface. Terraforming marks patches dirty and they are rebuilt
// from the foundation before the next draw.

// Long enough for a cursor ray from the eye at CAMERA_MAX_DISTANCE (planet
// center distance R + 6R = 7560) to reach the far limb of the sphere.
TERRAIN_RAY_MAX_DISTANCE :: f32(16000)
// Downward surface probe window around the cached height, along the local
// radial: rendered geometry can sit slightly off the analytic height after
// mesh quantisation.
TERRAIN_SURFACE_PROBE_LIFT :: f32(24)
TERRAIN_SURFACE_PROBE_DROP :: f32(40)
// Mesh-pool slots left for flora, structures, water, and cosmetics.
TERRAIN_MESH_SLOT_RESERVE :: 200
WATER_SHADER_REVISION :: "water-composite-v5-far-path"

// Per-face baked albedo in face-UV space: 1024x1024 texels per face over 768
// cells, so biome blends, baked AO and dither resolve finer than the cell
// grid. Pixels are R8G8B8 because the engine's UpdateTexture expands exactly
// that layout in place.
PLANET_ALBEDO_SIZE :: 1024
PLANET_ALBEDO_FACE_TEXELS :: PLANET_ALBEDO_SIZE * PLANET_ALBEDO_SIZE
PLANET_ALBEDO_TEXELS :: shared.PLANET_FACE_COUNT * PLANET_ALBEDO_FACE_TEXELS
PLANET_ALBEDO_ROWS :: shared.PLANET_FACE_COUNT * PLANET_ALBEDO_SIZE
// Cells per texel and the texel step in world units on the face grid.
PLANET_ALBEDO_CELL_STEP :: f32(shared.PLANET_FACE_CELLS) / f32(PLANET_ALBEDO_SIZE)
PLANET_ALBEDO_WORLD_STEP :: PLANET_ALBEDO_CELL_STEP * shared.GRID_CELL_SIZE
// Incremental bake pacing: each frame bakes rows until the time budget is
// spent, with a minimum row count so the bake always finishes even on slow
// builds.
TERRAIN_BAKE_BUDGET :: time.Millisecond
TERRAIN_BAKE_MIN_ROWS :: i32(1)
TERRAIN_BAKE_GAMEPLAY_STRIPE_ROWS :: i32(1)
TERRAIN_CLIMATE_REVISION_QUIET_FRAMES :: u32(30)
// Patches built per loading step before the budget check.
PLANET_PATCH_BUILD_BATCH :: 8
// Finished-but-unuploaded patches per worker. Each ready index gates ~1 MB
// of generated patch data, so a small bounded queue keeps every worker fed
// without stacking the whole planet ahead of the uploads.
TERRAIN_PAR_QUEUE_PER_WORKER :: 2
// Producer back-off while the queue is full. The main thread drains every
// frame, so this is a sub-frame wait, not a stall.
TERRAIN_PAR_QUEUE_WAIT :: 500 * time.Microsecond

// Discrete LOD per render patch, level zero being the full-resolution grid
// mesh. Two levels: the engine's mesh pool is GPU_3D_MAX_MESHES slots and
// the 384 render patches already claim one each, so the chain has to stay
// shallow. What is adopted is the part that pays today: the projected-error
// selection rule and the locked border that makes it crack-free, from
// ../ingot/docs/cluster-lod.md, applied at patch granularity.
TERRAIN_LOD_COUNT :: 2
// Index-count fraction of level zero. A level the simplifier refuses, or one
// that fails to shrink, simply does not exist for that patch.
TERRAIN_LOD_RATIOS := [TERRAIN_LOD_COUNT]f32{1, 0.35}
// A level is too coarse once its geometric error exceeds this fraction of
// the view depth; the projection constants are folded into the threshold,
// tuned against the shipping window, the same way the flora apparent-size
// rule folds them.
TERRAIN_LOD_ERROR_RATIO :: f32(0.006)
// Depth floor for that division, well inside any sane near plane.
TERRAIN_LOD_MIN_DEPTH :: f32(0.01)
// UV slack for the border lock, half a face cell: patch borders sit exactly
// on cell boundaries in face-UV space, so this only absorbs float rounding.
TERRAIN_LOD_BORDER_UV_EPSILON :: f32(0.5) / f32(shared.PLANET_FACE_CELLS)

// Albedo palette, in unclamped f32 RGB so band blending stays linear.
ALBEDO_SEDIMENT :: [3]f32{58, 76, 72}
ALBEDO_LAKEBED :: [3]f32{45, 86, 100}
ALBEDO_SAND :: [3]f32{214, 188, 116}
ALBEDO_LOAM_DRY :: [3]f32{132, 108, 72}
ALBEDO_LOAM_WET :: [3]f32{92, 78, 60}
ALBEDO_COLD_EARTH :: [3]f32{112, 108, 98}
ALBEDO_SAVANNAH_SOIL :: [3]f32{164, 119, 66}
ALBEDO_FOREST_SOIL :: [3]f32{82, 68, 52}
ALBEDO_TAIGA_SOIL :: [3]f32{88, 82, 72}
ALBEDO_DESERT :: [3]f32{200, 150, 66}
ALBEDO_TUNDRA_SOIL :: [3]f32{124, 116, 104}
ALBEDO_SNOWLANDS :: [3]f32{218, 226, 232}
ALBEDO_PEAT :: [3]f32{66, 58, 48}
ALBEDO_MOUNTAIN :: [3]f32{132, 126, 118}
ALBEDO_ROCK :: [3]f32{140, 124, 104}
ALBEDO_SNOW :: [3]f32{246, 249, 252}
ALBEDO_SCAR :: [3]f32{132, 82, 42}
ALBEDO_FLORA_LOW :: [3]f32{96, 126, 54}
ALBEDO_FLORA_GRASS :: [3]f32{52, 142, 62}
ALBEDO_FLORA_WOODY :: [3]f32{34, 108, 50}

// Water rendering: per-vertex scalar = shallowness (1 at the shore, 0 at
// WATER_DEPTH_MAX of standing water); uv carries {depth, coverage} for the
// shader's absorption and shoreline discard.
WATER_DEPTH_MAX :: f32(6)
WATER_DEEP :: rl.Color{12, 58, 102, 216}
WATER_SHALLOW :: rl.Color{54, 174, 184, 122}
// World-space drop of the visual water surface below the sim's level, so
// the sheet is never coplanar with near-level lakebed terrain.
WATER_SURFACE_DROP :: f32(0.05)

Terrain :: struct {
	// The sim world the terrain renders; set by terrain_init_begin and used
	// by rebuilds and the legacy face-local height queries.
	world_ref:                     ^shared.World,
	sea_level:                     f32,
	snow_level:                    f32,
	physics_world:                 b3.WorldId,
	// 384 spherical render patches, one GPU LOD chain and one static Box3D
	// mesh each. The physics meshes are what picking and flora seating
	// raycast; physics always uses the full-resolution patch grid so what
	// the player hits never depends on the rendered level.
	planet_patches:                [PLANET_RENDER_PATCH_COUNT]Planet_Render_Patch,
	planet_meshes:                 [PLANET_RENDER_PATCH_COUNT][TERRAIN_LOD_COUNT]rl.Gpu_Mesh,
	patch_lods:                    [PLANET_RENDER_PATCH_COUNT]int,
	patch_lod_error:               [PLANET_RENDER_PATCH_COUNT][TERRAIN_LOD_COUNT]f32,
	patch_bodies:                  [PLANET_RENDER_PATCH_COUNT]b3.BodyId,
	patch_physics:                 [PLANET_RENDER_PATCH_COUNT]^b3.MeshData,
	// patch_collision_revision counts committed collision replacements per
	// patch (bumped only after _planet_patch_upload installed a new body), so
	// seat caches keyed on it never outlive the geometry they were probed
	// against and are not invalidated by a mark-dirty that has not landed.
	patch_collision_revision:      [PLANET_RENDER_PATCH_COUNT]u64,
	// surface_probe_casts counts Box3D radial probes; steady frames should
	// add none once seats are cached.
	surface_probe_casts:           u64,
	planet_patch_cursor:           int,
	planet_patches_ready:          bool,
	// Terraform dirty flags, one per patch. Named `dirty` because dependent
	// systems (sockets) poll "is any rebuild pending" on it.
	dirty:                         [PLANET_RENDER_PATCH_COUNT]bool,
	// preview marks the sculpt-hold fast path: dirty patches upload the raw
	// grid as the only LOD level, skipping optimize and simplify, so the
	// ground tracks the brush live. refine_pending queues the full rebuild
	// that replaces each preview patch once the hold ends.
	preview:                       bool,
	refine_pending:                [PLANET_RENDER_PATCH_COUNT]bool,
	// Parallel initial build: workers generate patch grids CPU-side and
	// publish indices to par_ready; the main thread drains the queue and
	// does the GPU/physics uploads under the loading budget.
	par_workers:                   [dynamic]^thread.Thread,
	par_ready:                     [dynamic]int,
	par_mutex:                     sync.Mutex,
	par_dispatch:                  int,
	par_cancel:                    bool,
	par_failed:                    bool,
	par_spawned:                   bool,
	par_queue_limit:               int,
	par_world:                     ^shared.World,
	ocean:                         Ocean_Renderer,
	water_dirty:                   bool,
	// Baked per-face albedo plus the immutable climate cache feeding it. The
	// cache makes terraform re-bakes pure table lookups: the foundation is
	// only interpolated once per texel, at init.
	base_heights:                  [PLANET_ALBEDO_TEXELS]f32,
	moisture:                      [PLANET_ALBEDO_TEXELS]u8,
	temperature:                   [PLANET_ALBEDO_TEXELS]u8,
	primary_biome:                 [PLANET_ALBEDO_TEXELS]shared.Biome_Id,
	plate_crust:                   [PLANET_ALBEDO_TEXELS]shared.Plate_Crust,
	plate_boundary:                [PLANET_ALBEDO_TEXELS]shared.Plate_Boundary,
	boundary_strength:             [PLANET_ALBEDO_TEXELS]u8,
	lithosphere_debug:             bool,
	lithosphere_debug_revision:    u64,
	cutaway:                       bool,
	albedo_pixels:                 [PLANET_ALBEDO_TEXELS * 3]u8,
	normal_pixels:                 [PLANET_ALBEDO_TEXELS * 3]u8,
	roughness_ao_pixels:           [PLANET_ALBEDO_TEXELS * 3]u8,
	albedo_textures:               [shared.PLANET_FACE_COUNT]rl.Texture2D,
	normal_textures:               [shared.PLANET_FACE_COUNT]rl.Texture2D,
	roughness_ao_textures:         [shared.PLANET_FACE_COUNT]rl.Texture2D,
	// Bake cursors in global row space: face * PLANET_ALBEDO_SIZE + row.
	climate_row:                   i32,
	albedo_row:                    i32,
	// Terraform re-bake window (inclusive global rows); empty when min > max.
	albedo_min_row:                i32,
	albedo_max_row:                i32,
	upload_faces:                  [shared.PLANET_FACE_COUNT]bool,
	surface_publication:           Planet_Surface_Publication,
	surface_revision:              u64,
	surface_target_revision:       u64,
	surface_observed_revision:     u64,
	surface_revision_quiet_frames: u32,
	last_bake_rows:                i32,
	last_upload_faces:             u32,
	last_worker_dispatches:        u32,
	// Bumped whenever the effective heights change, so dependent caches
	// (placement highlight) can skip rebuilds on unchanged frames.
	heights_revision:              u64,
	tectonic_revision:             u64,
	// Custom WGSL shaders; a zero id falls back to the engine's built-in
	// shader, so creation failure degrades visuals instead of failing init.
	terrain_shader:                rl.Gpu_3D_Shader,
	profile_shader:                Profile_Terrain_Identity,
	water_shader:                  rl.Gpu_3D_Shader,
	far_water_shader:              rl.Gpu_3D_Shader,
	section_shader:                rl.Gpu_3D_Shader,
	section_mesh:                  rl.Gpu_Mesh,
	section_cpu:                   Planet_Section_Mesh,
	section_revision:              u64,
	build_active:                  bool,
	ready:                         bool,
}

terrain_init :: proc(value: ^Terrain, world: ^shared.World, physics_world: b3.WorldId) -> bool {
	if !terrain_init_begin(value, world, physics_world) do return false
	for value.build_active {
		if !terrain_init_step(value, world, max(time.Duration)) do return false
	}
	return value.ready
}

// terrain_init_begin arms the incremental build; terrain_init_step does the
// patch generation and uploads under a time budget.
terrain_init_begin :: proc(
	value: ^Terrain,
	world: ^shared.World,
	physics_world: b3.WorldId,
) -> bool {
	assert(value != nil, "terrain_init_begin: nil terrain")
	assert(world != nil, "terrain_init_begin: nil world")
	assert(!value.ready, "terrain_init_begin: already ready")
	assert(b3.World_IsValid(physics_world), "terrain_init_begin: invalid physics world")
	// A failed attempt (GPU context not up yet) may leave uploaded meshes
	// behind; release them so retries start clean.
	terrain_deinit(value)
	value.profile_shader = {}
	value.world_ref = world
	value.physics_world = physics_world
	value.sea_level = f32(world.foundation.sea_level) / f32(shared.HEIGHT_DELTA_SCALE)
	value.snow_level = f32(world.foundation.snow_level) / f32(shared.HEIGHT_DELTA_SCALE)
	material_revision := terrain_material_revision(world)
	value.surface_target_revision = material_revision
	value.surface_observed_revision = material_revision
	value.surface_revision_quiet_frames = TERRAIN_CLIMATE_REVISION_QUIET_FRAMES
	value.heights_revision += 1
	value.tectonic_revision = world.foundation.tectonic_revision
	value.albedo_min_row = PLANET_ALBEDO_ROWS
	value.albedo_max_row = -1
	value.build_active = true
	return true
}

// terrain_init_step builds render patches until the budget is spent; when
// the last patch lands it builds the water sheets and shaders and marks the
// terrain ready. A failed patch keeps the cursor so the next call retries.
terrain_init_step :: proc(value: ^Terrain, world: ^shared.World, budget: time.Duration) -> bool {
	assert(value != nil, "terrain_init_step: nil terrain")
	assert(world != nil, "terrain_init_step: nil world")
	assert(value.build_active, "terrain_init_step: build not active")
	start := time.tick_now()
	if !value.planet_patches_ready {
		// Spawn workers once: they generate patch grids CPU-side in parallel
		// while the main thread uploads finished ones under the budget.
		if !value.par_spawned {
			value.par_world = world
			sync.atomic_store(&value.par_dispatch, 0)
			worker_count := terrain_bake_worker_count()
			value.par_queue_limit = worker_count * TERRAIN_PAR_QUEUE_PER_WORKER
			value.par_ready = make([dynamic]int, 0, value.par_queue_limit)
			value.par_workers = make([dynamic]^thread.Thread, 0, worker_count)
			for _ in 0 ..< worker_count {
				worker := thread.create_and_start_with_poly_data(value, _patch_worker)
				if worker != nil do append(&value.par_workers, worker)
			}
			value.par_spawned = true
			return true
		}
		if len(value.par_workers) == 0 {
			// No worker could start: generate and upload inline so a
			// thread-limited host still loads, the same fallback
			// terrain_rows_parallel takes.
			for value.planet_patch_cursor < PLANET_RENDER_PATCH_COUNT {
				for _ in 0 ..< PLANET_PATCH_BUILD_BATCH {
					if value.planet_patch_cursor >= PLANET_RENDER_PATCH_COUNT do break
					patch_index := value.planet_patch_cursor
					per_face := shared.PLANET_PATCHES_PER_FACE * shared.PLANET_PATCHES_PER_FACE
					face_index := patch_index / per_face
					remainder := patch_index % per_face
					value.planet_patches[patch_index].face = procgen.Terrain_Face_V4(face_index)
					value.planet_patches[patch_index].patch_u =
						remainder % shared.PLANET_PATCHES_PER_FACE
					value.planet_patches[patch_index].patch_v =
						remainder / shared.PLANET_PATCHES_PER_FACE
					if !planet_render_patch_generate(&value.planet_patches[patch_index], world) {
						return false
					}
					if !_planet_patch_upload(value, patch_index) do return false
					value.planet_patch_cursor += 1
				}
				if time.tick_since(start) >= budget do return true
			}
		} else if !_patch_drain_ready(value, start, budget) {
			return false
		}
		if value.planet_patch_cursor < PLANET_RENDER_PATCH_COUNT do return true
		value.planet_patches_ready = true
	}
	if len(value.ocean.rings[0].vertices) == 0 {
		ocean_renderer_init(&value.ocean, world, ocean_visual_settings_default())
	}
	terrain_shader_ok := value.terrain_shader.id != 0
	if !terrain_shader_ok {
		source := profile_terrain_prepare(&value.profile_shader)
		if source == "" do return false
		value.terrain_shader, terrain_shader_ok = rl.create_gpu_3d_shader(source)
		when PROFILE_ENABLED {
			value.profile_shader.validation = "passed" if terrain_shader_ok else "failed"
			fmt.printfln("[profile] terrain sha256=%s validation=%s artifact_saved=%v",
				string(value.profile_shader.sha256[:]), value.profile_shader.validation,
				value.profile_shader.artifact_saved)
		}
	}
	water_shader_ok := value.water_shader.id != 0
	if !water_shader_ok {
		value.water_shader, water_shader_ok = rl.create_gpu_3d_shader(WATER_SHADER)
		fmt.printfln(
			"[planetforger] water shader revision=%s id=%d ok=%v",
			WATER_SHADER_REVISION,
			value.water_shader.id,
			water_shader_ok,
		)
	}
	far_water_shader_ok := value.far_water_shader.id != 0
	if !far_water_shader_ok {
		value.far_water_shader, far_water_shader_ok = rl.create_gpu_3d_shader(FAR_WATER_SHADER)
	}
	section_shader_ok := value.section_shader.id != 0
	if !section_shader_ok {
		value.section_shader, section_shader_ok = rl.create_gpu_3d_shader(PLANET_SECTION_SHADER)
	}
	if value.section_mesh.id == 0 {
		if !planet_section_generate(&value.section_cpu, world, {1, 0, 0}) do return false
		value.section_mesh, section_shader_ok = rl.create_gpu_mesh(
			value.section_cpu.vertices[:],
			value.section_cpu.indices[:],
			.Triangles,
		)
	}
	if !terrain_shader_ok || !water_shader_ok || !far_water_shader_ok || !section_shader_ok {
		return false
	}
	value.build_active = false
	value.ready = true
	return true
}

// terrain_build_progress reports the incremental build fraction for the
// loading screen: patch generation dominates the bar, the material bake
// (climate + albedo rows) fills the tail so the bar only completes when
// gameplay can start at a stable frame rate.
terrain_build_progress :: proc(value: ^Terrain) -> f32 {
	assert(value != nil, "terrain_build_progress: nil terrain")
	patch_fraction := f32(1)
	if !value.ready {
		if !value.build_active do return 0
		patch_fraction = f32(value.planet_patch_cursor) / f32(PLANET_RENDER_PATCH_COUNT)
	}
	bake_done := value.climate_row + min(value.albedo_row, PLANET_ALBEDO_ROWS)
	bake_fraction := f32(bake_done) / f32(2 * PLANET_ALBEDO_ROWS)
	return patch_fraction * 0.7 + bake_fraction * 0.3
}

// terrain_material_bake_pending reports whether the one-time climate/albedo
// bake still has rows or a GPU upload outstanding. The loading screen holds
// the Playing transition on this: baking climate rows during gameplay forces
// long frames and a laggy camera.
terrain_material_bake_pending :: proc(value: ^Terrain) -> bool {
	assert(value != nil, "terrain_material_bake_pending: nil terrain")
	if !value.ready do return true
	if value.climate_row < PLANET_ALBEDO_ROWS do return true
	if value.albedo_row < PLANET_ALBEDO_ROWS do return true
	for pending in value.upload_faces do if pending do return true
	return false
}

// terrain_albedo_ready reports whether every face's baked material textures
// exist on the GPU, which is what the loading gate waits for.
terrain_albedo_ready :: proc(value: ^Terrain) -> bool {
	assert(value != nil, "terrain_albedo_ready: nil terrain")
	for face_index in 0 ..< shared.PLANET_FACE_COUNT {
		if value.albedo_textures[face_index].id == 0 do return false
		if value.normal_textures[face_index].id == 0 do return false
		if value.roughness_ao_textures[face_index].id == 0 do return false
	}
	return true
}

// terrain_mark_dirty flags every render patch a terraform mound of `radius`
// cells centred on a cell can touch, crossing face seams through
// planet_neighbour, and widens the albedo re-bake window to the touched
// texel rows.
terrain_mark_dirty :: proc(
	value: ^Terrain,
	center: shared.Planet_Coord,
	radius: i32 = shared.TERRAFORM_RADIUS,
) {
	assert(value != nil, "terrain_mark_dirty: nil terrain")
	assert(shared.planet_coord_valid(center), "terrain_mark_dirty: cell out of world")
	assert(shared.terraform_radius_valid(radius), "terrain_mark_dirty: radius out of range")
	// One cell of margin covers the normal stencil across the mound edge.
	reach := radius + 1
	offsets := [3]i32{-reach, 0, reach}
	for offset_v in offsets {
		for offset_u in offsets {
			target := shared.planet_neighbour(center, offset_u, offset_v)
			value.dirty[_planet_patch_index_for(target)] = true
			// Edge cells live on 2-3 faces; their duplicates' patches must
			// rebuild too or the seam shows a crack.
			duplicates, count := shared.planet_duplicates(target)
			for index in 0 ..< count {
				value.dirty[_planet_patch_index_for(duplicates[index])] = true
				_albedo_rows_mark(value, duplicates[index], reach)
			}
			_albedo_rows_mark(value, target, reach)
		}
	}
	material_reach := radius + i32(math.ceil(32 * PLANET_ALBEDO_CELL_STEP)) + 2
	for offset_v in -material_reach ..= material_reach {
		for offset_u in -material_reach ..= material_reach {
			target := shared.planet_neighbour(center, offset_u, offset_v)
			_albedo_rows_mark(value, target, 1)
			duplicates, count := shared.planet_duplicates(target)
			for index in 0 ..< count do _albedo_rows_mark(value, duplicates[index], 1)
		}
	}
	value.water_dirty = true
	value.heights_revision += 1
}

@(private)
_planet_patch_index_for :: proc(coord: shared.Planet_Coord) -> int {
	patch_u := clamp(
		int(coord.u) / shared.PLANET_PATCH_CELLS,
		0,
		shared.PLANET_PATCHES_PER_FACE - 1,
	)
	patch_v := clamp(
		int(coord.v) / shared.PLANET_PATCH_CELLS,
		0,
		shared.PLANET_PATCHES_PER_FACE - 1,
	)
	per_face := shared.PLANET_PATCHES_PER_FACE * shared.PLANET_PATCHES_PER_FACE
	return int(coord.face) * per_face + patch_v * shared.PLANET_PATCHES_PER_FACE + patch_u
}

// _albedo_rows_mark widens the re-bake window to the texel rows a brush
// reaches on one face, one row of margin so blended neighbours refresh too.
@(private)
_albedo_rows_mark :: proc(value: ^Terrain, coord: shared.Planet_Coord, reach: i32) {
	texels_per_cell := f32(PLANET_ALBEDO_SIZE) / f32(shared.PLANET_FACE_CELLS)
	row_base := i32(coord.face) * PLANET_ALBEDO_SIZE
	low := i32(math.floor(f32(coord.v - reach) * texels_per_cell)) - 1
	high := i32(math.ceil(f32(coord.v + reach) * texels_per_cell)) + 1
	low = clamp(low, 0, PLANET_ALBEDO_SIZE - 1)
	high = clamp(high, 0, PLANET_ALBEDO_SIZE - 1)
	value.albedo_min_row = min(value.albedo_min_row, row_base + low)
	value.albedo_max_row = max(value.albedo_max_row, row_base + high)
}

// terrain_update regenerates every dirty patch before the next draw so one
// terraform operation reaches the screen atomically, refreshes the water
// sheets when the waterfield moved, and advances the albedo bake.
terrain_water_dirty_update :: proc(value: ^Terrain, revision: u64) {
	assert(value != nil, "terrain_water_dirty_update: nil terrain")
	value.water_dirty = value.ocean.water_revision != revision
}

terrain_update :: proc(value: ^Terrain, world: ^shared.World) {
	assert(value != nil, "terrain_update: nil terrain")
	assert(world != nil, "terrain_update: nil world")
	if !value.ready do return
	terrain_tectonic_revision_update(value, world)
	has_dirty := false
	for dirty in value.dirty {
		if dirty {
			has_dirty = true
			break
		}
	}
	if has_dirty {
		for patch_index in 0 ..< PLANET_RENDER_PATCH_COUNT {
			if !value.dirty[patch_index] do continue
			if !planet_render_patch_generate(&value.planet_patches[patch_index], world) do continue
			if _planet_patch_upload(value, patch_index, value.preview) {
				value.dirty[patch_index] = false
				if value.preview do value.refine_pending[patch_index] = true
			}
		}
	} else if !value.preview {
		// Budgeted post-hold refine: one full rebuild per frame until the
		// preview-quality patches are all replaced.
		for patch_index in 0 ..< PLANET_RENDER_PATCH_COUNT {
			if !value.refine_pending[patch_index] do continue
			if !planet_render_patch_generate(&value.planet_patches[patch_index], world) do break
			if _planet_patch_upload(value, patch_index) {
				value.refine_pending[patch_index] = false
			}
			break
		}
	}
	terrain_water_dirty_update(value, world.waterfield.revision)
	planet_surface_observe(value, world)
	_albedo_update(value, world)
}

terrain_tectonic_revision_update :: proc(value: ^Terrain, world: ^shared.World) {
	assert(value != nil && world != nil, "terrain tectonic revision: nil input")
	if value.tectonic_revision == world.foundation.tectonic_revision do return
	state := &world.planetary.tectonics
	for index in 0 ..< int(state.dirty_count) {
		coord := shared.planet_sim_terrain_coord(
			shared.planet_sim_coord_for_index(int(state.dirty_tiles[index])),
		)
		terrain_mark_dirty(value, coord, shared.TERRAFORM_RADIUS_MAX)
	}
	value.tectonic_revision = world.foundation.tectonic_revision
}

terrain_material_revision :: proc(world: ^shared.World, debug_revision := u64(0)) -> u64 {
	assert(world != nil, "terrain_material_revision: nil world")
	return(
		world.planetary.climate.surface_revision ~
		(world.flora_ecology.revision * 0x9e3779b97f4a7c15) ~
		(debug_revision * 0xbf58476d1ce4e5b9) \
	)
}

terrain_material_revision_update :: proc(value: ^Terrain, revision: u64) {
	assert(value != nil, "terrain_material_revision_update: nil terrain")
	if revision != value.surface_observed_revision {
		value.surface_observed_revision = revision
		value.surface_revision_quiet_frames = 0
	} else if value.surface_revision_quiet_frames < TERRAIN_CLIMATE_REVISION_QUIET_FRAMES {
		value.surface_revision_quiet_frames += 1
	}
	idle := value.albedo_row == PLANET_ALBEDO_ROWS && value.albedo_min_row > value.albedo_max_row
	stable := value.surface_revision_quiet_frames >= TERRAIN_CLIMATE_REVISION_QUIET_FRAMES
	if idle && stable && value.surface_revision != revision {
		value.surface_target_revision = revision
		value.albedo_min_row = 0
		value.albedo_max_row = PLANET_ALBEDO_ROWS - 1
	}
}

// _planet_patch_upload replaces one patch's GPU LOD chain and Box3D
// collision mesh with the current generated vertices. `fast` is the sculpt
// preview path: it uploads the raw grid as the only level, skipping the
// optimize pass and the simplify chain, and leaves physics identical so
// picking and seating stay live mid-hold.
@(private)
_planet_patch_upload :: proc(value: ^Terrain, patch_index: int, fast := false) -> bool {
	assert(value != nil, "_planet_patch_upload: nil terrain")
	assert(
		patch_index >= 0 && patch_index < PLANET_RENDER_PATCH_COUNT,
		"_planet_patch_upload: index",
	)
	temp_mark := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp_mark)
	patch := &value.planet_patches[patch_index]
	gpu_vertices := make([]rl.Gpu_3D_Vertex, len(patch.vertices), context.temp_allocator)
	bounds := asset.Bounds_3D {
		minimum = {max(f32), max(f32), max(f32)},
		maximum = {min(f32), min(f32), min(f32)},
	}
	for vertex, index in patch.vertices {
		gpu_vertices[index] = {
			position = vertex.position,
			normal   = vertex.normal,
			scalar   = vertex.scalar,
			uv       = vertex.uv,
		}
		bounds.minimum.x = min(bounds.minimum.x, vertex.position.x)
		bounds.minimum.y = min(bounds.minimum.y, vertex.position.y)
		bounds.minimum.z = min(bounds.minimum.z, vertex.position.z)
		bounds.maximum.x = max(bounds.maximum.x, vertex.position.x)
		bounds.maximum.y = max(bounds.maximum.y, vertex.position.y)
		bounds.maximum.z = max(bounds.maximum.z, vertex.position.z)
	}
	chain: [TERRAIN_LOD_COUNT]rl.Gpu_Mesh
	errors: [TERRAIN_LOD_COUNT]f32
	levels := 1
	gpu_ok := false
	if fast {
		chain[0], gpu_ok = rl.create_gpu_mesh(gpu_vertices, patch.indices, .Triangles)
	} else {
		optimized := _terrain_mesh_optimize(patch.vertices, patch.indices, bounds)
		upload := _terrain_gpu_vertices(optimized.vertices)
		chain[0], gpu_ok = rl.create_gpu_mesh(upload, optimized.indices, .Triangles)
		if gpu_ok {
			levels = _planet_patch_lod_build(
				&chain,
				&errors,
				optimized.vertices,
				optimized.indices,
				bounds,
				patch,
			)
		}
	}
	if !gpu_ok {
		fmt.eprintln("[terrain] planet patch", patch_index, "create_gpu_mesh failed")
		return false
	}
	if b3.World_IsValid(value.physics_world) {
		physics_vertices := make([]b3.Vec3, len(patch.vertices), context.temp_allocator)
		physics_indices := make([]i32, len(patch.indices), context.temp_allocator)
		for vertex, index in patch.vertices do physics_vertices[index] = vertex.position
		for index, offset in patch.indices do physics_indices[offset] = i32(index)
		mesh_def := b3.MeshDef {
			vertices       = raw_data(physics_vertices),
			indices        = raw_data(physics_indices),
			vertexCount    = c.int(len(physics_vertices)),
			triangleCount  = c.int(len(physics_indices) / 3),
			weldVertices   = false,
			useMedianSplit = true,
			identifyEdges  = true,
		}
		physics_mesh := b3.CreateMesh(mesh_def, nil, 0)
		if physics_mesh == nil {
			fmt.eprintln("[terrain] planet patch", patch_index, "b3.CreateMesh failed")
			_patch_chain_destroy(&chain)
			return false
		}
		body_def := b3.DefaultBodyDef()
		body_def.type = .staticBody
		body := b3.CreateBody(value.physics_world, body_def)
		if !b3.Body_IsValid(body) {
			fmt.eprintln("[terrain] planet patch", patch_index, "b3.CreateBody failed")
			b3.DestroyMesh(physics_mesh)
			_patch_chain_destroy(&chain)
			return false
		}
		shape_def := b3.DefaultShapeDef()
		shape_def.filter.categoryBits = PHYSICS_CATEGORY_TERRAIN
		shape_def.filter.maskBits = PHYSICS_CATEGORY_DEBRIS | PHYSICS_CATEGORY_SURFABLE
		shape := b3.CreateMeshShape(body, shape_def, physics_mesh, {1, 1, 1})
		if !b3.Shape_IsValid(shape) {
			fmt.eprintln("[terrain] planet patch", patch_index, "b3.CreateMeshShape failed")
			b3.DestroyBody(body)
			b3.DestroyMesh(physics_mesh)
			_patch_chain_destroy(&chain)
			return false
		}
		if b3.Body_IsValid(value.patch_bodies[patch_index]) {
			b3.DestroyBody(value.patch_bodies[patch_index])
		}
		if value.patch_physics[patch_index] != nil {
			b3.DestroyMesh(value.patch_physics[patch_index])
		}
		value.patch_bodies[patch_index] = body
		value.patch_physics[patch_index] = physics_mesh
		value.patch_collision_revision[patch_index] += 1
	}
	_patch_chain_destroy(&value.planet_meshes[patch_index])
	value.planet_meshes[patch_index] = chain
	value.patch_lods[patch_index] = levels
	value.patch_lod_error[patch_index] = errors
	return true
}

// _albedo_update advances the incremental bake pipeline: the immutable
// climate cache first (runs once), then the initial albedo bake, then
// terraform re-bakes of the dirty row window. Each frame bakes rows until
// TERRAIN_BAKE_BUDGET is spent (minimum TERRAIN_BAKE_MIN_ROWS so progress is
// guaranteed), and each completed (re)bake uploads only the touched faces.
_albedo_update :: proc(value: ^Terrain, world: ^shared.World) {
	assert(value != nil, "_albedo_update: nil terrain")
	assert(world != nil, "_albedo_update: nil world")
	value.last_bake_rows = 0
	value.last_upload_faces = 0
	value.last_worker_dispatches = 0
	if !value.surface_publication.initialized do planet_surface_observe(value, world)
	pending_upload := false
	for upload in value.upload_faces do pending_upload = pending_upload || upload
	idle :=
		value.climate_row == PLANET_ALBEDO_ROWS &&
		value.albedo_row == PLANET_ALBEDO_ROWS &&
		value.albedo_min_row > value.albedo_max_row &&
		!pending_upload && !value.surface_publication.active
	if idle do return
	start := time.tick_now()
	rows_baked := i32(0)
	stripe := TERRAIN_BAKE_GAMEPLAY_STRIPE_ROWS
	assert(stripe >= 1, "_albedo_update: degenerate stripe width")
	for value.climate_row < PLANET_ALBEDO_ROWS && _bake_has_budget(start, rows_baked) {
		end := min(value.climate_row + stripe, PLANET_ALBEDO_ROWS)
		_climate_bake_rows(value, world, value.climate_row, end)
		rows_baked += end - value.climate_row
		value.climate_row = end
	}
	if value.climate_row < PLANET_ALBEDO_ROWS do return
	if value.albedo_row < PLANET_ALBEDO_ROWS {
		for value.albedo_row < PLANET_ALBEDO_ROWS && _bake_has_budget(start, rows_baked) {
			end := min(value.albedo_row + stripe, PLANET_ALBEDO_ROWS)
			_albedo_bake_rows(value, world, value.albedo_row, end)
			rows_baked += end - value.albedo_row
			value.albedo_row = end
		}
		if value.albedo_row == PLANET_ALBEDO_ROWS {
			for face_index in 0 ..< shared.PLANET_FACE_COUNT {
				value.upload_faces[face_index] = true
			}
		}
	} else if value.albedo_min_row <= value.albedo_max_row {
		for value.albedo_min_row <= value.albedo_max_row && _bake_has_budget(start, rows_baked) {
			end := min(value.albedo_min_row + stripe, value.albedo_max_row + 1)
			_albedo_bake_rows(value, world, value.albedo_min_row, end)
			rows_baked += end - value.albedo_min_row
			value.albedo_min_row = end
		}
		if value.albedo_min_row > value.albedo_max_row {
			for &upload in value.upload_faces do upload = true
			value.albedo_min_row = PLANET_ALBEDO_ROWS
			value.albedo_max_row = -1
		}
	}
	planet_surface_bake(value, world, start, &rows_baked)
	value.last_bake_rows = rows_baked
	_terrain_material_upload(value)
	if value.surface_publication.active && value.surface_publication.cursor == PLANET_ALBEDO_ROWS {
		pending := false
		for upload in value.upload_faces do pending = pending || upload
		if !pending {
			value.surface_publication.published = value.surface_publication.target
			value.surface_publication.active = false
		}
	}
	if value.albedo_row == PLANET_ALBEDO_ROWS && value.albedo_min_row > value.albedo_max_row {
		pending := false
		for upload in value.upload_faces do if upload do pending = true
		if !pending do value.surface_revision = value.surface_target_revision
	}
}

@(private)
Material_Bake_Job :: struct {
	terrain: ^Terrain,
	world:   ^shared.World,
}

@(private)
_climate_bake_rows :: proc(value: ^Terrain, world: ^shared.World, row_start, row_end: i32) {
	assert(value != nil, "_climate_bake_rows: nil terrain")
	assert(world != nil, "_climate_bake_rows: nil world")
	assert(
		0 <= row_start && row_start <= row_end && row_end <= PLANET_ALBEDO_ROWS,
		"_climate_bake_rows: row range",
	)
	job := Material_Bake_Job {
		terrain = value,
		world   = world,
	}
	value.last_worker_dispatches += 1
	terrain_rows_parallel(int(row_start), int(row_end), &job, _climate_bake_row_range)
}

@(private)
_climate_bake_row_range :: proc(data: rawptr, row_start, row_end: int) {
	assert(data != nil, "_climate_bake_row_range: nil job")
	job := cast(^Material_Bake_Job)data
	for row in row_start ..< row_end {
		_climate_bake_row(job.terrain, job.world, i32(row))
	}
}

@(private)
_albedo_bake_rows :: proc(value: ^Terrain, world: ^shared.World, row_start, row_end: i32) {
	assert(value != nil, "_albedo_bake_rows: nil terrain")
	assert(world != nil, "_albedo_bake_rows: nil world")
	assert(
		0 <= row_start && row_start <= row_end && row_end <= PLANET_ALBEDO_ROWS,
		"_albedo_bake_rows: row range",
	)
	job := Material_Bake_Job {
		terrain = value,
		world   = world,
	}
	value.last_worker_dispatches += 1
	terrain_rows_parallel(int(row_start), int(row_end), &job, _albedo_bake_row_range)
}

@(private)
_albedo_bake_row_range :: proc(data: rawptr, row_start, row_end: int) {
	assert(data != nil, "_albedo_bake_row_range: nil job")
	job := cast(^Material_Bake_Job)data
	// One scratch per worker, reused for every row in this stripe. Heap,
	// not stack: worker threads should not carry it in their frame.
	scratch := new(Albedo_Row_Scratch)
	defer free(scratch)
	for row in row_start ..< row_end {
		_albedo_bake_row_scratch(job.terrain, job.world, i32(row), scratch)
	}
}

// _bake_has_budget paces the incremental bake: always allow the minimum row
// count (guaranteed forward progress and a bounded worst-case bake length),
// then keep going only while the frame-time budget holds.
_bake_has_budget :: proc(start: time.Tick, rows_baked: i32) -> bool {
	assert(rows_baked >= 0, "_bake_has_budget: negative row count")
	if rows_baked < TERRAIN_BAKE_MIN_ROWS do return true
	return time.tick_since(start) < TERRAIN_BAKE_BUDGET
}

// _terrain_material_upload creates or updates the three material textures of
// every face whose pixels were rebaked since the last upload.
_terrain_material_upload :: proc(value: ^Terrain) {
	assert(value != nil, "_terrain_material_upload: nil terrain")
	for face_index in 0 ..< shared.PLANET_FACE_COUNT {
		if !value.upload_faces[face_index] do continue
		if value.last_upload_faces >= 1 do break
		value.last_upload_faces += 1
		pixels := make([]u8, PLANET_MATERIAL_PADDED_SIZE * PLANET_MATERIAL_PADDED_SIZE * 3)
		defer delete(pixels)
		textures := [3]^rl.Texture2D{&value.albedo_textures[face_index], &value.normal_textures[face_index], &value.roughness_ao_textures[face_index]}
		sources := [3][]u8{value.albedo_pixels[:], value.normal_pixels[:], value.roughness_ao_pixels[:]}
		complete := true
		for texture, channel in textures {
			planet_material_gutter_fill(pixels, sources[channel], procgen.Terrain_Face_V4(face_index))
			if texture.id == 0 {
				texture^ = rl.LoadTextureFromImage(rl.Image{data = raw_data(pixels), width = PLANET_MATERIAL_PADDED_SIZE, height = PLANET_MATERIAL_PADDED_SIZE, mipmaps = 1, format = .UNCOMPRESSED_R8G8B8})
			} else {
				rl.UpdateTexture(texture^, raw_data(pixels))
			}
			complete = complete && texture.id != 0
		}
		value.upload_faces[face_index] = !complete

	}
}

// _albedo_texel_cell maps a texel index to its face-grid coordinate (texel
// centre), in cells.
_albedo_texel_cell :: proc(texel: i32) -> f32 {
	return (f32(texel) + 0.5) * PLANET_ALBEDO_CELL_STEP
}

// _face_bilinear_i16 / _u8 interpolate a foundation table at a fractional
// face coordinate. The corner cells always stay inside the face because the
// texel centres sit strictly inside [0, 768].
@(private)
_face_bilinear_i16 :: proc(
	values: []i16,
	face: procgen.Terrain_Face_V4,
	cell_u, cell_v: f32,
) -> f32 {
	column := min(i32(cell_u), i32(shared.PLANET_FACE_CELLS - 1))
	row := min(i32(cell_v), i32(shared.PLANET_FACE_CELLS - 1))
	fraction_u := cell_u - f32(column)
	fraction_v := cell_v - f32(row)
	low := f32(values[shared.planet_index({face, column, row})]) * (1 - fraction_u)
	low += f32(values[shared.planet_index({face, column + 1, row})]) * fraction_u
	high := f32(values[shared.planet_index({face, column, row + 1})]) * (1 - fraction_u)
	high += f32(values[shared.planet_index({face, column + 1, row + 1})]) * fraction_u
	return low * (1 - fraction_v) + high * fraction_v
}

@(private)
_face_bilinear_u8 :: proc(
	values: []u8,
	face: procgen.Terrain_Face_V4,
	cell_u, cell_v: f32,
) -> f32 {
	column := min(i32(cell_u), i32(shared.PLANET_FACE_CELLS - 1))
	row := min(i32(cell_v), i32(shared.PLANET_FACE_CELLS - 1))
	fraction_u := cell_u - f32(column)
	fraction_v := cell_v - f32(row)
	low := f32(values[shared.planet_index({face, column, row})]) * (1 - fraction_u)
	low += f32(values[shared.planet_index({face, column + 1, row})]) * fraction_u
	high := f32(values[shared.planet_index({face, column, row + 1})]) * (1 - fraction_u)
	high += f32(values[shared.planet_index({face, column + 1, row + 1})]) * fraction_u
	return low * (1 - fraction_v) + high * fraction_v
}

// _climate_bake_row caches the immutable per-texel terrain data for one
// face-row: base height (pre-terraform), moisture, temperature, and the
// nearest cell's biome. All later albedo bakes are table lookups over these.
_climate_bake_row :: proc(value: ^Terrain, world: ^shared.World, row: i32) {
	assert(value != nil, "_climate_bake_row: nil terrain")
	assert(world != nil, "_climate_bake_row: nil world")
	assert(row >= 0 && row < PLANET_ALBEDO_ROWS, "_climate_bake_row: row out of range")
	face := procgen.Terrain_Face_V4(row / PLANET_ALBEDO_SIZE)
	texel_v := row % PLANET_ALBEDO_SIZE
	cell_v := _albedo_texel_cell(texel_v)
	nearest_v := clamp(i32(cell_v + 0.5), 0, i32(shared.PLANET_FACE_CELLS))
	for column in i32(0) ..< i32(PLANET_ALBEDO_SIZE) {
		cell_u := _albedo_texel_cell(column)
		index := int(row) * PLANET_ALBEDO_SIZE + int(column)
		value.base_heights[index] =
			_face_bilinear_i16(world.foundation.base_height, face, cell_u, cell_v) /
			f32(shared.HEIGHT_DELTA_SCALE)
		value.moisture[index] = u8(
			clamp(_face_bilinear_u8(world.foundation.moisture, face, cell_u, cell_v), 0, 255),
		)
		value.temperature[index] = u8(
			clamp(_face_bilinear_u8(world.foundation.temperature, face, cell_u, cell_v), 0, 255),
		)
		nearest_u := clamp(i32(cell_u + 0.5), 0, i32(shared.PLANET_FACE_CELLS))
		foundation_index := shared.planet_index({face, nearest_u, nearest_v})
		value.primary_biome[index] = world.foundation.primary_biome[foundation_index]
		value.plate_crust[index] = world.foundation.plate_crust[foundation_index]
		value.plate_boundary[index] = world.foundation.plate_boundary[foundation_index]
		value.boundary_strength[index] = world.foundation.boundary_strength[foundation_index]
	}
}

// The nine rows _albedo_bake_row samples relative to its own row: the
// vertical slope taps and the three _terrain_ao radii. Index
// ALBEDO_TAP_CENTER is the baked row itself.
ALBEDO_ROW_TAPS :: [9]i32{-32, -8, -2, -1, 0, 1, 2, 8, 32}
ALBEDO_TAP_CENTER :: 4
ALBEDO_TAP_DOWN :: 3
ALBEDO_TAP_UP :: 5
// AO radius i reads rows ALBEDO_TAP_AO_LOW[i] / ALBEDO_TAP_AO_HIGH[i].
ALBEDO_TAP_AO_LOW :: [3]int{2, 1, 0}
ALBEDO_TAP_AO_HIGH :: [3]int{6, 7, 8}

// Albedo_Row_Scratch holds the effective (base + terraform delta) heights of
// the nine rows one albedo row samples, plus that row's raw delta for the
// scar blend.
Albedo_Row_Scratch :: struct {
	heights: [len(ALBEDO_ROW_TAPS)][PLANET_ALBEDO_SIZE]f32,
	delta:   [PLANET_ALBEDO_SIZE]f32,
}

// _albedo_scratch_fill computes base + delta per tap row. Tap rows clamp to
// the face band: a cross-face tap would need a direction resample, and the
// one-face clamp only softens AO/slope in the outermost texel rows.
_albedo_scratch_fill :: proc(
	scratch: ^Albedo_Row_Scratch,
	value: ^Terrain,
	world: ^shared.World,
	row: i32,
) {
	assert(scratch != nil, "_albedo_scratch_fill: nil scratch")
	assert(value != nil, "_albedo_scratch_fill: nil terrain")
	assert(world != nil, "_albedo_scratch_fill: nil world")
	face := procgen.Terrain_Face_V4(row / PLANET_ALBEDO_SIZE)
	texel_v := row % PLANET_ALBEDO_SIZE
	face_row_base := i32(face) * PLANET_ALBEDO_SIZE
	modified := world.heightfield.modified
	taps := ALBEDO_ROW_TAPS
	for offset, tap in taps {
		source_v := clamp(texel_v + offset, 0, PLANET_ALBEDO_SIZE - 1)
		source_row := face_row_base + source_v
		base := value.base_heights[int(source_row) * PLANET_ALBEDO_SIZE:][:PLANET_ALBEDO_SIZE]
		heights := &scratch.heights[tap]
		if texel_v + offset < 0 || texel_v + offset >= PLANET_ALBEDO_SIZE {
			for column in 0 ..< PLANET_ALBEDO_SIZE do heights[column] = planet_material_height_tap(world, face, i32(column), texel_v + offset)
			continue
		}
		cell_v := _albedo_texel_cell(source_v)
		for column in 0 ..< PLANET_ALBEDO_SIZE {
			cell_u := _albedo_texel_cell(i32(column))
			tectonic := _face_bilinear_i16(world.foundation.tectonic_delta, face, cell_u, cell_v) / f32(shared.HEIGHT_DELTA_SCALE)
			delta := modified ? _face_delta_bilinear(world, face, cell_u, cell_v) : f32(0)
			heights[column] = base[column] + tectonic + delta
			if tap == ALBEDO_TAP_CENTER do scratch.delta[column] = delta
		}
	}
	if !modified do slice.zero(scratch.delta[:])
}

@(private)
_face_delta_bilinear :: proc(
	world: ^shared.World,
	face: procgen.Terrain_Face_V4,
	cell_u, cell_v: f32,
) -> f32 {
	return(
		_face_bilinear_i16(world.heightfield.deltas, face, cell_u, cell_v) /
		f32(shared.HEIGHT_DELTA_SCALE) \
	)
}

// _albedo_bake_row colors one texel row: biome bands blended by smoothstep
// margins, slope-driven rock, terraform scars, then concavity AO, and hash
// dither for small-scale variation. The scratch-free form allocates its own
// scratch; the bake driver uses _albedo_bake_row_scratch to reuse one per
// worker stripe.
_albedo_bake_row :: proc(value: ^Terrain, world: ^shared.World, row: i32) {
	scratch := new(Albedo_Row_Scratch)
	defer free(scratch)
	_albedo_bake_row_scratch(value, world, row, scratch)
}

_albedo_bake_row_scratch :: proc(
	value: ^Terrain,
	world: ^shared.World,
	row: i32,
	scratch: ^Albedo_Row_Scratch,
) {
	assert(row >= 0 && row < PLANET_ALBEDO_ROWS, "_albedo_bake_row: row out of range")
	assert(value.climate_row == PLANET_ALBEDO_ROWS, "_albedo_bake_row: climate cache incomplete")
	sea := value.sea_level
	face := procgen.Terrain_Face_V4(row / PLANET_ALBEDO_SIZE)
	texel_v := row % PLANET_ALBEDO_SIZE
	_albedo_scratch_fill(scratch, value, world, row)
	center := &scratch.heights[ALBEDO_TAP_CENTER]
	below := &scratch.heights[ALBEDO_TAP_DOWN]
	above := &scratch.heights[ALBEDO_TAP_UP]
	for column in i32(0) ..< i32(PLANET_ALBEDO_SIZE) {
		index := int(row) * PLANET_ALBEDO_SIZE + int(column)
		height := center[column]
		left := center[max(column - 1, 0)]
		right := center[min(column + 1, PLANET_ALBEDO_SIZE - 1)]
		if column == 0 do left = planet_material_height_tap(world, face, column - 1, texel_v)
		if column == PLANET_ALBEDO_SIZE - 1 do right = planet_material_height_tap(world, face, column + 1, texel_v)
		down := below[column]
		up := above[column]
		step_u, step_v := planet_material_metric(face, column, texel_v)
		slope := planet_material_slope(face, column, texel_v, left, right, down, up)
		moisture := f32(value.moisture[index]) / 255
		temperature := f32(value.temperature[index]) / 255
		color := _biome_color(value.primary_biome[index], moisture, temperature)
		if value.surface_publication.debug {
			debug_color := lithosphere_debug_color(
				value.plate_crust[index],
				value.plate_boundary[index],
				value.boundary_strength[index],
			)
			color = {f32(debug_color.r) / 255, f32(debug_color.g) / 255, f32(debug_color.b) / 255}
		}
		coord := shared.Planet_Coord {
			face,
			clamp(i32(_albedo_texel_cell(column) + 0.5), 0, i32(shared.PLANET_FACE_CELLS)),
			clamp(i32(_albedo_texel_cell(texel_v) + 0.5), 0, i32(shared.PLANET_FACE_CELLS)),
		}
		if value.surface_publication.debug {
			value.albedo_pixels[index * 3 + 0] = u8(clamp(color[0] * 255, 0, 255))
			value.albedo_pixels[index * 3 + 1] = u8(clamp(color[1] * 255, 0, 255))
			value.albedo_pixels[index * 3 + 2] = u8(clamp(color[2] * 255, 0, 255))
			value.normal_pixels[index * 3 + 0] = 0
			value.normal_pixels[index * 3 + 1] = 0
			value.normal_pixels[index * 3 + 2] = 0
			value.roughness_ao_pixels[index * 3 + 0] = 220
			value.roughness_ao_pixels[index * 3 + 1] = 255
			value.roughness_ao_pixels[index * 3 + 2] = 0
			continue
		}
		foundation_index := shared.planet_index(coord)
		direction := shared.planet_direction_uv(face, _albedo_texel_cell(column), _albedo_texel_cell(texel_v))
		sample := planet_surface_sample(&value.surface_publication, direction)
		color = sample.color
		moisture = sample.moisture
		ruggedness := f32(world.foundation.ruggedness[foundation_index]) / 255
		coast_rock := terrain_rocky_coast_weight(
			value.primary_biome[index],
			height,
			sea,
			slope,
			ruggedness,
		)
		// Beach band just above the waterline, sediment below it.
		beach := 1 - _smoothstep(sea + 0.2, sea + 0.9, height)
		color = _mix3(color, ALBEDO_SAND, beach * (1 - coast_rock))
		color = _mix3(color, ALBEDO_ROCK, coast_rock)
		color = _mix3(color, ALBEDO_SEDIMENT, 1 - _smoothstep(sea - 0.6, sea + 0.1, height))
		// Steep ground reads as bare rock, mirroring PLACEMENT_MAX_SLOPE so
		// unbuildable cliffs are visually obvious.
		rock := max(_smoothstep(0.45, 0.75, slope), coast_rock)
		color = _mix3(color, ALBEDO_ROCK, rock)
		surface_temperature := clamp(sample.air_temperature - i32(max(height - sea, 0) * shared.TERRAIN_ENVIRONMENTAL_LAPSE_MK_PER_M), shared.PLANET_MIN_TEMPERATURE, shared.PLANET_MAX_TEMPERATURE)
		snow_amount := shared.terrain_surface_snow_cover(height, value.snow_level, surface_temperature, sample.snow)
		river := f32(world.foundation.river_strength[shared.planet_index(coord)]) / 255
		chasm := f32(world.foundation.chasm_strength[shared.planet_index(coord)]) / 255
		color = _mix3(color, ALBEDO_SEDIMENT, river * 0.55)
		color = _mix3(color, ALBEDO_ROCK, chasm * 0.8)
		// Terraformed ground shows raw worked earth.
		delta := scratch.delta[column]
		color = _mix3(color, ALBEDO_SCAR, _smoothstep(0.05, 1.0, abs(delta)) * 0.6)
		ao := _terrain_ao(scratch, column, height, world, face, texel_v, (step_u + step_v) * 0.5)
		brightness := 0.97 + 0.06 * planet_material_noise(direction)
		color *= brightness
		value.albedo_pixels[index * 3 + 0] = u8(clamp(color[0], 0, 255))
		value.albedo_pixels[index * 3 + 1] = u8(clamp(color[1], 0, 255))
		value.albedo_pixels[index * 3 + 2] = u8(clamp(color[2], 0, 255))
		living := sample.ground * (1 - rock)
		organic := sample.organic * (1 - rock)
		controls := planet_material_pack({living, organic, max(sample.sediment, max(beach, river) * max(1 - living - organic, 0))})
		value.normal_pixels[index * 3 + 0] = controls[0]
		value.normal_pixels[index * 3 + 1] = controls[1]
		value.normal_pixels[index * 3 + 2] = controls[2]
		roughness := clamp(0.90 - rock * 0.30 - snow_amount * 0.18 + moisture * 0.05, 0.35, 1)
		value.roughness_ao_pixels[index * 3 + 0] = u8(roughness * 255)
		value.roughness_ao_pixels[index * 3 + 1] = u8(ao * 255)
		value.roughness_ao_pixels[index * 3 + 2] = u8(snow_amount * 255)
	}
}

terrain_material_weights :: proc(slope, snow: f32) -> (rock, snow_weight: f32) {
	rock = _smoothstep(0.16, 0.58, slope)
	snow_weight = snow * (1 - rock * 0.70)
	return
}

terrain_rocky_coast_weight :: proc(
	biome: shared.Biome_Id,
	height, sea, slope, ruggedness: f32,
) -> f32 {
	if biome != .Coast do return 0
	exposure := _smoothstep(0.18, 0.52, slope) * 0.65 + _smoothstep(0.38, 0.78, ruggedness) * 0.55
	shore := 1 - _smoothstep(sea + 1.2, sea + 3.5, height)
	return clamp(exposure * shore, 0, 1)
}

// Tap order (left, right, down, up) and the (a+b+c+d)*0.25 association are
// preserved exactly so the sum rounds identically across stripe widths.
_terrain_ao :: proc(scratch: ^Albedo_Row_Scratch, column: i32, center: f32, world: ^shared.World = nil, face: procgen.Terrain_Face_V4 = .Pos_X, row: i32 = 0, step := PLANET_ALBEDO_WORLD_STEP) -> f32 {
	radii := [3]i32{2, 8, 32}
	weights := [3]f32{0.5, 0.3, 0.2}
	low_taps := ALBEDO_TAP_AO_LOW
	high_taps := ALBEDO_TAP_AO_HIGH
	row_heights := &scratch.heights[ALBEDO_TAP_CENTER]
	occlusion := f32(0)
	for radius, index in radii {
		left := row_heights[max(column - radius, 0)]
		right := row_heights[min(column + radius, PLANET_ALBEDO_SIZE - 1)]
		if world != nil {
			if column - radius < 0 do left = planet_material_height_tap(world, face, column - radius, row)
			if column + radius >= PLANET_ALBEDO_SIZE do right = planet_material_height_tap(world, face, column + radius, row)
		}
		average :=
			(left + right +
				scratch.heights[low_taps[index]][column] +
				scratch.heights[high_taps[index]][column]) *
			0.25
		distance := f32(radius) * step
		occlusion += max(average - center, 0) / distance * weights[index]
	}
	return 1 - clamp(occlusion * 0.18, 0, 0.35)
}

_terrain_correlated_noise :: proc(column, row: i32) -> f32 {
	fine := _texel_hash01(column / 2, row / 2)
	medium := _texel_hash01(column / 8, row / 8)
	coarse := _texel_hash01(column / 32, row / 32)
	return fine * 0.25 + medium * 0.45 + coarse * 0.30
}

_biome_color :: proc(biome: shared.Biome_Id, moisture, temperature: f32) -> [3]f32 {
	base := _mix3(ALBEDO_LOAM_DRY, ALBEDO_LOAM_WET, moisture)
	switch biome {
	case .Ocean:
		return ALBEDO_SEDIMENT
	case .Lake:
		return ALBEDO_LAKEBED
	case .Coast:
		return ALBEDO_SAND
	case .Wetland:
		return ALBEDO_PEAT
	case .Savannah:
		return _mix3(ALBEDO_SAVANNAH_SOIL, ALBEDO_LOAM_DRY, moisture)
	case .Forest:
		return ALBEDO_FOREST_SOIL
	case .Taiga:
		return ALBEDO_TAIGA_SOIL
	case .Desert:
		return ALBEDO_DESERT
	case .Tundra:
		return _mix3(ALBEDO_TUNDRA_SOIL, ALBEDO_COLD_EARTH, moisture)
	case .Snowlands:
		return ALBEDO_SNOWLANDS
	case .Mountain:
		return ALBEDO_MOUNTAIN
	case .Grassland:
		base = _mix3(ALBEDO_COLD_EARTH, base, _smoothstep(0.25, 0.48, temperature))
		return _mix3(base, ALBEDO_SAVANNAH_SOIL, _smoothstep(0.68, 0.88, temperature))
	}
	return base
}

_flora_ground_color :: proc(
	world: ^shared.World,
	direction: [3]f32,
) -> (
	color: [3]f32,
	cover: f32,
) {
	assert(world != nil, "_flora_ground_color: nil world")
	cell := &world.flora_ecology.cells[shared.planetary_sample_index(direction)]
	total: u32
	weighted_form: u32
	for cohort in cell.cohorts {
		if cohort.lineage == shared.Lineage_Id(0) do continue
		lineage, found := shared.flora_ecology_lineage(&world.flora_ecology, cohort.lineage)
		if !found do continue
		cohort_cover := u32(max(cohort.ground_cover, cohort.canopy_cover))
		total += cohort_cover
		weighted_form += cohort_cover * u32(lineage.form)
	}
	if total == 0 do return ALBEDO_FLORA_LOW, 0
	form := f32(weighted_form) / f32(total) / f32(shared.Flora_Growth_Form.Tree)
	color = _mix3(ALBEDO_FLORA_LOW, ALBEDO_FLORA_GRASS, _smoothstep(0.12, 0.45, form))
	color = _mix3(color, ALBEDO_FLORA_WOODY, _smoothstep(0.55, 0.9, form))
	cover = clamp(f32(total) / f32(shared.FLORA_COVER_SCALE), 0, 1) * 0.82
	return
}

_mix3 :: proc(a, b: [3]f32, t: f32) -> [3]f32 {
	factor := clamp(t, 0, 1)
	return a + (b - a) * factor
}

_smoothstep :: proc(edge0, edge1, x: f32) -> f32 {
	assert(edge1 > edge0, "_smoothstep: degenerate edge order")
	t := clamp((x - edge0) / (edge1 - edge0), 0, 1)
	return t * t * (3 - 2 * t)
}

// _texel_hash01 is a splitmix-style hash of texel coordinates mapped to
// 0..1, used for deterministic per-texel dither.
_texel_hash01 :: proc(column, row: i32) -> f32 {
	hash := (u64(u32(column)) * 0x9E3779B97F4A7C15) ~ (u64(u32(row)) * 0xBF58476D1CE4E5B9)
	hash = (hash ~ (hash >> 30)) * 0x94D049BB133111EB
	hash ~= hash >> 27
	return f32(hash & 0xFFFF) / 65535
}

Water_Render_Kind :: enum u8 {
	None,
	Ocean,
	Lake,
	River,
}

Water_Optical_Profile :: struct {
	absorption: [3]f32,
	scattering: [3]f32,
	turbidity:  f32,
}

Water_Render_Sample :: struct {
	surface:        f32,
	shallow:        f32,
	coverage:       f32,
	depth:          f32,
	kind:           Water_Render_Kind,
	flow_direction: [2]f32,
	flow_speed:     f32,
	river_strength: f32,
	agitation:      f32,
	optical:        Water_Optical_Profile,
}

Water_Render_Classification :: struct {
	kinds:    []Water_Render_Kind,
	revision: u64,
	ready:    bool,
}

water_optical_profile :: proc(kind: Water_Render_Kind, turbidity: f32) -> Water_Optical_Profile {
	switch kind {
	case .None:
		return {}
	case .Ocean:
		return {{0.42, 0.16, 0.07}, {0.016, 0.09, 0.125}, turbidity}
	case .Lake:
		return {{0.55, 0.22, 0.12}, {0.035, 0.105, 0.075}, turbidity}
	case .River:
		return {{0.7, 0.34, 0.18}, {0.12, 0.105, 0.065}, turbidity}
	case:
		return {}
	}
}

water_render_kind :: proc(world: ^shared.World, coord: shared.Planet_Coord) -> Water_Render_Kind {
	assert(world != nil, "water_render_kind: nil world")
	canonical := shared.planet_canonical(coord)
	index := shared.planet_index(canonical)
	if world.waterfield.depths[index] < shared.WATER_WET_THRESHOLD do return .None
	biome := world.foundation.primary_biome[index]
	if biome == .Ocean || biome == .Coast do return .Ocean
	if biome == .Lake do return .Lake
	if world.foundation.river_strength[index] > 0 do return .River
	for radius in 1 ..= 12 {
		for offset in -radius ..= radius {
			neighbours := [4]shared.Planet_Coord {
				shared.planet_neighbour(canonical, i32(offset), i32(-radius)),
				shared.planet_neighbour(canonical, i32(offset), i32(radius)),
				shared.planet_neighbour(canonical, i32(-radius), i32(offset)),
				shared.planet_neighbour(canonical, i32(radius), i32(offset)),
			}
			for neighbour in neighbours {
				neighbour_index := shared.planet_index(shared.planet_canonical(neighbour))
				neighbour_biome := world.foundation.primary_biome[neighbour_index]
				if neighbour_biome == .Ocean || neighbour_biome == .Coast do return .Ocean
			}
		}
	}
	return .Lake
}

water_render_sample :: proc(ground, depth: f32) -> (surface, shallow, coverage: f32) {
	visible_depth := max(depth, 0)
	surface = ground + visible_depth - WATER_SURFACE_DROP
	shallow = 1 - clamp(visible_depth / WATER_DEPTH_MAX, 0, 1)
	coverage = clamp(
		visible_depth / f32(shared.WATER_WET_THRESHOLD) * f32(shared.WATER_DEPTH_SCALE),
		0,
		1,
	)
	return
}

water_render_column_depth :: proc(depth, radial_surface_displacement: f32) -> f32 {
	if depth <= 0 do return 0
	return max(depth + radial_surface_displacement, 0)
}

water_render_sample_at :: proc(
	world: ^shared.World,
	coord: shared.Planet_Coord,
) -> Water_Render_Sample {
	assert(world != nil, "water_render_sample_at: nil world")
	ground := shared.terrain_height_at_coord(world, coord)
	depth := max(shared.waterfield_depth_at_coord(world, coord), f32(0))
	surface, shallow, coverage := water_render_sample(ground, depth)
	kind := water_render_kind(world, coord)
	direction := shared.planet_direction(coord)
	planet_index := shared.planetary_sample_index(direction)
	transport_east := f32(world.planetary.ocean.transport_east[planet_index])
	transport_north := f32(world.planetary.ocean.transport_north[planet_index])
	flow_speed := (abs(transport_east) + abs(transport_north)) / f32(shared.PLANET_VELOCITY_SCALE)
	flow_length := math.sqrt(transport_east * transport_east + transport_north * transport_north)
	flow_direction := [2]f32{}
	if flow_length > 0.0001 do flow_direction = {transport_east / flow_length, transport_north / flow_length}
	river_strength :=
		f32(world.foundation.river_strength[shared.planet_index(shared.planet_canonical(coord))]) /
		255
	agitation := f32(world.planetary.waves.breaking[planet_index]) / 255
	turbidity := clamp(river_strength * 0.7 + agitation * 0.2 + shallow * 0.1, f32(0), f32(1))
	return {
		surface = surface,
		shallow = shallow,
		coverage = coverage,
		depth = depth,
		kind = kind,
		flow_direction = flow_direction,
		flow_speed = flow_speed,
		river_strength = river_strength,
		agitation = agitation,
		optical = water_optical_profile(kind, turbidity),
	}
}

world_water_physics_sample :: proc(
	value: ^Client_State,
	query: ^Ocean_Macro_Wave_Query,
	position: [3]f32,
	sample_time: f32,
) -> Water_Physics_Sample {
	assert(value != nil && query != nil, "world_water_physics_sample: nil input")
	length := math.sqrt(
		position.x * position.x + position.y * position.y + position.z * position.z,
	)
	if length <= 0.0001 do return {}
	radial := position / length
	if value.terrain.ocean.nearshore.fixture_active {
		local_surface, wet := ocean_nearshore_surface_sample(&value.terrain.ocean.nearshore, position)
		if !wet do return {}
		return {
			surface = shared.planet_position(radial, 0) + local_surface.displacement,
			normal = local_surface.normal,
			velocity = local_surface.velocity,
			depth = local_surface.depth,
			whitewater = local_surface.foam,
			wet = true,
		}
	}
	face, u, v := shared.planet_locate(radial)
	coord := shared.Planet_Coord{face, i32(u), i32(v)}
	ground := shared.terrain_height_at_coord(&value.world, coord)
	depth := max(shared.waterfield_depth_at_coord(&value.world, coord), 0)
	coverage := clamp(
		depth / f32(shared.WATER_WET_THRESHOLD) * f32(shared.WATER_DEPTH_SCALE),
		0,
		1,
	)
	local_surface, local_wet := ocean_nearshore_surface_sample(&value.terrain.ocean.nearshore, position)
	if !local_wet && local_surface.blend >= 0.999 do return {}
	if local_wet && local_surface.blend >= 0.999 {
		wave := ocean_wave_query_sample(
			&value.terrain.ocean,
			query,
			{position = shared.planet_position(radial, 0), depth = local_surface.depth, coverage = 1, sample_time = sample_time},
		)
		return {
			surface = shared.planet_position(radial, 0) + wave.displacement,
			normal = wave.normal,
			velocity = wave.velocity,
			acceleration = wave.acceleration,
			depth = local_surface.depth,
			breaking = wave.breaking,
			whitewater = wave.whitewater,
			flow_drag = wave.drag,
			wet = true,
		}
	}
	if coverage <= 0 do return {}
	planet_index := shared.planetary_sample_index(radial)
	surface_height :=
		ground +
		depth +
		shared.planet_render_height_from_mm(value.world.planetary.ocean.surface_mm[planet_index])
	_, east, north := shared.planet_basis(radial)
	current :=
		east * f32(value.world.planetary.ocean.transport_east[planet_index]) +
		north * f32(value.world.planetary.ocean.transport_north[planet_index])
	current /= f32(shared.PLANET_VELOCITY_SCALE)
	base_surface := shared.planet_position(radial, surface_height)
	wave := ocean_wave_query_sample(
		&value.terrain.ocean,
		query,
		{position = base_surface, depth = depth, coverage = coverage, sample_time = sample_time},
	)
	return {
		surface = base_surface + wave.displacement,
		normal = wave.normal,
		velocity = current + wave.velocity,
		acceleration = wave.acceleration,
		depth = depth,
		breaking = wave.breaking,
		whitewater = wave.whitewater,
		flow_drag = wave.drag,
		wet = true,
	}
}

terrain_draw_opaque :: proc(
	value: ^Terrain,
	pass: ^rl.Gpu_3D_Pass,
	camera: rl.Camera3D,
	atmosphere: ^Atmosphere,
) {
	assert(value != nil, "terrain_draw_opaque: nil terrain")
	assert(pass != nil, "terrain_draw: nil pass")
	assert(atmosphere != nil, "terrain_draw: nil atmosphere")
	if !value.ready do return
	if value.ocean.nearshore.fixture_active {
		fixture := &value.ocean.fixture_render
		if !fixture.ready || fixture.last_time != value.ocean.macro.time || fixture.last_focus != value.ocean.nearshore.focus {
			ocean_fixture_mesh_fill(fixture, &value.ocean.nearshore)
			ocean_fixture_upload(fixture)
			if fixture.ready {
				fixture.last_time = value.ocean.macro.time
				fixture.last_focus = value.ocean.nearshore.focus
			}
		}
		if fixture.ready && value.ocean.fixture_render.bed.id != 0 {
			rl.draw_gpu_mesh(pass, value.ocean.fixture_render.bed, rl.Matrix(1), {color = WATER_SHALLOW, style = .Opaque})
		}
		return
	}
	fog := [4]f32{0, 0, atmosphere.fog_density, max(atmosphere.fog_height_falloff, 0.001)}
	visibility := _planet_visibility_prepare(camera.position)
	value.surface_publication.visible = {}
	for patch in value.planet_patches {
		if _planet_patch_visible_prepared(patch.center, visibility) do value.surface_publication.visible[int(patch.face)] = true
	}
	identity := rl.Matrix(1)
	per_face := shared.PLANET_PATCHES_PER_FACE * shared.PLANET_PATCHES_PER_FACE
	for face_index in 0 ..< shared.PLANET_FACE_COUNT {
		// Baked per-face material once its textures exist; before that the
		// biome scalar gradient stands in.
		material := rl.Gpu_Material {
			color           = {42, 92, 48, 255},
			color_high      = {238, 242, 246, 255},
			use_scalar      = true,
			custom_params_4 = fog,
			shader          = value.terrain_shader,
		}
		if value.albedo_textures[face_index].id != 0 &&
		   value.normal_textures[face_index].id != 0 &&
		   value.roughness_ao_textures[face_index].id != 0 {
			material = rl.Gpu_Material {
				color                = rl.WHITE,
				texture              = value.albedo_textures[face_index],
				normal_texture       = value.normal_textures[face_index],
				roughness_ao_texture = value.roughness_ao_textures[face_index],
				custom_params_4      = fog,
				shader               = value.terrain_shader,
			}
		}
		for slot in 0 ..< per_face {
			patch_index := face_index * per_face + slot
			if value.planet_meshes[patch_index][0].id == 0 do continue
			if !value.cutaway &&
			   !_planet_patch_visible_prepared(
					   value.planet_patches[patch_index].center,
					   visibility,
				   ) {
				continue
			}
			level := _planet_patch_lod(value, patch_index, camera.position)
			mesh := value.planet_meshes[patch_index][level]
			actual_level := level
			if mesh.id == 0 {
				mesh = value.planet_meshes[patch_index][0]
				actual_level = 0
			}
			profile_terrain_draw_begin(pass, face_index, slot, actual_level, material.texture.id != 0)
			rl.draw_gpu_mesh(&pass^, mesh, identity, material)
			profile_terrain_draw_end(pass)
		}
	}
}

terrain_draw_ocean :: proc(
	value: ^Terrain,
	pass: ^rl.Gpu_3D_Pass,
	camera: rl.Camera3D,
	settings: Ocean_Visual_Settings,
	atmosphere: ^Atmosphere,
	scene_color, scene_depth: rl.Texture2D,
) {
	assert(value != nil, "terrain_draw_ocean: nil terrain")
	assert(pass != nil, "terrain_draw_ocean: nil pass")
	assert(atmosphere != nil, "terrain_draw_ocean: nil atmosphere")
	ocean_renderer_draw(
		&value.ocean,
		pass,
		camera,
		value.water_shader,
		value.far_water_shader,
		settings,
		atmosphere,
		scene_color,
		scene_depth,
	)
}

terrain_draw :: proc(
	value: ^Terrain,
	pass: ^rl.Gpu_3D_Pass,
	camera: rl.Camera3D,
	settings: Ocean_Visual_Settings,
) {
	atmosphere := atmosphere_preset(.Orbital_Day, atmosphere_default_quality())
	terrain_draw_opaque(value, pass, camera, &atmosphere)
	terrain_draw_ocean(value, pass, camera, settings, &atmosphere, {}, {})
}

terrain_draw_section :: proc(value: ^Terrain, pass: ^rl.Gpu_3D_Pass, camera: rl.Camera3D) {
	assert(value != nil && pass != nil, "terrain draw section: nil input")
	if !value.ready || value.section_mesh.id == 0 do return
	if planet_section_generate(&value.section_cpu, value.world_ref, camera.position) {
		_ = rl.update_gpu_mesh_vertices(value.section_mesh, value.section_cpu.vertices[:])
	}
	material := rl.Gpu_Material {
		color           = UI_CUTAWAY_INNER_CORE,
		custom_params   = {
			f32(UI_CUTAWAY_INNER_CORE.r) / 255,
			f32(UI_CUTAWAY_INNER_CORE.g) / 255,
			f32(UI_CUTAWAY_INNER_CORE.b) / 255,
			1,
		},
		custom_params_2 = {
			f32(UI_CUTAWAY_OUTER_CORE.r) / 255,
			f32(UI_CUTAWAY_OUTER_CORE.g) / 255,
			f32(UI_CUTAWAY_OUTER_CORE.b) / 255,
			1,
		},
		custom_params_3 = {
			f32(UI_CUTAWAY_MANTLE.r) / 255,
			f32(UI_CUTAWAY_MANTLE.g) / 255,
			f32(UI_CUTAWAY_MANTLE.b) / 255,
			1,
		},
		custom_params_4 = {
			f32(UI_CUTAWAY_CRUST.r) / 255,
			f32(UI_CUTAWAY_CRUST.g) / 255,
			f32(UI_CUTAWAY_CRUST.b) / 255,
			1,
		},
		custom_params_7 = {
			f32(UI_CUTAWAY_OCEAN.r) / 255,
			f32(UI_CUTAWAY_OCEAN.g) / 255,
			f32(UI_CUTAWAY_OCEAN.b) / 255,
			1,
		},
		custom_params_8 = {
			f32(UI_CUTAWAY_BOUNDARY.r) / 255,
			f32(UI_CUTAWAY_BOUNDARY.g) / 255,
			f32(UI_CUTAWAY_BOUNDARY.b) / 255,
			1,
		},
		style           = .Opaque_Overlay,
		shader          = value.section_shader,
	}
	rl.draw_gpu_mesh(pass, value.section_mesh, rl.Matrix(1), material)
}

// _planet_patch_visible is a horizon test: a patch whose centre direction
// points away from the camera beyond the sphere's horizon (plus a generous
// margin for patch extent and terrain relief) cannot be seen.
Planet_Visibility :: struct {
	camera_direction: [3]f32,
	threshold:        f32,
	draw_all:         bool,
}

@(private)
_planet_visibility_prepare :: proc(camera_position: [3]f32) -> Planet_Visibility {
	distance_squared :=
		camera_position.x * camera_position.x +
		camera_position.y * camera_position.y +
		camera_position.z * camera_position.z
	if distance_squared <= shared.PLANET_RADIUS * shared.PLANET_RADIUS do return {draw_all = true}
	distance := math.sqrt(distance_squared)
	cos_horizon := shared.PLANET_RADIUS / distance
	return {
		camera_direction = camera_position / distance,
		threshold = math.cos(math.acos(clamp(cos_horizon, -1, 1)) + f32(0.25)),
	}
}

@(private)
_planet_patch_visible_prepared :: proc(
	patch_center: [3]f32,
	visibility: Planet_Visibility,
) -> bool {
	if visibility.draw_all do return true
	dot :=
		visibility.camera_direction.x * patch_center.x +
		visibility.camera_direction.y * patch_center.y +
		visibility.camera_direction.z * patch_center.z
	return dot > visibility.threshold
}

@(private)
_planet_patch_visible :: proc(patch_center: [3]f32, camera_position: [3]f32) -> bool {
	return _planet_patch_visible_prepared(
		patch_center,
		_planet_visibility_prepare(camera_position),
	)
}

terrain_ray_hit :: proc(value: ^Terrain, ray: rl.Ray_3D) -> (position: [3]f32, ok: bool) {
	assert(value != nil, "terrain_ray_hit: nil terrain")
	assert(value.ready, "terrain_ray_hit: terrain not ready")
	assert(b3.World_IsValid(value.physics_world), "terrain_ray_hit: invalid physics world")
	filter := b3.DefaultQueryFilter()
	filter.categoryBits = PHYSICS_CATEGORY_DEBRIS
	filter.maskBits = PHYSICS_CATEGORY_TERRAIN
	result := b3.World_CastRayClosest(
		value.physics_world,
		ray.origin,
		ray.direction * TERRAIN_RAY_MAX_DISTANCE,
		filter,
	)
	if !result.hit do return {}, false
	point := result.point
	if !_point_on_planet(point) || !_terrain_ray_hit_near_side(ray, point) do return {}, false
	return point, true
}

_terrain_ray_hit_near_side :: proc(ray: rl.Ray_3D, point: [3]f32) -> bool {
	if math.is_nan(point.x) || math.is_nan(point.y) || math.is_nan(point.z) do return false
	length_squared :=
		ray.direction.x * ray.direction.x +
		ray.direction.y * ray.direction.y +
		ray.direction.z * ray.direction.z
	if math.is_nan(length_squared) || length_squared <= 0.000001 do return false
	direction := ray.direction / math.sqrt(length_squared)
	to_hit := point - ray.origin
	hit_distance := to_hit.x * direction.x + to_hit.y * direction.y + to_hit.z * direction.z
	closest_to_center := -(ray.origin.x * direction.x +
		ray.origin.y * direction.y +
		ray.origin.z * direction.z)
	return hit_distance >= 0 && closest_to_center >= 0 && hit_distance <= closest_to_center + 0.01
}

// _point_on_planet accepts hits inside the plausible surface shell; NaNs and
// stray geometry outside the height band are rejected.
_point_on_planet :: proc(point: [3]f32) -> bool {
	if math.is_nan(point.x) || math.is_nan(point.y) || math.is_nan(point.z) do return false
	radius := math.sqrt(point.x * point.x + point.y * point.y + point.z * point.z)
	return radius > shared.PLANET_RADIUS - 96 && radius < shared.PLANET_RADIUS + 112
}

// terrain_surface_height_at_direction probes the rendered isosurface along
// the local radial at a sphere direction: ray from just above the analytic
// height straight down toward the core. Falls back to the analytic height
// when nothing is hit (a patch pending regeneration).
terrain_surface_height_at_direction :: proc(value: ^Terrain, direction: [3]f32) -> f32 {
	assert(value != nil, "terrain_surface_height_at_direction: nil terrain")
	coord := shared.planet_coord_from_direction(direction)
	cached := shared.terrain_height_at_coord(value.world_ref, coord)
	if !value.ready || !b3.World_IsValid(value.physics_world) do return cached
	filter := b3.DefaultQueryFilter()
	filter.categoryBits = PHYSICS_CATEGORY_DEBRIS
	filter.maskBits = PHYSICS_CATEGORY_TERRAIN
	origin := direction * (shared.PLANET_RADIUS + cached + TERRAIN_SURFACE_PROBE_LIFT)
	travel := direction * -(TERRAIN_SURFACE_PROBE_LIFT + TERRAIN_SURFACE_PROBE_DROP)
	value.surface_probe_casts += 1
	result := b3.World_CastRayClosest(value.physics_world, origin, travel, filter)
	if !result.hit do return cached
	point := result.point
	return(
		math.sqrt(point.x * point.x + point.y * point.y + point.z * point.z) -
		shared.PLANET_RADIUS \
	)
}

// terrain_seat_revision is the cache key for anything seated on the rendered
// surface at `coord`: the committed collision revisions of the patch that
// owns the cell and of every seam duplicate's patch (a seam cell can be hit
// by up to three patches' geometry), plus the heights revision that moves
// the probe origin. Any of them changing changes the key.
terrain_seat_revision :: proc(value: ^Terrain, coord: shared.Planet_Coord) -> u64 {
	assert(value != nil, "terrain_seat_revision: nil terrain")
	revision := value.patch_collision_revision[_planet_patch_index_for(coord)]
	duplicates, count := shared.planet_duplicates(coord)
	for index in 0 ..< count {
		revision += value.patch_collision_revision[_planet_patch_index_for(duplicates[index])]
	}
	return revision * 0x9e3779b97f4a7c15 ~ value.heights_revision
}

// Legacy face-local height queries. Flora, ruins, sockets and the highlight
// still lay out in flat face-plane coordinates (grid cell * GRID_CELL_SIZE);
// these resolve that plane onto the spawn face's foundation heights so those
// systems seat on real ground instead of a zeroed cache.
terrain_height_cached :: proc(value: ^Terrain, world_x, world_y: f32) -> f32 {
	assert(value != nil, "terrain_height_cached: nil terrain")
	if value.world_ref == nil do return 0
	return shared.terrain_height(value.world_ref, world_x, world_y)
}

terrain_seat_height :: proc(value: ^Terrain, world_x, world_y: f32) -> f32 {
	assert(value != nil, "terrain_seat_height: nil terrain")
	return terrain_height_cached(value, world_x, world_y)
}

terrain_surface_height :: proc(value: ^Terrain, world_x, world_y: f32) -> f32 {
	assert(value != nil, "terrain_surface_height: nil terrain")
	return terrain_height_cached(value, world_x, world_y)
}

terrain_deinit :: proc(value: ^Terrain) {
	assert(value != nil, "terrain_deinit: nil terrain")
	// Release any producer parked on a full queue before joining, or a
	// mid-bake teardown deadlocks: a blocked worker never reaches the
	// dispatch check that would end it.
	sync.atomic_store(&value.par_cancel, true)
	for worker in value.par_workers {
		thread.join(worker)
		thread.destroy(worker)
	}
	delete(value.par_workers)
	value.par_workers = nil
	sync.mutex_lock(&value.par_mutex)
	delete(value.par_ready)
	value.par_ready = nil
	sync.mutex_unlock(&value.par_mutex)
	value.par_dispatch = 0
	value.par_failed = false
	value.par_queue_limit = 0
	value.par_spawned = false
	value.par_world = nil
	sync.atomic_store(&value.par_cancel, false)
	for index in 0 ..< PLANET_RENDER_PATCH_COUNT {
		if b3.Body_IsValid(value.patch_bodies[index]) do b3.DestroyBody(value.patch_bodies[index])
		value.patch_bodies[index] = {}
		if value.patch_physics[index] != nil do b3.DestroyMesh(value.patch_physics[index])
		value.patch_physics[index] = nil
		_patch_chain_destroy(&value.planet_meshes[index])
		value.patch_lods[index] = 0
		value.patch_lod_error[index] = {}
		planet_render_patch_deinit(&value.planet_patches[index])
	}
	value.planet_patch_cursor = 0
	value.planet_patches_ready = false
	value.dirty = {}
	value.preview = false
	value.refine_pending = {}
	ocean_renderer_deinit(&value.ocean)
	for face_index in 0 ..< shared.PLANET_FACE_COUNT {
		if value.albedo_textures[face_index].id != 0 {
			rl.UnloadTexture(value.albedo_textures[face_index])
		}
		value.albedo_textures[face_index] = {}
		if value.normal_textures[face_index].id != 0 {
			rl.UnloadTexture(value.normal_textures[face_index])
		}
		value.normal_textures[face_index] = {}
		if value.roughness_ao_textures[face_index].id != 0 {
			rl.UnloadTexture(value.roughness_ao_textures[face_index])
		}
		value.roughness_ao_textures[face_index] = {}
		value.upload_faces[face_index] = false
	}
	value.water_dirty = false
	rl.destroy_gpu_3d_shader(&value.terrain_shader)
	rl.destroy_gpu_3d_shader(&value.water_shader)
	rl.destroy_gpu_3d_shader(&value.far_water_shader)
	rl.destroy_gpu_3d_shader(&value.section_shader)
	if value.section_mesh.id != 0 do rl.destroy_gpu_mesh(&value.section_mesh)
	value.section_cpu = {}
	value.surface_publication = {}
	value.climate_row = 0
	value.albedo_row = 0
	value.albedo_min_row = PLANET_ALBEDO_ROWS
	value.albedo_max_row = -1
	value.heights_revision += 1
	value.physics_world = {}
	value.world_ref = nil
	value.build_active = false
	value.ready = false
}

// _patch_chain_destroy releases every uploaded level of one render patch.
_patch_chain_destroy :: proc(chain: ^[TERRAIN_LOD_COUNT]rl.Gpu_Mesh) {
	assert(chain != nil, "_patch_chain_destroy: nil chain")
	for level in 0 ..< TERRAIN_LOD_COUNT {
		if chain[level].id != 0 do rl.destroy_gpu_mesh(&chain[level])
		chain[level] = {}
	}
}

Terrain_Optimize_Result :: struct {
	vertices:  []asset.Vertex,
	indices:   []u32,
	optimized: bool,
}

_terrain_gpu_vertices :: proc(vertices: []asset.Vertex) -> []rl.Gpu_3D_Vertex {
	upload := make([]rl.Gpu_3D_Vertex, len(vertices), context.temp_allocator)
	for vertex, index in vertices {
		upload[index] = {
			position = vertex.position,
			normal   = vertex.normal,
			scalar   = vertex.scalar,
			uv       = vertex.uv,
		}
	}
	return upload
}

// _terrain_mesh_optimize runs the engine's vertex-cache/overdraw/fetch pass
// over one patch surface. Any refusal (size caps, scratch failure) falls
// back to the unoptimized input, never to a failed patch.
_terrain_mesh_optimize :: proc(
	vertices: []asset.Vertex,
	indices: []u32,
	bounds: asset.Bounds_3D,
) -> Terrain_Optimize_Result {
	fallback := Terrain_Optimize_Result {
		vertices = vertices,
		indices  = indices,
	}
	if len(vertices) == 0 || len(vertices) > procgen.OPTIMIZE_MAX_VERTICES do return fallback
	if len(indices) < 3 || len(indices) > procgen.OPTIMIZE_MAX_INDICES do return fallback
	if len(indices) % 3 != 0 do return fallback
	block := make(
		[]u8,
		procgen.optimize_scratch_size(len(vertices), len(indices)) +
		procgen.OPTIMIZE_SCRATCH_PADDING,
		context.temp_allocator,
	)
	scratch, scratch_ok := procgen.optimize_scratch_make(block, len(vertices), len(indices))
	if !scratch_ok do return fallback
	out_vertices := make([]asset.Vertex, len(vertices), context.temp_allocator)
	out_indices := make([]u32, len(indices), context.temp_allocator)
	source := asset.Mesh_View {
		id        = 1,
		vertices  = vertices,
		indices   = indices,
		primitive = .Triangles,
		bounds    = bounds,
	}
	result, ok := procgen.optimize_mesh(source, out_vertices, out_indices, scratch)
	if !ok do return fallback
	return {
		vertices = out_vertices[:result.vertex_count],
		indices = out_indices[:result.index_count],
		optimized = true,
	}
}

// _planet_patch_lod_border locks every vertex on the patch's face-UV
// boundary so the simplifier cannot move it: neighbouring patches keep the
// full-resolution border on every level, which is what makes mixed-level
// seams crack-free. UVs survive the optimize pass, so the lock is exact.
_planet_patch_lod_border :: proc(
	locked: []bool,
	vertices: []asset.Vertex,
	patch: ^Planet_Render_Patch,
) {
	assert(len(locked) == len(vertices), "_planet_patch_lod_border: length mismatch")
	cells := f32(shared.PLANET_FACE_CELLS)
	u_low := f32(patch.patch_u * shared.PLANET_PATCH_CELLS) / cells
	u_high := f32((patch.patch_u + 1) * shared.PLANET_PATCH_CELLS) / cells
	v_low := f32(patch.patch_v * shared.PLANET_PATCH_CELLS) / cells
	v_high := f32((patch.patch_v + 1) * shared.PLANET_PATCH_CELLS) / cells
	for vertex, index in vertices {
		locked[index] =
			abs(vertex.uv.x - u_low) < TERRAIN_LOD_BORDER_UV_EPSILON ||
			abs(vertex.uv.x - u_high) < TERRAIN_LOD_BORDER_UV_EPSILON ||
			abs(vertex.uv.y - v_low) < TERRAIN_LOD_BORDER_UV_EPSILON ||
			abs(vertex.uv.y - v_high) < TERRAIN_LOD_BORDER_UV_EPSILON
	}
}

// _planet_patch_lod_build simplifies the patch surface into the coarser
// levels of its chain, uploading each level that actually shrank.
//
// Every failure path is a shorter chain rather than a failed patch: the
// simplifier refuses meshes above SIMPLIFY_MAX_VERTICES, a level may fail to
// shrink, and an upload may be refused by a full mesh pool. One level is
// always a valid answer, so `patch_lods` is the count and selection clamps
// to it.
_planet_patch_lod_build :: proc(
	chain: ^[TERRAIN_LOD_COUNT]rl.Gpu_Mesh,
	errors: ^[TERRAIN_LOD_COUNT]f32,
	vertices: []asset.Vertex,
	indices: []u32,
	bounds: asset.Bounds_3D,
	patch: ^Planet_Render_Patch,
) -> int {
	assert(chain != nil, "_planet_patch_lod_build: nil chain")
	assert(errors != nil, "_planet_patch_lod_build: nil errors")
	if len(vertices) == 0 || len(indices) < 3 do return 1
	if len(vertices) > procgen.SIMPLIFY_MAX_VERTICES do return 1
	block := make(
		[]u8,
		procgen.simplify_scratch_size(len(vertices), len(indices)) +
		procgen.SIMPLIFY_SCRATCH_PADDING,
		context.temp_allocator,
	)
	scratch, scratch_ok := procgen.simplify_scratch_make(block, len(vertices), len(indices))
	if !scratch_ok do return 1
	locked := make([]bool, len(vertices), context.temp_allocator)
	_planet_patch_lod_border(locked, vertices, patch)
	out_vertices := make([]asset.Vertex, len(vertices), context.temp_allocator)
	out_indices := make([]u32, len(indices), context.temp_allocator)
	upload := make([]rl.Gpu_3D_Vertex, len(vertices), context.temp_allocator)
	source := asset.Mesh_View {
		id        = 1,
		vertices  = vertices,
		indices   = indices,
		primitive = .Triangles,
		bounds    = bounds,
	}
	levels := 1
	for level in 1 ..< TERRAIN_LOD_COUNT {
		target := int(f32(len(indices)) * TERRAIN_LOD_RATIOS[level]) / 3 * 3
		if target < 3 do break
		options := procgen.Simplify_Options {
			target_index_count = target,
		}
		result, ok := procgen.simplify_mesh(
			source,
			options,
			locked,
			out_vertices,
			out_indices,
			scratch,
		)
		if !ok || result.index_count >= len(indices) do break
		optimized := _terrain_mesh_optimize(
			out_vertices[:result.vertex_count],
			out_indices[:result.index_count],
			bounds,
		)
		for vertex, index in optimized.vertices {
			upload[index] = {
				position = vertex.position,
				normal   = vertex.normal,
				scalar   = vertex.scalar,
				uv       = vertex.uv,
			}
		}
		mesh, mesh_ok := rl.create_gpu_mesh(
			upload[:len(optimized.vertices)],
			optimized.indices,
			.Triangles,
		)
		if !mesh_ok do break
		chain[level] = mesh
		errors[level] = result.error
		levels = level + 1
	}
	return levels
}

// _planet_patch_lod selects the coarsest level whose geometric error stays
// under the depth-scaled budget - the projected-error rule from
// ../ingot/docs/cluster-lod.md. Level zero has zero error, so it is always a
// legal answer and the loop can only ever improve on it.
_planet_patch_lod :: proc(value: ^Terrain, patch_index: int, camera_position: [3]f32) -> int {
	assert(value != nil, "_planet_patch_lod: nil terrain")
	assert(patch_index >= 0 && patch_index < PLANET_RENDER_PATCH_COUNT, "_planet_patch_lod: index")
	levels := value.patch_lods[patch_index]
	if levels <= 1 do return 0
	patch := &value.planet_patches[patch_index]
	mid_height := (patch.height_min + patch.height_max) * 0.5
	center := patch.center * (shared.PLANET_RADIUS + mid_height)
	offset := center - camera_position
	distance_squared := offset.x * offset.x + offset.y * offset.y + offset.z * offset.z
	// The nearest point of the patch decides, not its centre: a patch the
	// camera hovers over must not drop a level because its midpoint is far.
	half_extent := f32(shared.PLANET_PATCH_CELLS) * shared.GRID_CELL_SIZE * 0.5
	selected := 0
	for level in 1 ..< min(levels, TERRAIN_LOD_COUNT) {
		required_depth := value.patch_lod_error[patch_index][level] / TERRAIN_LOD_ERROR_RATIO
		required_distance := max(required_depth, TERRAIN_LOD_MIN_DEPTH) + half_extent
		if distance_squared < required_distance * required_distance do break
		selected = level
	}
	return selected
}

// _patch_worker generates patch grids CPU-side: each atomic dispatch claims
// one patch index, fills that patch's own vertex/index storage (no two
// workers ever share a patch), and publishes the index for the main thread
// to upload. Runs only during the initial load, against an immutable world.
_patch_worker :: proc(terrain: ^Terrain) {
	per_face := shared.PLANET_PATCHES_PER_FACE * shared.PLANET_PATCHES_PER_FACE
	// tigerstyle: allow-unbounded-loop -- bounded by PLANET_RENDER_PATCH_COUNT dispatches
	for !sync.atomic_load(&terrain.par_cancel) {
		index := sync.atomic_add(&terrain.par_dispatch, 1)
		if index >= PLANET_RENDER_PATCH_COUNT do break
		patch := &terrain.planet_patches[index]
		patch.face = procgen.Terrain_Face_V4(index / per_face)
		remainder := index % per_face
		patch.patch_u = remainder % shared.PLANET_PATCHES_PER_FACE
		patch.patch_v = remainder / shared.PLANET_PATCHES_PER_FACE
		if !planet_render_patch_generate(patch, terrain.par_world) {
			sync.mutex_lock(&terrain.par_mutex)
			terrain.par_failed = true
			sync.mutex_unlock(&terrain.par_mutex)
			break
		}
		if !_patch_publish(terrain, index) do break
	}
}

// _patch_publish hands a finished patch index to the main thread, waiting
// while the queue is at its cap. It returns false only when terrain_deinit
// has asked the bake to stop.
_patch_publish :: proc(terrain: ^Terrain, patch_index: int) -> bool {
	limit := max(terrain.par_queue_limit, 1)
	// tigerstyle: allow-unbounded-loop -- the main thread drains every frame and par_cancel releases teardown
	for {
		if sync.atomic_load(&terrain.par_cancel) do return false
		sync.mutex_lock(&terrain.par_mutex)
		if len(terrain.par_ready) < limit {
			append(&terrain.par_ready, patch_index)
			sync.mutex_unlock(&terrain.par_mutex)
			return true
		}
		sync.mutex_unlock(&terrain.par_mutex)
		time.sleep(TERRAIN_PAR_QUEUE_WAIT)
	}
}

// _patch_drain_ready uploads finished patches until the budget is spent or
// the queue runs dry. Returns false only on a worker-reported failure.
_patch_drain_ready :: proc(value: ^Terrain, start: time.Tick, budget: time.Duration) -> bool {
	assert(value != nil, "_patch_drain_ready: nil terrain")
	// Pop from the back (O(1)) to avoid copying the slice forward.
	for time.tick_since(start) < budget {
		sync.mutex_lock(&value.par_mutex)
		pending := len(value.par_ready)
		failed := value.par_failed
		if pending == 0 || failed {
			sync.mutex_unlock(&value.par_mutex)
			return !failed
		}
		patch_index := pop(&value.par_ready)
		sync.mutex_unlock(&value.par_mutex)
		if !_planet_patch_upload(value, patch_index) do return false
		value.planet_patch_cursor += 1
	}
	return true
}

// terrain_albedo_binding resolves the baked albedo texture for a face.
terrain_albedo_binding :: proc(value: ^Terrain, face: procgen.Terrain_Face_V4) -> rl.Texture2D {
	assert(value != nil, "terrain_albedo_binding: nil terrain")
	return value.albedo_textures[int(face)]
}

// terrain_scatter_prepare arms a bare Terrain for a GPU-free flora scatter:
// the planet seat fallback reads heights straight off the sim world.
terrain_scatter_prepare :: proc(value: ^Terrain, world: ^shared.World) {
	assert(value != nil && world != nil, "terrain_scatter_prepare: nil input")
	value.world_ref = world
}
