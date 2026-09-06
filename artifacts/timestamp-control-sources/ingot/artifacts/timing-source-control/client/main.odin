package main

import shared "../shared"
import "core:fmt"
import "core:math"
import "core:time"
import ecs "ingot:ecs"
import fit "ingot:fit"
import rl "ingot:gfx"
import procgen "ingot:procgen"

SCREEN_WIDTH :: 1280
SCREEN_HEIGHT :: 720
MAX_FRAME_DT :: f32(0.25)
// Minimum camera eye height above the terrain directly beneath it.
CAMERA_TERRAIN_CLEARANCE :: f32(1.5)
// Steep top-down band for the RTS view: the camera can tilt between these
// pitches but never drop to a horizon-level or underground view.
CAMERA_MIN_PITCH :: f32(20.0 * math.PI / 180.0)
CAMERA_MAX_PITCH :: f32(88.0 * math.PI / 180.0)
// Start pitched all the way up (= CAMERA_MAX_PITCH) so the first frame looks
// down the radial through the globe centre and the planet is centred: the
// globe centre projects R*cos(pitch) off screen-centre, which is ~0.42R at 65
// but a negligible ~0.035R at 88.
CAMERA_START_PITCH :: f32(88.0 * math.PI / 180.0)
// Default facing direction; the start position {-16, -16, ...} already
// implies this yaw, the constant just makes the default deliberate.
CAMERA_START_YAW :: f32(-135.0 * math.PI / 180.0)
// Start far enough out that the whole planet (angular diameter ~33 degrees
// at 3.5 radii against the 42 degree fovy) fits in the first frame.
CAMERA_START_DISTANCE :: f32(3.5 * shared.PLANET_RADIUS)
// Fraction of orbit distance kept per scroll notch: multiplicative zoom
// covers the 6..6480 range in ~50 notches where the library's fixed
// 2-units-per-notch step would need ~1900 from the start distance.
CAMERA_ZOOM_STEP :: f32(0.87)
// Exponential damping rate for the globe throw, per second; ~2 s glide.
CAMERA_SPIN_DAMPING :: f32(1.6)
// Below this angular speed (rad/s) a thrown globe is considered stopped.
CAMERA_SPIN_MIN_SPEED :: f32(0.02)
// A throw may not spin faster than this (rad/s), however hard the flick.
CAMERA_SPIN_MAX_SPEED :: f32(3)
CAMERA_BUILDING_FOCUS_DISTANCE :: f32(18)
CAMERA_MIN_DISTANCE :: f32(6)
CAMERA_SURFACE_MAX_DISTANCE :: f32(320)
PLANET_SURFACE_ZOOM :: CAMERA_SURFACE_MAX_DISTANCE
CAMERA_MAX_DISTANCE :: f32(4 * shared.PLANET_RADIUS)
CAMERA_NEAR_PLANE :: f32(0.5)
CAMERA_FAR_PLANE :: f32(18000)
// Keyboard pan speed: target moves pan_speed * distance per second, giving a
// constant screen-space feel at any zoom level.
CAMERA_PAN_SPEED :: f32(1.2)
// Space/Shift elevation speed, scaled by orbit distance for the same reason
// CAMERA_PAN_SPEED is: a lift reads at the same screen speed at any zoom.
CAMERA_ELEVATE_SPEED :: f32(0.8)
// How fast the orbit pivot eases onto the surface under it, as an exponential
// rate per second. Fast enough to track a pan across a ridge within a few
// frames, slow enough that the height change cannot drive the grab-pan that
// caused it; see camera_pivot_follow.
CAMERA_SEAT_FOLLOW_RATE :: f32(8)
// Band the orbit target's height is held within. The ceiling is on the order
// of CAMERA_MAX_DISTANCE so the eye stays inside the decoration streaming
// window and flora does not pop in below it; the floor sits under the sea
// bed, with camera_clamp_above_terrain still holding the eye above ground.
CAMERA_MIN_ELEVATION :: f32(-32)
CAMERA_MAX_ELEVATION :: f32(240)
// A pointer gesture stays a click until its displacement from the press point
// crosses this UI-scaled radius, then camera pan owns it permanently.
CLICK_SELECT_MAX_DRAG :: f32(4)
ENTITY_TERRAIN_HIT_TOLERANCE :: f32(1)
// Seconds between terraform steps while the left button is held. The press
// seeds a full interval so a click applies exactly one step immediately;
// holding repeats at this cadence.
TERRAFORM_HOLD_INTERVAL :: f32(1.0 / 12.0)
// The sim runs at 4 Hz; never replay more than this many ticks in one frame
// so a long hitch degrades gracefully instead of spiralling.
MAX_TICKS_PER_FRAME :: 1
FLORA_DEBUG_STEPS_PER_FRAME_MAX :: 1
MAX_DRAW_INSTANCES :: int(shared.MAX_BUILDINGS)
MAX_ENTITY_QUERIES :: int(shared.MAX_ENTITIES)
PLANET_TOOLS_ENABLED :: false
// Per-frame budget for incremental world building on the loading screen;
// large enough to make solid progress, small enough to keep it animating.
LOADING_STEP_BUDGET :: 12 * time.Millisecond
// The chunk phase is different work: create_gpu_mesh + LOD simplify + Box3D
// BVH build on the main thread while 12 workers sit on finished chunks. A
// 12 ms slice uploaded roughly one chunk per frame, so 400 chunks cost ~400
// frames of the load. The loading screen only animates a gauge and an
// ellipsis, so ~25 fps there is free.
LOADING_BUILD_BUDGET :: 40 * time.Millisecond
// Square offscreen resolution for the inspect panel's building portrait.
PORTRAIT_RESOLUTION :: i32(256)
BALANCE_RESOLUTION :: i32(640)
// Screen-space HUD text inset from the window corners, and the gap between
// the status line and the controls line. Authored at UI scale 1.0.
HUD_MARGIN :: i32(18)
HUD_LINE_GAP :: i32(10)
// Gap between adjacent label/value readouts on the HUD's instrument row.
HUD_READOUT_GAP :: i32(14)

WORLD_LIGHT :: rl.Gpu_3D_Light {
	direction = {-0.42, 0.54, 0.73},
	ambient   = 0.16,
	diffuse   = 0.62,
}

// Building accents, the selection outline, and every other paint value in
// this client live in theme.odin so one palette governs the whole UI.
SELECTED_OUTLINE_COLOR :: UI_SELECTED_OUTLINE
// Subtle scale pulse amplitude for the outer selection frame.
SELECTED_OUTLINE_PULSE :: f32(0.03)

LOCAL_PLAYER :: u32(0)

// Mode is the in-game interaction mode; Inspect (select/pan only) is the
// zero-value default. Keys 1-4 enter Build, T toggles Terraform, Escape
// returns to Inspect; the toolbar tabs mirror the same transitions.
Mode :: enum u8 {
	Inspect,
	Build,
	Terraform,
}

MODE_NAMES :: [Mode]cstring {
	.Inspect   = "inspect",
	.Build     = "build",
	.Terraform = "terraform",
}

Client_State :: struct {
	screen:                     Screen,
	world:                      shared.World,
	tick:                       u64,
	accumulator:                f64,
	flora_time_scale:           u32,
	flora_time_accumulator:     f64,
	flora_step_requested:       bool,
	flora_inoculate_requested:  bool,
	flora_sterilize_requested:  bool,
	flora_lineage_debug:        Flora_Lineage_Debug_State,
	selected_kind:              shared.Building_Kind,
	// selected is the click-selected building entity; ENTITY_NIL when none.
	selected:                   ecs.Entity,
	mode:                       Mode,
	terraform_tool:             Terraform_Tool,
	// terraform_radius is the selected brush's cell radius (0 = 1x1 through
	// TERRAFORM_RADIUS_MAX = 9x9). It survives mode changes so returning to
	// terraform keeps the brush the player last chose, exactly as
	// selected_kind survives for build mode.
	terraform_radius:           i32,
	// ui_pointer_captured is true while the pointer is over the toolbar, so
	// world hover/selection/sculpt/camera never react to toolbar clicks.
	ui_pointer_captured:        bool,
	// ui_scale mirrors the frame's UI scale (1.0 on macOS/web, the monitor
	// DPI factor on Windows) so layout code that never sees a surface can
	// still convert its scale-1.0 constants through ui_px.
	ui_scale:                   f32,
	// toolbar_note_width is last frame's measured inspect-note width; the
	// toolbar sizes its note segment from it instead of guessing a pixel
	// width that only fits at scale 1.0. One frame stale on the frame the
	// selection changes, which moves the panel edge by a few pixels.
	toolbar_note_width:         i32,
	// header_shown latches the auto-hiding Windows title strip so it does
	// not strobe while the pointer sits on the reveal boundary.
	header_shown:               bool,
	hover_valid:                bool,
	hover_face:                 procgen.Terrain_Face_V4,
	hover_x:                    i32,
	hover_y:                    i32,
	// place_x/place_y is the armed footprint's min-corner anchor, derived
	// from the hover so the footprint stays centered under the cursor. Only
	// meaningful while hover_valid in build mode.
	place_x:                    i32,
	place_y:                    i32,
	hover_point:                [3]f32,
	// hover_entity is the building under the cursor (ENTITY_NIL when none),
	// resolved once per frame; hover_entity_seconds is the dwell time on it.
	hover_entity:               ecs.Entity,
	hover_entity_seconds:       f32,
	grab_pan:                   rl.Orbit_Camera_Grab_Pan,
	// globe_spin is the residual angular velocity of a released globe drag:
	// the pivot radial keeps rotating around axis at speed, decaying to rest.
	globe_spin:                 Globe_Spin,
	// Click-vs-drag disambiguation for left-button select.
	press_active:               bool,
	press_position:             rl.Vector2,
	press_drag:                 f32,
	// Hold-to-sculpt terraforming: while the left button is held the brush
	// follows the hovered cell and sculpt_accum accumulates frame time,
	// draining one command per TERRAFORM_HOLD_INTERVAL.
	sculpt_active:              bool,
	sculpt_face:                procgen.Terrain_Face_V4,
	sculpt_x:                   i32,
	sculpt_y:                   i32,
	sculpt_accum:               f32,
	sculpt_direction:           i8,
	status:                     cstring,
	// Entities that had a Construction before the tick, used to detect
	// completions for the cosmetic debris burst.
	pending:                    [shared.MAX_BUILDINGS]ecs.Entity,
	pending_count:              u32,
	draw_transforms:            [MAX_DRAW_INSTANCES]rl.Matrix,
	cosmetics:                  Cosmetics,
	surfboard:                  Surfboard,
	balance:                    Balance_Minigame,
	queries:                    Entity_Queries,
	highlight:                  Highlight,
	selection_frame:            Selection_Frame,
	sockets:                    Sockets,
	cursor:                     Cursor_State,
	terrain:                    Terrain,
	wind_visual:                Wind_Visual,
	flora:                      Flora,
	ruins:                      Ruins,
	structures:                 Structure_Assets,
	fauna:                      Fauna_Assets,
	atmosphere:                 Atmosphere,
	visual_weather:             Visual_Weather,
	target:                     rl.Gpu_3D_Target,
	opaque_scene_target:        rl.Gpu_3D_Target,
	water_scene_capture:        bool,
	// portrait_target holds the inspect panel's live 3D building portrait.
	portrait_target:            rl.Gpu_3D_Target,
	balance_target:             rl.Gpu_3D_Target,
	cube:                       rl.Gpu_Mesh,
	cube_edges:                 rl.Gpu_Mesh,
	sphere:                     rl.Gpu_Mesh,
	cylinder:                   rl.Gpu_Mesh,
	cone:                       rl.Gpu_Mesh,
	wedge:                      rl.Gpu_Mesh,
	camera:                     rl.Camera3D,
	camera_visual:              Camera_Visual_Context,
	orbit:                      rl.Orbit_Camera_State,
	orbit_config:               rl.Orbit_Camera_Config,
	orbit_bindings:             rl.Orbit_Camera_Bindings,
	camera_frame_east:          [3]f32,
	// camera_height_offset is the Space/Shift lift above the surface under
	// the orbit pivot. The pivot is seated on that surface every frame, so
	// this offset is the only thing that lifts it off the ground and the
	// seating survives panning across any relief.
	camera_height_offset:       f32,
	graphics_ready:             bool,
	world_ready:                bool,
	// world_load tracks the background sim-world build during loading.
	world_load:                 World_Load,
	// planetary_prepare runs the next tick's planetary stage ahead of time
	// on a worker; see client/planetary_prepare_async.odin.
	planetary_prepare:          Planetary_Prepare,
	// node_seats caches the probed surface seat of every drawn node.
	node_seats:                 Node_Seat_Cache,
	regenerate_pending:         bool,
	regenerate_loading:         bool,
	regenerate_seed:            u64,
	resize_failures:            u64,
	console:                    Console,
	// debug is the developer debug panel; see forgecore client/debug_panel.odin.
	debug:                      Debug_Panel,
	debug_pinned:               Debug_Panel,
	lithosphere_debug:          bool,
	lithosphere_debug_revision: u64,
	ocean_visual:               Ocean_Visual_Settings,
	sim_proof_settings:         Sim_Proof_Settings,
	sim_proof_revision:         u64,
	// pause is the in-world Escape menu; see client/pause_menu.odin.
	pause:                      Pause_Menu,
	// quit_requested is raised by the pause menu's exit confirmation and
	// read by the host through the game_should_quit export. The library
	// cannot end the session itself: the host owns the frame loop.
	quit_requested:             bool,
	// HUD visibility toggles, controlled from the console ("set hud/fps ...").
	show_hud_text:              bool,
	show_fps:                   bool,
	planet_cutaway:             bool,
	// profiler samples the per-frame phase timeline; see client/profile.odin.
	profiler:                   Profiler,
	performance:                Performance_State,
	profile_scenario:           Profile_Scenario,
	opaque_draw_mask:           u32,
	// telemetry forwards profiler output to aesir; see client/telemetry.odin.
	telemetry:                  Telemetry,
	// was_focused tracks window focus across frames so focus loss can cancel
	// held inputs; see focus_update.
	was_focused:                bool,
}

