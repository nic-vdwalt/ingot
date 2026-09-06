package main

import shared "../shared"
import "core:math"
import "ingot:asset"
import rl "ingot:gfx"
import procgen "ingot:procgen"

PLANET_WATER_FACE_CELLS :: 128
PLANET_WATER_FACE_EDGE :: PLANET_WATER_FACE_CELLS + 1
PLANET_WATER_FACE_VERTICES :: PLANET_WATER_FACE_EDGE * PLANET_WATER_FACE_EDGE
PLANET_WATER_FACE_INDICES :: PLANET_WATER_FACE_CELLS * PLANET_WATER_FACE_CELLS * 6
// One water vertex covers this many heightfield cells along a face edge.
PLANET_WATER_CELL_STRIDE :: shared.PLANET_FACE_CELLS / PLANET_WATER_FACE_CELLS
#assert(PLANET_WATER_FACE_CELLS > 0)
#assert(PLANET_WATER_FACE_CELLS <= shared.PLANET_FACE_CELLS)
#assert(PLANET_WATER_CELL_STRIDE * PLANET_WATER_FACE_CELLS == shared.PLANET_FACE_CELLS)

Planet_Water_Mesh :: struct {
	face:      procgen.Terrain_Face_V4,
	vertices:  []asset.Vertex,
	indices:   []u32,
	// Whether any vertex on this face carries water; a fully dry face's
	// sheet is skipped by the draw.
	has_water: bool,
}

// planet_water_mesh_generate allocates the face sheet's constant topology
// and runs the first vertex fill. Topology never changes afterwards;
// planet_water_mesh_fill refreshes the vertices when the waterfield moves.
planet_water_mesh_generate :: proc(
	mesh: ^Planet_Water_Mesh,
	world: ^shared.World,
	allocator := context.allocator,
) {
	assert(mesh != nil, "planet_water_mesh_generate: nil mesh")
	assert(world != nil, "planet_water_mesh_generate: nil world")
	mesh.vertices = make([]asset.Vertex, PLANET_WATER_FACE_VERTICES, allocator)
	mesh.indices = make([]u32, PLANET_WATER_FACE_INDICES, allocator)
	planet_water_mesh_fill(mesh, world)
	cursor := 0
	for row in 0 ..< PLANET_WATER_FACE_CELLS {
		for column in 0 ..< PLANET_WATER_FACE_CELLS {
			a := u32(row * PLANET_WATER_FACE_EDGE + column)
			b := a + 1
			c := a + u32(PLANET_WATER_FACE_EDGE)
			d := c + 1
			mesh.indices[cursor + 0] = a
			mesh.indices[cursor + 1] = c
			mesh.indices[cursor + 2] = b
			mesh.indices[cursor + 3] = b
			mesh.indices[cursor + 4] = c
			mesh.indices[cursor + 5] = d
			cursor += 6
		}
	}
}

// planet_water_mesh_fill writes the WATER_SHADER vertex contract for one
// face sheet: position on the actual water surface (ground + depth, dropped
// by WATER_SURFACE_DROP), scalar = shallowness for the deep->shore colour
// mix, uv = {depth, coverage} for absorption and the shoreline discard.
// Dry vertices sit just below ground with zero coverage, so the fragment
// stage discards them instead of flooding the land.
planet_water_mesh_fill :: proc(mesh: ^Planet_Water_Mesh, world: ^shared.World) {
	assert(mesh != nil, "planet_water_mesh_fill: nil mesh")
	assert(world != nil, "planet_water_mesh_fill: nil world")
	assert(len(mesh.vertices) == PLANET_WATER_FACE_VERTICES, "planet_water_mesh_fill: storage")
	mesh.has_water = false
	surfaces: [PLANET_WATER_FACE_VERTICES]f32
	for row in 0 ..< PLANET_WATER_FACE_EDGE {
		for column in 0 ..< PLANET_WATER_FACE_EDGE {
			coord := shared.Planet_Coord {
				mesh.face,
				i32(column * PLANET_WATER_CELL_STRIDE),
				i32(row * PLANET_WATER_CELL_STRIDE),
			}
			sample := water_render_sample_at(world, coord)
			surface := sample.surface
			if sample.coverage > 0 do mesh.has_water = true
			direction := shared.planet_direction(coord)
			if sample.kind == .Ocean {
				planetary_index := shared.planetary_sample_index(direction)
				surface += shared.planet_render_height_from_mm(
					world.planetary.ocean.surface_mm[planetary_index],
				)
			}
			index := row * PLANET_WATER_FACE_EDGE + column
			surfaces[index] = surface
			mesh.vertices[index] = {
				position = shared.planet_position(direction, surface),
				normal   = direction,
				scalar   = sample.shallow,
				uv       = {sample.depth, sample.coverage},
			}
		}
	}
	// Normals from finite differences over the filled surface heights, so
	// shore transitions shade like the flat water grid did. The height
	// differences ride on top of the radial direction.
	for row in 0 ..< PLANET_WATER_FACE_EDGE {
		low_row := max(row - 1, 0)
		high_row := min(row + 1, PLANET_WATER_FACE_CELLS)
		for column in 0 ..< PLANET_WATER_FACE_EDGE {
			low_column := max(column - 1, 0)
			high_column := min(column + 1, PLANET_WATER_FACE_CELLS)
			left := surfaces[row * PLANET_WATER_FACE_EDGE + low_column]
			right := surfaces[row * PLANET_WATER_FACE_EDGE + high_column]
			down := surfaces[low_row * PLANET_WATER_FACE_EDGE + column]
			up := surfaces[high_row * PLANET_WATER_FACE_EDGE + column]
			step := f32(PLANET_WATER_CELL_STRIDE) * shared.GRID_CELL_SIZE
			distance_u := f32(high_column - low_column) * step
			distance_v := f32(high_row - low_row) * step
			slope_u := (right - left) / distance_u
			slope_v := (up - down) / distance_v
			index := row * PLANET_WATER_FACE_EDGE + column
			radial := mesh.vertices[index].normal
			_, east, north := shared.planet_basis(radial)
			normal := radial - east * slope_u - north * slope_v
			length := math.sqrt(normal.x * normal.x + normal.y * normal.y + normal.z * normal.z)
			if length > 0.000001 do mesh.vertices[index].normal = normal / length
		}
	}
}

planet_water_mesh_deinit :: proc(mesh: ^Planet_Water_Mesh, allocator := context.allocator) {
	assert(mesh != nil, "planet_water_mesh_deinit: nil mesh")
	delete(mesh.indices, allocator)
	delete(mesh.vertices, allocator)
	mesh^ = {}
}

Ocean_Wave_Source :: enum u8 {
	Gerstner,
	Spectral,
}

Ocean_Spectral_Init_State :: enum u8 {
	Pending,
	Unsupported,
	Failed,
	Ready,
}

Ocean_Spectral_Failure_Stage :: enum u8 {
	None,
	Capabilities,
	Uniform,
	Shader_Module,
	Bind_Group_Layout,
	Compute_Pipeline,
	Textures,
	Bind_Group,
	Commands,
	Compute_Pass,
	Pass_Setup,
	Dispatch,
	Pass_End,
	Submit,
}

Ocean_Draw_Skip_Reason :: enum u8 {
	None,
	Renderer_Not_Ready,
	No_Water_Draw,
}

