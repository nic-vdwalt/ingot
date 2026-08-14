#+build !js
// Headless GPU-3D coverage: everything testable without a WebGPU device -
// sphere geometry generation (counts, bounds, normals, UVs, index validity),
// parameter rejection, pool-handle mapping, light normalization, uniform
// layout locks, and instanced-draw chunk arithmetic. On-device behavior
// (depth test, lighting, textures, instancing, per-backend rendering) is
// validated by examples/render_fixture; see docs/rendering.md "GPU 3D
// validation matrix".
package gfx

import "core:math"
import "core:math/linalg"
import "core:testing"
import wg "vendor:wgpu"

@(test)
test_gpu_3d_target_size_rejects_invalid_target :: proc(t: ^testing.T) {
	width, height, ok := gpu_3d_target_size(nil)
	testing.expect_value(t, width, i32(0))
	testing.expect_value(t, height, i32(0))
	testing.expect_value(t, ok, false)

	target: Gpu_3D_Target
	width, height, ok = gpu_3d_target_size(&target)
	testing.expect_value(t, width, i32(0))
	testing.expect_value(t, height, i32(0))
	testing.expect_value(t, ok, false)
}

@(test)
test_cube_geometry_contract :: proc(t: ^testing.T) {
	vertices: [GPU_3D_CUBE_VERTEX_COUNT]Gpu_3D_Vertex
	indices: [GPU_3D_CUBE_INDEX_COUNT]u32
	_cube_mesh_geometry(&vertices, &indices)
	testing.expect_value(t, len(vertices), GPU_3D_CUBE_VERTEX_COUNT)
	testing.expect_value(t, len(indices), GPU_3D_CUBE_INDEX_COUNT)
	testing.expect_value(t, len(indices) % 3, 0)
	bounds_min := Vector3{0.5, 0.5, 0.5}
	bounds_max := Vector3{-0.5, -0.5, -0.5}
	for vertex, vertex_index in vertices {
		for component in vertex.position {
			testing.expect(t, component == -0.5 || component == 0.5, "cube position off bound")
		}
		bounds_min.x = min(bounds_min.x, vertex.position.x)
		bounds_min.y = min(bounds_min.y, vertex.position.y)
		bounds_min.z = min(bounds_min.z, vertex.position.z)
		bounds_max.x = max(bounds_max.x, vertex.position.x)
		bounds_max.y = max(bounds_max.y, vertex.position.y)
		bounds_max.z = max(bounds_max.z, vertex.position.z)
		normal_length_squared := linalg.dot(vertex.normal, vertex.normal)
		testing.expect_value(t, normal_length_squared, f32(1))
		testing.expect(t, vertex.uv.x >= 0 && vertex.uv.x <= 1, "cube u outside domain")
		testing.expect(t, vertex.uv.y >= 0 && vertex.uv.y <= 1, "cube v outside domain")
		face_start := vertex_index / GPU_3D_CUBE_FACE_VERTEX_COUNT * GPU_3D_CUBE_FACE_VERTEX_COUNT
		testing.expect_value(t, vertex.normal, vertices[face_start].normal)
	}
	testing.expect_value(t, bounds_min, Vector3{-0.5, -0.5, -0.5})
	testing.expect_value(t, bounds_max, Vector3{0.5, 0.5, 0.5})
	for index in indices {
		testing.expect(t, index < GPU_3D_CUBE_VERTEX_COUNT, "cube index out of range")
	}
	for face in 0 ..< GPU_3D_CUBE_FACE_COUNT {
		face_start := face * GPU_3D_CUBE_FACE_VERTEX_COUNT
		testing.expect_value(t, vertices[face_start + 0].uv, Vector2{0, 0})
		testing.expect_value(t, vertices[face_start + 1].uv, Vector2{1, 0})
		testing.expect_value(t, vertices[face_start + 2].uv, Vector2{1, 1})
		testing.expect_value(t, vertices[face_start + 3].uv, Vector2{0, 1})
	}
}