// _world_build constructs the local embedded sim into world: foundation,
// one player, and a few ore nodes. Pure sim-side work with no Client_State
// access, so the loading screen can run it on a worker thread.
// The server milestone replaces this with snapshot replication over ingot:net.
_world_build :: proc(world: ^shared.World, seed: u64) -> bool {
	assert(world != nil, "_world_build: nil world")
	// Always log the seed-bake wall time: it is the dominant load cost, and
	// a number in the log turns "loading feels slower" into a measurement.
	bake_start := time.tick_now()
	if !shared.world_init_seed(world, seed) do return false
	fmt.eprintfln(
		"[planetforger] world seed bake: %.0f ms (seed=%d)",
		time.duration_milliseconds(time.tick_since(bake_start)),
		seed,
	)
	_, ok_player := shared.spawn_player(world, LOCAL_PLAYER)
	if !ok_player {
		shared.world_deinit(world)
		return false
	}
	node_count, node_ok := shared.world_populate_nodes(world)
	if !node_ok {
		shared.world_deinit(world)
		return false
	}
	gazelle_count, gazelle_ok := shared.world_populate_gazelles(world)
	if !gazelle_ok {
		shared.world_deinit(world)
		return false
	}
	assert(node_count > 0, "_world_build: seed produced no resource nodes")
	fmt.eprintfln(
		"[planetforger] population: nodes=%d gazelles=%d flora_cells=%d lineages=%d",
		node_count,
		gazelle_count,
		world.flora_ecology.diagnostics.occupied_cells,
		world.flora_ecology.lineage_count,
	)
	// Tick zero satisfies every cadence, including the geology bundle and
	// the first waterfield settle: tens of milliseconds that used to land in
	// the first gameplay frame. Run it here, on the loader thread, and start
	// gameplay at tick WORLD_PREROLL_TICKS. The state sequence is unchanged
	// (tick 0 then tick 1 ...); only the wall-clock moment tick 0 runs moves.
	preroll_start := time.tick_now()
	for tick in u64(0) ..< WORLD_PREROLL_TICKS do shared.sim_tick(world, tick)
	fmt.eprintfln(
		"[planetforger] world preroll: %d tick(s) in %.0f ms",
		WORLD_PREROLL_TICKS,
		time.duration_milliseconds(time.tick_since(preroll_start)),
	)
	return true
}

// WORLD_PREROLL_TICKS is the number of authoritative ticks _world_build runs
// before the world is handed to gameplay; the client's tick counter starts
// here so the sequence of (world, tick) pairs is the same as ticking from 0.
WORLD_PREROLL_TICKS :: u64(1)

// world_finalize applies the client-side defaults once the sim world exists;
// runs on the main thread after a synchronous or background build.
world_finalize :: proc(value: ^Client_State) {
	assert(value != nil, "world_finalize: nil state")
	assert(!value.world_ready, "world_finalize: world already ready")
	// The world is adopted; clear the loader's result so shutdown never
	// double-frees after a later map_regenerate tears the world down.
	value.world_load.ok = false
	value.selected_kind = .Mine
	value.selected = ecs.ENTITY_NIL
	// The zero value of terraform_radius is a legal 1x1 brush, so the
	// default has to be set deliberately rather than inherited.
	value.terraform_radius = shared.TERRAFORM_RADIUS
	assert(ecs.set_len(&value.world.creatures) > 0, "world_finalize: missing fauna population")
	value.status = "ready"
	value.tick = WORLD_PREROLL_TICKS
	value.accumulator = 0
	value.world_ready = true
	if planetary_prepare_init(&value.planetary_prepare, &value.world) {
		planetary_prepare_begin(&value.planetary_prepare, value.tick)
	}
}

// world_create is the synchronous build used by tests and as a fallback
// when the background loader cannot start.
world_create :: proc(value: ^Client_State, seed := shared.TERRAIN_SEED) -> bool {
	assert(value != nil, "world_create: nil state")
	assert(!value.world_ready, "world_create: world already ready")
	if !_world_build(&value.world, seed) do return false
	world_finalize(value)
	return true
}

// Globe_Spin is the residual angular velocity of a released globe drag: the
// pivot radial keeps rotating around axis at speed until damping stops it.
Globe_Spin :: struct {
	axis:  [3]f32,
	speed: f32, // radians per second
}

camera_reset :: proc(value: ^Client_State) {
	assert(value != nil, "camera_reset: nil state")
	surface_direction := shared.planet_direction({.Pos_X, 384, 384})
	surface_point := surface_direction * (shared.PLANET_RADIUS + 10)
	value.camera = {
		position   = surface_point + surface_direction * CAMERA_START_DISTANCE,
		target     = surface_point,
		up         = surface_direction,
		fovy       = 42,
		projection = .PERSPECTIVE,
		near_plane = CAMERA_NEAR_PLANE,
		far_plane  = CAMERA_FAR_PLANE,
	}
	value.orbit, _ = rl.orbit_camera_from_camera(value.camera)
	value.orbit.pitch = CAMERA_START_PITCH
	value.orbit.yaw = CAMERA_START_YAW
	value.orbit.distance = CAMERA_START_DISTANCE
	_, value.camera_frame_east, _ = _camera_surface_frame(surface_direction, {})
	// The pivot is seated on the surface as soon as a terrain exists; a
	// reset only clears the player's own lift above it.
	value.camera_height_offset = 0
	value.orbit_config = rl.orbit_camera_config_default()
	value.orbit_config.min_distance = CAMERA_MIN_DISTANCE
	value.orbit_config.max_distance = CAMERA_MAX_DISTANCE
	value.orbit_config.min_pitch = CAMERA_MIN_PITCH
	value.orbit_config.max_pitch = CAMERA_MAX_PITCH
	value.orbit_config.rotate_speed = math.PI / 3
	value.orbit_config.pan_speed = CAMERA_PAN_SPEED
	value.orbit_bindings = rl.Orbit_Camera_Bindings {
		rotate_left = {primary = .Q},
		rotate_right = {primary = .E},
		drag_button = .LEFT,
		drag_modifier = {primary = .LEFT_ALT, secondary = .RIGHT_ALT},
		pan_button = {button = .LEFT, bound = true},
		pointer_drag_scale = {-1, -1},
	}
}

graphics_create :: proc(value: ^Client_State) -> bool {
	assert(value != nil, "graphics_create: nil state")
	assert(!value.graphics_ready, "graphics_create: graphics already ready")
	if value.atmosphere.sun_intensity <= 0 {
		value.atmosphere = atmosphere_preset(.Orbital_Day, atmosphere_default_quality())
	}
	camera_reset(value)
	antialiasing := rl.Gpu_3D_Antialiasing.MSAA_4X
	when ODIN_OS == .JS do antialiasing = .None
	// Every resource is created at most once: the terrain below is built
	// incrementally across loading frames, so this proc runs many times per
	// load and must not churn targets or mesh-pool slots on each call.
	target_ok, opaque_ok, portrait_ok, balance_ok, cube_ok, edges_ok: bool
	sphere_ok, cylinder_ok, cone_ok, wedge_ok: bool
	if _, _, target_alive := rl.gpu_3d_target_size(&value.target); target_alive {
		target_ok = true
	} else {
		value.target, target_ok = rl.create_gpu_3d_target(
			rl.GetRenderWidth(),
			rl.GetRenderHeight(),
			.None,
		)
	}
	if _, _, opaque_alive := rl.gpu_3d_target_size(&value.opaque_scene_target); opaque_alive {
		opaque_ok = true
	} else {
		value.opaque_scene_target, opaque_ok = rl.create_gpu_3d_target(
			rl.GetRenderWidth(),
			rl.GetRenderHeight(),
			.None,
		)
	}
	value.water_scene_capture = target_ok && opaque_ok
	if _, _, portrait_alive := rl.gpu_3d_target_size(&value.portrait_target); portrait_alive {
		portrait_ok = true
	} else {
		value.portrait_target, portrait_ok = rl.create_gpu_3d_target(
			PORTRAIT_RESOLUTION,
			PORTRAIT_RESOLUTION,
			antialiasing,
		)
	}
	if _, _, balance_alive := rl.gpu_3d_target_size(&value.balance_target); balance_alive {
		balance_ok = true
	} else {
		value.balance_target, balance_ok = rl.create_gpu_3d_target(
			BALANCE_RESOLUTION,
			BALANCE_RESOLUTION,
			antialiasing,
		)
	}
	cube_ok = value.cube.id != 0
	if !cube_ok do value.cube, cube_ok = rl.create_cube_mesh()
	edges_ok = value.cube_edges.id != 0
	if !edges_ok do value.cube_edges, edges_ok = rl.create_cube_edge_mesh()
	sphere_ok = value.sphere.id != 0
	if !sphere_ok do value.sphere, sphere_ok = rl.create_sphere_mesh(0.5, 16, 32)
	cylinder_ok = value.cylinder.id != 0
	if !cylinder_ok do value.cylinder, cylinder_ok = _cylinder_mesh_create()
	cone_ok = value.cone.id != 0
	if !cone_ok do value.cone, cone_ok = _cone_mesh_create()
	wedge_ok = value.wedge.id != 0
	if !wedge_ok do value.wedge, wedge_ok = _wedge_mesh_create()
	highlight_ok := highlight_init(value)
	selection_frame_ok := selection_frame_init(&value.selection_frame)
	debug_marker_ok := debug_marker_init(&value.debug)
	debug_pinned_marker_ok := debug_marker_init(&value.debug_pinned)
	// graphics_create retries every frame until the GPU context is up, so the
	// non-GPU cosmetics world and the terrain meshes must only init once.
	cosmetics_ok := value.cosmetics.ready
	if !cosmetics_ok do cosmetics_ok = cosmetics_init(&value.cosmetics)
	terrain_ok := _terrain_build_advance(value, cosmetics_ok)
	if terrain_ok && !value.wind_visual.ready && !wind_visual_init(&value.wind_visual) {
		value.sim_proof_settings.proof = .None
	}
	structures_ok := structure_assets_init(&value.structures)
	fauna_ok := fauna_assets_init(&value.fauna)
	ruins_ok := value.ruins.ready
	if !ruins_ok && terrain_ok && structures_ok {
		focus := [2]f32{value.orbit.target.x, value.orbit.target.y}
		ruins_ok = ruins_generate(&value.ruins, &value.terrain, &value.world, focus)
	}
	flora_ok := value.flora.ready
	if !flora_ok && terrain_ok {
		flora_ok = flora_init(
			&value.flora,
			&value.terrain,
			&value.world,
			&value.ruins,
			value.orbit.target,
		)
	}
	atmosphere_ok := atmosphere_init(&value.atmosphere)
	value.graphics_ready =
		target_ok &&
		opaque_ok &&
		portrait_ok &&
		balance_ok &&
		cube_ok &&
		edges_ok &&
		sphere_ok &&
		cylinder_ok &&
		cone_ok &&
		wedge_ok &&
		highlight_ok &&
		selection_frame_ok &&
		debug_marker_ok &&
		debug_pinned_marker_ok &&
		cosmetics_ok &&
		terrain_ok &&
		flora_ok &&
		ruins_ok &&
		structures_ok &&
		fauna_ok &&
		atmosphere_ok
	if !value.graphics_ready {
		// Loading retries this every frame; report which subsystem blocks so
		// a persistent failure is diagnosable instead of an endless spinner.
		mask: u32 = 0
		flags := [?]bool {
			target_ok,
			portrait_ok,
			balance_ok,
			cube_ok,
			edges_ok,
			sphere_ok,
			cylinder_ok,
			cone_ok,
			wedge_ok,
			highlight_ok,
			selection_frame_ok,
			debug_marker_ok,
			debug_pinned_marker_ok,
			cosmetics_ok,
			terrain_ok,
			flora_ok,
			ruins_ok,
			structures_ok,
			fauna_ok,
			atmosphere_ok,
		}
		names := [?]string {
			"target",
			"portrait",
			"balance",
			"cube",
			"edges",
			"sphere",
			"cylinder",
			"cone",
			"wedge",
			"highlight",
			"selection-frame",
			"debug-marker",
			"debug-pinned-marker",
			"cosmetics",
			"terrain",
			"flora",
			"ruins",
			"structures",
			"fauna",
			"atmosphere",
		}
		for flag, index in flags do if !flag do mask |= 1 << u32(index)
		@(static) last_failure_mask: u32
		if mask != last_failure_mask {
			last_failure_mask = mask
			fmt.eprint("[planetforger] graphics init blocked by:")
			for flag, index in flags do if !flag do fmt.eprint(" ", names[index])
			fmt.eprintln()
		}
	}
	if value.graphics_ready do _pipelines_warm(value)
	return value.graphics_ready
}

// _pipelines_warm compiles every material-style/primitive pipeline combination
// the game uses by drawing each once into the offscreen portrait target. The
// gfx layer builds pipelines lazily on first draw, which otherwise stalls the
// frame the first time a combination appears (e.g. the blended line frame on
// first build-mode entry). The portrait target shares the world target's
// format and sample count, so the warmed pipelines match the cache keys used
// by the world pass; its junk content is overwritten before it is sampled.
_pipelines_warm :: proc(value: ^Client_State) {
	assert(value != nil, "_pipelines_warm: nil state")
	camera := rl.Camera3D {
		position   = {0, -3, 0},
		target     = {0, 0, 0},
		up         = rl.CAMERA_WORLD_UP,
		fovy       = 45,
		projection = .PERSPECTIVE,
		near_plane = 0.1,
		far_plane  = 100,
	}
	pass, ok := rl.begin_gpu_3d(&value.portrait_target, camera)
	if !ok do return
	rl.set_gpu_3d_light(&pass, WORLD_LIGHT)
	// Triangles / Opaque: buildings, nodes, terrain props.
	rl.draw_gpu_mesh(&pass, value.cube, rl.Matrix(1), {color = rl.WHITE, style = .Opaque})
	// Triangles / Default blend with scalar mix: the placement highlight grid.
	rl.draw_gpu_mesh(
		&pass,
		value.cube,
		rl.Matrix(1),
		{color = {255, 255, 255, 128}, color_high = rl.WHITE, use_scalar = true},
	)
	// Lines / Opaque_Outline: building and cosmetic edge frames.
	rl.draw_gpu_mesh(
		&pass,
		value.cube_edges,
		rl.Matrix(1),
		{color = rl.WHITE, style = .Opaque_Outline},
	)
	// Lines / Default blend: the footprint frame drawn in build/terraform
	// modes — the previously cold pipeline behind the first-entry hitch.
	rl.draw_gpu_mesh(&pass, value.cube_edges, rl.Matrix(1), {color = rl.RAYWHITE})
	if value.wind_visual.ready {
		wind_visual_layer_draw(
			&value.wind_visual,
			&pass,
			&value.wind_visual.close,
			0.001,
			value.sim_proof_settings,
		)
	}
	rl.end_gpu_3d(&pass)
}

