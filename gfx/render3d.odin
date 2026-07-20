// ingot:gfx — 3D draw calls (raylib parity) realised as CPU-projected 2D
// billboards/discs over the batch renderer. A full GPU 3D pipeline (instanced
// meshes, depth prepass) is a larger effort; this projects world geometry
// through the active Camera3D (BeginMode3D) and draws camera-facing quads so
// the galaxy's core sphere, glow/soft-particle billboards and node coronas
// render. Meshes are approximated as shaded discs. Draws honour the active
// custom shader (BeginShaderMode) and blend mode.
package gfx

import "core:math"

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

// --- billboards ------------------------------------------------------------

DrawBillboard :: proc(camera: Camera, texture: Texture2D, position: Vector3, size: f32, tint: Color) {
	src := Rectangle{0, 0, f32(texture.width), f32(texture.height)}
	_draw_billboard_world(texture, src, position, {size, size}, tint)
}

DrawBillboardPro :: proc(camera: Camera, texture: Texture2D, source: Rectangle, position: Vector3, up: Vector3, size: Vector2, origin: Vector2, rotation: f32, tint: Color) {
	_draw_billboard_world(texture, source, position, size, tint)
}

// --- helpers ---------------------------------------------------------------

@(private)
_v3len :: proc(v: Vector3) -> f32 {
	return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
}

// _draw_billboard_world projects a world-space, camera-facing quad and emits it
// through the image pipeline (so an active custom shader / blend mode applies).
@(private)
_draw_billboard_world :: proc(texture: Texture2D, source: Rectangle, position: Vector3, size: Vector2, tint: Color) {
	if !cam3d_active do return
	e := get_texture(texture.id)
	hw := size.x * 0.5
	hh := size.y * 0.5
	// world-space corners on the camera plane
	r := cam3d_right
	u := cam3d_up
	wtl := Vector3{position.x - r.x * hw + u.x * hh, position.y - r.y * hw + u.y * hh, position.z - r.z * hw + u.z * hh}
	wtr := Vector3{position.x + r.x * hw + u.x * hh, position.y + r.y * hw + u.y * hh, position.z + r.z * hw + u.z * hh}
	wbr := Vector3{position.x + r.x * hw - u.x * hh, position.y + r.y * hw - u.y * hh, position.z + r.z * hw - u.z * hh}
	wbl := Vector3{position.x - r.x * hw - u.x * hh, position.y - r.y * hw - u.y * hh, position.z - r.z * hw - u.z * hh}
	tl, ok0 := _project(cam3d_vp, wtl)
	tr, ok1 := _project(cam3d_vp, wtr)
	br, ok2 := _project(cam3d_vp, wbr)
	bl, ok3 := _project(cam3d_vp, wbl)
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
	push_quad4(&g.rend,
		{tl.x, tl.y}, {tr.x, tr.y}, {br.x, br.y}, {bl.x, bl.y},
		{u0, v0}, {u1, v0}, {u1, v1}, {u0, v1}, col,
	)
}

// _draw_disc_world projects a world sphere to a solid screen-space disc.
@(private)
_draw_disc_world :: proc(position: Vector3, radius: f32, tint: Color) {
	center, ok := _project(cam3d_vp, position)
	if !ok do return
	// estimate screen radius by projecting an offset point along camera-right
	edge := Vector3{position.x + cam3d_right.x * radius, position.y + cam3d_right.y * radius, position.z + cam3d_right.z * radius}
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