@(test)
test_cube_geometry_winding_faces_outward :: proc(t: ^testing.T) {
	vertices: [GPU_3D_CUBE_VERTEX_COUNT]Gpu_3D_Vertex
	indices: [GPU_3D_CUBE_INDEX_COUNT]u32
	_cube_mesh_geometry(&vertices, &indices)
	for triangle := 0; triangle < len(indices); triangle += 3 {
		a := vertices[indices[triangle]].position
		b := vertices[indices[triangle + 1]].position
		c := vertices[indices[triangle + 2]].position
		face := linalg.cross(b - a, c - a)
		center := (a + b + c) / 3
		testing.expect(t, linalg.dot(face, center) > 0, "cube triangle faces inward")
	}
}

@(test)
test_cube_edge_geometry_contract :: proc(t: ^testing.T) {
	vertices: [GPU_3D_CUBE_CORNER_COUNT]Gpu_3D_Vertex
	indices: [GPU_3D_CUBE_EDGE_INDEX_COUNT]u32
	_cube_edge_mesh_geometry(&vertices, &indices)
	testing.expect_value(t, len(vertices), GPU_3D_CUBE_CORNER_COUNT)
	testing.expect_value(t, len(indices), GPU_3D_CUBE_EDGE_INDEX_COUNT)
	testing.expect_value(t, len(indices) % 2, 0)
	seen: [GPU_3D_CUBE_CORNER_COUNT * GPU_3D_CUBE_CORNER_COUNT]bool
	for edge := 0; edge < len(indices); edge += 2 {
		a_index := indices[edge]
		b_index := indices[edge + 1]
		testing.expect(t, a_index < GPU_3D_CUBE_CORNER_COUNT, "cube edge index out of range")
		testing.expect(t, b_index < GPU_3D_CUBE_CORNER_COUNT, "cube edge index out of range")
		a := vertices[a_index].position
		b := vertices[b_index].position
		different_axes := int(a.x != b.x) + int(a.y != b.y) + int(a.z != b.z)
		testing.expect_value(t, different_axes, 1)
		low := min(a_index, b_index)
		high := max(a_index, b_index)
		key := low * GPU_3D_CUBE_CORNER_COUNT + high
		testing.expect(t, !seen[key], "duplicate cube edge")
		seen[key] = true
	}
}

@(test)
test_create_cube_meshes_reject_headless :: proc(t: ^testing.T) {
	gfx_shared_test_lock()
	defer gfx_shared_test_unlock()
	cube, cube_ok := create_cube_mesh()
	edges, edges_ok := create_cube_edge_mesh()
	testing.expect_value(t, cube_ok, false)
	testing.expect_value(t, cube.id, u32(0))
	testing.expect_value(t, edges_ok, false)
	testing.expect_value(t, edges.id, u32(0))
}

@(test)
test_grid_geometry_contract :: proc(t: ^testing.T) {
	vertices: [GPU_3D_COMPAT_GRID_MAX_VERTICES]Gpu_3D_Vertex
	indices: [GPU_3D_COMPAT_GRID_MAX_INDICES]u32
	vertex_count, index_count, ok := _grid_mesh_geometry(20, &vertices, &indices)
	testing.expect(t, ok)
	testing.expect_value(t, vertex_count, 84)
	testing.expect_value(t, index_count, vertex_count)
	for index in 0 ..< vertex_count {
		testing.expect_value(t, vertices[index].position.z, f32(0))
		testing.expect_value(t, indices[index], u32(index))
	}
	testing.expect_value(t, vertices[0].position, Vector3{-10, -10, 0})
	testing.expect_value(t, vertices[1].position, Vector3{10, -10, 0})
	testing.expect_value(t, vertices[2].position, Vector3{-10, -10, 0})
	testing.expect_value(t, vertices[3].position, Vector3{-10, 10, 0})
	testing.expect_value(t, vertices[vertex_count - 1].position, Vector3{10, 10, 0})
}

@(test)
test_grid_geometry_rejects_invalid_slices :: proc(t: ^testing.T) {
	vertices: [GPU_3D_COMPAT_GRID_MAX_VERTICES]Gpu_3D_Vertex
	indices: [GPU_3D_COMPAT_GRID_MAX_INDICES]u32
	cases := [?]i32{0, -1, GPU_3D_COMPAT_GRID_MAX_SLICES + 1}
	for slices in cases {
		vertex_count, index_count, ok := _grid_mesh_geometry(slices, &vertices, &indices)
		testing.expect_value(t, vertex_count, 0)
		testing.expect_value(t, index_count, 0)
		testing.expect(t, !ok)
	}
}