Ocean_Draw_Diagnostics :: struct {
	draw_serial:                   u64,
	shader_id:                     u32,
	far_shader_id:                 u32,
	scene_color_id:                u32,
	scene_depth_id:                u32,
	spectral_texture_ids:          [OCEAN_SPECTRAL_CASCADE_COUNT]u32,
	ring_displacement_modes:       [OCEAN_CLIPMAP_RING_COUNT]f32,
	near_draw_count:               u32,
	far_draw_count:                u32,
	breaker_draw_count:            u32,
	spectral_update_serial:        u64,
	spectral_init_state:           Ocean_Spectral_Init_State,
	wave_source:                   Ocean_Wave_Source,
	spectral_ready:                bool,
	spectral_displacement_enabled: bool,
	skip_reason:                   Ocean_Draw_Skip_Reason,
}

Ocean_Pipeline_Status :: struct {
	verdict:                       string,
	custom_shader_created:         bool,
	custom_shader_submitted:       bool,
	spectral_compute_ready:        bool,
	spectral_update_advancing:     bool,
	spectral_textures_bound:       bool,
	wet_mesh_submitted:            bool,
	spectral_displacement_enabled: bool,
	scene_inputs_valid:            bool,
	proven_active:                 bool,
}

Ocean_Spectral_Cascade :: struct {
	length_scale: f32,
	resolution:   u32,
	spectrum:     rl.Gpu_Texture,
	frequency:    [2]rl.Gpu_Texture,
	displacement: rl.Gpu_Texture,
	slope:        rl.Gpu_Texture,
	foam:         rl.Gpu_Texture,
}

OCEAN_CLIPMAP_RING_COUNT :: 3
OCEAN_CLIPMAP_CELLS :: 128
OCEAN_CLIPMAP_EDGE :: OCEAN_CLIPMAP_CELLS + 1
OCEAN_CLIPMAP_VERTICES :: OCEAN_CLIPMAP_EDGE * OCEAN_CLIPMAP_EDGE
OCEAN_CLIPMAP_INDICES_MAX :: OCEAN_CLIPMAP_CELLS * OCEAN_CLIPMAP_CELLS * 6
OCEAN_CLIPMAP_OVERLAP_CELLS :: 2
OCEAN_CLIPMAP_ROWS_PER_UPDATE :: 12

Ocean_Clipmap_Ring :: struct {
	inner_radius:       f32,
	outer_radius:       f32,
	vertices:           []asset.Vertex,
	gpu_vertices:       []rl.Gpu_3D_Vertex,
	indices:            []u32,
	index_count:        int,
	gpu_mesh:           rl.Gpu_Mesh,
	has_water:          bool,
	phase_origin:       [2]f32,
	cpu_macro_deformed: bool,
}

Ocean_Clipmap_Metrics :: struct {
	anchor_changes:        u64,
	generations_started:   u64,
	generations_published: u64,
	rings_filled:          u64,
	rows_filled:           u64,
	vertices_filled:       u64,
	gpu_uploads:           u64,
}

Ocean_Material_Packets :: struct {
	center_height:    [OCEAN_RENDER_PACKET_MAX][4]f32,
	direction_period: [OCEAN_RENDER_PACKET_MAX][4]f32,
	envelope_phase:   [OCEAN_RENDER_PACKET_MAX][4]f32,
}

Ocean_Renderer :: struct {
	rings:                    [OCEAN_CLIPMAP_RING_COUNT]Ocean_Clipmap_Ring,
	staging_rings:            [OCEAN_CLIPMAP_RING_COUNT]Ocean_Clipmap_Ring,
	far_faces:                [shared.PLANET_FACE_COUNT]Planet_Water_Mesh,
	far_gpu_meshes:           [shared.PLANET_FACE_COUNT]rl.Gpu_Mesh,
	weather:                  Ocean_Weather_Cache,
	focus_direction:          [3]f32,
	focus_east:               [3]f32,
	focus_north:              [3]f32,
	anchor_direction:         [3]f32,
	anchor_east:              [3]f32,
	anchor_north:             [3]f32,
	water_revision:           u64,
	weather_tick:             u64,
	wave_source:              Ocean_Wave_Source,
	spectral_init_state:      Ocean_Spectral_Init_State,
	cascades:                 [OCEAN_SPECTRAL_CASCADE_COUNT]Ocean_Spectral_Cascade,
	spectral:                 Ocean_Spectral_Runtime,
	spectral_pending_dt:      f32,
	spectral_update_serial:   u64,
	spectral_failure_stage:   Ocean_Spectral_Failure_Stage,
	spectral_failure_cascade: i32,
	spectral_failure_count:   u32,
	draw_diagnostics:         Ocean_Draw_Diagnostics,
	breakers:                 Ocean_Breaker_Renderer,
	nearshore:                Ocean_Nearshore,
	fixture_render:           Ocean_Fixture_Renderer,
	macro:                    Ocean_Macro_Wave_Field,
	render_query:             Ocean_Macro_Wave_Query,
	debug_pulse:              Ocean_Render_Packet,
	debug_pulse_active:       bool,
	fixture_saved_macro:      Ocean_Macro_Wave_Field,
	fixture_saved_spectral_dt: f32,
	fixture_clock_saved:      bool,
	surf_dropped_time:        f32,
	surf_events:              Ocean_Surf_Events,
	surf_ledger:              Ocean_Surf_Time_Ledger,
	foam_history:             rl.Gpu_History_Texture,
	underwater:               Water_Underwater_State,
	geometry_dirty:           bool,
	pending_rings:            [OCEAN_CLIPMAP_RING_COUNT]bool,
	staging_rows:             [OCEAN_CLIPMAP_RING_COUNT]int,
	staging_anchor_direction: [3]f32,
	staging_anchor_east:      [3]f32,
	staging_anchor_north:     [3]f32,
	staging_anchor_pending:   bool,
	pending_anchor_radial:    [3]f32,
	pending_anchor_request:   bool,
	staging_water_revision:   u64,
	staging_generation:       u64,
	published_generation:     u64,
	staging_active:           bool,
	pending_far_faces:        [shared.PLANET_FACE_COUNT]bool,
	last_geometry_units:      u32,
	total_geometry_units:     u64,
	clipmap_metrics:          Ocean_Clipmap_Metrics,
	far_faces_active:         bool,
	render_mode_initialized:  bool,
	ready:                    bool,
}

Water_Underwater_State :: struct {
	active:           bool,
	target:           bool,
	kind:             Water_Render_Kind,
	surface_radius:   f32,
	submersion:       f32,
	flow:             [2]f32,
	absorption:       [3]f32,
	scattering:       [3]f32,
	turbidity:        f32,
	blend:            f32,
	transition_count: u64,
}

water_underwater_target :: proc(
	active: bool,
	signed_height, enter_depth, exit_height: f32,
) -> bool {
	if active do return signed_height < exit_height
	return signed_height <= -enter_depth
}

water_underwater_blend_next :: proc(current: f32, active: bool, frame_dt, transition: f32) -> f32 {
	assert(frame_dt >= 0 && transition > 0, "water underwater blend: invalid time")
	target := f32(1) if active else f32(0)
	step := clamp(frame_dt / transition, f32(0), f32(1))
	return current + (target - current) * step
}