game_prepare_frame :: proc(value: ^Client_State) {
	assert(value != nil, "game_prepare_frame: nil state")
	if !value.world_ready || len(value.terrain.ocean.rings[0].vertices) == 0 do return
	start := time.tick_now()
	frame_elapsed := f32(time.duration_seconds(time.tick_since(value.performance.frame_started)))
	ocean_spectral_prepare(
		&value.terrain.ocean,
		value.world.foundation.seed,
		performance_optional_budget_available(&value.performance, frame_elapsed),
	)
	profile_external(&value.profiler, .Spectral_Prepare, time.tick_since(start))
}

map_resources_init :: proc(value: ^Client_State) -> bool {
	assert(value != nil, "map_resources_init: nil state")
	cosmetics_ok := value.cosmetics.ready
	if !cosmetics_ok do cosmetics_ok = cosmetics_init(&value.cosmetics)
	terrain_ok := _terrain_build_advance(value, cosmetics_ok)
	if terrain_ok && !value.wind_visual.ready && !wind_visual_init(&value.wind_visual) {
		value.sim_proof_settings.proof = .None
	}
	ruins_ok := value.ruins.ready
	focus := [2]f32{value.orbit.target.x, value.orbit.target.y}
	if !ruins_ok && terrain_ok {
		ruins_ok = ruins_generate(&value.ruins, &value.terrain, &value.world, focus)
	}
	flora_ok := value.flora.ready
	if !flora_ok && terrain_ok {
		flora_ok = flora_init(
			&value.flora,
			&value.terrain,
			&value.world,
			&value.ruins,
			value.orbit.target,
		)
	}
	return cosmetics_ok && terrain_ok && ruins_ok && flora_ok
}

// _terrain_build_advance drives the incremental terrain build one budgeted
// step per call; it returns true once the terrain is fully ready.
_terrain_build_advance :: proc(value: ^Client_State, cosmetics_ok: bool) -> bool {
	if value.terrain.ready do return true
	if !cosmetics_ok do return false
	if !value.terrain.build_active {
		if !terrain_init_begin(&value.terrain, &value.world, value.cosmetics.world) do return false
	}
	_ = terrain_init_step(&value.terrain, &value.world, LOADING_BUILD_BUDGET)
	return value.terrain.ready
}

// _loading_fail reports a failed world build and returns to the menu.
_loading_fail :: proc(value: ^Client_State) {
	assert(value != nil, "_loading_fail: nil state")
	value.status = "world creation failed"
	console_print(value.console.terminal, "[planetforger] map regeneration failed")
	value.regenerate_loading = false
	value.screen = .Menu
}

loading_update :: proc(value: ^Client_State) {
	assert(value != nil, "loading_update: nil state")
	assert(value.screen == .Loading_Graphics, "loading_update: wrong screen")
	if !value.world_ready {
		// The multi-second foundation bake runs on a worker thread; the
		// loading screen polls it each frame so the window never freezes.
		if !world_load_active(&value.world_load) {
			profile_loading_publish()
			seed := value.regenerate_seed if value.regenerate_loading else profile_scenario_seed(shared.TERRAIN_SEED)
			if world_load_begin(&value.world_load, &value.world, seed) do return
			// Worker creation failed: build synchronously as a fallback.
			if !world_create(value, seed) {
				_loading_fail(value)
			}
			return
		}
		finished, ok := world_load_poll(&value.world_load)
		if !finished do return
		if !ok {
			_loading_fail(value)
			return
		}
		world_finalize(value)
	}
	if !value.graphics_ready {
		if !graphics_create(value) do return
	} else if !map_resources_init(value) {
		return
	}
	// Drive the one-time climate/albedo bake to completion before gameplay:
	// terrain_update advances it a bounded slice per call, so loop it under
	// the loading budget and stay on the loading screen while rows remain.
	// Entering Playing mid-bake forced 30-50ms frames and a laggy camera.
	bake_start := time.tick_now()
	for {
		terrain_update(&value.terrain, &value.world)
		if !terrain_material_bake_pending(&value.terrain) do break
		if time.tick_since(bake_start) >= LOADING_STEP_BUDGET do return
	}
	if !terrain_albedo_ready(&value.terrain) do return
	if rl.resize_gpu_3d_target_to_render_size(&value.target) == .Failed ||
	   rl.resize_gpu_3d_target_to_render_size(&value.opaque_scene_target) == .Failed {
		value.resize_failures += 1
		return
	}
	// The map is ready: seat the camera on its surface before the first
	// frame is drawn, so a regenerated world never appears with the pivot
	// buried in the ground (or under the sea) the previous camera_reset
	// knew nothing about.
	camera_apply_seated(value, 0)
	weather_refresh(value)
	ocean_renderer_update(
		&value.terrain.ocean,
		&value.world,
		value.camera,
		value.orbit.target,
		value.tick,
		value.ocean_visual,
		0,
		false,
	)
	wind_visual_update(
		&value.wind_visual,
		&value.world,
		&value.terrain,
		value.orbit.target,
		value.tick,
		value.sim_proof_settings,
		value.sim_proof_revision,
	)
	if draw_world(value) {
		value.screen = .Playing
		if value.regenerate_loading {
			seed := value.world.foundation.seed
			biome := shared.terrain_sample(&value.world, 0, 0).primary_biome
			console_print(
				value.console.terminal,
				fmt.tprintf("[planetforger] map ready seed=%d biome=%v", seed, biome),
			)
			value.regenerate_loading = false
		}
	}
}

performance_world_targets_resize :: proc(value: ^Client_State) -> bool {
	assert(value != nil, "performance_world_targets_resize: nil state")
	width, height := performance_render_size(
		rl.GetRenderWidth(),
		rl.GetRenderHeight(),
		value.performance.render_scale,
	)
	if width <= 0 || height <= 0 do return true
	target_width, target_height, target_ok := rl.gpu_3d_target_size(&value.target)
	opaque_width, opaque_height, opaque_ok := rl.gpu_3d_target_size(&value.opaque_scene_target)
	if !target_ok || !opaque_ok do return false
	if target_width != width || target_height != height {
		if !rl.resize_gpu_3d_target(&value.target, width, height) do return false
	}
	if opaque_width != width || opaque_height != height {
		if !rl.resize_gpu_3d_target(&value.opaque_scene_target, width, height) do return false
	}
	return true
}

focus_update :: proc(value: ^Client_State) {
	assert(value != nil, "focus_update: nil state")
	focused := rl.IsWindowFocused()
	defer value.was_focused = focused
	if value.was_focused && !focused {
		value.grab_pan.active = false
		value.debug.interaction = .None
		value.debug.pin_armed = false
		value.press_active = false
		value.press_drag = 0
		value.sculpt_active = false
		value.sculpt_accum = 0
		value.sculpt_direction = 0
	}
}

game_frame :: proc(value: ^Client_State, surface: ^fit.Surface) {
	assert(value != nil, "game_frame: nil state")
	assert(surface != nil, "game_frame: nil surface")
	assert(value.world_ready, "game_frame: world not ready")
	refresh := fit.Surface_Monitor_Refresh(surface)
	if value.performance.target_seconds <= 0 {
		value.performance = performance_init(refresh)
	} else {
		_ = performance_sync_refresh(&value.performance, refresh)
	}
	value.performance.frame_started = time.tick_now()
	profile_scenario_frame(value)
	focus_update(value)
	profile_scenario_publish(value)
	// Registered before profile_frame_end so it runs after it: deferred calls
	// unwind last-registered-first, and the window must be closed before it is
	// summarised. Both cover every early return below.
	value.opaque_draw_mask = 0
	defer {
		opaque_mode := u32(0)
		when PROFILE_ENABLED && rl.RENDER_STATS_ENABLED {
			opaque_mode = 2 if profile_opaque_split() else 1
		}
		telemetry_publish(
			&value.telemetry, &value.profiler, &value.performance, rl.GetTime(), &value.target,
			opaque_mode, value.opaque_draw_mask,
		)
	}
	profile_frame_begin(&value.profiler)
	defer profile_frame_end(&value.profiler)
	viewport := fit.Viewport(surface)
	fit.Fill_Rect(surface, viewport, fit.Get_Theme_Tokens(surface).background_color)
	if !value.graphics_ready {
		if !graphics_create(value) do return
	}
	frame_dt := clamp(rl.GetFrameTime(), 0, MAX_FRAME_DT)
	_ = performance_frame_record(&value.performance, frame_dt)
	gpu := rl.renderer_gpu_frame_timing()
	if performance_gpu_record(&value.performance, gpu.frame_index, gpu.seconds, gpu.valid) {
		if !performance_world_targets_resize(value) do value.resize_failures += 1
	}
	profile_phase(&value.profiler, .Console)
	console_update(value, surface)
	if value.regenerate_pending {
		map_regenerate(value)
		return
	}
	// Escape is resolved before any world system runs, so the frame that
	// opens the menu is already a paused frame rather than one last tick of
	// gameplay. The minigame owns Escape while it is up (it cancels the
	// tuning), and the open console owns the whole keyboard.
	debug_panel_update(value, surface, frame_dt)
	debug_pinned_panel_update(value, surface, frame_dt)
	if !value.balance.active && !value.console.open && !debug_panel_keyboard_captured(value) {
		pause_menu_input(value)
	}
	// Pointer capture is computed once, before any world system runs, so the
	// window strip, toolbar and inspect panel swallow hover, selection,
	// sculpt, and camera drag/zoom. The pause menu captures the whole
	// viewport: a click on its scrim must not place a building underneath.
	mouse := rl.GetMousePosition()
	value.ui_pointer_captured =
		value.pause.open ||
		header_contains(value, surface, mouse) ||
		(PLANET_TOOLS_ENABLED && toolbar_contains(value, mouse)) ||
		inspect_panel_contains(value, mouse) ||
		debug_panel_contains(value, mouse) ||
		debug_pinned_panel_contains(value, mouse)
	world_pointer_gesture_update(value, mouse)
	// The open console owns the keyboard and the pointer stays on the panel,
	// so gameplay input, camera motion, and the custom cursor pause.
	if value.balance.active && !value.terrain.ocean.nearshore.fixture_active {
		balance_frame(value, frame_dt)
	} else if !value.console.open && !value.pause.open && !debug_panel_keyboard_captured(value) {
		profile_phase(&value.profiler, .Camera)
		if !value.profile_scenario.active do camera_update(value, frame_dt)
		profile_phase(&value.profiler, .Entity_Queries)
		entity_queries_sync(value)
		profile_phase(&value.profiler, .Hover)
		hover_update(value)
		profile_phase(&value.profiler, .Input)
		if !value.profile_scenario.active do input_update(value)
	}
	// A real pause: the fixed-step accumulator never advances, so no tick is
	// owed when the player resumes. Streaming, terrain updates and rendering
	// below keep running, which is what makes the world look held rather
	// than frozen mid-draw.
	profile_phase(&value.profiler, .Sim)
	if !value.pause.open do sim_update(value, frame_dt)
	weather_sync_sun_direction(value)
	profile_phase(&value.profiler, .Terrain_Update)
	// sculpt_active is cleared on release, mode change, and focus loss, so
	// the preview fast path exactly brackets the hold.
	value.terrain.preview = value.sculpt_active
	value.terrain.lithosphere_debug = value.lithosphere_debug
	value.terrain.lithosphere_debug_revision = value.lithosphere_debug_revision
	value.terrain.cutaway = value.planet_cutaway
	terrain_update(&value.terrain, &value.world)
	if value.terrain.ocean.weather_tick != value.tick &&
	   value.tick % shared.PLANET_WAVE_CADENCE_TICKS == 0 {
		weather_ocean_cache_update(&value.terrain.ocean.weather, &value.world)
	}
	profile_phase(&value.profiler, .Ocean_Update)
	surf_control: [2]f32
	if value.terrain.ocean.nearshore.fixture_active && !value.pause.open && !value.console.open && !value.balance.active && !debug_panel_keyboard_captured(value) {
		if rl.IsKeyDown(.UP) do surf_control.x += 1
		if rl.IsKeyDown(.DOWN) do surf_control.x -= 1
		if rl.IsKeyDown(.LEFT) do surf_control.y += 1
		if rl.IsKeyDown(.RIGHT) do surf_control.y -= 1
	}
	if value.terrain.ocean.nearshore.fixture_active {
		_ = ocean_surf_control_submit(&value.terrain.ocean, surf_control)
	} else {
		value.surfboard.control = {}
	}
	if value.terrain.ocean.nearshore.fixture_active && !value.pause.open {
		_ = ocean_surf_advance(&value.terrain.ocean, &value.world, value.terrain.ocean.nearshore.focus, frame_dt, value)
	}
	ocean_renderer_update(
		&value.terrain.ocean,
		&value.world,
		value.camera,
		value.orbit.target,
		value.tick,
		value.ocean_visual,
		frame_dt,
		!value.pause.open,
		performance_optional_budget_now(&value.performance),
	)
	clipmap := ocean_clipmap_metrics_take(&value.terrain.ocean)
	profile_clipmap_record(
		&value.profiler,
		clipmap.anchor_changes,
		clipmap.generations_started,
		clipmap.generations_published,
		clipmap.rings_filled,
		clipmap.rows_filled,
		clipmap.vertices_filled,
		clipmap.gpu_uploads,
	)
	profile_phase(&value.profiler, .Wind_Update)
	wind_visual_update(
		&value.wind_visual,
		&value.world,
		&value.terrain,
		value.orbit.target,
		value.tick,
		value.sim_proof_settings,
		value.sim_proof_revision,
		performance_optional_budget_now(&value.performance),
	)
	// Ruins still lay out on a flat plane and stay disabled until their own
	// spherical port; flora streams on the sphere through the seam procs in
	// flora_seam.odin. Residency stays current in orbit so returning to the
	// surface cannot expose an empty or stale stream window.
	profile_phase(&value.profiler, .Flora_Stream)
	flora_stream_update(
		&value.flora,
		&value.terrain,
		&value.world,
		&value.ruins,
		value.orbit.target,
	)
	profile_phase(&value.profiler, .Flora_Update)
	flora_update(&value.flora, &value.terrain)
	profile_phase(&value.profiler, .Cosmetics)
	if !value.pause.open && !value.terrain.ocean.nearshore.fixture_active && frame_dt > 0 {
		surfboard_update_control(value, frame_dt)
		cosmetics_update(&value.cosmetics, value, frame_dt)
	}
	profile_phase(&value.profiler, .Highlight)
	highlight_update(value)
	profile_phase(&value.profiler, .Cursor)
	if !value.console.open && !value.pause.open do cursor_update(value, frame_dt)
	if !performance_world_targets_resize(value) do value.resize_failures += 1
	profile_phase(&value.profiler, .Draw_World)
	draw_world(value)
	if value.balance.active do draw_balance_world(value)
	// The portrait needs its own 3D pass, so it renders after the world pass
	// ends and before the screen-space panel samples its target.
	profile_phase(&value.profiler, .Portrait)
	if inspect_panel_visible(value) do inspect_panel_portrait_render(value)
	profile_phase(&value.profiler, .Draw_Screen)
	draw_screen(value, surface)
}

