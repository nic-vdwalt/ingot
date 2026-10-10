package gfx

import "core:math"
import wg "vendor:wgpu"

@(private)
_gpu_3d_compat_ensure :: proc(ctx: ^Context) -> bool {
	assert(ctx != nil, "_gpu_3d_compat_ensure: nil context")
	assert(ctx.initialized, "_gpu_3d_compat_ensure: uninitialized context")
	resources := &ctx.resources.gpu_3d
	if resources.active_pass_generation != 0 do return false
	compat := &resources.compat
	width := context_render_width(ctx)
	height := context_render_height(ctx)
	if width <= 0 || height <= 0 do return false
	_, _, target_ok := gpu_3d_target_size(&compat.target)
	if !target_ok {
		compat.target, target_ok = context_create_gpu_3d_target(ctx, width, height, .MSAA_4X)
	} else if context_resize_gpu_3d_target_to_render_size(ctx, &compat.target) == .Failed {
		return false
	}
	if compat.cube.id == 0 do compat.cube, _ = _gpu_3d_create_cube_mesh(ctx)
	if compat.cube_edges.id == 0 do compat.cube_edges, _ = _gpu_3d_create_cube_edge_mesh(ctx)
	return target_ok && compat.cube.id != 0 && compat.cube_edges.id != 0
}

@(private)
_gpu_3d_compat_begin :: proc(ctx: ^Context, camera: Camera3D) -> bool {
	assert(ctx != nil, "_gpu_3d_compat_begin: nil context")
	resources := &ctx.resources.gpu_3d
	compat := &resources.compat
	assert(!compat.pass_available, "_gpu_3d_compat_begin: pass already available")
	if !ctx.frame.has_frame || !_gpu_3d_compat_ensure(ctx) do return false
	compat.pass, compat.pass_available = context_begin_gpu_3d(ctx, &compat.target, camera)
	if !compat.pass_available do return false
	set_gpu_3d_light(&compat.pass, {direction = CAMERA_WORLD_UP, ambient = 1, diffuse = 0})
	return true
}

@(private)
_gpu_3d_compat_end :: proc(ctx: ^Context) {
	assert(ctx != nil, "_gpu_3d_compat_end: nil context")
	compat := &ctx.resources.gpu_3d.compat
	if !compat.pass_available do return
	assert(compat.pass.active, "_gpu_3d_compat_end: inactive pass")
	end_gpu_3d(&compat.pass)
	compat.pass_available = false
	context_draw_gpu_3d_target(ctx, &compat.target, {0, 0, f32(ctx.width), f32(ctx.height)}, WHITE)
	assert(!compat.pass.active, "_gpu_3d_compat_end: pass still active")
}

