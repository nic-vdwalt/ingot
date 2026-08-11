// examples/box3d_water - graphics. The water surface is one indexed grid mesh
// whose topology never changes; only its vertex positions and normals are
// rewritten each frame from the same wave function the physics samples. That
// shared source is what makes the picture trustworthy: if the mesh and the
// buoyancy ever disagreed, the cubes would visibly float in the wrong place.
package main

import rl "ingot:gfx"

// The pool surface is drawn under the floaters, so it uses the blended default
// material with a colour ramp keyed to surface height: troughs read as deep
// water and crests as foam, which is what makes the motion legible without a
// custom shader.
WATER_COLOR_LOW :: rl.Color{18, 62, 112, 205}
WATER_COLOR_HIGH :: rl.Color{140, 210, 240, 205}
BOX_LIGHT :: rl.Gpu_3D_Light {
	direction = {-0.35, 0.45, 0.82},
	ambient   = 0.30,
	diffuse   = 0.70,
}

// Vertex storage lives at package scope rather than on the stack: it is
// POOL_VERTEX_COUNT * size_of(Gpu_3D_Vertex) bytes, rebuilt every frame, and a
// buffer that large has no business being copied through a stack frame.
water_vertices: [POOL_VERTEX_COUNT]rl.Gpu_3D_Vertex

graphics_create :: proc(value: ^State) -> bool {
	assert(value != nil, "graphics_create: nil state")
	assert(!value.graphics_ready, "graphics_create: graphics already ready")
	value.camera = {
		position   = {-18, -18, 11},
		target     = {0, 0, 0},
		up         = rl.CAMERA_WORLD_UP,
		fovy       = 45,
		projection = .PERSPECTIVE,
	}
	value.orbit, _ = rl.orbit_camera_from_camera(value.camera)
	value.orbit_config = rl.orbit_camera_config_default()
	value.orbit_config.min_distance = 12
	value.orbit_config.max_distance = 120
	value.orbit_bindings = rl.orbit_camera_bindings_default()
	target_ok, cube_ok, edges_ok: bool
	value.target, target_ok = rl.create_gpu_3d_target(
		rl.GetRenderWidth(),
		rl.GetRenderHeight(),
		.MSAA_4X,
	)
	value.cube, cube_ok = rl.create_cube_mesh()
	value.cube_edges, edges_ok = rl.create_cube_edge_mesh()
	water_ok := water_mesh_create(value)
	value.graphics_ready = target_ok && cube_ok && edges_ok && water_ok
	return value.graphics_ready
}

graphics_target_resize :: proc(value: ^State) {
	assert(value != nil, "graphics_target_resize: nil state")
	assert(value.resize_failures < max(u64), "graphics_target_resize: counter overflow")
	if !value.graphics_ready do return
	result := rl.resize_gpu_3d_target_to_render_size(&value.target)
	if result == .Failed do value.resize_failures += 1
}

// water_mesh_create builds the fixed topology once with the engine's plane
// helper. Indices are never touched again, which is precisely why the per-frame
// update only has to rewrite vertices - the expensive part of a mesh upload is
// the part that is constant.
water_mesh_create :: proc(value: ^State) -> bool {
	assert(value != nil, "water_mesh_create: nil state")
	assert(POOL_CELLS > 0, "water_mesh_create: empty grid")
	// The local vertex buffer is refilled in place every frame, so it must
	// address exactly the vertices the engine generated. Checking the count
	// against the engine's own formula is what makes the shared row-major
	// ordering contract a checked one rather than an assumed one.
	assert(
		int(rl.plane_mesh_vertex_count(POOL_CELLS)) == POOL_VERTEX_COUNT,
		"water_mesh_create: plane vertex layout changed",
	)
	mesh, ok := rl.create_plane_mesh(POOL_EXTENT, POOL_CELLS)
	if !ok do return false
	value.water = mesh
	// The engine's plane is flat; the first displaced surface is uploaded here
	// so frame zero already shows the wave rather than a plate of glass.
	water_vertices_fill(value.phase)
	if !rl.update_gpu_mesh_vertices(value.water, water_vertices[:]) do return false
	return true
}