water_underwater_medium_params :: proc(
	state: Water_Underwater_State,
) -> (
	primary, secondary: [4]f32,
) {
	primary = {state.absorption[0], state.absorption[1], state.absorption[2], state.blend}
	secondary = {state.scattering[0], state.scattering[1], state.scattering[2], state.turbidity}
	return
}

water_underwater_state_update :: proc(
	renderer: ^Ocean_Renderer,
	world: ^shared.World,
	camera: rl.Camera3D,
	settings: Ocean_Visual_Settings,
	frame_dt: f32,
	advance_time: bool,
) {
	assert(renderer != nil && world != nil, "water underwater state: nil input")
	state := &renderer.underwater
	camera_length := math.sqrt(
		camera.position.x * camera.position.x +
		camera.position.y * camera.position.y +
		camera.position.z * camera.position.z,
	)
	if camera_length <= 0.0001 do return
	radial := camera.position / camera_length
	coord := shared.planet_coord_from_direction(radial)
	sample := water_render_sample_at(world, coord)
	state.kind = sample.kind
	state.flow = sample.flow_direction * sample.flow_speed
	medium_index := 0
	if sample.kind == .Lake do medium_index = 1
	if sample.kind == .River do medium_index = 2
	medium := settings.water_medium[medium_index]
	state.absorption = sample.optical.absorption * medium.absorption_scale
	state.scattering = sample.optical.scattering * medium.scatter_scale
	state.turbidity = clamp(sample.optical.turbidity * medium.turbidity_scale, f32(0), f32(1))
	surface_height := sample.surface
	if sample.kind == .Ocean {
		planet_index := shared.planetary_sample_index(radial)
		surface_height += shared.planet_render_height_from_mm(
			world.planetary.ocean.surface_mm[planet_index],
		)
		base_surface := shared.planet_position(radial, surface_height)
		wave := ocean_wave_field_sample(
			renderer,
			world,
			&renderer.render_query,
			base_surface,
			sample.depth,
			sample.coverage,
		)
		surface_height +=
			wave.displacement.x * radial.x +
			wave.displacement.y * radial.y +
			wave.displacement.z * radial.z
	}
	state.surface_radius = shared.PLANET_RADIUS + surface_height
	signed_height := camera_length - state.surface_radius
	state.submersion = max(-signed_height, f32(0))
	if sample.kind == .Ocean {
		planet_index := shared.planetary_sample_index(radial)
		depth_blend := clamp(state.submersion / max(sample.depth, f32(0.01)), f32(0), f32(1))
		surface_flow := [2]f32 {
			f32(world.planetary.ocean.transport_east[planet_index]),
			f32(world.planetary.ocean.transport_north[planet_index]),
		}
		deep_flow := [2]f32 {
			f32(world.planetary.ocean.deep_transport_east[planet_index]),
			f32(world.planetary.ocean.deep_transport_north[planet_index]),
		}
		state.flow =
			(surface_flow + (deep_flow - surface_flow) * depth_blend) /
			f32(shared.PLANET_VELOCITY_SCALE)
	}
	wet := sample.coverage > 0 && sample.kind != .None
	next_target :=
		wet &&
		water_underwater_target(
			state.target,
			signed_height,
			settings.underwater_enter_depth,
			settings.underwater_exit_height,
		)
	if next_target != state.target do state.transition_count += 1
	state.target = next_target
	elapsed := frame_dt if advance_time else f32(0)
	state.blend = water_underwater_blend_next(
		state.blend,
		state.target,
		elapsed,
		settings.underwater_transition,
	)
	state.active = state.blend > 0.001
}

ocean_clipmap_direction :: proc(radial, east, north: [3]f32, x, y: f32) -> [3]f32 {
	distance := math.sqrt(x * x + y * y)
	if distance <= 0.000001 do return radial
	tangent := (east * x + north * y) / distance
	angle := distance / shared.PLANET_RADIUS
	return radial * math.cos(angle) + tangent * math.sin(angle)
}

ocean_clipmap_anchor_update :: proc(
	renderer: ^Ocean_Renderer,
	radial: [3]f32,
	cell_size: f32,
) -> bool {
	assert(renderer != nil, "ocean_clipmap_anchor_update: nil renderer")
	if renderer.staging_active {
		renderer.pending_anchor_radial = radial
		renderer.pending_anchor_request = true
		return false
	}
	requested_radial := radial
	if renderer.pending_anchor_request {
		requested_radial = renderer.pending_anchor_radial
		renderer.pending_anchor_request = false
	}
	if !renderer.ready {
		renderer.staging_anchor_direction = requested_radial
		_, renderer.staging_anchor_east, renderer.staging_anchor_north = shared.planet_basis(
			requested_radial,
		)
		renderer.staging_anchor_pending = true
		return true
	}
	dot := clamp(
		requested_radial.x * renderer.anchor_direction.x +
		requested_radial.y * renderer.anchor_direction.y +
		requested_radial.z * renderer.anchor_direction.z,
		-1,
		1,
	)
	tangent := requested_radial - renderer.anchor_direction * dot
	x :=
		(tangent.x * renderer.anchor_east.x +
			tangent.y * renderer.anchor_east.y +
			tangent.z * renderer.anchor_east.z) *
		f32(shared.PLANET_RADIUS)
	y :=
		(tangent.x * renderer.anchor_north.x +
			tangent.y * renderer.anchor_north.y +
			tangent.z * renderer.anchor_north.z) *
		f32(shared.PLANET_RADIUS)
	steps_x := math.round(x / cell_size)
	steps_y := math.round(y / cell_size)
	if steps_x == 0 && steps_y == 0 do return false
	renderer.clipmap_metrics.anchor_changes += 1
	renderer.staging_anchor_direction = ocean_clipmap_direction(
		renderer.anchor_direction,
		renderer.anchor_east,
		renderer.anchor_north,
		steps_x * cell_size,
		steps_y * cell_size,
	)
	_, renderer.staging_anchor_east, renderer.staging_anchor_north = shared.planet_basis(
		renderer.staging_anchor_direction,
	)
	renderer.staging_anchor_pending = true
	return true
}

ocean_ring_cell_active :: proc(ring: Ocean_Clipmap_Ring, column, row: int) -> bool {
	if ring.inner_radius <= 0 do return true
	cell_size := ring.outer_radius * 2 / f32(OCEAN_CLIPMAP_CELLS)
	overlap := cell_size * OCEAN_CLIPMAP_OVERLAP_CELLS
	x := (f32(column) + 0.5) / f32(OCEAN_CLIPMAP_CELLS) * 2 * ring.outer_radius - ring.outer_radius
	y := (f32(row) + 0.5) / f32(OCEAN_CLIPMAP_CELLS) * 2 * ring.outer_radius - ring.outer_radius
	return max(abs(x), abs(y)) >= ring.inner_radius - overlap
}