@(test)
test_cube_transform_contract :: proc(t: ^testing.T) {
	transform := _cube_transform({1, 2, 3}, {4, 5, 6})
	testing.expect_value(t, transform * [4]f32{0, 0, 0, 1}, [4]f32{1, 2, 3, 1})
	testing.expect_value(t, transform * [4]f32{0.5, 0.5, 0.5, 1}, [4]f32{3, 4.5, 6, 1})
}

@(test)
test_transform_primitives_skip_without_mode :: proc(t: ^testing.T) {
	gfx_shared_test_lock()
	defer gfx_shared_test_unlock()
	transform := MatrixTranslate(1, 2, 3) * MatrixScale(4, 5, 6)
	DrawCubeTransform(transform, WHITE)
	DrawCubeWiresTransform(transform, WHITE)
	testing.expect(t, !g.resources.gpu_3d.compat.pass_available)
}

@(test)
test_compat_primitives_skip_without_mode :: proc(t: ^testing.T) {
	gfx_shared_test_lock()
	defer gfx_shared_test_unlock()
	DrawCube({}, 1, 1, 1, WHITE)
	DrawCubeV({}, {1, 1, 1}, WHITE)
	DrawCubeWires({}, 1, 1, 1, WHITE)
	DrawCubeWiresV({}, {1, 1, 1}, WHITE)
	DrawGrid(20, 1)
	testing.expect(t, !g.resources.gpu_3d.compat.pass_available)
}

// -- _sphere_mesh_geometry -----------------------------------------------------

@(test)
test_sphere_geometry_counts :: proc(t: ^testing.T) {
	cases := [?]struct {
		rings, slices: u32,
	}{{2, 3}, {8, 12}, {16, 24}, {3, 64}}
	for c in cases {
		vertices := make([dynamic]Gpu_3D_Vertex, context.temp_allocator)
		indices := make([dynamic]u32, context.temp_allocator)
		_sphere_mesh_geometry(1, c.rings, c.slices, &vertices, &indices)
		testing.expect_value(t, len(vertices), int((c.rings + 1) * (c.slices + 1)))
		testing.expect_value(t, len(indices), int(c.rings * c.slices * 6))
		// Triangle list: index count divisible by 3.
		testing.expect_value(t, len(indices) % 3, 0)
	}
}

@(test)
test_sphere_geometry_bounds_and_normals :: proc(t: ^testing.T) {
	radius: f32 = 2.5
	vertices := make([dynamic]Gpu_3D_Vertex, context.temp_allocator)
	indices := make([dynamic]u32, context.temp_allocator)
	_sphere_mesh_geometry(radius, 8, 12, &vertices, &indices)

	testing.expect_value(t, vertices[0].position, Vector3{0, 0, radius})
	testing.expect(t, abs(vertices[len(vertices) - 1].position.z + radius) < 1e-4)
	equator := vertices[4 * 13].position
	testing.expect(t, abs(equator.z) < 1e-4)

	for v in vertices {
		pos_len := math.sqrt(
			v.position.x * v.position.x +
			v.position.y * v.position.y +
			v.position.z * v.position.z,
		)
		nrm_len := math.sqrt(
			v.normal.x * v.normal.x + v.normal.y * v.normal.y + v.normal.z * v.normal.z,
		)
		// Every vertex lies on the sphere surface; every normal is unit.
		testing.expect(t, abs(pos_len - radius) < 1e-4, "vertex off the sphere surface")
		testing.expect(t, abs(nrm_len - 1) < 1e-4, "non-unit normal")
	}
	// Every index addresses a real vertex.
	for index in indices {
		testing.expect(t, int(index) < len(vertices), "index out of range")
	}
}