camera_update :: proc(value: ^Client_State, frame_dt: f32) {
	assert(value != nil, "camera_update: nil state")
	assert(value.orbit.distance > 0, "camera_update: invalid orbit distance")
	input := rl.orbit_camera_input_poll(value.orbit_bindings)
	// Terraform mode claims the left button for sculpting, overriding both
	// the Alt-gated rotate and the grab-pan intents.
	if value.mode == .Terraform do input.pointer_drag = {}
	// Shift+wheel resizes the brush instead of zooming. The scroll channel
	// is cleared when it does, so one notch cannot both resize and zoom.
	brush_resized := terraform_brush_wheel(value)
	if brush_resized do input.scroll = 0
	if value.ui_pointer_captured {
		input.pointer_drag = {}
		input.scroll = 0
	}
	// Scroll zooms straight in and out at the current pivot; the channel is
	// consumed so the library's additive fixed-step zoom (2 units per notch -
	// useless across a 6..6480 range) never fires. Aiming is the globe
	// drag's job: cursor-anchored zoom cannot avoid apparent rotation while
	// the camera up is locked to the pivot radial.
	if input.scroll != 0 {
		value.orbit.distance = camera_zoom_next(value.orbit.distance, input.scroll)
		input.scroll = 0
	}
	// Left-drag spins the globe: the pivot direction rotates so the grabbed
	// surface follows the cursor. Alt+drag stays the library's orbit
	// rotate (yaw/pitch tilt), applied in the local surface frame below.
	input.pan = {}
	_camera_globe_drag(value, frame_dt)
	_camera_spin_update(value, frame_dt)
	// Space/Shift move the player's lift above the seated pivot rather than
	// the pivot itself: the pivot rides the surface under it, so a raw target
	// offset would be overwritten by the next seat. Shift is suppressed on a
	// frame that resized the brush, or one shift+wheel notch would also sink
	// the camera.
	shift_held := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
	value.camera_height_offset = camera_elevation_offset_next(
		value.camera_height_offset,
		camera_elevation_delta(
			rl.IsKeyDown(.SPACE),
			shift_held && !brush_resized,
			value.orbit.distance,
			frame_dt,
		),
	)
	rl.update_orbit_camera(&value.orbit, input, value.orbit_config, frame_dt)
	pan_intent := camera_spherical_pan_intent(
		rl.IsKeyDown(.D) || rl.IsKeyDown(.RIGHT),
		rl.IsKeyDown(.A) || rl.IsKeyDown(.LEFT),
		rl.IsKeyDown(.W) || rl.IsKeyDown(.UP),
		rl.IsKeyDown(.S) || rl.IsKeyDown(.DOWN),
	)
	value.orbit.target, value.camera_frame_east = camera_spherical_pan_next(
		value.orbit.target,
		value.camera_frame_east,
		value.orbit.yaw,
		pan_intent,
		value.orbit.distance,
		frame_dt,
	)
	camera_apply_seated(value, frame_dt)
}

// camera_zoom_next is the multiplicative zoom curve: each notch keeps a
// fixed fraction of the distance, so one notch covers the same screen-space
// step from orbit as from ground level. Pure for tests.
camera_zoom_next :: proc(distance, scroll: f32) -> f32 {
	assert(distance > 0, "camera_zoom_next: invalid distance")
	return clamp(
		distance * math.pow(CAMERA_ZOOM_STEP, scroll),
		CAMERA_MIN_DISTANCE,
		CAMERA_MAX_DISTANCE,
	)
}

// camera_apply_seated seats the orbit pivot on the planet surface along its
// current radial, then applies the orbit state in the pivot's local surface
// frame (up = radial): yaw spins around the local vertical, pitch is the
// elevation above the local horizon. The library's Z-up orbit apply would
// put the eye inside the planet everywhere except the north pole.
//
// frame_dt of zero snaps the pivot onto its seat: the loading transition has
// no previous frame to ease from and must hand gameplay a seated camera.
camera_apply_seated :: proc(value: ^Client_State, frame_dt: f32) {
	assert(value != nil, "camera_apply_seated: nil state")
	assert(frame_dt >= 0, "camera_apply_seated: negative delta time")
	assert(value.orbit.distance > 0, "camera_apply_seated: invalid orbit distance")
	radial := _camera_pivot_radial(value)
	if value.terrain.ready {
		surface_height := camera_surface_height(value, radial)
		seat_radius := shared.PLANET_RADIUS + surface_height + value.camera_height_offset
		value.orbit.target = radial * seat_radius
	} else {
		value.orbit.target = radial * (shared.PLANET_RADIUS + 10 + value.camera_height_offset)
	}
	_camera_planet_apply(value)
	value.camera_visual = planet_camera_visual_context(
		value.camera.position,
		value.camera.target,
		value.orbit.distance,
		value.camera.fovy,
		f32(max(rl.GetScreenHeight(), 1)),
	)
	value.atmosphere.overview_weight = value.camera_visual.overview_weight
}

// _camera_pivot_radial is the unit direction of the orbit pivot, falling
// back to the spawn direction while the pivot is degenerate (a zeroed
// state before the first seat).
_camera_pivot_radial :: proc(value: ^Client_State) -> [3]f32 {
	target := value.orbit.target
	length := math.sqrt(target.x * target.x + target.y * target.y + target.z * target.z)
	if length < 1 do return shared.planet_direction({.Pos_X, 384, 384})
	return target / length
}

// _camera_surface_frame is the camera's transported local frame at a radial:
// up is radial, east is the previous frame projected onto its tangent plane,
// and north completes the right-handed set. The fallback only initializes an
// empty or invalid hint; normal movement rotates the hint through both poles.
_camera_surface_frame :: proc(radial, east_hint: [3]f32) -> (up, east, north: [3]f32) {
	up_length := math.sqrt(radial.x * radial.x + radial.y * radial.y + radial.z * radial.z)
	if up_length < 0.0001 do up = shared.planet_direction({.Pos_X, 384, 384})
	if up_length >= 0.0001 do up = radial / up_length
	east = east_hint - up * (east_hint.x * up.x + east_hint.y * up.y + east_hint.z * up.z)
	east_length := math.sqrt(east.x * east.x + east.y * east.y + east.z * east.z)
	if east_length < 0.0001 {
		reference := [3]f32{1, 0, 0}
		if abs(up.y) <= abs(up.x) && abs(up.y) <= abs(up.z) do reference = {0, 1, 0}
		if abs(up.z) < abs(up.x) && abs(up.z) < abs(up.y) do reference = {0, 0, 1}
		east = _camera_cross(reference, up)
		east_length = math.sqrt(east.x * east.x + east.y * east.y + east.z * east.z)
	}
	east /= east_length
	north = _camera_cross(up, east)
	return
}

camera_spherical_pan_intent :: proc(right, left, forward, back: bool) -> [2]f32 {
	intent := [2]f32{}
	if right do intent.x += 1
	if left do intent.x -= 1
	if forward do intent.y += 1
	if back do intent.y -= 1
	length := math.sqrt(intent.x * intent.x + intent.y * intent.y)
	if length > 1 do intent /= length
	return intent
}

camera_spherical_pan_next :: proc(
	target, east_hint: [3]f32,
	yaw: f32,
	intent: [2]f32,
	distance: f32,
	frame_dt: f32,
) -> (
	next_target, next_east: [3]f32,
) {
	assert(distance > 0, "camera_spherical_pan_next: invalid distance")
	assert(frame_dt >= 0, "camera_spherical_pan_next: negative delta")
	radius := math.sqrt(target.x * target.x + target.y * target.y + target.z * target.z)
	if radius < 1 || frame_dt == 0 || intent == ([2]f32{}) do return target, east_hint
	radial, east, north := _camera_surface_frame(target / radius, east_hint)
	cos_yaw := f32(math.cos(f64(yaw)))
	sin_yaw := f32(math.sin(f64(yaw)))
	forward := -east * cos_yaw - north * sin_yaw
	right := north * cos_yaw - east * sin_yaw
	tangent := right * intent.x + forward * intent.y
	tangent_length := math.sqrt(
		tangent.x * tangent.x + tangent.y * tangent.y + tangent.z * tangent.z,
	)
	if tangent_length < 0.0001 do return target, east
	tangent /= tangent_length
	axis := _camera_cross(radial, tangent)
	angle := min(CAMERA_PAN_SPEED * distance * frame_dt / radius, f32(math.PI / 4))
	next_radial: [3]f32
	next_radial, next_east = camera_surface_rotate(radial, east, axis, angle)
	return next_radial * radius, next_east
}

// _camera_planet_apply positions the camera from the orbit state in the
// pivot's local surface frame. Mirrors rl.orbit_camera_apply's spherical
// math with (east, north, up) standing in for (x, y, z).
_camera_planet_apply :: proc(value: ^Client_State) {
	radial := _camera_pivot_radial(value)
	up, east, north := _camera_surface_frame(radial, value.camera_frame_east)
	value.camera_frame_east = east
	horizontal := value.orbit.distance * math.cos(value.orbit.pitch)
	offset :=
		east * (horizontal * math.cos(value.orbit.yaw)) +
		north * (horizontal * math.sin(value.orbit.yaw)) +
		up * (value.orbit.distance * math.sin(value.orbit.pitch))
	value.camera.target = value.orbit.target
	value.camera.position = value.orbit.target + offset
	value.camera.up = up
}

// _camera_globe_drag converts a left-drag into a globe spin: the pivot's
// radial rotates so the grabbed surface point follows the cursor. The spin
// rate matches the world-units-per-pixel at the pivot depth, so the ground
// tracks the pointer instead of sliding under it.
_camera_globe_drag :: proc(value: ^Client_State, frame_dt: f32) {
	intent := rl.orbit_camera_pointer_intent(value.orbit_bindings)
	left_pan :=
		intent == .Pan &&
		value.mode != .Terraform &&
		value.press_active &&
		value.press_drag >= terrain_click_drag_threshold(value.ui_scale)
	dragging := rl.IsMouseButtonDown(.MIDDLE) || left_pan
	if !dragging || (value.ui_pointer_captured && !value.grab_pan.active) {
		value.grab_pan.active = false
		return
	}
	value.grab_pan.active = true
	// Grabbing the globe stops any residual throw; it restarts from the
	// motion recorded below, so a still hold pins the ground in place.
	value.globe_spin = {}
	delta := rl.GetMouseDelta()
	if delta.x == 0 && delta.y == 0 do return
	height := f32(rl.GetScreenHeight())
	if height <= 0 do return
	pivot := value.orbit.target
	pivot_length := math.sqrt(pivot.x * pivot.x + pivot.y * pivot.y + pivot.z * pivot.z)
	if pivot_length < 1 do return
	world_per_pixel :=
		2 * value.orbit.distance * math.tan(value.camera.fovy * math.PI / 360) / height
	angle_per_pixel := world_per_pixel / pivot_length
	forward := value.camera.target - value.camera.position
	forward_length := math.sqrt(
		forward.x * forward.x + forward.y * forward.y + forward.z * forward.z,
	)
	if forward_length <= 0.0001 do return
	forward /= forward_length
	right := _camera_cross(forward, value.camera.up)
	right_length := math.sqrt(right.x * right.x + right.y * right.y + right.z * right.z)
	if right_length <= 0.0001 do return
	right /= right_length
	screen_up := _camera_cross(right, forward)
	radial := pivot / pivot_length
	radial, value.camera_frame_east = camera_surface_rotate(
		radial,
		value.camera_frame_east,
		screen_up,
		-delta.x * angle_per_pixel,
	)
	radial, value.camera_frame_east = camera_surface_rotate(
		radial,
		value.camera_frame_east,
		right,
		-delta.y * angle_per_pixel,
	)
	// The instantaneous rotation vector doubles as the throw: releasing the
	// button leaves the last frame's axis and angular speed coasting.
	if frame_dt > 0 {
		spin := screen_up * (-delta.x * angle_per_pixel) + right * (-delta.y * angle_per_pixel)
		magnitude := math.sqrt(spin.x * spin.x + spin.y * spin.y + spin.z * spin.z)
		if magnitude > 0 {
			value.globe_spin = {
				axis  = spin / magnitude,
				speed = min(magnitude / frame_dt, CAMERA_SPIN_MAX_SPEED),
			}
		}
	}
	radial_length := math.sqrt(radial.x * radial.x + radial.y * radial.y + radial.z * radial.z)
	if radial_length <= 0.0001 do return
	value.orbit.target = radial / radial_length * pivot_length
}

_camera_cross :: proc(a, b: [3]f32) -> [3]f32 {
	return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}
}

// camera_spin_next decays a thrown globe's angular speed exponentially and
// snaps to rest below the visible-motion floor. Pure for tests.
camera_spin_next :: proc(speed, frame_dt: f32) -> f32 {
	assert(speed >= 0, "camera_spin_next: negative speed")
	assert(frame_dt >= 0, "camera_spin_next: negative delta time")
	next := speed * math.exp(-CAMERA_SPIN_DAMPING * frame_dt)
	if next < CAMERA_SPIN_MIN_SPEED do return 0
	return next
}