@(private)
_cube_mesh_geometry :: proc(
	vertices: ^[GPU_3D_CUBE_VERTEX_COUNT]Gpu_3D_Vertex,
	indices: ^[GPU_3D_CUBE_INDEX_COUNT]u32,
) {
	assert(vertices != nil, "_cube_mesh_geometry: nil vertices")
	assert(indices != nil, "_cube_mesh_geometry: nil indices")
	vertices^ = {
		{position = {0.5, -0.5, -0.5}, normal = {1, 0, 0}, uv = {0, 0}},
		{position = {0.5, 0.5, -0.5}, normal = {1, 0, 0}, uv = {1, 0}},
		{position = {0.5, 0.5, 0.5}, normal = {1, 0, 0}, uv = {1, 1}},
		{position = {0.5, -0.5, 0.5}, normal = {1, 0, 0}, uv = {0, 1}},
		{position = {-0.5, 0.5, -0.5}, normal = {-1, 0, 0}, uv = {0, 0}},
		{position = {-0.5, -0.5, -0.5}, normal = {-1, 0, 0}, uv = {1, 0}},
		{position = {-0.5, -0.5, 0.5}, normal = {-1, 0, 0}, uv = {1, 1}},
		{position = {-0.5, 0.5, 0.5}, normal = {-1, 0, 0}, uv = {0, 1}},
		{position = {-0.5, 0.5, -0.5}, normal = {0, 1, 0}, uv = {0, 0}},
		{position = {0.5, 0.5, -0.5}, normal = {0, 1, 0}, uv = {1, 0}},
		{position = {0.5, 0.5, 0.5}, normal = {0, 1, 0}, uv = {1, 1}},
		{position = {-0.5, 0.5, 0.5}, normal = {0, 1, 0}, uv = {0, 1}},
		{position = {0.5, -0.5, -0.5}, normal = {0, -1, 0}, uv = {0, 0}},
		{position = {-0.5, -0.5, -0.5}, normal = {0, -1, 0}, uv = {1, 0}},
		{position = {-0.5, -0.5, 0.5}, normal = {0, -1, 0}, uv = {1, 1}},
		{position = {0.5, -0.5, 0.5}, normal = {0, -1, 0}, uv = {0, 1}},
		{position = {-0.5, -0.5, 0.5}, normal = {0, 0, 1}, uv = {0, 0}},
		{position = {0.5, -0.5, 0.5}, normal = {0, 0, 1}, uv = {1, 0}},
		{position = {0.5, 0.5, 0.5}, normal = {0, 0, 1}, uv = {1, 1}},
		{position = {-0.5, 0.5, 0.5}, normal = {0, 0, 1}, uv = {0, 1}},
		{position = {-0.5, 0.5, -0.5}, normal = {0, 0, -1}, uv = {0, 0}},
		{position = {0.5, 0.5, -0.5}, normal = {0, 0, -1}, uv = {1, 0}},
		{position = {0.5, -0.5, -0.5}, normal = {0, 0, -1}, uv = {1, 1}},
		{position = {-0.5, -0.5, -0.5}, normal = {0, 0, -1}, uv = {0, 1}},
	}
	indices^ = {
		0,
		1,
		2,
		0,
		2,
		3,
		4,
		5,
		6,
		4,
		6,
		7,
		8,
		10,
		9,
		8,
		11,
		10,
		12,
		14,
		13,
		12,
		15,
		14,
		16,
		17,
		18,
		16,
		18,
		19,
		20,
		21,
		22,
		20,
		22,
		23,
	}
	assert(_gpu_3d_geometry_valid(vertices^[:], indices^[:], .Triangles))
}

@(private)
_cube_edge_mesh_geometry :: proc(
	vertices: ^[GPU_3D_CUBE_CORNER_COUNT]Gpu_3D_Vertex,
	indices: ^[GPU_3D_CUBE_EDGE_INDEX_COUNT]u32,
) {
	assert(vertices != nil, "_cube_edge_mesh_geometry: nil vertices")
	assert(indices != nil, "_cube_edge_mesh_geometry: nil indices")
	vertices^ = {
		{position = {-0.5, -0.5, -0.5}},
		{position = {0.5, -0.5, -0.5}},
		{position = {0.5, 0.5, -0.5}},
		{position = {-0.5, 0.5, -0.5}},
		{position = {-0.5, -0.5, 0.5}},
		{position = {0.5, -0.5, 0.5}},
		{position = {0.5, 0.5, 0.5}},
		{position = {-0.5, 0.5, 0.5}},
	}
	indices^ = {0, 1, 1, 2, 2, 3, 3, 0, 4, 5, 5, 6, 6, 7, 7, 4, 0, 4, 1, 5, 2, 6, 3, 7}
	assert(_gpu_3d_geometry_valid(vertices^[:], indices^[:], .Lines))
}

@(private)
_gpu_3d_create_cube_mesh :: proc(ctx: ^Context) -> (Gpu_Mesh, bool) {
	assert(ctx != nil, "_gpu_3d_create_cube_mesh: nil context")
	vertices: [GPU_3D_CUBE_VERTEX_COUNT]Gpu_3D_Vertex
	indices: [GPU_3D_CUBE_INDEX_COUNT]u32
	_cube_mesh_geometry(&vertices, &indices)
	return context_create_gpu_mesh(ctx, vertices[:], indices[:], .Triangles)
}

create_cube_mesh :: proc() -> (Gpu_Mesh, bool) {
	return _gpu_3d_create_cube_mesh(default_context())
}

@(private)
_gpu_3d_create_cube_edge_mesh :: proc(ctx: ^Context) -> (Gpu_Mesh, bool) {
	assert(ctx != nil, "_gpu_3d_create_cube_edge_mesh: nil context")
	vertices: [GPU_3D_CUBE_CORNER_COUNT]Gpu_3D_Vertex
	indices: [GPU_3D_CUBE_EDGE_INDEX_COUNT]u32
	_cube_edge_mesh_geometry(&vertices, &indices)
	return context_create_gpu_mesh(ctx, vertices[:], indices[:], .Lines)
}