ocean_ring_indices_fill :: proc(ring: ^Ocean_Clipmap_Ring) {
	assert(ring != nil, "ocean_ring_indices_fill: nil ring")
	assert(len(ring.indices) == OCEAN_CLIPMAP_INDICES_MAX, "ocean_ring_indices_fill: capacity")
	cursor := 0
	for row in 0 ..< OCEAN_CLIPMAP_CELLS {
		for column in 0 ..< OCEAN_CLIPMAP_CELLS {
			if !ocean_ring_cell_active(ring^, column, row) do continue
			a := u32(row * OCEAN_CLIPMAP_EDGE + column)
			b := a + 1
			c := a + u32(OCEAN_CLIPMAP_EDGE)
			d := c + 1
			ring.indices[cursor + 0] = a
			ring.indices[cursor + 1] = c
			ring.indices[cursor + 2] = b
			ring.indices[cursor + 3] = b
			ring.indices[cursor + 4] = c
			ring.indices[cursor + 5] = d
			cursor += 6
		}
	}
	ring.index_count = cursor
}

ocean_ring_fill_rows :: proc(
	ring: ^Ocean_Clipmap_Ring,
	renderer: ^Ocean_Renderer,
	world: ^shared.World,
	ring_index, row_begin, row_end: int,
	radial, east, north: [3]f32,
) {
	assert(ring != nil && renderer != nil && world != nil, "ocean_ring_fill_rows: nil input")
	assert(
		ring_index >= 0 && ring_index < OCEAN_CLIPMAP_RING_COUNT,
		"ocean_ring_fill_rows: ring index",
	)
	assert(
		row_begin >= 0 && row_begin < row_end && row_end <= OCEAN_CLIPMAP_EDGE,
		"ocean_ring_fill_rows: range",
	)
	if row_begin == 0 {
		ring.has_water = false
		ring.cpu_macro_deformed =
			ring_index == 0 && !(renderer.wave_source == .Spectral && renderer.spectral.ready)
	}
	for row in row_begin ..< row_end {
		for column in 0 ..< OCEAN_CLIPMAP_EDGE {
			x := (f32(column) / f32(OCEAN_CLIPMAP_CELLS) * 2 - 1) * ring.outer_radius
			y := (f32(row) / f32(OCEAN_CLIPMAP_CELLS) * 2 - 1) * ring.outer_radius
			direction := ocean_clipmap_direction(radial, east, north, x, y)
			face, u, v := shared.planet_locate(direction)
			coord := shared.Planet_Coord{face, i32(u), i32(v)}
			sample := water_render_sample_at(world, coord)
			surface := sample.surface
			if sample.coverage > 0 do ring.has_water = true
			if sample.kind == .Ocean {
				planetary_index := shared.planetary_sample_index(direction)
				surface += shared.planet_render_height_from_mm(
					world.planetary.ocean.surface_mm[planetary_index],
				)
			}
			index := row * OCEAN_CLIPMAP_EDGE + column
			position := shared.planet_position(direction, surface)
			normal := direction
			if ring.cpu_macro_deformed && sample.coverage > 0 && sample.kind == .Ocean {
				wave := ocean_wave_field_sample(
					renderer,
					world,
					&renderer.render_query,
					position,
					sample.depth,
					sample.coverage,
				)
				radial_displacement :=
					wave.displacement.x * direction.x +
					wave.displacement.y * direction.y +
					wave.displacement.z * direction.z
				position += direction * radial_displacement
				normal = wave.normal
			}
			vertex := asset.Vertex {
				position = position,
				normal   = normal,
				scalar   = sample.shallow,
				uv       = {sample.depth, sample.coverage},
			}
			ring.vertices[index] = vertex
			ring.gpu_vertices[index] = {
				position = vertex.position,
				normal   = vertex.normal,
				scalar   = vertex.scalar,
				uv       = vertex.uv,
			}
		}
	}
	rows := row_end - row_begin
	renderer.clipmap_metrics.rows_filled += u64(rows)
	renderer.clipmap_metrics.vertices_filled += u64(rows * OCEAN_CLIPMAP_EDGE)
	if row_end == OCEAN_CLIPMAP_EDGE do renderer.clipmap_metrics.rings_filled += 1
}

ocean_ring_fill :: proc(
	ring: ^Ocean_Clipmap_Ring,
	renderer: ^Ocean_Renderer,
	world: ^shared.World,
	ring_index: int,
	radial, east, north: [3]f32,
) {
	ocean_ring_fill_rows(
		ring,
		renderer,
		world,
		ring_index,
		0,
		OCEAN_CLIPMAP_EDGE,
		radial,
		east,
		north,
	)
}

ocean_far_gpu_update :: proc(face: ^Planet_Water_Mesh, mesh: ^rl.Gpu_Mesh) -> bool {
	assert(face != nil && mesh != nil, "ocean_far_gpu_update: nil input")
	gpu_vertices := make([]rl.Gpu_3D_Vertex, len(face.vertices), context.temp_allocator)
	for vertex, index in face.vertices {
		gpu_vertices[index] = {
			position = vertex.position,
			normal   = vertex.normal,
			scalar   = vertex.scalar,
			uv       = vertex.uv,
		}
	}
	if mesh.id == 0 {
		created, ok := rl.create_gpu_mesh(gpu_vertices, face.indices, .Triangles)
		if !ok do return false
		mesh^ = created
		return true
	}
	return rl.update_gpu_mesh_vertices(mesh^, gpu_vertices)
}

ocean_renderer_init :: proc(
	renderer: ^Ocean_Renderer,
	world: ^shared.World,
	settings: Ocean_Visual_Settings,
	allocator := context.allocator,
) {
	assert(renderer != nil && world != nil, "ocean_renderer_init: nil input")
	renderer^ = {}
	for ring_index in 0 ..< OCEAN_CLIPMAP_RING_COUNT {
		for bank_index in 0 ..< 2 {
			ring := &renderer.rings[ring_index]
			if bank_index == 1 do ring = &renderer.staging_rings[ring_index]
			ring.inner_radius = 0 if ring_index == 0 else settings.ring_radius[ring_index - 1]
			ring.outer_radius = settings.ring_radius[ring_index]
			ring.vertices = make([]asset.Vertex, OCEAN_CLIPMAP_VERTICES, allocator)
			ring.gpu_vertices = make([]rl.Gpu_3D_Vertex, OCEAN_CLIPMAP_VERTICES, allocator)
			ring.indices = make([]u32, OCEAN_CLIPMAP_INDICES_MAX, allocator)
			ocean_ring_indices_fill(ring)
		}
	}
	for &face, face_index in renderer.far_faces {
		face.face = procgen.Terrain_Face_V4(face_index)
		planet_water_mesh_generate(&face, world, allocator)
		ocean_far_gpu_update(&face, &renderer.far_gpu_meshes[face_index])
	}
	weather_ocean_cache_update(&renderer.weather, world)
	renderer.spectral_init_state = .Pending
}

ocean_ring_geometry_changed :: proc(
	ring_index: int,
	ready, geometry_dirty, water_changed, wave_advanced, anchor_changed, spectral_ready: bool,
) -> bool {
	assert(
		ring_index >= 0 && ring_index < OCEAN_CLIPMAP_RING_COUNT,
		"ocean_ring_geometry_changed: ring index",
	)
	return(
		!ready ||
		geometry_dirty ||
		water_changed ||
		anchor_changed ||
		(ring_index == 0 && wave_advanced && !spectral_ready) \
	)
}