// _camera_spin_update coasts the globe after a throw: the pivot radial keeps
// rotating around the recorded axis while the speed decays to rest. The drag
// handler owns the channel while the pointer is down.
_camera_spin_update :: proc(value: ^Client_State, frame_dt: f32) {
	if value.grab_pan.active || value.globe_spin.speed <= 0 do return
	pivot := value.orbit.target
	pivot_length := math.sqrt(pivot.x * pivot.x + pivot.y * pivot.y + pivot.z * pivot.z)
	if pivot_length < 1 {
		value.globe_spin = {}
		return
	}
	radial := pivot / pivot_length
	radial, value.camera_frame_east = camera_surface_rotate(
		radial,
		value.camera_frame_east,
		value.globe_spin.axis,
		value.globe_spin.speed * frame_dt,
	)
	radial_length := math.sqrt(radial.x * radial.x + radial.y * radial.y + radial.z * radial.z)
	if radial_length > 0.0001 do value.orbit.target = radial / radial_length * pivot_length
	value.globe_spin.speed = camera_spin_next(value.globe_spin.speed, frame_dt)
}

camera_surface_rotate :: proc(
	radial, east, axis: [3]f32,
	angle: f32,
) -> (
	next_radial, next_east: [3]f32,
) {
	axis_length := math.sqrt(axis.x * axis.x + axis.y * axis.y + axis.z * axis.z)
	if axis_length < 0.0001 do return radial, east
	unit_axis := axis / axis_length
	next_radial = _camera_rotate_axis(radial, unit_axis, angle)
	next_east = _camera_rotate_axis(east, unit_axis, angle)
	next_radial, next_east, _ = _camera_surface_frame(next_radial, next_east)
	return
}

// _camera_rotate_axis rotates a vector around a unit axis (Rodrigues).
_camera_rotate_axis :: proc(vector, axis: [3]f32, angle: f32) -> [3]f32 {
	sine := math.sin(angle)
	cosine := math.cos(angle)
	cross := _camera_cross(axis, vector)
	dot := axis.x * vector.x + axis.y * vector.y + axis.z * vector.z
	return vector * cosine + cross * sine + axis * (dot * (1 - cosine))
}

// camera_surface_height is the height the camera treats as the world surface
// under a sphere direction: the rendered ground, raised to the water top
// wherever the point is submerged.
camera_surface_height :: proc(value: ^Client_State, direction: [3]f32) -> f32 {
	assert(value != nil, "camera_surface_height: nil state")
	assert(value.terrain.ready, "camera_surface_height: terrain not ready")
	coord := shared.planet_coord_from_direction(direction)
	ground := shared.terrain_height_at_coord(&value.world, coord)
	depth := shared.waterfield_depth_at_direction(&value.world.waterfield, direction)
	return camera_water_surface(ground, depth)
}

// camera_water_surface lifts a ground height to the water top where the cell
// is actually covered, and leaves dry ground alone. Pure, so the ocean-start
// case is checkable without a window.
camera_water_surface :: proc(ground, depth: f32) -> f32 {
	surface, _, coverage := water_render_sample(ground, depth)
	if coverage <= 0 do return ground
	return max(ground, surface)
}

// camera_pivot_height places the orbit pivot: on the surface, plus whatever
// the player has lifted with Space, held inside the elevation band.
camera_pivot_height :: proc(surface, offset: f32) -> f32 {
	assert(offset >= 0, "camera_pivot_height: negative elevation offset")
	return clamp(surface + offset, CAMERA_MIN_ELEVATION, CAMERA_MAX_ELEVATION)
}

// camera_pivot_follow eases the pivot toward its seat rather than snapping it
// there every frame. Grab-pan keeps the grabbed world point under the cursor
// by re-solving the cursor ray each frame, so a pivot that jumped to the
// ground height under it would feed its own height change straight back into
// the pan - at a shallow pitch that loop has a gain above one on ordinary
// slopes and the view slides across the hill on its own. Easing keeps the
// gain far below one while still tracking the surface within a few frames.
// A zero step snaps, which is what the loading transition wants.
camera_pivot_follow :: proc(current, seat, frame_dt: f32) -> f32 {
	assert(frame_dt >= 0, "camera_pivot_follow: negative delta time")
	if frame_dt <= 0 do return seat
	blend := clamp(1 - math.exp(-CAMERA_SEAT_FOLLOW_RATE * frame_dt), 0, 1)
	return current + (seat - current) * blend
}

// camera_elevation_offset_next holds the player's lift at or above the
// surface: the pivot may never be driven back under the ground it orbits,
// which is the state that broke pitch in the first place.
camera_elevation_offset_next :: proc(offset, delta: f32) -> f32 {
	return clamp(offset + delta, 0, CAMERA_MAX_ELEVATION)
}

// camera_clamp_above_terrain keeps the camera eye from dipping under the
// world surface: after the orbit state is applied, the eye height is raised
// to a minimum clearance above the surface directly beneath it. With the
// pivot seated this is a safety net for the remaining case - terrain behind
// the pivot rising above the orbit sphere - rather than the every-frame
// correction it used to be on a mountainous map.
camera_clamp_above_terrain :: proc(value: ^Client_State) {
	assert(value != nil, "camera_clamp_above_terrain: nil state")
	assert(value.orbit.distance > 0, "camera_clamp_above_terrain: invalid orbit distance")
	if !value.terrain.ready do return
	eye := value.camera.position
	eye_length := math.sqrt(eye.x * eye.x + eye.y * eye.y + eye.z * eye.z)
	if eye_length < 1 do return
	direction := eye / eye_length
	surface := camera_surface_height(value, direction)
	floor_radius := shared.PLANET_RADIUS + surface + CAMERA_TERRAIN_CLEARANCE
	if eye_length < floor_radius do value.camera.position = direction * floor_radius
}

// camera_elevation_delta is the world-space height offset Space and Shift ask
// for in one frame. Space lifts, Shift drops, both held cancel; the rate
// scales with orbit distance for the same reason keyboard pan does, so the
// lift reads at a constant screen speed at any zoom. Pure and window-free -
// the caller polls the keys - so the sign, symmetry, and scaling are testable
// without a GPU, in the same spirit as pause_escape_action.
camera_elevation_delta :: proc(raise, lower: bool, distance, frame_dt: f32) -> f32 {
	assert(distance > 0, "camera_elevation_delta: invalid orbit distance")
	assert(frame_dt >= 0, "camera_elevation_delta: negative delta time")
	if raise == lower do return 0
	rate := f32(1) if raise else f32(-1)
	return rate * CAMERA_ELEVATE_SPEED * distance * frame_dt
}

// cursor_terrain_point returns the terrain point under the mouse cursor with
// the camera as currently applied.
cursor_terrain_point :: proc(value: ^Client_State) -> ([3]f32, bool) {
	assert(value != nil, "cursor_terrain_point: nil state")
	if value.planet_cutaway || value.terrain.ocean.nearshore.fixture_active || !value.terrain.ready do return {}, false
	width := rl.GetScreenWidth()
	height := rl.GetScreenHeight()
	if width <= 0 || height <= 0 do return {}, false
	ray := rl.screen_to_world_ray(rl.GetMousePosition(), value.camera, width, height)
	return terrain_ray_hit(&value.terrain, ray)
}

// hover_update casts the mouse ray onto the terrain and snaps the hit to a
// grid cell so placement, terraforming, and selection share one code path.
hover_update :: proc(value: ^Client_State) {
	assert(value != nil, "hover_update: nil state")
	assert(value.graphics_ready, "hover_update: graphics not ready")
	value.hover_valid = false
	if value.planet_cutaway || value.terrain.ocean.nearshore.fixture_active {
		hover_entity_update(value, {}, 0, false)
		return
	}
	width := rl.GetScreenWidth()
	height := rl.GetScreenHeight()
	if value.ui_pointer_captured || width <= 0 || height <= 0 {
		hover_entity_update(value, {}, 0, false)
		return
	}
	ray := rl.screen_to_world_ray(rl.GetMousePosition(), value.camera, width, height)
	hit, terrain_hit := terrain_ray_hit(&value.terrain, ray)
	terrain_distance := f32(0)
	if terrain_hit {
		delta := hit - ray.origin
		terrain_distance = math.sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
		hit_length := math.sqrt(hit.x * hit.x + hit.y * hit.y + hit.z * hit.z)
		if hit_length >= 1 {
			coord := shared.planet_coord_from_direction(hit / hit_length)
			value.hover_face = coord.face
			value.hover_x = coord.u
			value.hover_y = coord.v
			if shared.grid_in_world(value.hover_x, value.hover_y) {
				value.hover_point = hit
				value.hover_valid = true
				if value.mode == .Build {
					_, located_u, located_v := shared.planet_locate(hit / hit_length)
					limit := f32(shared.PLANET_FACE_CELLS)
					building_width, building_height := shared.building_footprint(
						value.selected_kind,
					)
					value.place_x = i32(
						clamp(located_u - f32(building_width - 1) / 2 + 0.5, 0, limit),
					)
					value.place_y = i32(
						clamp(located_v - f32(building_height - 1) / 2 + 0.5, 0, limit),
					)
				}
			}
		}
	}
	hover_entity_update(value, ray, terrain_distance, terrain_hit)
}

entity_hit_visible :: proc(entity_distance, terrain_distance: f32, terrain_hit: bool) -> bool {
	if entity_distance < 0 do return false
	return !terrain_hit || entity_distance <= terrain_distance + ENTITY_TERRAIN_HIT_TOLERANCE
}

// hover_entity_update caches the building (or bare resource node) under the
// cursor and its dwell time, so selection, outlines, and the tooltip share
// one lookup per frame.
hover_entity_update :: proc(
	value: ^Client_State,
	ray: rl.Ray_3D,
	terrain_distance: f32,
	terrain_hit: bool,
) {
	assert(value != nil, "hover_entity_update: nil state")
	entity := ecs.ENTITY_NIL
	if !value.ui_pointer_captured {
		if found, distance, hit := entity_queries_pick(value, ray);
		   hit && entity_hit_visible(distance, terrain_distance, terrain_hit) {
			entity = found
		}
	}
	if entity == ecs.ENTITY_NIL && value.hover_valid {
		if found_entity, found := building_at(value, value.hover_x, value.hover_y); found {
			entity = found_entity
		} else if node_entity, node_found := node_at(value, value.hover_x, value.hover_y);
		   node_found {
			entity = node_entity
		}
	}
	if entity != value.hover_entity {
		value.hover_entity = entity
		value.hover_entity_seconds = 0
		return
	}
	if entity != ecs.ENTITY_NIL do value.hover_entity_seconds += rl.GetFrameTime()
}

entity_query_bounds_valid :: proc(bounds: Bounds_3D) -> bool {
	size := bounds_size(bounds)
	center := bounds_center(bounds)
	if math.is_nan(center.x) || math.is_nan(center.y) || math.is_nan(center.z) do return false
	if math.is_nan(size.x) || math.is_nan(size.y) || math.is_nan(size.z) do return false
	return size.x > 0.001 && size.y > 0.001 && size.z > 0.001
}

map_regenerate :: proc(value: ^Client_State) {
	assert(value != nil, "map_regenerate: nil state")
	assert(value.regenerate_pending, "map_regenerate: no request")
	seed := value.regenerate_seed
	value.regenerate_pending = false
	balance_minigame_deinit(&value.balance)
	surfboard_deinit(value)
	entity_queries_deinit(&value.queries)
	wind_visual_deinit(&value.wind_visual)
	terrain_deinit(&value.terrain)
	flora_deinit(&value.flora)
	value.ruins = {}
	if value.sockets.mesh.id != 0 do rl.destroy_gpu_mesh(&value.sockets.mesh)
	value.sockets = {}
	cosmetics_deinit(&value.cosmetics)
	planetary_prepare_deinit(&value.planetary_prepare)
	node_seat_cache_deinit(&value.node_seats)
	if value.world_ready do shared.world_deinit(&value.world)
	value.world_ready = false
	value.tick = 0
	value.accumulator = 0
	value.pending = {}
	value.pending_count = 0
	value.selected_kind = .Mine
	value.selected = ecs.ENTITY_NIL
	value.mode = .Inspect
	value.terraform_tool = {}
	value.ui_pointer_captured = false
	value.hover_valid = false
	value.hover_x = 0
	value.hover_y = 0
	value.place_x = 0
	value.place_y = 0
	value.hover_point = {}
	value.hover_entity = ecs.ENTITY_NIL
	value.hover_entity_seconds = 0
	value.grab_pan = {}
	value.globe_spin = {}
	value.press_active = false
	value.press_position = {}
	value.press_drag = 0
	value.debug.interaction = .None
	value.debug.pin_armed = false
	value.sculpt_active = false
	value.sculpt_x = 0
	value.sculpt_y = 0
	value.sculpt_accum = 0
	value.sculpt_direction = 0
	value.highlight.visible = false
	value.cursor = {}
	// The debug panel survives a regenerate but its target points at torn-down
	// objects, so it falls back to the world view.
	value.debug.target = debug_target_world()
	value.debug.scroll = 0
	flora_lineage_debug_reset(&value.flora_lineage_debug)
	value.status = "regenerating map"
	camera_reset(value)
	value.regenerate_seed = seed
	value.regenerate_loading = true
	value.screen = .Loading_Graphics
}

_fingerprint_mix :: proc(hash, bits: u64) -> u64 {
	value := (hash ~ bits) * 0xBF58476D1CE4E5B9
	value ~= value >> 27
	value *= 0x94D049BB133111EB
	return value ~ (value >> 31)
}

_fingerprint_position :: proc(position: [3]f32) -> u64 {
	return(
		u64(transmute(u32)position.x) ~
		u64(transmute(u32)position.y) << 21 ~
		u64(transmute(u32)position.z) << 42 \
	)
}

// mode_set is the single mode-transition point: it clears sculpt sub-state
// and reports the change through the status line. selected_kind stays armed
// across transitions so re-entering build mode keeps the last kind.
mode_set :: proc(value: ^Client_State, mode: Mode) {
	assert(value != nil, "mode_set: nil state")
	previous := value.mode
	value.mode = mode
	value.sculpt_active = false
	value.sculpt_accum = 0
	value.sculpt_direction = 0
	switch mode {
	case .Inspect:
		if previous == .Build do value.status = "build off"
		if previous == .Terraform do value.status = "terraform off"
	case .Build:
		value.status = "build on"
	case .Terraform:
		value.status = "terraform on"
	}
}

// build_mode_enter arms placement for a building kind; pressing a kind key
// always leaves terraform mode so the two placement grids never overlap.
build_mode_enter :: proc(value: ^Client_State, kind: shared.Building_Kind) {
	assert(value != nil, "build_mode_enter: nil state")
	value.selected_kind = kind
	mode_set(value, .Build)
}