create_cube_edge_mesh :: proc() -> (Gpu_Mesh, bool) {
	return _gpu_3d_create_cube_edge_mesh(default_context())
}

@(private)
_grid_mesh_geometry :: proc(
	slices: i32,
	vertices: ^[GPU_3D_COMPAT_GRID_MAX_VERTICES]Gpu_3D_Vertex,
	indices: ^[GPU_3D_COMPAT_GRID_MAX_INDICES]u32,
) -> (
	vertex_count, index_count: int,
	ok: bool,
) {
	assert(vertices != nil, "_grid_mesh_geometry: nil vertices")
	assert(indices != nil, "_grid_mesh_geometry: nil indices")
	if slices < 1 || slices > GPU_3D_COMPAT_GRID_MAX_SLICES do return 0, 0, false
	line_count := (slices + 1) * 2
	vertex_count = int(line_count * 2)
	index_count = vertex_count
	extent := f32(slices) * 0.5
	for line in 0 ..= slices {
		offset := f32(line) - extent
		vertex := int(line * 4)
		vertices[vertex + 0].position = {-extent, offset, 0}
		vertices[vertex + 1].position = {extent, offset, 0}
		vertices[vertex + 2].position = {offset, -extent, 0}
		vertices[vertex + 3].position = {offset, extent, 0}
		for index in 0 ..< 4 do indices[vertex + index] = u32(vertex + index)
	}
	assert(vertex_count <= len(vertices), "_grid_mesh_geometry: vertex overflow")
	assert(index_count <= len(indices), "_grid_mesh_geometry: index overflow")
	return vertex_count, index_count, true
}

@(private)
_gpu_3d_compat_grid :: proc(ctx: ^Context, slices: i32) -> (Gpu_Mesh, bool) {
	assert(ctx != nil, "_gpu_3d_compat_grid: nil context")
	resources := &ctx.resources.gpu_3d
	assert(resources.compat.grid_count <= GPU_3D_COMPAT_GRID_CACHE_COUNT)
	for grid in resources.compat.grids[:resources.compat.grid_count] {
		if grid.slices == slices do return grid.mesh, true
	}
	if resources.compat.grid_count >= GPU_3D_COMPAT_GRID_CACHE_COUNT do return {}, false
	vertices: [GPU_3D_COMPAT_GRID_MAX_VERTICES]Gpu_3D_Vertex
	indices: [GPU_3D_COMPAT_GRID_MAX_INDICES]u32
	vertex_count, index_count, geometry_ok := _grid_mesh_geometry(slices, &vertices, &indices)
	if !geometry_ok do return {}, false
	mesh, mesh_ok := context_create_gpu_mesh(
		ctx,
		vertices[:vertex_count],
		indices[:index_count],
		.Lines,
	)
	if !mesh_ok do return {}, false
	index := resources.compat.grid_count
	resources.compat.grids[index] = {
		mesh   = mesh,
		slices = slices,
	}
	resources.compat.grid_count += 1
	assert(resources.compat.grid_count <= GPU_3D_COMPAT_GRID_CACHE_COUNT)
	return mesh, true
}