ocean_ring_gpu_update :: proc(ring: ^Ocean_Clipmap_Ring) -> bool {
	assert(ring != nil, "ocean_ring_gpu_update: nil ring")
	assert(len(ring.gpu_vertices) == len(ring.vertices), "ocean_ring_gpu_update: storage")
	if ring.gpu_mesh.id == 0 {
		mesh, ok := rl.create_gpu_mesh(
			ring.gpu_vertices,
			ring.indices[:ring.index_count],
			.Triangles,
		)
		if !ok do return false
		ring.gpu_mesh = mesh
		return true
	}
	return rl.update_gpu_mesh_vertices(ring.gpu_mesh, ring.gpu_vertices)
}

ocean_geometry_unit_limit :: proc(budget_available: bool) -> u32 {
	return 1 if budget_available else 0
}

ocean_clipmap_row_budget :: proc(budget_available: bool) -> int {
	return OCEAN_CLIPMAP_ROWS_PER_UPDATE if budget_available else 0
}

ocean_far_update_admitted :: proc(geometry_units: u32, budget_available: bool) -> bool {
	return geometry_units < ocean_geometry_unit_limit(budget_available)
}

ocean_ring_generation_begin :: proc(renderer: ^Ocean_Renderer, water_revision: u64) {
	assert(renderer != nil, "ocean ring generation: nil renderer")
	assert(!renderer.staging_active, "ocean ring generation: already active")
	renderer.staging_generation += 1
	renderer.clipmap_metrics.generations_started += 1
	if !renderer.staging_anchor_pending {
		renderer.staging_anchor_direction = renderer.anchor_direction
		renderer.staging_anchor_east = renderer.anchor_east
		renderer.staging_anchor_north = renderer.anchor_north
	}
	renderer.staging_anchor_pending = false
	renderer.staging_water_revision = water_revision
	for &pending, ring_index in renderer.pending_rings {
		pending = true
		renderer.staging_rows[ring_index] = 0
	}
	renderer.staging_active = true
}

ocean_ring_generation_complete :: proc(renderer: ^Ocean_Renderer) -> bool {
	if renderer == nil || !renderer.staging_active do return false
	for pending in renderer.pending_rings {
		if pending do return false
	}
	return true
}

ocean_ring_generation_publish :: proc(renderer: ^Ocean_Renderer) {
	assert(ocean_ring_generation_complete(renderer), "ocean ring generation: incomplete")
	renderer.rings, renderer.staging_rings = renderer.staging_rings, renderer.rings
	renderer.anchor_direction = renderer.staging_anchor_direction
	renderer.anchor_east = renderer.staging_anchor_east
	renderer.anchor_north = renderer.staging_anchor_north
	renderer.water_revision = renderer.staging_water_revision
	renderer.published_generation = renderer.staging_generation
	renderer.staging_active = false
	renderer.ready = true
	renderer.clipmap_metrics.generations_published += 1
}

ocean_clipmap_metrics_take :: proc(renderer: ^Ocean_Renderer) -> Ocean_Clipmap_Metrics {
	assert(renderer != nil, "ocean clipmap metrics: nil renderer")
	result := renderer.clipmap_metrics
	renderer.clipmap_metrics = {}
	return result
}

ocean_surf_advance :: proc(renderer: ^Ocean_Renderer, world: ^shared.World, focus: [3]f32, frame_dt: f32, tick_client: ^Client_State = nil, completed: proc(^Client_State, rawptr) = nil, observer: rawptr = nil) -> int {
	assert(renderer != nil && world != nil)
	if tick_client != nil {
		assert(renderer == &tick_client.terrain.ocean && world == &tick_client.world)
	}
	elapsed := frame_dt
	if !(elapsed > 0) || math.is_inf(elapsed, 0) do return 0
	radial := renderer.nearshore.focus if renderer.nearshore.fixture_active else focus
	if renderer.nearshore.fixture_active {
		if math.is_nan(debug_ocean_fixture_time_scale) || math.is_inf(debug_ocean_fixture_time_scale, 0) do return 0
		elapsed *= clamp(debug_ocean_fixture_time_scale, f32(0), f32(1))
	}
	if !(elapsed > 0) do return 0
	if renderer.nearshore.fixture_active do debug_ocean_fixture_query_update(renderer)
	accepted_elapsed := min(elapsed, f32(0.1))
	if renderer.nearshore.fixture_active {
		renderer.surf_ledger.eligible_scaled += f64(elapsed)
		renderer.surf_ledger.clip_rejected += f64(elapsed - accepted_elapsed)
	}
	renderer.surf_dropped_time += elapsed - accepted_elapsed
	renderer.macro.accumulator += accepted_elapsed
	if renderer.nearshore.fixture_active && renderer.macro.accumulator > 0.5 {
		renderer.surf_ledger.cap_rejected += f64(renderer.macro.accumulator - 0.5)
		renderer.surf_dropped_time += renderer.macro.accumulator - 0.5
		renderer.macro.accumulator = 0.5
	}
	fixed_steps := 0
	for renderer.macro.accumulator >= OCEAN_WAVE_FIXED_DT &&
	    fixed_steps < OCEAN_WAVE_MAX_STEPS_PER_FRAME {
		if renderer.nearshore.fixture_active {
			if !renderer.nearshore.tick_pending && tick_client != nil {
				ocean_surf_events_apply_due(tick_client)
			}
			water_field := renderer.macro
			water_field.time += OCEAN_WAVE_FIXED_DT
			nearshore := &renderer.nearshore
			water_dt := f32(0) if nearshore.tick_pending else OCEAN_WAVE_FIXED_DT
			if nearshore.tick_pending {
				for index in 0 ..< OCEAN_NEARSHORE_COUNT {
					nearshore.state[index], nearshore.pending_state[index] = nearshore.pending_state[index], nearshore.state[index]
					nearshore.foam[index], nearshore.pending_foam[index] = nearshore.pending_foam[index], nearshore.foam[index]
				}
			} else {
				nearshore.pending_state = nearshore.state
				nearshore.pending_foam = nearshore.foam
				if tick_client != nil do nearshore.pending_control = tick_client.surfboard.control
			}
			ocean_nearshore_fixed_step(
				nearshore, world, radial, &water_field,
				&renderer.render_query, water_dt,
			)
			nearshore.tick_pending = nearshore.time_backlog > 0
			if nearshore.tick_pending {
				for index in 0 ..< OCEAN_NEARSHORE_COUNT {
					nearshore.state[index], nearshore.pending_state[index] = nearshore.pending_state[index], nearshore.state[index]
					nearshore.foam[index], nearshore.pending_foam[index] = nearshore.pending_foam[index], nearshore.foam[index]
				}
				break
			}
		}
		renderer.macro.previous_time = renderer.macro.time
		renderer.macro.time += OCEAN_WAVE_FIXED_DT
		renderer.macro.accumulator -= OCEAN_WAVE_FIXED_DT
		renderer.macro.step_count += 1
		pulse_was_active := renderer.debug_pulse_active
		debug_ocean_test_pulse_update(&renderer.debug_pulse, &renderer.debug_pulse_active, OCEAN_WAVE_FIXED_DT)
		if pulse_was_active && !renderer.debug_pulse_active {
			if renderer.nearshore.fixture_active {
				debug_ocean_fixture_query_update(renderer)
			} else {
				_ = ocean_macro_query_update(&renderer.render_query, world, radial, renderer.macro.time)
			}
		}
		if !renderer.nearshore.fixture_active {
			ocean_nearshore_fixed_step(
				&renderer.nearshore, world, radial, &renderer.macro,
				&renderer.render_query, OCEAN_WAVE_FIXED_DT,
			)
		}
		if renderer.nearshore.fixture_active {
			ocean_breakers_advance(
				&renderer.breakers, world, &renderer.nearshore,
				renderer.render_query.packets[:renderer.render_query.packet_count],
				radial, renderer.macro.time, OCEAN_WAVE_FIXED_DT,
			)
		}
		if renderer.nearshore.fixture_active && tick_client != nil {
			frame_control := tick_client.surfboard.control
			tick_client.surfboard.control = renderer.nearshore.pending_control
			surfboard_fixture_tick(tick_client)
			tick_client.surfboard.control = frame_control
		}
		fixed_steps += 1
		if completed != nil && tick_client != nil do completed(tick_client, observer)
	}
	renderer.spectral_pending_dt += f32(fixed_steps) * OCEAN_WAVE_FIXED_DT
	return fixed_steps
}