input_update :: proc(value: ^Client_State) {
	assert(value != nil, "input_update: nil state")
	assert(value.world_ready, "input_update: world not ready")
	if value.terrain.ocean.nearshore.fixture_active do return
	if PLANET_TOOLS_ENABLED {
		if rl.IsKeyPressed(.ONE) do build_mode_enter(value, .Headquarters)
		if rl.IsKeyPressed(.TWO) do build_mode_enter(value, .Mine)
		if rl.IsKeyPressed(.THREE) do build_mode_enter(value, .Solar_Array)
		if rl.IsKeyPressed(.FOUR) do build_mode_enter(value, .Habitat)
		if rl.IsKeyPressed(.T) {
			mode_set(value, .Inspect if value.mode == .Terraform else .Terraform)
		}
	}
	// Escape is not read here: pause_menu_input owns it, because the same
	// press has to choose between cancelling this mode and opening the menu.
	// A selection whose building was destroyed silently clears.
	if !ecs.is_alive(&value.world.pool, value.selected) do value.selected = ecs.ENTITY_NIL
	selection_update(value)
	if value.mode == .Terraform {
		terraform_keys(value)
		// Terraform gets its own phase: it used to hide inside .Input, so
		// the overlay could not show the cost of the one operation that
		// runs several sim commands per frame.
		profile_phase(&value.profiler, .Terraform)
		terraform_input(value)
		profile_phase(&value.profiler, .Input)
		return
	}
	// Right-click cancels build mode; placement itself is a normal left
	// click, routed through the click-vs-drag logic in selection_update.
	if value.mode == .Build && rl.IsMouseButtonPressed(.RIGHT) {
		mode_set(value, .Inspect)
	}
	if value.selected == ecs.ENTITY_NIL do return
	if rl.IsKeyPressed(.U) do upgrade_selected(value)
	if rl.IsKeyPressed(.F) do tune_selected(value)
}

// upgrade_selected issues an Upgrade_Building command for the selected
// building; shared by the U key and the inspect toolbar button.
upgrade_selected :: proc(value: ^Client_State) {
	assert(value != nil, "upgrade_selected: nil state")
	if value.selected == ecs.ENTITY_NIL do return
	if !ecs.has(&value.world.buildings, value.selected) do return
	net_id, found := shared.world_net_id_for_entity(&value.world, value.selected)
	if !found do return
	command := shared.Command {
		kind   = .Upgrade_Building,
		player = LOCAL_PLAYER,
		target = net_id,
	}
	value.status = "upgrading" if shared.apply_command(&value.world, command) else "rejected"
}

tune_selected :: proc(value: ^Client_State) {
	assert(value != nil, "tune_selected: nil state")
	if value.selected == ecs.ENTITY_NIL || value.balance.active do return
	if !ecs.has(&value.world.buildings, value.selected) do return
	if balance_minigame_start(&value.balance, value.selected) {
		value.status = "tuning"
	} else {
		value.status = "tuning unavailable"
	}
}

balance_frame :: proc(value: ^Client_State, frame_dt: f32) {
	assert(value != nil, "balance_frame: nil state")
	if rl.IsKeyPressed(.ESCAPE) {
		balance_minigame_deinit(&value.balance)
		value.status = "tuning cancelled"
		return
	}
	tilt: [2]f32
	if rl.IsKeyDown(.D) || rl.IsKeyDown(.RIGHT) do tilt.x += 1
	if rl.IsKeyDown(.A) || rl.IsKeyDown(.LEFT) do tilt.x -= 1
	if rl.IsKeyDown(.UP) || rl.IsKeyDown(.W) do tilt.y += 1
	if rl.IsKeyDown(.DOWN) || rl.IsKeyDown(.S) do tilt.y -= 1
	result := balance_minigame_update(&value.balance, frame_dt, tilt)
	switch result {
	case .Running:
		return
	case .Failed:
		value.status = "tuning failed"
		balance_minigame_deinit(&value.balance)
	case .Succeeded:
		net_id, found := shared.world_net_id_for_entity(&value.world, value.balance.target)
		if !found {
			value.status = "rejected"
			balance_minigame_deinit(&value.balance)
			return
		}
		command := shared.Command {
			kind               = .Set_Efficiency,
			player             = LOCAL_PLAYER,
			target             = net_id,
			efficiency_percent = balance_minigame_score(&value.balance),
		}
		value.status = "tuned" if shared.apply_command(&value.world, command) else "rejected"
		balance_minigame_deinit(&value.balance)
	}
}

world_pointer_gesture_update :: proc(value: ^Client_State, mouse: rl.Vector2) {
	assert(value != nil, "world pointer gesture: nil state")
	if rl.IsMouseButtonPressed(.LEFT) && !value.ui_pointer_captured {
		value.press_active = true
		value.press_position = mouse
		value.press_drag = 0
	}
	if !value.press_active || !rl.IsMouseButtonDown(.LEFT) do return
	value.press_drag = pointer_displacement(value.press_position, mouse)
}

pointer_displacement :: proc(from, to: rl.Vector2) -> f32 {
	delta := to - from
	return math.sqrt(delta.x * delta.x + delta.y * delta.y)
}

terrain_click_drag_threshold :: proc(ui_scale: f32) -> f32 {
	assert(ui_scale > 0, "terrain click threshold: invalid scale")
	return CLICK_SELECT_MAX_DRAG * ui_scale
}

// selection_update commits a world press only when its release remains inside
// the UI-scaled click radius. Camera pan owns gestures that cross the radius.
selection_update :: proc(value: ^Client_State) {
	assert(value != nil, "selection_update: nil state")
	assert(value.press_drag >= 0, "selection_update: negative drag")
	if !rl.IsMouseButtonReleased(.LEFT) do return
	if !value.press_active do return
	value.press_active = false
	// A press that started in the world but released over the toolbar is
	// neither a placement nor a selection.
	if !terrain_click_completed(
		value.ui_pointer_captured,
		value.press_drag,
		terrain_click_drag_threshold(value.ui_scale),
	) {
		return
	}
	// Scope from the original press point so camera seating or simulation
	// changes during the gesture cannot move the sampled location.
	if debug_pin_place_at(value, value.press_position) do return
	if value.debug.open do debug_scope_click_at(value, value.press_position)
	if value.mode == .Terraform do return
	if value.mode == .Build {
		place_at_hover(value)
		return
	}
	if !value.hover_valid {
		value.selected = ecs.ENTITY_NIL
		return
	}
	value.selected = gameplay_selection_entity(
		value.selected,
		value.hover_entity,
		ecs.has(&value.world.buildings, value.hover_entity),
		value.debug.open,
	)
}

terrain_click_completed :: proc(pointer_captured: bool, drag, threshold: f32) -> bool {
	return !pointer_captured && drag >= 0 && threshold > 0 && drag < threshold
}

gameplay_selection_entity :: proc(
	selected, hovered: ecs.Entity,
	hovered_is_building, debug_scope_open: bool,
) -> ecs.Entity {
	if hovered != ecs.ENTITY_NIL && hovered_is_building do return hovered
	if debug_scope_open do return selected
	return ecs.ENTITY_NIL
}

// place_at_hover issues a Place_Building command at the armed footprint
// anchor. Build mode stays armed afterwards so placements chain without
// re-pressing 1-4.
place_at_hover :: proc(value: ^Client_State) {
	assert(value != nil, "place_at_hover: nil state")
	assert(value.mode == .Build, "place_at_hover: not in build mode")
	if !value.hover_valid do return
	command := shared.Command {
		kind     = .Place_Building,
		player   = LOCAL_PLAYER,
		building = value.selected_kind,
		face     = value.hover_face,
		grid_x   = value.place_x,
		grid_y   = value.place_y,
	}
	placed := shared.apply_command(&value.world, command)
	value.status = "placed" if placed else "rejected"
	if placed {
		value.sockets.dirty = true
		// Placement flattened the heightfield under the footprint; the
		// terraform-sized dirty reach covers the largest 3x3 footprint.
		width, height := shared.building_footprint(value.selected_kind)
		anchor := shared.Planet_Coord {
			value.hover_face,
			clamp(value.place_x + width / 2, 0, i32(shared.PLANET_FACE_CELLS)),
			clamp(value.place_y + height / 2, 0, i32(shared.PLANET_FACE_CELLS)),
		}
		terrain_mark_dirty(&value.terrain, anchor)
		cell := shared.GRID_CELL_SIZE
		anchor_coord := shared.Planet_Coord{value.hover_face, value.place_x, value.place_y}
		anchor_height := shared.terrain_height_at_coord(&value.world, anchor_coord)
		anchor_transform := shared.planet_transform_make(anchor_coord, anchor_height)
		footprint_center :=
			anchor_transform.position +
			anchor_transform.east * (f32(width - 1) * cell * 0.5) +
			anchor_transform.north * (f32(height - 1) * cell * 0.5)
		_ = flora_clear_footprint(
			&value.flora,
			footprint_center,
			anchor_transform.east,
			anchor_transform.north,
			f32(width - 1) * cell * 0.5 + 0.5,
			f32(height - 1) * cell * 0.5 + 0.5,
		)
		flora_mark_dirty(&value.flora)
	}
}

// terraform_keys handles the mode's own keyboard vocabulary: R, F and L pick
// the tool, [ and ] step the brush. All are letters/brackets rather than
// digits because 1-4 already mean "arm this building" everywhere else.
terraform_keys :: proc(value: ^Client_State) {
	assert(value != nil, "terraform_keys: nil state")
	assert(value.mode == .Terraform, "terraform_keys: not in terraform mode")
	if rl.IsKeyPressed(.R) do value.terraform_tool = .Raise
	if rl.IsKeyPressed(.F) do value.terraform_tool = .Lower
	if rl.IsKeyPressed(.L) do value.terraform_tool = .Level
	if rl.IsKeyPressed(.LEFT_BRACKET) do terraform_brush_set(value, value.terraform_radius - 1)
	if rl.IsKeyPressed(.RIGHT_BRACKET) do terraform_brush_set(value, value.terraform_radius + 1)
}

// terraform_brush_wheel converts a shift+wheel notch into a brush step and
// reports whether it consumed the wheel, so the camera does not also zoom.
// Shift is the gate because an unmodified wheel has to keep zooming: it is
// the only zoom control, and terraform mode is where the player most needs
// to get closer to what they are sculpting.
terraform_brush_wheel :: proc(value: ^Client_State) -> bool {
	assert(value != nil, "terraform_brush_wheel: nil state")
	if value.mode != .Terraform do return false
	if !rl.IsKeyDown(.LEFT_SHIFT) && !rl.IsKeyDown(.RIGHT_SHIFT) do return false
	notches := rl.GetMouseWheelMove()
	if notches == 0 do return false
	step := i32(1) if notches > 0 else i32(-1)
	terraform_brush_set(value, value.terraform_radius + step)
	return true
}

// terraform_brush_clamp is the one place a brush size is bounded. Pure, so
// the three call sites that can change the brush - the toolbar buttons, the
// bracket keys, and shift+wheel - cannot drift apart, and so the rule is
// testable without a 183 MB Client_State on the stack.
//
// It saturates rather than wrapping: one extra keypress at the top of the
// range must hold, not jump to the smallest brush, which would be the most
// destructive possible surprise mid-sculpt.
terraform_brush_clamp :: proc(radius: i32) -> i32 {
	clamped := clamp(radius, shared.TERRAFORM_RADIUS_MIN, shared.TERRAFORM_RADIUS_MAX)
	assert(shared.terraform_radius_valid(clamped), "terraform_brush_clamp: escaped the range")
	return clamped
}

// terraform_brush_set clamps and stores a brush size. Central so the
// keyboard, the wheel and the toolbar buttons cannot disagree about the
// range, and so the status line reports the change once.
terraform_brush_set :: proc(value: ^Client_State, radius: i32) {
	assert(value != nil, "terraform_brush_set: nil state")
	clamped := terraform_brush_clamp(radius)
	if clamped == value.terraform_radius do return
	value.terraform_radius = clamped
	value.status = "brush"
}

// terraform_affordable reports whether the player can pay for one apply of
// the current brush. Used by the cursor and the highlight to refuse
// *before* the click rather than reporting "rejected" after it.
terraform_affordable :: proc(value: ^Client_State) -> bool {
	assert(value != nil, "terraform_affordable: nil state")
	if !value.world_ready do return true
	ore, _ := stockpile_amounts(value)
	return ore >= shared.terraform_cost_ore(value.terraform_radius)
}

// terraform_would_be_refused predicts the sim's verdict for an apply at the
// hovered cell: unaffordable, a building inside the brush, or a centre
// delta already at the clamp in the direction the tool would move it.
//
// This mirrors _apply_terraform's validation rather than sharing it,
// because the sim's version charges and mutates. The duplication is the
// cost of showing the refusal before the click instead of after.
terraform_would_be_refused :: proc(value: ^Client_State) -> bool {
	assert(value != nil, "terraform_would_be_refused: nil state")
	if value.mode != .Terraform do return false
	if !value.hover_valid do return false
	if !terraform_affordable(value) do return true
	radius := value.terraform_radius
	for offset_y in -radius ..= radius {
		for offset_x in -radius ..= radius {
			cell_x := value.hover_x + offset_x
			cell_y := value.hover_y + offset_y
			if !shared.grid_in_world(cell_x, cell_y) do continue
			if _, occupied := building_at(value, cell_x, cell_y); occupied do return true
		}
	}
	return false
}

// terraform_saturation reports how close the hovered cell's centre delta is
// to the clamp, as 0..1. The brush silently stops working at the clamp, so
// the highlight fades toward neutral as this approaches 1 rather than
// leaving the player dragging against a wall with no feedback.
terraform_saturation :: proc(value: ^Client_State) -> f32 {
	assert(value != nil, "terraform_saturation: nil state")
	if !value.world_ready || !value.hover_valid do return 0
	if !shared.grid_in_world(value.hover_x, value.hover_y) do return 0
	index := shared.planet_index({value.hover_face, value.hover_x, value.hover_y})
	delta := value.world.heightfield.deltas[index]
	magnitude := f32(delta if delta >= 0 else -delta)
	return clamp(magnitude / f32(shared.TERRAFORM_MAX_DELTA), 0, 1)
}

// terraform_tool_direction maps the active tool onto the sim command's
// direction field: Raise pulls earth out, Lower pushes it in, Level flattens
// toward the analytic base. Pure so the mapping is testable without a GPU.
terraform_tool_direction :: proc(tool: Terraform_Tool) -> i8 {
	switch tool {
	case .Raise:
		return 1
	case .Lower:
		return -1
	case .Level:
		return 0
	}
	return 0
}