@(test)
test_sphere_geometry_winding_faces_outward :: proc(t: ^testing.T) {
	vertices := make([dynamic]Gpu_3D_Vertex, context.temp_allocator)
	indices := make([dynamic]u32, context.temp_allocator)
	_sphere_mesh_geometry(1, 8, 12, &vertices, &indices)
	// Skip pole cells because their duplicate vertices form intentional
	// zero-area triangles; every interior face must remain outward and CCW.
	for triangle := 24; triangle < len(indices) - 24; triangle += 3 {
		a := vertices[indices[triangle]].position
		b := vertices[indices[triangle + 1]].position
		c := vertices[indices[triangle + 2]].position
		face := linalg.cross(b - a, c - a)
		if linalg.dot(face, face) <= 1e-12 do continue
		center := (a + b + c) / 3
		testing.expect(t, linalg.dot(face, center) > 0, "sphere triangle faces inward")
	}
}

// -- _plane_mesh_geometry ------------------------------------------------------

@(test)
test_plane_geometry_counts :: proc(t: ^testing.T) {
	cases := [?]u32{1, 2, 8, 40, 64}
	for cells in cases {
		vertex_total := int(plane_mesh_vertex_count(cells))
		vertices := make([]Gpu_3D_Vertex, vertex_total, context.temp_allocator)
		indices := make([]u32, int(plane_mesh_index_count(cells)), context.temp_allocator)
		vertex_count, index_count, ok := _plane_mesh_geometry(1, cells, vertices, indices)
		testing.expect(t, ok)
		testing.expect_value(t, vertex_count, int((cells + 1) * (cells + 1)))
		testing.expect_value(t, index_count, int(cells * cells * 6))
		testing.expect_value(t, index_count % 3, 0)
	}
}

// Undersized storage must be refused, not overrun - cells is a runtime value.
@(test)
test_plane_geometry_rejects_short_storage :: proc(t: ^testing.T) {
	vertices := make([]Gpu_3D_Vertex, 4, context.temp_allocator)
	indices := make([]u32, 6, context.temp_allocator)
	_, _, ok := _plane_mesh_geometry(1, 4, vertices, indices)
	testing.expect(t, !ok)
	_, _, exact := _plane_mesh_geometry(1, 1, vertices, indices)
	testing.expect(t, exact)
}

// Row-major ordering is a published contract: deforming callers refill this
// buffer themselves and address it with row * (cells + 1) + column.
@(test)
test_plane_geometry_is_row_major_and_centered :: proc(t: ^testing.T) {
	cells := u32(4)
	extent := f32(2)
	vertices := make([]Gpu_3D_Vertex, int(plane_mesh_vertex_count(cells)), context.temp_allocator)
	indices := make([]u32, int(plane_mesh_index_count(cells)), context.temp_allocator)
	_, _, ok := _plane_mesh_geometry(extent, cells, vertices, indices)
	testing.expect(t, ok)
	stride := int(cells + 1)
	testing.expect_value(t, vertices[0].position, Vector3{-extent, -extent, 0})
	testing.expect_value(t, vertices[stride - 1].position, Vector3{extent, -extent, 0})
	testing.expect_value(t, vertices[stride * stride - 1].position, Vector3{extent, extent, 0})
	// Column advances fastest; the row only changes every stride vertices.
	testing.expect_value(t, vertices[1].position.y, -extent)
	testing.expect_value(t, vertices[stride].position.x, -extent)
	for v in vertices {
		testing.expect_value(t, v.position.z, f32(0))
		testing.expect_value(t, v.normal, CAMERA_WORLD_UP)
		testing.expect(t, v.uv.x >= 0 && v.uv.x <= 1, "u outside [0, 1]")
		testing.expect(t, v.uv.y >= 0 && v.uv.y <= 1, "v outside [0, 1]")
	}
	for index in indices {
		testing.expect(t, int(index) < len(vertices), "index out of range")
	}
}