ocean_renderer_update :: proc(
	renderer: ^Ocean_Renderer,
	world: ^shared.World,
	camera: rl.Camera3D,
	focus: [3]f32,
	tick: u64,
	settings: Ocean_Visual_Settings,
	frame_dt := f32(0),
	advance_time := true,
	budget_available := true,
) {
	assert(renderer != nil && world != nil, "ocean_renderer_update: nil input")
	elapsed := frame_dt if advance_time else f32(0)
	camera_length := math.sqrt(
		camera.position.x * camera.position.x +
		camera.position.y * camera.position.y +
		camera.position.z * camera.position.z,
	)
	if camera_length <= 0 do return
	focus_length := math.sqrt(focus.x * focus.x + focus.y * focus.y + focus.z * focus.z)
	radial := camera.position / camera_length
	if focus_length > 0.000001 do radial = focus / focus_length
	_, east, north := shared.planet_basis(radial)
	renderer.focus_east = east
	renderer.focus_north = north
	spectrum := renderer.macro.spectrum
	if !renderer.nearshore.fixture_active {
		summary := weather_ocean_sample(&renderer.weather, radial)
		spectrum = weather_ocean_render_spectrum(world, radial, summary)
		renderer.macro.spectrum = spectrum
		_ = ocean_macro_query_update(
			&renderer.render_query,
			world,
			shared.planet_position(radial, 0),
			renderer.macro.time,
		)
		ocean_macro_query_debug_packet_merge(
			&renderer.render_query,
			renderer.debug_pulse,
			renderer.debug_pulse_active,
		)
	}
	water_underwater_state_update(renderer, world, camera, settings, frame_dt, advance_time)
	ocean_spectral_apply_state(renderer, spectrum)
	fixed_steps := 0
	if !renderer.nearshore.fixture_active {
		fixed_steps = ocean_surf_advance(renderer, world, radial, elapsed)
	}
	packets := renderer.render_query.packets[:renderer.render_query.packet_count]
	advanced := f32(fixed_steps) * OCEAN_WAVE_FIXED_DT
	altitude := max(camera_length - f32(shared.PLANET_RADIUS), 0)
	renderer.far_faces_active = ocean_far_faces_next(
		renderer.far_faces_active,
		renderer.render_mode_initialized,
		altitude,
		settings.middle_altitude_limit,
	)
	renderer.render_mode_initialized = true
	if renderer.nearshore.fixture_active {
		ocean_breakers_upload(&renderer.breakers)
	} else if !renderer.far_faces_active {
		ocean_breakers_update(
			&renderer.breakers,
			world,
			&renderer.nearshore,
			packets,
			renderer.nearshore.focus if renderer.nearshore.fixture_active else radial,
			renderer.macro.time,
			advanced,
		)
	}
	anchor_cell_size := settings.ring_radius[0] * 2 / f32(OCEAN_CLIPMAP_CELLS)
	anchor_changed := ocean_clipmap_anchor_update(renderer, radial, anchor_cell_size)
	water_changed :=
		renderer.water_revision != world.waterfield.revision &&
		(!renderer.staging_active || renderer.staging_water_revision != world.waterfield.revision)
	if renderer.staging_active && renderer.staging_water_revision != world.waterfield.revision {
		renderer.staging_water_revision = world.waterfield.revision
		for &pending, ring_index in renderer.pending_rings {
			pending = true
			renderer.staging_rows[ring_index] = 0
		}
	}
	wave_advanced := fixed_steps > 0
	spectral_ready := renderer.wave_source == .Spectral && renderer.spectral.ready
	changed :=
		(!renderer.ready && !renderer.staging_active) ||
		renderer.geometry_dirty ||
		water_changed ||
		anchor_changed ||
		(wave_advanced && !spectral_ready)
	if changed && !renderer.staging_active {
		if !renderer.ready || renderer.geometry_dirty {
			for &ring, ring_index in renderer.staging_rings {
				ring.inner_radius = 0 if ring_index == 0 else settings.ring_radius[ring_index - 1]
				ring.outer_radius = settings.ring_radius[ring_index]
				ocean_ring_indices_fill(&ring)
			}
		}
		ocean_ring_generation_begin(renderer, world.waterfield.revision)
		if water_changed {
			for face_index in 0 ..< shared.PLANET_FACE_COUNT {
				renderer.pending_far_faces[face_index] = true
			}
		}
		if renderer.geometry_dirty do renderer.geometry_dirty = false
	}
	renderer.focus_direction = radial
	renderer.focus_east = east
	renderer.focus_north = north
	renderer.last_geometry_units = 0
	row_budget := ocean_clipmap_row_budget(budget_available)
	for &pending, ring_index in renderer.pending_rings {
		if !pending || row_budget <= 0 do continue
		ring := &renderer.staging_rings[ring_index]
		row_begin := renderer.staging_rows[ring_index]
		if row_begin < OCEAN_CLIPMAP_EDGE {
			row_end := min(row_begin + row_budget, OCEAN_CLIPMAP_EDGE)
			ocean_ring_fill_rows(
				ring,
				renderer,
				world,
				ring_index,
				row_begin,
				row_end,
				renderer.staging_anchor_direction,
				renderer.staging_anchor_east,
				renderer.staging_anchor_north,
			)
			renderer.staging_rows[ring_index] = row_end
			renderer.last_geometry_units = 1
		}
		if renderer.staging_rows[ring_index] == OCEAN_CLIPMAP_EDGE && ocean_ring_gpu_update(ring) {
			pending = false
			renderer.last_geometry_units = 1
			renderer.total_geometry_units += 1
			renderer.clipmap_metrics.gpu_uploads += 1
		}
		break
	}
	if ocean_ring_generation_complete(renderer) do ocean_ring_generation_publish(renderer)
	if ocean_far_update_admitted(renderer.last_geometry_units, budget_available) {
		for &pending, face_index in renderer.pending_far_faces {
			if !pending do continue
			planet_water_mesh_fill(&renderer.far_faces[face_index], world)
			if ocean_far_gpu_update(
				&renderer.far_faces[face_index],
				&renderer.far_gpu_meshes[face_index],
			) {
				pending = false
				renderer.last_geometry_units = 1
				renderer.total_geometry_units += 1
			}
			break
		}
	}
	renderer.weather_tick = tick
}