// terraform_hold_steps drains whole hold intervals from an accumulated time
// value: the step count to apply this frame plus the remainder to carry.
// The count is bounded because the accumulator is bounded by per-frame time
// (MAX_FRAME_DT) plus one seeded interval. Negative input yields zero steps.
terraform_hold_steps :: proc(accum: f32) -> (steps: int, remainder: f32) {
	if accum < TERRAFORM_HOLD_INTERVAL do return 0, max(accum, 0)
	steps = int(accum / TERRAFORM_HOLD_INTERVAL)
	remainder = accum - f32(steps) * TERRAFORM_HOLD_INTERVAL
	return steps, remainder
}

// terraform_input applies the active tool while the left button is held: the
// press seeds one full interval so a click fires exactly one step, and each
// held frame accumulates time that drains into one command per
// TERRAFORM_HOLD_INTERVAL. The brush follows the hovered cell, so holding
// and moving paints a stroke instead of pinning the press cell.
//
// Surface invalidation is deliberately *not* done per command. A hold issues
// several commands per second, and flora_mark_dirty rewinds the budgeted
// reseat sweep to zero, so per-command invalidation meant the sweep restarted
// before it could ever finish. Both flags are raised once at the end of the
// frame instead, from whether any command succeeded.
terraform_input :: proc(value: ^Client_State) {
	assert(value != nil, "terraform_input: nil state")
	assert(value.mode == .Terraform, "terraform_input: not in terraform mode")
	applied := false
	defer if applied {
		flora_mark_dirty(&value.flora)
		value.sockets.dirty = true
	}
	if rl.IsMouseButtonPressed(.LEFT) && value.hover_valid {
		value.sculpt_active = true
		value.sculpt_accum = TERRAFORM_HOLD_INTERVAL
		value.sculpt_direction = 0
	}
	if !value.sculpt_active do return
	if !rl.IsMouseButtonDown(.LEFT) {
		value.sculpt_active = false
		value.sculpt_accum = 0
		value.sculpt_direction = 0
		return
	}
	if value.hover_valid {
		value.sculpt_face = value.hover_face
		value.sculpt_x = value.hover_x
		value.sculpt_y = value.hover_y
	}
	value.sculpt_accum += clamp(rl.GetFrameTime(), 0, MAX_FRAME_DT)
	steps, remainder := terraform_hold_steps(value.sculpt_accum)
	value.sculpt_accum = remainder
	direction := terraform_tool_direction(value.terraform_tool)
	for _ in 0 ..< steps {
		applied = _terraform_apply(value, direction) || applied
	}
}

_terraform_apply :: proc(value: ^Client_State, direction: i8) -> bool {
	assert(value != nil, "_terraform_apply: nil state")
	assert(direction >= -1 && direction <= 1, "_terraform_apply: invalid direction")
	value.sculpt_direction = direction
	command := shared.Command {
		kind             = .Terraform,
		player           = LOCAL_PLAYER,
		face             = value.sculpt_face,
		grid_x           = value.sculpt_x,
		grid_y           = value.sculpt_y,
		direction        = direction,
		terraform_radius = i8(value.terraform_radius),
	}
	if !shared.apply_command(&value.world, command) {
		value.status = "rejected"
		return false
	}
	// The dirty reach has to follow the brush: a 9x9 edit widened with the
	// default radius would leave the outer chunks stale and show up as a
	// seam at the chunk boundary.
	terrain_mark_dirty(
		&value.terrain,
		{value.sculpt_face, value.sculpt_x, value.sculpt_y},
		value.terraform_radius,
	)
	switch direction {
	case -1:
		value.status = "dropping"
	case 0:
		value.status = "leveling"
	case 1:
		value.status = "raising"
	}
	return true
}

// building_at resolves the building whose footprint covers a cell on the
// hovered face; shares the sim's containment rule so picking and validation
// always agree.
building_at :: proc(value: ^Client_State, grid_x: i32, grid_y: i32) -> (ecs.Entity, bool) {
	assert(value != nil, "building_at: nil state")
	return shared.building_at_cell(&value.world, grid_x, grid_y, value.hover_face)
}

// building_center returns the world-space center of a building's footprint
// at its stored ground height; the shared anchor is the min corner.
building_center :: proc(value: ^Client_State, entity: ecs.Entity) -> [3]f32 {
	assert(value != nil, "building_center: nil state")
	transform, ok := ecs.get(&value.world.transforms, entity)
	if !ok do return {}
	building, has_building := ecs.get(&value.world.buildings, entity)
	if !has_building do return transform.position
	width, height := shared.building_footprint(building.kind)
	return building_anchor_center(transform, width, height)
}

focus_selected_building :: proc(value: ^Client_State) {
	assert(value != nil, "focus_selected_building: nil state")
	if value.selected == ecs.ENTITY_NIL do return
	if !ecs.has(&value.world.buildings, value.selected) do return
	value.orbit.target = building_center(value, value.selected)
	value.orbit.distance = clamp(
		CAMERA_BUILDING_FOCUS_DISTANCE,
		value.orbit_config.min_distance,
		value.orbit_config.max_distance,
	)
	value.status = "focused"
}

// node_at finds the bare resource-node entity on a grid cell. Node
// components copied onto mines are skipped, mirroring draw_nodes, so the
// building lookup always wins on occupied cells.
node_at :: proc(value: ^Client_State, grid_x: i32, grid_y: i32) -> (ecs.Entity, bool) {
	assert(value != nil, "node_at: nil state")
	nodes := &value.world.nodes
	for index in 0 ..< ecs.set_len(nodes) {
		entity := nodes.header.entities[index]
		if ecs.has(&value.world.buildings, entity) do continue
		transform, ok := ecs.get(&value.world.transforms, entity)
		if !ok do continue
		if transform.face != value.hover_face do continue
		if transform.grid_x == grid_x && transform.grid_y == grid_y do return entity, true
	}
	return ecs.ENTITY_NIL, false
}

// sim_update advances the deterministic sim on a fixed 4 Hz accumulator and
// fires cosmetic bursts for constructions that completed this frame.
sim_update :: proc(value: ^Client_State, frame_dt: f32) {
	assert(value != nil, "sim_update: nil state")
	assert(value.accumulator >= 0, "sim_update: negative accumulator")
	value.accumulator += f64(frame_dt)
	steps := 0
	for value.accumulator >= shared.TICK_DURATION_SECONDS && steps < MAX_TICKS_PER_FRAME {
		pending_record(value)
		timing: shared.Sim_Tick_Timing
		sim_tick_committed(value, &timing)
		profile_tick_record(&value.profiler, &timing)
		weather_apply_atmosphere(value)
		value.tick += 1
		value.accumulator -= shared.TICK_DURATION_SECONDS
		completions_detect(value)
		steps += 1
		// Start preparing the next tick immediately: the worker has until
		// the next tick boundary (250 ms) to finish the planetary stage.
		planetary_prepare_begin(&value.planetary_prepare, value.tick)
	}
	profile_tick_prepared(
		&value.profiler,
		value.planetary_prepare.commits,
		value.planetary_prepare.fallbacks,
		value.planetary_prepare.peak_ms,
	)
	// Drop backlog beyond the per-frame budget; the sim is idle-friendly.
	max_backlog := f64(MAX_TICKS_PER_FRAME) * shared.TICK_DURATION_SECONDS
	if value.accumulator > max_backlog do value.accumulator = max_backlog
	if value.flora_sterilize_requested {
		shared.flora_ecology_sterilize(&value.world.flora_ecology)
		flora_lineage_debug_reset(&value.flora_lineage_debug)
		value.flora_sterilize_requested = false
	}
	if value.flora_inoculate_requested {
		_ = shared.flora_ecology_inoculate(&value.world.flora_ecology, &value.world)
		value.flora_inoculate_requested = false
	}
	value.flora_time_accumulator += f64(frame_dt) * f64(value.flora_time_scale)
	flora_steps := 0
	for (value.flora_time_accumulator >= 1 || value.flora_step_requested) &&
	    flora_steps < FLORA_DEBUG_STEPS_PER_FRAME_MAX {
		shared.flora_ecology_step_state(&value.world.flora_ecology, &value.world)
		if value.flora_time_accumulator >= 1 do value.flora_time_accumulator -= 1
		value.flora_step_requested = false
		flora_steps += 1
	}
	if value.flora_time_accumulator > f64(FLORA_DEBUG_STEPS_PER_FRAME_MAX) {
		value.flora_time_accumulator = f64(FLORA_DEBUG_STEPS_PER_FRAME_MAX)
	}
}

// sim_tick_committed runs the authoritative tick for value.tick, using the
// asynchronously prepared planetary stage when it is exactly the state a
// synchronous tick would produce, and a plain synchronous tick otherwise.
sim_tick_committed :: proc(value: ^Client_State, timing: ^shared.Sim_Tick_Timing) {
	assert(value != nil, "sim_tick_committed: nil state")
	prepare := &value.planetary_prepare
	wait_started := time.tick_now()
	planetary_prepare_wait(prepare)
	wait_ms := time.duration_milliseconds(time.tick_since(wait_started))
	if planetary_prepare_take(prepare, value.tick) {
		shared.sim_tick_prepared(&value.world, value.tick, prepare.shadow, prepare.scratch, timing)
	} else {
		shared.sim_tick(&value.world, value.tick, timing)
	}
	if timing != nil do timing.stage_ms[.Planetary_Wait] += wait_ms
}

pending_record :: proc(value: ^Client_State) {
	assert(value != nil, "pending_record: nil state")
	constructions := &value.world.constructions
	count := ecs.set_len(constructions)
	assert(count <= shared.MAX_BUILDINGS, "pending_record: constructions over capacity")
	for index in 0 ..< count {
		value.pending[index] = constructions.header.entities[index]
	}
	value.pending_count = count
}

completions_detect :: proc(value: ^Client_State) {
	assert(value != nil, "completions_detect: nil state")
	assert(value.pending_count <= shared.MAX_BUILDINGS, "completions_detect: bad pending count")
	for index in 0 ..< value.pending_count {
		entity := value.pending[index]
		if ecs.has(&value.world.constructions, entity) do continue
		if !ecs.is_alive(&value.world.pool, entity) do continue
		if !ecs.has(&value.world.transforms, entity) do continue
		cosmetics_spawn_burst(&value.cosmetics, building_center(value, entity))
		value.sockets.dirty = true
	}
	value.pending_count = 0
}

world_scene_capture_required :: proc(far_only: bool) -> bool {
	return !far_only
}

draw_world :: proc(value: ^Client_State) -> bool {
	assert(value != nil, "draw_world: nil state")
	assert(value.graphics_ready, "draw_world: graphics not ready")
	sun_light, moon_light := weather_orbital_lights(value)
	capture_required := world_scene_capture_required(value.terrain.ocean.far_faces_active)
	opaque_target := &value.target
	if capture_required do opaque_target = &value.opaque_scene_target
	if !opaque_components_draw(value, opaque_target) do return false
	underwater_primary, underwater_secondary := water_underwater_medium_params(
		value.terrain.ocean.underwater,
	)
	value.water_scene_capture = false
	if capture_required {
		value.water_scene_capture = rl.copy_gpu_3d_target_named(
			&value.opaque_scene_target,
			&value.target,
			"world.scene-copy",
		)
		if !value.water_scene_capture do return false
	}
	pass, ok := rl.begin_gpu_3d_named(&value.target, value.camera, .Preserve, "world.ocean")
	if !ok do return false
	rl.set_gpu_3d_light(&pass, sun_light)
	rl.set_gpu_3d_secondary_light(&pass, moon_light)
	rl.set_gpu_3d_underwater_medium(&pass, underwater_primary, underwater_secondary)
	rl.set_gpu_3d_clip_plane(
		&pass,
		{value.camera.position.x, value.camera.position.y, value.camera.position.z, 0},
		value.planet_cutaway,
	)
	scene_color, scene_depth: rl.Texture2D
	if capture_required {
		scene_color = rl.gpu_3d_target_color_texture(&value.opaque_scene_target)
		scene_depth, _ = rl.gpu_3d_target_depth_texture(&value.opaque_scene_target)
	}
	terrain_draw_ocean(
		&value.terrain,
		&pass,
		value.camera,
		value.ocean_visual,
		&value.atmosphere,
		scene_color,
		scene_depth,
	)
	if value.planet_cutaway {
		rl.set_gpu_3d_clip_plane(&pass, {}, false)
		terrain_draw_section(&value.terrain, &pass, value.camera)
	} else {
		surfboard_draw(value, &pass)
		wind_visual_draw(&value.wind_visual, &pass, value.camera_visual, value.sim_proof_settings)
		debug_scope_draw(value, &pass)
		debug_pinned_scope_draw(value, &pass)
	}
	// The remaining flat-world decorations (sockets, ruins, the placement
	// grid and debris) lay out on a 3840-unit plane; drawn against a
	// radius-1080 sphere they float in space. Skipped until their own
	// spherical ports land.
	rl.end_gpu_3d(&pass)
	return true
}

draw_balance_world :: proc(value: ^Client_State) {
	assert(value != nil, "draw_balance_world: nil state")
	assert(value.graphics_ready, "draw_balance_world: graphics not ready")
	if !value.balance.active do return
	camera := rl.Camera3D {
		position   = {7, -9, 7},
		target     = {0, 0, 0.5},
		up         = rl.CAMERA_WORLD_UP,
		fovy       = 40,
		projection = .PERSPECTIVE,
		near_plane = 0.1,
		far_plane  = 50,
	}
	pass, ok := rl.begin_gpu_3d(&value.balance_target, camera)
	if !ok do return
	rl.set_gpu_3d_light(&pass, WORLD_LIGHT)
	balance_minigame_draw(&value.balance, &pass, value.cube, value.cube_edges)
	rl.end_gpu_3d(&pass)
}

draw_buildings :: proc(value: ^Client_State, pass: ^rl.Gpu_3D_Pass) {
	assert(value != nil, "draw_buildings: nil state")
	assert(pass != nil, "draw_buildings: nil pass")
	models_draw_buildings(value, pass)
}