// _sphere_mesh_geometry generates a UV sphere's vertex/index lists - pure
// CPU, no GPU calls - split out of create_sphere_mesh so headless tests can
// validate counts, bounds, and normals without a device.
@(private)
_sphere_mesh_geometry :: proc(
	radius: f32,
	rings, slices: u32,
	vertices: ^[dynamic]Gpu_3D_Vertex,
	indices: ^[dynamic]u32,
) {
	assert(vertices != nil, "_sphere_mesh_geometry: nil vertices")
	assert(indices != nil, "_sphere_mesh_geometry: nil indices")
	assert(radius > 0)
	assert(rings >= 2 && slices >= 3)
	for ring: u32 = 0; ring <= rings; ring += 1 {
		v := f32(ring) / f32(rings)
		phi := v * f32(math.PI)
		for slice: u32 = 0; slice <= slices; slice += 1 {
			u := f32(slice) / f32(slices)
			theta := u * f32(math.TAU)
			normal := [3]f32 {
				f32(math.sin(f64(phi))) * f32(math.cos(f64(theta))),
				f32(math.sin(f64(phi))) * f32(math.sin(f64(theta))),
				f32(math.cos(f64(phi))),
			}
			// Spherical UVs: u wraps the equator, v runs pole to pole - both
			// already computed as the parametric ring/slice fractions.
			append(
				vertices,
				Gpu_3D_Vertex{position = normal * radius, normal = normal, uv = {u, v}},
			)
		}
	}
	row := slices + 1
	for ring: u32 = 0; ring < rings; ring += 1 {
		for slice: u32 = 0; slice < slices; slice += 1 {
			a := ring * row + slice
			b := a + row
			append(indices, a, b, a + 1, a + 1, b, b + 1)
		}
	}
	assert(len(vertices) == int((rings + 1) * (slices + 1)))
	assert(len(indices) == int(rings * slices * 6))
}

context_create_sphere_mesh :: proc(
	ctx: ^Context,
	radius: f32,
	rings, slices: u32,
) -> (
	Gpu_Mesh,
	bool,
) {
	assert(ctx != nil, "context_create_sphere_mesh: nil context")
	assert(radius > 0)
	if !ctx.initialized || rings < 2 || slices < 3 do return {}, false
	resources := &ctx.resources.gpu_3d
	if resources.mesh_count >= GPU_3D_MAX_MESHES {
		// Pool full: operating condition - caller gets ok=false (counted).
		_stats_gpu3d_pool_exhaustion(ctx)
		return {}, false
	}

	vertices := make([dynamic]Gpu_3D_Vertex, 0, int((rings + 1) * (slices + 1)))
	indices := make([dynamic]u32, 0, int(rings * slices * 6))
	defer delete(vertices)
	defer delete(indices)
	_sphere_mesh_geometry(radius, rings, slices, &vertices, &indices)

	entry := new(Gpu_3D_Mesh_Entry)
	entry.vertex_buffer = _gpu_3d_buffer(
		ctx,
		raw_data(vertices),
		u64(len(vertices)) * size_of(Gpu_3D_Vertex),
		{.Vertex},
	)
	entry.index_buffer = _gpu_3d_buffer(
		ctx,
		raw_data(indices),
		u64(len(indices)) * size_of(u32),
		{.Index},
	)
	entry.index_count = u32(len(indices))
	entry.vertex_count = u32(len(vertices))
	entry.primitive = .Triangles
	if entry.vertex_buffer == nil || entry.index_buffer == nil {
		if entry.vertex_buffer != nil do wg.BufferRelease(entry.vertex_buffer)
		if entry.index_buffer != nil do wg.BufferRelease(entry.index_buffer)
		free(entry)
		return {}, false
	}
	for &slot, index in resources.meshes {
		if slot.occupied do continue
		slot.generation = _resource_generation_next(slot.generation)
		slot.entry = entry
		slot.occupied = true
		resources.mesh_count += 1
		return Gpu_Mesh{id = _resource_handle_make_context(ctx.id, index, slot.generation)}, true
	}
	assert(false, "context_create_sphere_mesh: count mismatch")
	return {}, false
}

create_sphere_mesh :: proc(radius: f32, rings, slices: u32) -> (Gpu_Mesh, bool) {
	return context_create_sphere_mesh(default_context(), radius, rings, slices)
}

// plane_mesh_vertex_count and plane_mesh_index_count expose create_plane_mesh's
// geometry arithmetic so an application that reuses the topology - rewriting
// vertices each frame through update_gpu_mesh_vertices - can size and check its
// own storage against the same formula the generator uses, instead of
// re-deriving it and drifting.
plane_mesh_vertex_count :: proc(cells: u32) -> u32 {
	assert(cells >= 1, "plane_mesh_vertex_count: empty plane")
	assert(cells <= GPU_3D_PLANE_MAX_CELLS, "plane_mesh_vertex_count: cells over bound")
	return (cells + 1) * (cells + 1)
}

plane_mesh_index_count :: proc(cells: u32) -> u32 {
	assert(cells >= 1, "plane_mesh_index_count: empty plane")
	assert(cells <= GPU_3D_PLANE_MAX_CELLS, "plane_mesh_index_count: cells over bound")
	return cells * cells * 6
}