// water_vertices_fill evaluates the same wave the physics uses. `scalar` is the
// normalized height, which the material maps between the deep and foam colours,
// so the ramp stays correct no matter how the amplitudes are retuned.
water_vertices_fill :: proc(phase: f32) {
	assert(POOL_CELLS > 0, "water_vertices_fill: empty grid")
	assert(WATER_HEIGHT_SPAN > 0, "water_vertices_fill: zero wave span")
	step := 2 * POOL_EXTENT / f32(POOL_CELLS)
	index := 0
	for row in 0 ..= POOL_CELLS {
		y := -POOL_EXTENT + f32(row) * step
		for column in 0 ..= POOL_CELLS {
			x := -POOL_EXTENT + f32(column) * step
			height := water_height(x, y, phase)
			offset := (height - WATER_BASE_Z) / (2 * WATER_HEIGHT_SPAN) + 0.5
			water_vertices[index] = {
				position = {x, y, height},
				normal   = water_normal(x, y, phase),
				scalar   = clamp(offset, 0, 1),
				uv       = {f32(column) / f32(POOL_CELLS), f32(row) / f32(POOL_CELLS)},
			}
			index += 1
		}
	}
	assert(index == POOL_VERTEX_COUNT, "water_vertices_fill: vertex count mismatch")
}

camera_update :: proc(value: ^State, frame_dt: f32) {
	assert(value != nil, "camera_update: nil state")
	assert(value.orbit.distance > 0, "camera_update: invalid distance")
	input := rl.orbit_camera_input_poll(value.orbit_bindings)
	rl.update_orbit_camera(&value.orbit, input, value.orbit_config, frame_dt)
	rl.orbit_camera_apply(value.orbit, &value.camera)
}

draw_world :: proc(value: ^State) {
	assert(value != nil, "draw_world: nil state")
	assert(value.floater_count <= FLOATER_MAX, "draw_world: floater count overflow")
	water_vertices_fill(value.phase)
	// A failed upload leaves the previous frame's surface resident, which is
	// stale but coherent; refusing to draw would be a worse answer than one
	// frame of lag on a transient device error.
	_ = rl.update_gpu_mesh_vertices(value.water, water_vertices[:])
	pass, ok := rl.begin_gpu_3d(&value.target, value.camera)
	if !ok do return
	rl.set_gpu_3d_light(&pass, BOX_LIGHT)
	floor :=
		rl.MatrixTranslate(0, 0, FLOOR_Z) * rl.MatrixScale(2 * POOL_EXTENT, 2 * POOL_EXTENT, 1)
	rl.draw_gpu_mesh(&pass, value.cube, floor, {color = {38, 44, 56, 255}, style = .Opaque})
	draw_floaters(value, &pass)
	// The surface is blended, so it is drawn last: the opaque floor and cubes
	// must already be in the depth buffer for the water to read as covering
	// the parts of them that are below it.
	rl.draw_gpu_mesh(
		&pass,
		value.water,
		rl.Matrix(1),
		{color = WATER_COLOR_LOW, color_high = WATER_COLOR_HIGH, use_scalar = true},
	)
	rl.end_gpu_3d(&pass)
}

draw_floaters :: proc(value: ^State, pass: ^rl.Gpu_3D_Pass) {
	assert(value != nil, "draw_floaters: nil state")
	assert(pass != nil, "draw_floaters: nil pass")
	for floater, index in value.floaters[:value.floater_count] {
		color := FLOATER_COLORS[index % len(FLOATER_COLORS)]
		rl.draw_gpu_mesh_outlined(
			pass,
			value.cube,
			value.cube_edges,
			floater.transform,
			{color = color},
			{20, 24, 32, 255},
		)
	}
}