// draw_selection outlines the selected building brightly and the hovered
// (unselected) building faintly, so click targets are visible before commit.
draw_selection :: proc(value: ^Client_State, pass: ^rl.Gpu_3D_Pass) {
	assert(value != nil, "draw_selection: nil state")
	assert(pass != nil, "draw_selection: nil pass")
	if value.mode != .Terraform {
		hovered := value.hover_entity
		if hovered != ecs.ENTITY_NIL && hovered != value.selected {
			if ecs.has(&value.world.buildings, hovered) {
				_draw_building_outline(value, pass, hovered, UI_HOVER_OUTLINE, 1.08)
			} else if ecs.has(&value.world.nodes, hovered) {
				_draw_node_outline(value, pass, hovered, UI_HOVER_OUTLINE)
			}
		}
	}
	selection_frame_draw(value, pass)
}

_draw_building_outline :: proc(
	value: ^Client_State,
	pass: ^rl.Gpu_3D_Pass,
	entity: ecs.Entity,
	color: rl.Color,
	scale: f32,
) {
	assert(value != nil, "_draw_building_outline: nil state")
	assert(scale > 1, "_draw_building_outline: scale must inflate")
	center, size, frame, ok := building_oriented_bounds(value, entity)
	if !ok do return
	size *= scale
	matrix_value :=
		rl.MatrixTranslate(center.x, center.y, center.z) *
		frame *
		rl.MatrixScale(size.x, size.y, size.z)
	rl.draw_gpu_mesh(&pass^, value.cube_edges, matrix_value, {color = color})
}

// _draw_node_outline frames a bare resource node's cluster with the same
// edge-cube used for building hover feedback.
_draw_node_outline :: proc(
	value: ^Client_State,
	pass: ^rl.Gpu_3D_Pass,
	entity: ecs.Entity,
	color: rl.Color,
) {
	assert(value != nil, "_draw_node_outline: nil state")
	center, size, frame, ok := node_oriented_bounds(value, entity)
	if !ok do return
	size *= 1.08
	matrix_value :=
		rl.MatrixTranslate(center.x, center.y, center.z) *
		frame *
		rl.MatrixScale(size.x, size.y, size.z)
	rl.draw_gpu_mesh(&pass^, value.cube_edges, matrix_value, {color = color})
}

Rain_Streak :: struct {
	start: rl.Vector2,
	end:   rl.Vector2,
}

rain_streak_geometry :: proc(
	index: i32,
	time, intensity, wind: f32,
	width, height: i32,
) -> Rain_Streak {
	assert(index >= 0, "rain streak: negative index")
	assert(width > 0 && height > 0, "rain streak: invalid viewport")
	strength := clamp(intensity, 0, 1)
	wind_speed := clamp(wind, -200, 200)
	seed := f32(index) * 17.371
	x_noise := math.sin(seed * 12.9898) * 43_758.547
	y_noise := math.sin(seed * 78.233) * 24_634.635
	base_x := (x_noise - math.floor(x_noise)) * f32(width)
	base_y := (y_noise - math.floor(y_noise)) * f32(height)
	x := base_x + time * wind_speed * 0.35
	y := base_y + time * f32(height) * (0.65 + strength * 0.8)
	x -= math.floor(x / f32(width)) * f32(width)
	y -= math.floor(y / f32(height)) * f32(height)
	length := 8 + strength * 20
	slant := wind_speed * 0.35
	return {start = {x, y}, end = {x + slant, y + length}}
}

precipitation_draw :: proc(value: ^Client_State) {
	assert(value != nil, "precipitation_draw: nil state")
	intensity := value.visual_weather.rain
	if intensity <= 0.01 do return
	altitude := max(
		math.sqrt(
			value.camera.position.x * value.camera.position.x +
			value.camera.position.y * value.camera.position.y +
			value.camera.position.z * value.camera.position.z,
		) -
		shared.PLANET_RADIUS,
		0,
	)
	altitude_fade := clamp((altitude - 120) / 300, 0, 1)
	altitude_fade = altitude_fade * altitude_fade * (3 - 2 * altitude_fade)
	intensity *= 1 - altitude_fade
	if intensity <= 0.01 do return
	width := max(rl.GetScreenWidth(), 1)
	height := max(rl.GetScreenHeight(), 1)
	count := clamp(i32(48 + intensity * 240), 0, 288)
	for index in 0 ..< count {
		streak := rain_streak_geometry(
			index,
			value.cursor.time,
			intensity,
			value.visual_weather.wind.x,
			width,
			height,
		)
		alpha := u8(clamp(45 + intensity * 110, 0, 180))
		color := UI_RAIN
		color.a = alpha
		rl.DrawLineEx(streak.start, streak.end, 1 + intensity, color)
	}
}

draw_screen :: proc(value: ^Client_State, surface: ^fit.Surface) {
	assert(value != nil, "draw_screen: nil state")
	assert(surface != nil, "draw_screen: nil surface")
	assert(value.world_ready, "draw_screen: world not ready")
	// The session frame is already open and cleared; draw straight into it.
	width := max(rl.GetScreenWidth(), 1)
	height := max(rl.GetScreenHeight(), 1)
	post_active := atmosphere_begin_post(&value.atmosphere, value.cursor.time, width, height)
	rl.draw_gpu_3d_target(&value.target, {0, 0, f32(width), f32(height)}, rl.WHITE)
	atmosphere_end_post(&value.atmosphere, post_active)
	precipitation_draw(value)
	ore, energy := stockpile_amounts(value)
	mode_names := MODE_NAMES
	mode := mode_names[value.mode]
	// The HUD is inset by the window strip's full height whenever the custom
	// title bar is active, using the constant height rather than the current
	// reveal state so the text never jitters as the strip auto-hides.
	hud_x := ui_px(value.ui_scale, HUD_MARGIN)
	hud_y := ui_px(value.ui_scale, HUD_MARGIN) + header_inset(value, surface)
	if value.show_hud_text {
		// One instrument row of label/value pairs rather than one run-on
		// sentence: the eye finds a number because its label is quieter,
		// and each reading can take the ink its meaning calls for.
		gap := ui_px(value.ui_scale, HUD_READOUT_GAP)
		cursor := hud_x
		cursor = ui_readout(surface, "ORE ", fmt.tprintf("%d", ore), cursor, hud_y, .Tool) + gap
		cursor = ui_readout(surface, "PWR ", fmt.tprintf("%d", energy), cursor, hud_y, .Tool) + gap
		cursor = ui_readout(surface, "TICK ", fmt.tprintf("%d", value.tick), cursor, hud_y) + gap
		cursor = ui_readout(surface, "MODE ", string(mode), cursor, hud_y, .Accent) + gap
		status_ink: fit.Ink = .Secondary
		if value.status == "rejected" do status_ink = .Danger
		_ = ui_readout(surface, "STATUS ", string(value.status), cursor, hud_y, status_ink)
		controls: cstring = "left-drag pan  alt+drag rotate  Q/E rotate  wheel zoom  WASD/arrows pan"
		if value.mode == .Terraform {
			controls = "hold to sculpt  R raise  F lower  L level  [ ] brush  shift+wheel brush  middle-drag pan"
		}
		fit.Text(
			surface,
			string(controls),
			hud_x,
			hud_y + fit.Text_Line_Height(surface, .Note) + ui_px(value.ui_scale, HUD_LINE_GAP),
			.Body,
			.Label,
		)
	}
	if value.planet_cutaway {
		legend_y := hud_y + ui_px(value.ui_scale, 48)
		fit.Text(surface, "PLANET CUTAWAY", hud_x, legend_y, .Title, .Heading)
		fit.Text(
			surface,
			"inner core · outer core · mantle · crust · ocean",
			hud_x,
			legend_y + fit.Text_Line_Height(surface, .Title),
			.Body,
			.Accent,
		)
		fit.Text(
			surface,
			"schematic layer boundaries · ocean/crust thickness visually exaggerated",
			hud_x,
			legend_y +
			fit.Text_Line_Height(surface, .Title) +
			fit.Text_Line_Height(surface, .Body),
			.Note,
			.Label,
		)
	}
	if value.show_fps {
		fps := fmt.ctprintf("fps %d", value.performance.fps_display)
		fps_text := string(fps)
		fit.Text(
			surface,
			fps_text,
			rl.GetScreenWidth() - fit.Text_Width(surface, fps_text, .Title) - hud_x,
			hud_y,
			.Title,
			.Accent,
		)
	}
	if value.balance.active {
		balance_overlay_draw(value, surface)
		console_draw(value, surface)
		return
	}
	tooltip_draw(value, surface)
	if PLANET_TOOLS_ENABLED do toolbar_frame(value, surface)
	inspect_panel_frame(value, surface)
	debug_panel_frame(value, surface)
	debug_pinned_panel_frame(value, surface)
	// The menu covers the HUD panels but not the console: the console is a
	// developer surface that has to stay reachable from anywhere.
	pause_menu_frame(value, surface)
	console_draw(value, surface)
	profile_overlay_draw(value, surface)
	// The procedural cursor is a world tool. While the menu is up the OS
	// pointer is showing (game_uses_custom_cursor), so drawing it too would
	// put two pointers on screen.
	if !value.pause.open do cursor_draw(value, surface)
}

balance_overlay_draw :: proc(value: ^Client_State, surface: ^fit.Surface) {
	assert(value != nil, "balance_overlay_draw: nil state")
	assert(surface != nil, "balance_overlay_draw: nil surface")
	width := rl.GetScreenWidth()
	height := rl.GetScreenHeight()
	fit.Fill_Rect(surface, fit.Rect{0, 0, width, height}, fit.Color(UI_MODAL_DIM))
	scene_size := min(i32(640), min(width - 80, height - 180))
	panel_width := scene_size + 40
	panel_height := scene_size + 140
	x := (width - panel_width) / 2
	y := (height - panel_height) / 2
	panel := fit.Float_Rect{f32(x), f32(y), f32(panel_width), f32(panel_height)}
	ui_panel_draw(value, surface, panel, .Modal)
	scene := rl.Rectangle{f32(x + 20), f32(y + 58), f32(scene_size), f32(scene_size)}
	rl.draw_gpu_3d_target(&value.balance_target, scene, rl.WHITE)
	fit.Stroke_Rect(
		surface,
		{i32(scene.x), i32(scene.y), i32(scene.width), i32(scene.height)},
		fit.Color(UI_SELECTED_OUTLINE),
	)
	title := "EFFICIENCY TUNING"
	fit.Text(
		surface,
		title,
		x + (panel_width - fit.Text_Width(surface, title, .Title)) / 2,
		y + 18,
		.Title,
		.Heading,
	)
	remaining := max(0, BALANCE_DURATION - value.balance.elapsed)
	status := fmt.tprintf("balance the payload  %.1f seconds", remaining)
	// The countdown is the thing being weighed, so it takes the amber
	// channel; the control hint below stays quiet.
	fit.Text(
		surface,
		status,
		x + (panel_width - fit.Text_Width(surface, status, .Body)) / 2,
		y + scene_size + 68,
		.Body,
		.Tool,
	)
	controls := "WASD or arrows tilt   Escape cancels"
	fit.Text(
		surface,
		controls,
		x + (panel_width - fit.Text_Width(surface, controls, .Body)) / 2,
		y + scene_size + 98,
		.Body,
		.Label,
	)
}

stockpile_amounts :: proc(value: ^Client_State) -> (ore: u64, energy: u64) {
	assert(value != nil, "stockpile_amounts: nil state")
	assert(value.world_ready, "stockpile_amounts: world not ready")
	player_entity := value.world.players[LOCAL_PLAYER]
	stockpile, ok := ecs.get(&value.world.stockpiles, player_entity)
	if !ok do return 0, 0
	return stockpile.amounts[.Ore], stockpile.amounts[.Energy]
}

shutdown :: proc(value: ^Client_State) {
	assert(value != nil, "shutdown: nil state")
	telemetry_shutdown(&value.telemetry)
	delete(value.profile_scenario.name)
	value.profile_scenario = {}
	// A background world build may still be running (quit from the loading
	// screen); wait for it so the worker never writes into freed state, and
	// release a world that finished but was never adopted.
	world_load_finish(&value.world_load)
	if !value.world_ready && value.world_load.ok {
		shared.world_deinit(&value.world)
		value.world_load.ok = false
	}
	// World and graphics teardown is conditional: quitting from the menu
	// leaves both uninitialized and must still exit cleanly.
	if value.world_ready {
		balance_minigame_deinit(&value.balance)
		surfboard_deinit(value)
		entity_queries_deinit(&value.queries)
		wind_visual_deinit(&value.wind_visual)
		terrain_deinit(&value.terrain)
		flora_deinit(&value.flora)
		value.ruins = {}
		structure_assets_deinit(&value.structures)
		fauna_assets_deinit(&value.fauna)
		cosmetics_deinit(&value.cosmetics)
	}
	console_shutdown(&value.console)
	atmosphere_deinit(&value.atmosphere)
	if value.highlight.mesh.id != 0 do rl.destroy_gpu_mesh(&value.highlight.mesh)
	selection_frame_deinit(&value.selection_frame)
	debug_marker_deinit(&value.debug)
	debug_marker_deinit(&value.debug_pinned)
	if value.sockets.mesh.id != 0 do rl.destroy_gpu_mesh(&value.sockets.mesh)
	if value.cube_edges.id != 0 do rl.destroy_gpu_mesh(&value.cube_edges)
	if value.cube.id != 0 do rl.destroy_gpu_mesh(&value.cube)
	if value.sphere.id != 0 do rl.destroy_gpu_mesh(&value.sphere)
	if value.cylinder.id != 0 do rl.destroy_gpu_mesh(&value.cylinder)
	if value.cone.id != 0 do rl.destroy_gpu_mesh(&value.cone)
	if value.wedge.id != 0 do rl.destroy_gpu_mesh(&value.wedge)
	_, _, target_ok := rl.gpu_3d_target_size(&value.target)
	if target_ok do rl.destroy_gpu_3d_target(&value.target)
	_, _, opaque_ok := rl.gpu_3d_target_size(&value.opaque_scene_target)
	if opaque_ok do rl.destroy_gpu_3d_target(&value.opaque_scene_target)
	_, _, portrait_ok := rl.gpu_3d_target_size(&value.portrait_target)
	if portrait_ok do rl.destroy_gpu_3d_target(&value.portrait_target)
	_, _, balance_ok := rl.gpu_3d_target_size(&value.balance_target)
	if balance_ok do rl.destroy_gpu_3d_target(&value.balance_target)
	planetary_prepare_deinit(&value.planetary_prepare)
	node_seat_cache_deinit(&value.node_seats)
	if value.world_ready do shared.world_deinit(&value.world)
	value.graphics_ready = false
	value.world_ready = false
}