OCEAN_RENDER_MODE_HYSTERESIS_RATIO :: f32(0.08)
OCEAN_RENDER_MODE_HYSTERESIS_MIN :: f32(24)

ocean_uses_far_faces :: proc(altitude, altitude_limit: f32) -> bool {
	return altitude > altitude_limit
}

ocean_far_faces_next :: proc(active, initialized: bool, altitude, altitude_limit: f32) -> bool {
	if !initialized do return ocean_uses_far_faces(altitude, altitude_limit)
	margin := max(
		altitude_limit * OCEAN_RENDER_MODE_HYSTERESIS_RATIO,
		OCEAN_RENDER_MODE_HYSTERESIS_MIN,
	)
	if active do return altitude >= altitude_limit - margin
	return altitude > altitude_limit + margin
}

ocean_draw_layers :: proc(far_only: bool) -> (far_faces, clipmap_overlays: bool) {
	return true, !far_only
}

ocean_water_material_style :: proc() -> rl.Gpu_Material_Style {
	return .Transparent
}

ocean_background_material :: proc(
	near_material: rl.Gpu_Material,
	far_shader: rl.Gpu_3D_Shader,
	far_only: bool,
) -> rl.Gpu_Material {
	material := near_material
	material.custom_params_7.z = 1
	if far_only {
		material.color.a = 255
		material.color_high.a = 255
		material.scene_color_texture = {}
		material.scene_depth_texture = {}
		material.shader = far_shader
	}
	return material
}

ocean_pipeline_status :: proc(renderer: ^Ocean_Renderer, shader_id: u32) -> Ocean_Pipeline_Status {
	assert(renderer != nil, "ocean_pipeline_status: nil renderer")
	draw := renderer.draw_diagnostics
	result := Ocean_Pipeline_Status {
		custom_shader_created         = shader_id != 0,
		custom_shader_submitted       = shader_id != 0 && draw.shader_id == shader_id,
		spectral_compute_ready        = renderer.spectral_init_state ==
			.Ready && renderer.wave_source == .Spectral && renderer.spectral.ready,
		spectral_update_advancing     = renderer.spectral_update_serial >
			0 && draw.spectral_update_serial == renderer.spectral_update_serial,
		wet_mesh_submitted            = draw.near_draw_count + draw.far_draw_count > 0,
		spectral_displacement_enabled = draw.spectral_displacement_enabled,
		scene_inputs_valid            = draw.scene_color_id != 0 && draw.scene_depth_id != 0,
	}
	result.spectral_textures_bound = true
	for id in draw.spectral_texture_ids do result.spectral_textures_bound = result.spectral_textures_bound && id != 0
	result.proven_active =
		result.custom_shader_created &&
		result.custom_shader_submitted &&
		result.spectral_compute_ready &&
		result.spectral_update_advancing &&
		result.spectral_textures_bound &&
		result.wet_mesh_submitted &&
		result.spectral_displacement_enabled &&
		result.scene_inputs_valid
	switch renderer.spectral_init_state {
	case .Pending:
		result.verdict = "PENDING"
	case .Unsupported:
		result.verdict = "UNSUPPORTED"
	case .Failed:
		result.verdict = "FAILED"
	case .Ready:
		if result.proven_active {
			result.verdict = "PROVEN SPECTRAL"
		} else if renderer.wave_source == .Gerstner {
			result.verdict = "GERSTNER FALLBACK"
		} else {
			result.verdict = "NO WATER DRAW"
		}
	}
	return result
}

ocean_ring_displacement_mode :: proc(cpu_macro_deformed: bool) -> f32 {
	return 0 if cpu_macro_deformed else 1
}

ocean_material_packets :: proc(renderer: ^Ocean_Renderer) -> Ocean_Material_Packets {
	assert(renderer != nil, "ocean_material_packets: nil renderer")
	result: Ocean_Material_Packets
	count := min(renderer.render_query.packet_count, OCEAN_RENDER_PACKET_MAX)
	for packet, index in renderer.render_query.packets[:count] {
		result.center_height[index] = {
			packet.center.x,
			packet.center.y,
			packet.center.z,
			packet.significant_height,
		}
		result.direction_period[index] = {
			packet.direction.x,
			packet.direction.y,
			packet.direction.z,
			packet.period,
		}
		if packet.radial {
			center_radial, center_valid := ocean_wave_normalize(packet.center)
			if center_valid do result.direction_period[index].xyz = center_radial * packet.front_speed
			result.envelope_phase[index] = {
				packet.front_radius,
				packet.band,
				packet.phase_epoch,
				-ocean_packet_wave_number(packet) if packet.id == OCEAN_DEBUG_TEST_PULSE_ID else packet.breaking,
			}
			continue
		}
		if packet.id == OCEAN_DEBUG_TEST_PULSE_ID {
			direction, valid := ocean_wave_normalize(packet.direction)
			if valid do result.direction_period[index].xyz = direction * ocean_packet_wave_number(packet)
		}
		result.envelope_phase[index] = {
			packet.envelope_length,
			packet.envelope_width,
			packet.phase_epoch,
			-packet.front_speed if packet.id == OCEAN_DEBUG_TEST_PULSE_ID else packet.breaking,
		}
	}
	return result
}

ocean_material_packet_count :: proc(renderer: ^Ocean_Renderer) -> int {
	assert(renderer != nil, "ocean material packet count: nil renderer")
	return min(renderer.render_query.packet_count, OCEAN_RENDER_PACKET_MAX)
}

// ocean_material_mode_word packs the packet count (low 3 bits) and the proof
// view (bits 3+) into custom_params_7.w. custom_params_5/6 belong to ingot's
// underwater pass, which overwrites them at draw, so the proof view cannot
// travel there.
OCEAN_MATERIAL_PACKET_BITS :: 3

ocean_material_mode_word :: proc(packet_count: int, proof_view: Ocean_Proof_View) -> f32 {
	assert(
		packet_count >= 0 && packet_count < (1 << OCEAN_MATERIAL_PACKET_BITS),
		"ocean material mode word: packet count",
	)
	return f32(packet_count) + f32(int(proof_view) << OCEAN_MATERIAL_PACKET_BITS)
}

ocean_material_mode_unpack :: proc(
	word: f32,
) -> (
	packet_count: int,
	proof_view: Ocean_Proof_View,
) {
	bits := int(max(word, 0))
	packet_count = bits & ((1 << OCEAN_MATERIAL_PACKET_BITS) - 1)
	proof_view = Ocean_Proof_View(
		min(bits >> OCEAN_MATERIAL_PACKET_BITS, int(max(Ocean_Proof_View))),
	)
	return
}