// _plane_mesh_geometry generates a flat XY plane centered on the local origin -
// pure CPU, no GPU calls - split out of create_plane_mesh so headless tests can
// validate counts, ordering, winding, and UVs without a device.
//
// Vertex order is row-major with y outermost and x innermost, and index
// (row, column) is therefore at row * (cells + 1) + column. That ordering is
// part of the public contract because callers that deform the surface refill
// the vertex buffer themselves and must address the same vertices.
@(private)
_plane_mesh_geometry :: proc(
	extent: f32,
	cells: u32,
	vertices: []Gpu_3D_Vertex,
	indices: []u32,
) -> (
	vertex_count, index_count: int,
	ok: bool,
) {
	assert(extent > 0, "_plane_mesh_geometry: non-positive extent")
	assert(cells >= 1, "_plane_mesh_geometry: empty plane")
	assert(cells <= GPU_3D_PLANE_MAX_CELLS, "_plane_mesh_geometry: cells over bound")
	vertex_count = int(plane_mesh_vertex_count(cells))
	index_count = int(plane_mesh_index_count(cells))
	// Undersized caller storage is an operating condition, not a programmer
	// error: cells is often a runtime tuning value.
	if len(vertices) < vertex_count || len(indices) < index_count do return 0, 0, false
	stride := cells + 1
	step := 2 * extent / f32(cells)
	vertex := 0
	for row in 0 ..= cells {
		y := -extent + f32(row) * step
		for column in 0 ..= cells {
			x := -extent + f32(column) * step
			vertices[vertex] = {
				position = {x, y, 0},
				normal   = CAMERA_WORLD_UP,
				uv       = {f32(column) / f32(cells), f32(row) / f32(cells)},
			}
			vertex += 1
		}
	}
	index := 0
	for row in 0 ..< cells {
		for column in 0 ..< cells {
			origin := row * stride + column
			// Counter-clockwise seen from +Z, matching the cube's outward
			// winding so one cull policy serves both.
			indices[index + 0] = origin
			indices[index + 1] = origin + 1
			indices[index + 2] = origin + stride
			indices[index + 3] = origin + 1
			indices[index + 4] = origin + stride + 1
			indices[index + 5] = origin + stride
			index += 6
		}
	}
	assert(vertex == vertex_count, "_plane_mesh_geometry: vertex count mismatch")
	assert(index == index_count, "_plane_mesh_geometry: index count mismatch")
	return vertex_count, index_count, true
}

// create_plane_mesh uploads a flat XY plane centered on the local origin with
// +Z normals and [0, 1] UVs, spanning [-extent, +extent] on both axes and
// subdivided into cells x cells quads. Model transforms provide the final
// placement.
//
// A deforming surface - water, terrain, cloth - creates this once for its
// topology and then rewrites positions and normals each frame with
// update_gpu_mesh_vertices, using plane_mesh_vertex_count to size its buffer
// and the row-major ordering documented on _plane_mesh_geometry to address it.
context_create_plane_mesh :: proc(ctx: ^Context, extent: f32, cells: u32) -> (Gpu_Mesh, bool) {
	assert(ctx != nil, "context_create_plane_mesh: nil context")
	assert(extent > 0, "context_create_plane_mesh: non-positive extent")
	if !ctx.initialized || cells < 1 || cells > GPU_3D_PLANE_MAX_CELLS do return {}, false

	vertices := make([dynamic]Gpu_3D_Vertex, int(plane_mesh_vertex_count(cells)))
	indices := make([dynamic]u32, int(plane_mesh_index_count(cells)))
	defer delete(vertices)
	defer delete(indices)
	vertex_count, index_count, ok := _plane_mesh_geometry(extent, cells, vertices[:], indices[:])
	if !ok do return {}, false
	assert(vertex_count == len(vertices), "context_create_plane_mesh: vertex storage mismatch")
	assert(index_count == len(indices), "context_create_plane_mesh: index storage mismatch")

	return context_create_gpu_mesh(ctx, vertices[:], indices[:], .Triangles)
}

create_plane_mesh :: proc(extent: f32, cells: u32) -> (Gpu_Mesh, bool) {
	return context_create_plane_mesh(default_context(), extent, cells)
}