// Winding must match the cube's outward convention or one cull policy cannot
// serve both meshes.
@(test)
test_plane_geometry_winding_faces_up :: proc(t: ^testing.T) {
	cells := u32(4)
	vertices := make([]Gpu_3D_Vertex, int(plane_mesh_vertex_count(cells)), context.temp_allocator)
	indices := make([]u32, int(plane_mesh_index_count(cells)), context.temp_allocator)
	_, index_count, ok := _plane_mesh_geometry(1, cells, vertices, indices)
	testing.expect(t, ok)
	for triangle := 0; triangle < index_count; triangle += 3 {
		a := vertices[indices[triangle]].position
		b := vertices[indices[triangle + 1]].position
		c := vertices[indices[triangle + 2]].position
		face := linalg.cross(b - a, c - a)
		testing.expect(t, face.z > 0, "plane triangle faces down")
	}
}

// A headless run has no device, so creation must refuse rather than build a
// mesh nothing can draw; out-of-range cell counts are refused independently.
@(test)
test_create_plane_mesh_rejects_headless_and_out_of_range :: proc(t: ^testing.T) {
	gfx_shared_test_lock()
	defer gfx_shared_test_unlock()
	mesh, ok := create_plane_mesh(1, 4)
	testing.expect_value(t, ok, false)
	testing.expect_value(t, mesh.id, u32(0))
	_, zero_ok := create_plane_mesh(1, 0)
	testing.expect_value(t, zero_ok, false)
	_, over_ok := create_plane_mesh(1, GPU_3D_PLANE_MAX_CELLS + 1)
	testing.expect_value(t, over_ok, false)
}

// -- create_sphere_mesh: parameter/uninitialized rejection ---------------------

@(test)
test_create_sphere_mesh_rejects_headless :: proc(t: ^testing.T) {
	gfx_shared_test_lock()
	defer gfx_shared_test_unlock()
	// No device in unit tests (g.initialized == false): must refuse with the
	// invalid handle rather than touching wgpu. Degenerate ring/slice counts
	// are rejected the same way once a device exists.
	mesh, ok := create_sphere_mesh(1, 16, 24)
	testing.expect_value(t, ok, false)
	testing.expect_value(t, mesh.id, u32(0))
}

@(test)
test_gpu_3d_geometry_validation :: proc(t: ^testing.T) {
	vertices := [?]Gpu_3D_Vertex {
		{position = {0, 0, 0}, normal = CAMERA_WORLD_UP, scalar = 0},
		{position = {1, 0, 0}, normal = CAMERA_WORLD_UP, scalar = 0.5},
		{position = {0, 1, 0}, normal = CAMERA_WORLD_UP, scalar = 1},
	}
	triangles := [?]u32{0, 1, 2}
	lines := [?]u32{0, 1, 1, 2}
	points := [?]u32{0, 1, 2}
	bad_index := [?]u32{0, 1, 3}

	testing.expect(t, _gpu_3d_geometry_valid(vertices[:], triangles[:], .Triangles))
	testing.expect(t, _gpu_3d_geometry_valid(vertices[:], lines[:], .Lines))
	testing.expect(t, _gpu_3d_geometry_valid(vertices[:], points[:], .Points))
	testing.expect(t, !_gpu_3d_geometry_valid(vertices[:], lines[:], .Triangles))
	testing.expect(t, !_gpu_3d_geometry_valid(vertices[:], bad_index[:], .Triangles))
	testing.expect(t, !_gpu_3d_geometry_valid(nil, triangles[:], .Triangles))
}

@(test)
test_create_gpu_mesh_rejects_headless :: proc(t: ^testing.T) {
	gfx_shared_test_lock()
	defer gfx_shared_test_unlock()
	vertices := [?]Gpu_3D_Vertex {
		{position = {0, 0, 0}, normal = CAMERA_WORLD_UP},
		{position = {1, 0, 0}, normal = CAMERA_WORLD_UP},
		{position = {0, 1, 0}, normal = CAMERA_WORLD_UP},
	}
	indices := [?]u32{0, 1, 2}
	mesh, ok := create_gpu_mesh(vertices[:], indices[:])
	testing.expect_value(t, ok, false)
	testing.expect_value(t, mesh.id, u32(0))
}

