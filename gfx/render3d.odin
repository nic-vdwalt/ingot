// ingot:gfx - 3D draw calls (raylib parity) realised as CPU-projected 2D
// billboards/discs over the batch renderer. A full GPU 3D pipeline (instanced
// meshes, depth prepass) is a larger effort; this projects world geometry
// through the active Camera3D (BeginMode3D) and draws camera-facing quads so
// the galaxy's core sphere, glow/soft-particle billboards and node coronas
// render. Meshes are approximated as shaded discs. Draws honour the active
// custom shader (BeginShaderMode) and blend mode.
package gfx

import "core:math"
import "core:math/linalg"

// --- meshes / materials ----------------------------------------------------

// GenMeshSphere records the radius/tessellation; the CPU-projected DrawMesh
// uses the radius to size the shaded disc.
GenMeshSphere :: proc(radius: f32, rings, slices: i32) -> Mesh {
	m: Mesh
	m.vertexCount = rings * slices
	m.triangleCount = rings * slices * 2
	// stash radius in the first vertex-count slot via vaoId (repurposed tag);
	// DrawMesh reads GALAXY radius from the transform scale instead, so this is
	// only a non-zero marker that the mesh is valid.
	m.vaoId = 1
	return m
}

UnloadMesh :: proc(mesh: Mesh) {}

LoadMaterialDefault :: proc() -> Material {
	return Material{}
}

// DrawMesh approximates a unit sphere (scaled/positioned by `transform`) as a
// camera-facing shaded disc at the transformed origin.
DrawMesh :: proc(mesh: Mesh, material: Material, transform: Matrix) {
	if !cam3d_active do return
	// world position = transform * origin
	pos := Vector3{transform[3, 0], transform[3, 1], transform[3, 2]}
	// world radius ≈ length of the transform's x-axis (uniform scale assumed)
	rx := Vector3{transform[0, 0], transform[0, 1], transform[0, 2]}
	radius := _v3len(rx)
	if radius <= 0 do radius = 1
	// base colour from the material's diffuse map if present, else warm white
	col := Color{255, 240, 220, 255}
	if material.maps != nil {
		col = material.maps[ShaderLocationIndex.MAP_ALBEDO].color
		if col == (Color{}) do col = Color{255, 240, 220, 255}
	}
	_draw_disc_world(pos, radius, col)
}

// --- depth-tested primitives -----------------------------------------------

@(private)
_cube_transform :: proc(position, size: Vector3) -> Matrix {
	assert(_camera_vector_is_finite(position), "_cube_transform: non-finite position")
	assert(_camera_vector_is_finite(size), "_cube_transform: non-finite size")
	return(
		MatrixTranslate(position.x, position.y, position.z) *
		MatrixScale(size.x, size.y, size.z) \
	)
}

DrawCube :: proc(position: Vector3, width, height, length: f32, color: Color) {
	DrawCubeV(position, {width, height, length}, color)
}

DrawCubeV :: proc(position, size: Vector3, color: Color) {
	DrawCubeTransform(_cube_transform(position, size), color)
}

DrawCubeTransform :: proc(transform: Matrix, color: Color) {
	if !cam3d_active do return
	assert(_camera_matrix_is_finite(transform), "DrawCubeTransform: non-finite transform")
	compat := &default_context_storage.resources.gpu_3d.compat
	if !compat.pass_available do return
	draw_gpu_mesh(&compat.pass, compat.cube, transform, {color = color})
}

DrawCubeWires :: proc(position: Vector3, width, height, length: f32, color: Color) {
	DrawCubeWiresV(position, {width, height, length}, color)
}

DrawCubeWiresV :: proc(position, size: Vector3, color: Color) {
	DrawCubeWiresTransform(_cube_transform(position, size), color)
}

DrawCubeWiresTransform :: proc(transform: Matrix, color: Color) {
	if !cam3d_active do return
	assert(_camera_matrix_is_finite(transform), "DrawCubeWiresTransform: non-finite transform")
	compat := &default_context_storage.resources.gpu_3d.compat
	if !compat.pass_available do return
	draw_gpu_mesh(
		&compat.pass,
		compat.cube_edges,
		transform,
		{color = color, style = .Opaque_Outline},
	)
}

DrawGrid :: proc(slices: i32, spacing: f32) {
	if !cam3d_active do return
	assert(_f32_is_finite(spacing), "DrawGrid: non-finite spacing")
	if spacing <= 0 do return
	resources := &default_context_storage.resources.gpu_3d
	if !resources.compat.pass_available do return
	grid, ok := _gpu_3d_compat_grid(resources, slices)
	if !ok do return
	transform := MatrixScale(spacing, spacing, 1)
	draw_gpu_mesh(&resources.compat.pass, grid, transform, {color = GRAY, depth_nudge = 0.0005})
}