ocean_renderer_draw :: proc(
	renderer: ^Ocean_Renderer,
	pass: ^rl.Gpu_3D_Pass,
	camera: rl.Camera3D,
	shader, far_shader: rl.Gpu_3D_Shader,
	settings: Ocean_Visual_Settings,
	atmosphere: ^Atmosphere,
	scene_color, scene_depth: rl.Texture2D,
) {
	assert(renderer != nil, "ocean_renderer_draw: nil renderer")
	assert(pass != nil, "ocean_renderer_draw: nil pass")
	assert(atmosphere != nil, "ocean_renderer_draw: nil atmosphere")
	renderer.draw_diagnostics = {
		draw_serial            = renderer.draw_diagnostics.draw_serial + 1,
		shader_id              = 0,
		scene_color_id         = 0,
		scene_depth_id         = 0,
		spectral_update_serial = renderer.spectral_update_serial,
		spectral_init_state    = renderer.spectral_init_state,
		wave_source            = renderer.wave_source,
		spectral_ready         = renderer.spectral.ready,
		skip_reason            = .Renderer_Not_Ready if !renderer.ready else .No_Water_Draw,
	}
	if !renderer.ready do return
	summary := weather_ocean_sample(&renderer.weather, renderer.focus_direction)
	params, params_2, params_3, params_4 := ocean_visual_material_params(settings, summary)
	params_4.z = atmosphere.fog_density
	params_4.w = max(atmosphere.fog_height_falloff, 0.001)
	packet_bindings := ocean_material_packets(renderer)
	packet_count := ocean_material_packet_count(renderer)
	spectral_textures := [OCEAN_SPECTRAL_CASCADE_COUNT]rl.Texture2D {
		ocean_spectral_displacement_texture(renderer, 0),
		ocean_spectral_displacement_texture(renderer, 1),
		ocean_spectral_displacement_texture(renderer, 2),
	}
	for texture, index in spectral_textures do renderer.draw_diagnostics.spectral_texture_ids[index] = texture.id
	near_material := rl.Gpu_Material {
		color                = WATER_DEEP,
		color_high           = WATER_SHALLOW,
		use_scalar           = true,
		style                = ocean_water_material_style(),
		custom_params        = params,
		custom_params_2      = params_2,
		custom_params_3      = params_3,
		custom_params_4      = params_4,
		custom_params_7      = {
			summary.peak_period,
			renderer.macro.time,
			1,
			ocean_material_mode_word(packet_count, settings.proof_view),
		},
		custom_params_8      = packet_bindings.center_height[0],
		custom_params_9      = packet_bindings.direction_period[0],
		custom_params_10     = packet_bindings.envelope_phase[0],
		custom_params_11     = packet_bindings.center_height[1],
		custom_params_12     = packet_bindings.direction_period[1],
		custom_params_13     = packet_bindings.envelope_phase[1],
		custom_params_14     = packet_bindings.center_height[2],
		custom_params_15     = packet_bindings.direction_period[2],
		custom_params_16     = packet_bindings.envelope_phase[2],
		custom_params_17     = packet_bindings.center_height[3],
		custom_params_18     = packet_bindings.direction_period[3],
		custom_params_19     = packet_bindings.envelope_phase[3],
		texture              = spectral_textures[0],
		normal_texture       = spectral_textures[1],
		roughness_ao_texture = spectral_textures[2],
		scene_color_texture  = scene_color,
		scene_depth_texture  = scene_depth,
		shader               = shader,
	}
	if renderer.nearshore.fixture_active {
		if !renderer.fixture_render.ready do return
		fixture_material := near_material
		fixture_material.custom_params_7.z = -1
		if renderer.fixture_render.water.id != 0 {
			rl.draw_gpu_mesh(pass, renderer.fixture_render.water, rl.Matrix(1), fixture_material)
			renderer.draw_diagnostics.near_draw_count = 1
			renderer.draw_diagnostics.skip_reason = .None
		}
		ocean_breakers_draw(&renderer.breakers, pass, fixture_material)
		return
	}
	far_material := ocean_background_material(near_material, far_shader, renderer.far_faces_active)
	identity := rl.Matrix(1)
	draw_far_faces, draw_clipmap_overlays := ocean_draw_layers(renderer.far_faces_active)
	if draw_far_faces {
		for mesh, face_index in renderer.far_gpu_meshes {
			if renderer.far_faces[face_index].has_water && mesh.id != 0 {
				rl.draw_gpu_mesh(pass, mesh, identity, far_material)
				renderer.draw_diagnostics.shader_id = far_material.shader.id
				renderer.draw_diagnostics.far_shader_id = far_material.shader.id
				renderer.draw_diagnostics.scene_color_id = far_material.scene_color_texture.id
				renderer.draw_diagnostics.scene_depth_id = far_material.scene_depth_texture.id
				renderer.draw_diagnostics.far_draw_count += 1
				renderer.draw_diagnostics.spectral_displacement_enabled = !renderer.far_faces_active
			}
		}
	}
	if !draw_clipmap_overlays {
		if renderer.draw_diagnostics.far_draw_count > 0 do renderer.draw_diagnostics.skip_reason = .None
		return
	}
	for &ring, ring_index in renderer.rings {
		if !settings.ring_visible[ring_index] do continue
		if ring.has_water && ring.gpu_mesh.id != 0 {
			ring_material := near_material
			mode := ocean_ring_displacement_mode(ring.cpu_macro_deformed)
			ring_material.custom_params_7.z = mode
			rl.draw_gpu_mesh(pass, ring.gpu_mesh, identity, ring_material)
			renderer.draw_diagnostics.shader_id = ring_material.shader.id
			renderer.draw_diagnostics.scene_color_id = ring_material.scene_color_texture.id
			renderer.draw_diagnostics.scene_depth_id = ring_material.scene_depth_texture.id
			renderer.draw_diagnostics.ring_displacement_modes[ring_index] = mode
			renderer.draw_diagnostics.near_draw_count += 1
			renderer.draw_diagnostics.spectral_displacement_enabled =
				renderer.draw_diagnostics.spectral_displacement_enabled || mode >= 0
		}
	}
	breaker_material := near_material
	breaker_material.custom_params_7.z = -1
	breaker_material.custom_params_2.w = max(breaker_material.custom_params_2.w, f32(1.35))
	breaker_material.custom_params_3.x = max(breaker_material.custom_params_3.x, f32(0.85))
	if renderer.breakers.front_count > 0 && renderer.breakers.mesh.id != 0 {
		renderer.draw_diagnostics.breaker_draw_count = 1
	}
	ocean_breakers_draw(&renderer.breakers, pass, breaker_material)
	if renderer.draw_diagnostics.near_draw_count + renderer.draw_diagnostics.far_draw_count > 0 {
		renderer.draw_diagnostics.skip_reason = .None
	}
}

ocean_renderer_deinit :: proc(renderer: ^Ocean_Renderer, allocator := context.allocator) {
	assert(renderer != nil, "ocean_renderer_deinit: nil renderer")
	ocean_breakers_deinit(&renderer.breakers)
	ocean_fixture_deinit(&renderer.fixture_render)
	ocean_nearshore_deinit(&renderer.nearshore)
	ocean_spectral_deinit(renderer)
	for ring_index in 0 ..< OCEAN_CLIPMAP_RING_COUNT {
		for bank_index in 0 ..< 2 {
			ring := &renderer.rings[ring_index]
			if bank_index == 1 do ring = &renderer.staging_rings[ring_index]
			if ring.gpu_mesh.id != 0 do rl.destroy_gpu_mesh(&ring.gpu_mesh)
			delete(ring.indices, allocator)
			delete(ring.gpu_vertices, allocator)
			delete(ring.vertices, allocator)
		}
	}
	for &face, face_index in renderer.far_faces {
		if renderer.far_gpu_meshes[face_index].id != 0 {
			rl.destroy_gpu_mesh(&renderer.far_gpu_meshes[face_index])
		}
		planet_water_mesh_deinit(&face, allocator)
	}
	renderer^ = {}
}