// A headless run has no device, so the update must refuse rather than write
// through a nil buffer. This is the only reachable failure path without a GPU,
// and it is the one an app hits when it updates a mesh it never created.
@(test)
test_update_gpu_mesh_vertices_rejects_headless :: proc(t: ^testing.T) {
	gfx_shared_test_lock()
	defer gfx_shared_test_unlock()
	vertices := [?]Gpu_3D_Vertex {
		{position = {0, 0, 0}, normal = CAMERA_WORLD_UP},
		{position = {1, 0, 0}, normal = CAMERA_WORLD_UP},
		{position = {0, 1, 0}, normal = CAMERA_WORLD_UP},
	}
	testing.expect(t, !update_gpu_mesh_vertices(Gpu_Mesh{}, vertices[:]))
	testing.expect(t, !update_gpu_mesh_vertices(Gpu_Mesh{}, nil))
}

@(test)
test_gpu_3d_opaque_material_policies :: proc(t: ^testing.T) {
	default := _gpu_3d_material_policy(.Default)
	opaque := _gpu_3d_material_policy(.Opaque)
	overlay := _gpu_3d_material_policy(.Opaque_Overlay)
	outline := _gpu_3d_material_policy(.Opaque_Outline)
	testing.expect(t, default.blend)
	testing.expect_value(t, default.depth_bias, i32(0))
	testing.expect(t, !opaque.blend)
	testing.expect(t, opaque.depth_write)
	testing.expect_value(t, opaque.depth_compare, wg.CompareFunction.Less)
	testing.expect_value(t, opaque.depth_bias, i32(0))
	testing.expect(t, !overlay.blend)
	testing.expect(t, !overlay.depth_write)
	testing.expect_value(t, overlay.depth_compare, wg.CompareFunction.Less)
	testing.expect(t, overlay.depth_bias < 0)
	testing.expect(t, !outline.blend)
	testing.expect(t, !outline.depth_write)
	testing.expect_value(t, outline.depth_compare, wg.CompareFunction.LessEqual)
	testing.expect_value(t, outline.depth_bias, i32(0))
}

@(test)
test_gpu_3d_antialiasing_sample_count :: proc(t: ^testing.T) {
	testing.expect_value(t, _gpu_3d_sample_count(.None), u32(1))
	testing.expect_value(t, _gpu_3d_sample_count(.MSAA_4X), u32(4))
}

@(test)
test_gpu_3d_pipeline_identity_includes_compatibility_fields :: proc(t: ^testing.T) {
	entry := Gpu_3D_Pipeline_Entry {
		format       = .RGBA8Unorm,
		primitive    = .Triangles,
		style        = .Default,
		sample_count = 4,
	}
	testing.expect(t, _gpu_3d_pipeline_matches(entry, .RGBA8Unorm, .Triangles, .Default, 4, 0))
	testing.expect(t, !_gpu_3d_pipeline_matches(entry, .RGBA8Unorm, .Triangles, .Opaque, 4, 0))
	testing.expect(
		t,
		!_gpu_3d_pipeline_matches(entry, .RGBA8Unorm, .Triangles, .Opaque_Overlay, 4, 0),
	)
	testing.expect(
		t,
		!_gpu_3d_pipeline_matches(entry, .RGBA8Unorm, .Triangles, .Opaque_Outline, 4, 0),
	)
	testing.expect(t, !_gpu_3d_pipeline_matches(entry, .RGBA8Unorm, .Triangles, .Default, 1, 0))
	testing.expect(t, !_gpu_3d_pipeline_matches(entry, .RGBA8Unorm, .Triangles, .Default, 4, 7))
}

// -- pool handle mapping -------------------------------------------------------

@(test)
test_gpu_3d_mesh_handle_mapping :: proc(t: ^testing.T) {
	resources: Gpu_3D_Resources
	context_id := u32(2)
	testing.expect(t, _gpu_3d_mesh_slot(context_id, &resources, Gpu_Mesh{}) == nil)

	entry: Gpu_3D_Mesh_Entry
	slot := &resources.meshes[0]
	slot.generation = _resource_generation_next(slot.generation)
	slot.entry = &entry
	slot.occupied = true
	old_mesh := Gpu_Mesh {
		id = _resource_handle_make_context(context_id, 0, slot.generation),
	}
	testing.expect(t, _gpu_3d_mesh_slot(context_id, &resources, old_mesh) == slot)
	testing.expect(t, _gpu_3d_mesh_slot(3, &resources, old_mesh) == nil)

	slot.generation = _resource_generation_next(slot.generation)
	new_mesh := Gpu_Mesh {
		id = _resource_handle_make_context(context_id, 0, slot.generation),
	}
	testing.expect(t, _gpu_3d_mesh_slot(context_id, &resources, old_mesh) == nil)
	testing.expect(t, _gpu_3d_mesh_slot(context_id, &resources, new_mesh) == slot)
}