// --- billboards ------------------------------------------------------------

DrawBillboard :: proc(
	camera: Camera,
	texture: Texture2D,
	position: Vector3,
	size: f32,
	tint: Color,
) {
	src := Rectangle{0, 0, f32(texture.width), f32(texture.height)}
	_draw_billboard_world(
		camera,
		texture,
		src,
		position,
		camera.up,
		{size, size},
		{size / 2, size / 2},
		0,
		tint,
	)
}

DrawBillboardPro :: proc(
	camera: Camera,
	texture: Texture2D,
	source: Rectangle,
	position: Vector3,
	up: Vector3,
	size: Vector2,
	origin: Vector2,
	rotation: f32,
	tint: Color,
) {
	_draw_billboard_world(camera, texture, source, position, up, size, origin, rotation, tint)
}

// --- helpers ---------------------------------------------------------------

@(private)
_v3len :: proc(v: Vector3) -> f32 {
	return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
}

@(private)
_billboard_world_corners :: proc(
	camera: Camera,
	position, up: Vector3,
	size, origin: Vector2,
	rotation: f32,
) -> (
	[4]Vector3,
	bool,
) {
	forward, forward_ok := _camera_vector_normalize(camera.target - camera.position)
	vertical, vertical_ok := _camera_vector_normalize(up)
	if !forward_ok || !vertical_ok do return {}, false
	right, right_ok := _camera_vector_normalize(linalg.cross(forward, vertical))
	if !right_ok do return {}, false
	vertical, _ = _camera_vector_normalize(linalg.cross(right, forward))
	angle := rotation * math.PI / 180
	cosine := math.cos(angle)
	sine := math.sin(angle)
	local := [4]Vector2 {
		{-origin.x, origin.y},
		{size.x - origin.x, origin.y},
		{size.x - origin.x, origin.y - size.y},
		{-origin.x, origin.y - size.y},
	}
	corners: [4]Vector3
	for offset, index in local {
		x := offset.x * cosine - offset.y * sine
		y := offset.x * sine + offset.y * cosine
		corners[index] = position + right * x + vertical * y
	}
	return corners, true
}

// Explicit camera geometry keeps matrix-only Pro projection independent from
// hidden compatibility camera state while preserving the active VP transform.
@(private)
_draw_billboard_world :: proc(
	camera: Camera,
	texture: Texture2D,
	source: Rectangle,
	position, up: Vector3,
	size, origin: Vector2,
	rotation: f32,
	tint: Color,
) {
	if !cam3d_active do return
	assert(_camera_vector_is_finite(position), "DrawBillboardPro: non-finite position")
	assert(_camera_vector_is_finite(up), "DrawBillboardPro: non-finite up")
	assert(_f32_is_finite(size.x) && _f32_is_finite(size.y), "DrawBillboardPro: non-finite size")
	assert(_f32_is_finite(rotation), "DrawBillboardPro: non-finite rotation")
	corners, ok := _billboard_world_corners(camera, position, up, size, origin, rotation)
	if !ok do return
	e := get_texture(texture.id)
	tl, ok0 := _project(cam3d_vp, corners[0])
	tr, ok1 := _project(cam3d_vp, corners[1])
	br, ok2 := _project(cam3d_vp, corners[2])
	bl, ok3 := _project(cam3d_vp, corners[3])
	if !(ok0 && ok1 && ok2 && ok3) do return

	tw := f32(max(texture.width, 1))
	th := f32(max(texture.height, 1))
	u0 := source.x / tw
	v0 := source.y / th
	u1 := (source.x + source.width) / tw
	v1 := (source.y + source.height) / th
	col := col_f(tint)

	if e != nil {
		batch_set(&g.rend, .Image, e.bind)
	} else {
		batch_set(&g.rend, .Solid, nil)
	}
	push_quad4(
		&g.rend,
		{tl.x, tl.y},
		{tr.x, tr.y},
		{br.x, br.y},
		{bl.x, bl.y},
		{u0, v0},
		{u1, v0},
		{u1, v1},
		{u0, v1},
		col,
	)
}

// _draw_disc_world projects a world sphere to a solid screen-space disc.
@(private)
_draw_disc_world :: proc(position: Vector3, radius: f32, tint: Color) {
	center, ok := _project(cam3d_vp, position)
	if !ok do return
	// estimate screen radius by projecting an offset point along camera-right
	edge := Vector3 {
		position.x + cam3d_right.x * radius,
		position.y + cam3d_right.y * radius,
		position.z + cam3d_right.z * radius,
	}
	ep, oke := _project(cam3d_vp, edge)
	pr: f32 = 6
	if oke {
		dx := ep.x - center.x
		dy := ep.y - center.y
		pr = math.sqrt(dx * dx + dy * dy)
	}
	if pr < 1 do pr = 1
	DrawCircleV(center, pr, tint)
}