@(test)
test_gpu_3d_shader_handle_mapping :: proc(t: ^testing.T) {
	resources: Gpu_3D_Resources
	context_id := u32(2)
	// Zero handle resolves to the built-in shader (nil module, id 0).
	module, id := _gpu_3d_shader_resolve(context_id, &resources, Gpu_3D_Shader{})
	testing.expect(t, module == nil)
	testing.expect_value(t, id, u32(0))

	slot := &resources.shaders[0]
	slot.generation = _resource_generation_next(slot.generation)
	slot.module = wg.ShaderModule(rawptr(uintptr(0xBEEF)))
	slot.occupied = true
	old_shader := Gpu_3D_Shader {
		id = _resource_handle_make_context(context_id, 0, slot.generation),
	}
	module, id = _gpu_3d_shader_resolve(context_id, &resources, old_shader)
	testing.expect(t, module == slot.module)
	testing.expect_value(t, id, old_shader.id)
	foreign_module, foreign_id := _gpu_3d_shader_resolve(3, &resources, old_shader)
	testing.expect(t, foreign_module == nil)
	testing.expect_value(t, foreign_id, u32(0))

	// A stale generation falls back to the built-in shader, matching the
	// texture fallback policy.
	slot.generation = _resource_generation_next(slot.generation)
	module, id = _gpu_3d_shader_resolve(context_id, &resources, old_shader)
	testing.expect(t, module == nil)
	testing.expect_value(t, id, u32(0))

	// Out-of-range and unoccupied handles also fall back.
	slot.occupied = false
	current := Gpu_3D_Shader {
		id = _resource_handle_make_context(context_id, 0, slot.generation),
	}
	module, id = _gpu_3d_shader_resolve(context_id, &resources, current)
	testing.expect(t, module == nil)
	testing.expect_value(t, id, u32(0))
}

@(test)
test_gpu_3d_shader_pool_bounds :: proc(t: ^testing.T) {
	// The pool bound must fit the handle index space like the mesh pool.
	testing.expect(t, GPU_3D_MAX_SHADERS <= RESOURCE_SLOT_COUNT)
	testing.expect(t, GPU_3D_MAX_SHADERS > 0)
	// Custom pipelines share the bounded pipeline cache; keep headroom so a
	// full shader pool cannot alone exhaust it (one entry per format/style
	// combination actually drawn, at least one per shader).
	testing.expect(t, GPU_3D_MAX_SHADERS < GPU_3D_MAX_PIPELINES)
}

// -- lighting, uniforms, textures, instancing ----------------------------------

@(test)
test_gpu_3d_uniforms_layout_locked :: proc(t: ^testing.T) {
	// The Odin structs are copied raw into the uniform stream and read back
	// through the WGSL views, so their sizes are load-bearing contracts.
	testing.expect(t, size_of(Gpu_3D_Uniforms) >= 224, "uniforms smaller than WGSL view")
	testing.expect_value(t, size_of(Gpu_3D_Uniforms) % 16, 0)
	testing.expect_value(t, size_of(Gpu_3D_Vertex), 36)
	testing.expect_value(t, size_of(Matrix), 64)
	testing.expect_value(
		t,
		size_of(Gpu_3D_Instance_Uniforms),
		GPU_3D_MAX_INSTANCES_PER_DRAW * size_of(Matrix),
	)
	testing.expect(t, size_of(Gpu_3D_Instance_Uniforms) <= 65536, "over uniform-binding floor")
}

@(test)
test_gpu_3d_default_light_matches_legacy_shader :: proc(t: ^testing.T) {
	// These values were the hard-coded shader constants before lighting
	// became configurable; default rendering must stay bit-identical.
	testing.expect_value(t, GPU_3D_DEFAULT_LIGHT.direction, Vector3{0.4, 0.8, 0.3})
	testing.expect_value(t, GPU_3D_DEFAULT_LIGHT.ambient, f32(0.25))
	testing.expect_value(t, GPU_3D_DEFAULT_LIGHT.diffuse, f32(0.75))
}

@(test)
test_light_normalize_contract :: proc(t: ^testing.T) {
	normalized, ok := _light_normalize({direction = {0, 0, 10}, ambient = -1, diffuse = 7})
	testing.expect(t, ok)
	testing.expect_value(t, normalized.direction, Vector3{0, 0, 1})
	testing.expect_value(t, normalized.ambient, f32(0))
	testing.expect_value(t, normalized.diffuse, f32(1))

	kept, kept_ok := _light_normalize({direction = {1, 0, 0}, ambient = 0.4, diffuse = 0.5})
	testing.expect(t, kept_ok)
	testing.expect_value(t, kept.ambient, f32(0.4))
	testing.expect_value(t, kept.diffuse, f32(0.5))

	// Degenerate direction is rejected, not silently defaulted.
	_, zero_ok := _light_normalize({direction = {}, ambient = 0.5, diffuse = 0.5})
	testing.expect(t, !zero_ok)
}

@(test)
test_sphere_mesh_uvs_cover_unit_square :: proc(t: ^testing.T) {
	vertices := make([dynamic]Gpu_3D_Vertex, context.temp_allocator)
	indices := make([dynamic]u32, context.temp_allocator)
	_sphere_mesh_geometry(1, 8, 12, &vertices, &indices)
	u_min, v_min := f32(1), f32(1)
	u_max, v_max := f32(0), f32(0)
	for v in vertices {
		testing.expect(t, v.uv.x >= 0 && v.uv.x <= 1, "u outside [0, 1]")
		testing.expect(t, v.uv.y >= 0 && v.uv.y <= 1, "v outside [0, 1]")
		u_min = min(u_min, v.uv.x)
		u_max = max(u_max, v.uv.x)
		v_min = min(v_min, v.uv.y)
		v_max = max(v_max, v.uv.y)
	}
	// The parametric grid must span the full square including the wrap seam.
	testing.expect_value(t, u_min, f32(0))
	testing.expect_value(t, u_max, f32(1))
	testing.expect_value(t, v_min, f32(0))
	testing.expect_value(t, v_max, f32(1))
}

@(test)
test_gpu_3d_chunk_count_boundaries :: proc(t: ^testing.T) {
	testing.expect_value(t, _gpu_3d_chunk_count(0), 0)
	testing.expect_value(t, _gpu_3d_chunk_count(1), 1)
	testing.expect_value(t, _gpu_3d_chunk_count(GPU_3D_MAX_INSTANCES_PER_DRAW - 1), 1)
	testing.expect_value(t, _gpu_3d_chunk_count(GPU_3D_MAX_INSTANCES_PER_DRAW), 1)
	testing.expect_value(t, _gpu_3d_chunk_count(GPU_3D_MAX_INSTANCES_PER_DRAW + 1), 2)
	testing.expect_value(t, _gpu_3d_chunk_count(2 * GPU_3D_MAX_INSTANCES_PER_DRAW + 1), 3)
	testing.expect_value(t, _gpu_3d_chunk_count(171), 1)
}

@(test)
test_draw_gpu_mesh_instanced_rejects_headless :: proc(t: ^testing.T) {
	// Without a device there is no active pass; both the nil pass and the
	// empty transform list must be quiet no-ops, never crashes.
	transforms := [?]Matrix{1}
	draw_gpu_mesh_instanced(nil, Gpu_Mesh{}, transforms[:], {})
	pass: Gpu_3D_Pass
	draw_gpu_mesh_instanced(&pass, Gpu_Mesh{}, nil, {})
	draw_gpu_mesh_outlined(nil, {}, {}, 1, {}, {})
	draw_gpu_mesh_outlined(&pass, {}, {}, 1, {}, {})
	testing.expect(t, !pass.active)
}
