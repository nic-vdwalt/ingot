package gfx

import "core:math"
import wg "vendor:wgpu"

// Fixed pools (Tiger Style: every pool has a static upper bound). Exhaustion
// is an operating condition, not a programmer error: create_sphere_mesh
// returns ok=false and draw_gpu_mesh skips draws once the pipeline pool is
// full - both are counted in renderer_stats().gpu3d_pool_exhaustions.
GPU_3D_MAX_MESHES :: 256
GPU_3D_MAX_PIPELINES :: 48
GPU_3D_MAX_SHADERS :: 8
GPU_3D_MAX_VERTICES :: 1_048_576
GPU_3D_MAX_INDICES :: 6_291_456
GPU_3D_MAX_MESH_BYTES :: 128 * 1024 * 1024
GPU_3D_CUBE_FACE_COUNT :: 6
GPU_3D_CUBE_FACE_VERTEX_COUNT :: 4
GPU_3D_CUBE_FACE_TRIANGLE_COUNT :: 2
GPU_3D_CUBE_TRIANGLE_INDEX_COUNT :: 3
GPU_3D_CUBE_VERTEX_COUNT :: 24
GPU_3D_CUBE_INDEX_COUNT :: 36
GPU_3D_CUBE_CORNER_COUNT :: 8
GPU_3D_CUBE_EDGE_COUNT :: 12
GPU_3D_CUBE_EDGE_INDEX_COUNT :: 24
GPU_3D_COMPAT_GRID_CACHE_COUNT :: 8
GPU_3D_COMPAT_GRID_MAX_SLICES :: 256
GPU_3D_COMPAT_GRID_MAX_VERTICES :: (GPU_3D_COMPAT_GRID_MAX_SLICES + 1) * 4
GPU_3D_COMPAT_GRID_MAX_INDICES :: GPU_3D_COMPAT_GRID_MAX_VERTICES
// A plane's cost is quadratic in its cell count, so the bound is chosen as the
// largest power of two whose geometry still clears every mesh cap below with
// room to spare: 513*513 vertices and 512*512*6 indices is about 15 MiB.
GPU_3D_PLANE_MAX_CELLS :: 512
GPU_3D_PLANE_MAX_VERTICES :: (GPU_3D_PLANE_MAX_CELLS + 1) * (GPU_3D_PLANE_MAX_CELLS + 1)
GPU_3D_PLANE_MAX_INDICES :: GPU_3D_PLANE_MAX_CELLS * GPU_3D_PLANE_MAX_CELLS * 6
#assert(GPU_3D_PLANE_MAX_VERTICES <= GPU_3D_MAX_VERTICES)
#assert(GPU_3D_PLANE_MAX_INDICES <= GPU_3D_MAX_INDICES)
#assert(
	GPU_3D_PLANE_MAX_VERTICES * size_of(Gpu_3D_Vertex) + GPU_3D_PLANE_MAX_INDICES * 4 <=
	GPU_3D_MAX_MESH_BYTES,
)
#assert(GPU_3D_CUBE_VERTEX_COUNT == GPU_3D_CUBE_FACE_COUNT * GPU_3D_CUBE_FACE_VERTEX_COUNT)
#assert(
	GPU_3D_CUBE_INDEX_COUNT ==
	GPU_3D_CUBE_FACE_COUNT * GPU_3D_CUBE_FACE_TRIANGLE_COUNT * GPU_3D_CUBE_TRIANGLE_INDEX_COUNT,
)
#assert(GPU_3D_CUBE_EDGE_INDEX_COUNT == GPU_3D_CUBE_EDGE_COUNT * 2)
// 256 transforms fill one 16 KiB uniform binding - safely under the 64 KiB
// maxUniformBufferBindingSize floor WebGPU guarantees on every adapter, and
// large enough that per-chunk overhead amortizes to one upload and one draw.
GPU_3D_MAX_INSTANCES_PER_DRAW :: 256

Gpu_Mesh :: struct {
	id: u32,
}

Gpu_Primitive :: enum u8 {
	Triangles,
	Lines,
	Points,
}

Gpu_3D_Antialiasing :: enum u8 {
	None,
	MSAA_4X,
}

Gpu_3D_Target_Resize_Result :: enum u8 {
	Unchanged,
	Resized,
	Deferred,
	Failed,
}

Gpu_3D_Target :: struct {
	texture:           RenderTexture2D,
	antialiasing:      Gpu_3D_Antialiasing,
	multisample_color: ^Tex_Entry,
	multisample_depth: ^Tex_Entry,
}

Gpu_Material_Style :: enum {
	Default,
	Opaque,
	Opaque_Overlay,
	Opaque_Outline,
}

Gpu_Material :: struct {
	color:       Color,
	color_high:  Color,
	use_scalar:  bool,
	style:       Gpu_Material_Style,
	// depth_nudge shifts fragments toward the camera by a constant NDC
	// offset. Unlike pipeline depthBias - which WebGPU forbids on line and
	// point topologies - it works on every primitive, so overlays (wire
	// grids, point clouds) can sit on coplanar surfaces without z-fighting.
	depth_nudge: f32,
	// texture with a zero id means untextured: the draw binds the shared
	// neutral white texture and the shader multiplies by pure white.
	texture:     Texture2D,
	// shader with a zero id means the built-in GPU_3D_SHADER; a custom
	// handle from create_gpu_3d_shader replaces both shader stages. Stale
	// handles fall back to the built-in shader (operating condition).
	shader:      Gpu_3D_Shader,
}

Gpu_3D_Light :: struct {
	direction: Vector3, // world-space direction toward the light
	ambient:   f32, // 0..1 base illumination independent of angle
	diffuse:   f32, // 0..1 angle-dependent contribution
}

// Matches the previously hard-coded shader constants so default rendering is
// bit-identical for consumers that never call set_gpu_3d_light.
GPU_3D_DEFAULT_LIGHT :: Gpu_3D_Light {
	direction = {0.4, 0.8, 0.3},
	ambient   = 0.25,
	diffuse   = 0.75,
}

Gpu_3D_Load_Action :: enum {
	Clear,
	Preserve,
}

Gpu_3D_Pass :: struct {
	owner:                     ^Context,
	epoch:                     u64,
	encoder:                   wg.CommandEncoder,
	pass:                      wg.RenderPassEncoder,
	target:                    ^Gpu_3D_Target,
	view_projection:           Matrix,
	light:                     Gpu_3D_Light,
	// World-space camera eye fed to shaders for view-dependent shading.
	// begin_gpu_3d fills it from the camera; begin_gpu_3d_pro supplies a
	// synthetic camera, so callers wanting meaningful view-dependent
	// shading there must set this field themselves after begin.
	camera_position:           Vector3,
	// Pass start time in seconds since context start, fed to shaders via
	// light_params.w for animation.
	time:                      f32,
	generation:                u64,
	active:                    bool,
	sample_count:              u32,
	owns_stream:               bool,
	// Offset of the shared identity instance block uploaded once per pass;
	// plain draw_gpu_mesh calls reuse it so the instance binding's
	// minBindingSize cost is paid once per pass, not once per draw.
	identity_instances_offset: u32,
}

Gpu_3D_Vertex :: struct {
	position: [3]f32,
	normal:   [3]f32,
	scalar:   f32,
	uv:       [2]f32,
}

Gpu_3D_Uniforms :: struct {
	view_projection: Matrix,
	model:           Matrix,
	color:           [4]f32,
	color_high:      [4]f32,
	light_direction: [4]f32, // xyz direction toward the light, w unused
	light_params:    [4]f32, // x ambient, y diffuse, z depth_nudge, w time seconds
	camera_position: [4]f32, // xyz world-space camera position, w unused
	use_scalar:      u32,
	use_texture:     u32,
	_padding:        [2]u32,
}

// Per-instance model transforms for draw_gpu_mesh_instanced, read by the
// shader through @builtin(instance_index). The block is copied raw into the
// uniform stream, so the Odin layout must match the WGSL
// array<mat4x4<f32>, N> stride of 64 bytes exactly on every target.
Gpu_3D_Instance_Uniforms :: struct {
	transforms: [GPU_3D_MAX_INSTANCES_PER_DRAW]Matrix,
}

// The dynamic-offset uniform bind group declares minBindingSize =
// size_of(Gpu_3D_Uniforms). The WGSL view of the struct is 224 bytes (two
// mat4x4 + five vec4 + one 16-byte u32 block); Odin may append tail padding
// (matrix alignment is target-dependent), and WebGPU permits a binding
// larger than the shader view. Lock the invariants a struct edit could
// silently break: never smaller than the shader view, always 16-byte
// aligned as dynamic offsets require.
#assert(size_of(Gpu_3D_Uniforms) >= 224)
#assert(size_of(Gpu_3D_Uniforms) % 16 == 0)
#assert(size_of(Gpu_3D_Vertex) == 36)
#assert(size_of(Matrix) == 64)
#assert(size_of(Gpu_3D_Instance_Uniforms) == GPU_3D_MAX_INSTANCES_PER_DRAW * size_of(Matrix))
// Stay under the 64 KiB uniform-binding floor WebGPU guarantees everywhere.
#assert(size_of(Gpu_3D_Instance_Uniforms) <= 65536)

@(private)
Gpu_3D_Mesh_Entry :: struct {
	vertex_buffer: wg.Buffer,
	index_buffer:  wg.Buffer,
	index_count:   u32,
	vertex_count:  u32,
	primitive:     Gpu_Primitive,
}

@(private)
Gpu_3D_Pipeline_Entry :: struct {
	format:       wg.TextureFormat,
	primitive:    Gpu_Primitive,
	style:        Gpu_Material_Style,
	sample_count: u32,
	shader_id:    u32, // 0 = built-in GPU_3D_SHADER
	pipeline:     wg.RenderPipeline,
}

@(private)
Gpu_3D_Material_Policy :: struct {
	blend:         bool,
	depth_write:   bool,
	depth_compare: wg.CompareFunction,
	depth_bias:    i32,
}

@(private)
_gpu_3d_material_policy :: proc(style: Gpu_Material_Style) -> Gpu_3D_Material_Policy {
	return {
		blend = style == .Default,
		depth_write = style != .Opaque_Overlay && style != .Opaque_Outline,
		depth_compare = .LessEqual if style == .Opaque_Outline else .Less,
		depth_bias = -2 if style == .Opaque_Overlay else 0,
	}
}

@(private)
_gpu_3d_pipeline_matches :: proc(
	entry: Gpu_3D_Pipeline_Entry,
	format: wg.TextureFormat,
	primitive: Gpu_Primitive,
	style: Gpu_Material_Style,
	sample_count: u32,
	shader_id: u32,
) -> bool {
	return(
		entry.format == format &&
		entry.primitive == primitive &&
		entry.style == style &&
		entry.sample_count == sample_count &&
		entry.shader_id == shader_id \
	)
}

@(private)
Gpu_3D_Mesh_Slot :: struct {
	entry:      ^Gpu_3D_Mesh_Entry,
	generation: u32,
	occupied:   bool,
}

// Handle to a custom WGSL module usable in Gpu_Material.shader. The module
// must declare the exact same bind groups, vertex attributes, and entry
// points (vs_main / fs_main) as GPU_3D_SHADER; only the shading logic may
// differ. id 0 means the built-in shader.
Gpu_3D_Shader :: struct {
	id: u32,
}

@(private)
Gpu_3D_Shader_Slot :: struct {
	module:     wg.ShaderModule,
	generation: u32,
	occupied:   bool,
}

@(private)
Gpu_3D_Compat_Grid :: struct {
	mesh:   Gpu_Mesh,
	slices: i32,
}

@(private)
Gpu_3D_Compat :: struct {
	target:         Gpu_3D_Target,
	cube:           Gpu_Mesh,
	cube_edges:     Gpu_Mesh,
	grids:          [GPU_3D_COMPAT_GRID_CACHE_COUNT]Gpu_3D_Compat_Grid,
	grid_count:     u32,
	pass:           Gpu_3D_Pass,
	pass_available: bool,
}

Gpu_3D_Resources :: struct {
	meshes:                 [GPU_3D_MAX_MESHES]Gpu_3D_Mesh_Slot,
	mesh_count:             u32,
	pipelines:              [GPU_3D_MAX_PIPELINES]Gpu_3D_Pipeline_Entry,
	pipeline_count:         u32,
	shaders:                [GPU_3D_MAX_SHADERS]Gpu_3D_Shader_Slot,
	shader_count:           u32,
	shader:                 wg.ShaderModule,
	layout:                 wg.BindGroupLayout,
	bind:                   [STREAM_SLOT_COUNT]wg.BindGroup,
	next_pass_generation:   u64,
	active_pass_generation: u64,
	compat:                 Gpu_3D_Compat,
}

#assert(GPU_3D_MAX_MESHES <= RESOURCE_SLOT_COUNT)
#assert(GPU_3D_MAX_SHADERS <= RESOURCE_SLOT_COUNT)

GPU_3D_SHADER :: `
struct Uniforms {
    view_projection: mat4x4<f32>,
    model: mat4x4<f32>,
    color: vec4<f32>,
    color_high: vec4<f32>,
    light_direction: vec4<f32>,
    light_params: vec4<f32>,
    camera_position: vec4<f32>,
    use_scalar: u32,
    use_texture: u32,
    padding: vec2<u32>,
};
// Array length mirrors GPU_3D_MAX_INSTANCES_PER_DRAW.
struct Instances {
    transforms: array<mat4x4<f32>, 256>,
};
@group(0) @binding(0) var<uniform> u: Uniforms;
@group(0) @binding(1) var<uniform> instances: Instances;
@group(1) @binding(0) var mesh_texture: texture_2d<f32>;
@group(1) @binding(1) var mesh_sampler: sampler;

struct VertexOut {
    @builtin(position) position: vec4<f32>,
    @location(0) normal: vec3<f32>,
    @location(1) scalar: f32,
    @location(2) uv: vec2<f32>,
};

@vertex
fn vs_main(
    @builtin(instance_index) instance_index: u32,
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) scalar: f32,
    @location(3) uv: vec2<f32>,
) -> VertexOut {
    var out: VertexOut;
    let model = u.model * instances.transforms[instance_index];
    out.position = u.view_projection * model * vec4<f32>(position, 1.0);
    // Nudge NDC depth after projection; multiplying by w keeps the offset a
    // constant NDC shift after the perspective divide, which lets overlay
    // materials win the depth test on line and point topologies where
    // WebGPU forbids pipeline depthBias.
    out.position.z -= u.light_params.z * out.position.w;
    out.normal = normalize((model * vec4<f32>(normal, 0.0)).xyz);
    out.scalar = scalar;
    out.uv = uv;
    return out;
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4<f32> {
    let light = normalize(u.light_direction.xyz);
    let diffuse = u.light_params.x + u.light_params.y * max(dot(normalize(in.normal), light), 0.0);
    // Sample unconditionally and select by flag: textureSample requires
    // uniform control flow, and the unconditional form is trivially uniform
    // regardless of analyzer strictness. Untextured draws bind the neutral
    // white texture, so the multiply is exact identity.
    let texel = textureSample(mesh_texture, mesh_sampler, in.uv);
    var base = u.color;
    if u.use_scalar != 0u {
        base = mix(u.color, u.color_high, clamp(in.scalar, 0.0, 1.0));
    }
    base = mix(base, base * texel, f32(u.use_texture));
    return vec4<f32>(base.rgb * diffuse * base.a, base.a);
}
`

@(private)
_gpu_3d_sample_count :: proc(antialiasing: Gpu_3D_Antialiasing) -> u32 {
	#partial switch antialiasing {
	case .None:
		return 1
	case .MSAA_4X:
		return 4
	}
	return 1
}

@(private)
_gpu_3d_target_create :: proc(
	ctx: ^Context,
	width, height: i32,
	antialiasing: Gpu_3D_Antialiasing,
) -> (
	Gpu_3D_Target,
	bool,
) {
	assert(ctx != nil, "_gpu_3d_target_create: nil context")
	if !ctx.initialized || width <= 0 || height <= 0 do return {}, false
	target := Gpu_3D_Target {
		texture      = LoadRenderTextureEx(width, height, ctx.format, true),
		antialiasing = antialiasing,
	}
	ok := target.texture.texture.id != 0 && target.texture.depth.id != 0
	if !ok {
		if target.texture.texture.id != 0 do UnloadRenderTexture(target.texture)
		return {}, false
	}
	if antialiasing == .MSAA_4X {
		target.multisample_color = _new_rt_attachment(ctx, width, height, ctx.format, 4)
		target.multisample_depth = _new_rt_attachment(ctx, width, height, .Depth24Plus, 4)
		if target.multisample_color == nil || target.multisample_depth == nil {
			_gpu_3d_target_destroy(ctx, &target)
			return {}, false
		}
	}
	return target, true
}

@(private)
_gpu_3d_target_destroy :: proc(ctx: ^Context, target: ^Gpu_3D_Target) {
	assert(ctx != nil, "_gpu_3d_target_destroy: nil context")
	assert(target != nil, "_gpu_3d_target_destroy: nil target")
	assert(
		ctx.resources.gpu_3d.active_pass_generation == 0,
		"_gpu_3d_target_destroy: active GPU 3D pass",
	)
	_destroy_rt_attachment(target.multisample_color)
	_destroy_rt_attachment(target.multisample_depth)
	if target.texture.texture.id != 0 do UnloadRenderTexture(target.texture)
	target^ = {}
	assert(target.texture.texture.id == 0)
	assert(target.multisample_color == nil && target.multisample_depth == nil)
}

@(private)
_gpu_3d_target_views :: proc(
	ctx: ^Context,
	target: ^Gpu_3D_Target,
) -> (
	wg.TextureView,
	wg.TextureView,
	wg.TextureView,
	u32,
	bool,
) {
	assert(ctx != nil && target != nil, "_gpu_3d_target_views: invalid arguments")
	color_slot := _texture_slot_context(ctx.id, &ctx.resources.textures, target.texture.texture.id)
	depth_slot := _texture_slot_context(ctx.id, &ctx.resources.textures, target.texture.depth.id)
	if color_slot == nil || depth_slot == nil do return nil, nil, nil, 0, false
	if color_slot.entry == nil || depth_slot.entry == nil do return nil, nil, nil, 0, false
	if color_slot.entry.view == nil || depth_slot.entry.view == nil do return nil, nil, nil, 0, false
	assert(color_slot.entry.sample_count == 1, "_gpu_3d_target_views: multisampled resolve color")
	assert(depth_slot.entry.sample_count == 1, "_gpu_3d_target_views: multisampled resolve depth")
	sample_count := _gpu_3d_sample_count(target.antialiasing)
	if sample_count == 1 do return color_slot.entry.view, depth_slot.entry.view, nil, 1, true
	assert(target.multisample_color != nil, "_gpu_3d_target_views: missing multisample color")
	assert(target.multisample_depth != nil, "_gpu_3d_target_views: missing multisample depth")
	color := target.multisample_color
	depth := target.multisample_depth
	assert(
		color.view != nil && depth.view != nil,
		"_gpu_3d_target_views: invalid multisample view",
	)
	assert(color.sample_count == sample_count, "_gpu_3d_target_views: color sample-count mismatch")
	assert(depth.sample_count == sample_count, "_gpu_3d_target_views: depth sample-count mismatch")
	assert(
		color.wgformat == color_slot.entry.wgformat,
		"_gpu_3d_target_views: resolve format mismatch",
	)
	assert(
		color.width == color_slot.entry.width && color.height == color_slot.entry.height,
		"_gpu_3d_target_views: resolve dimensions mismatch",
	)
	assert(
		depth.width == depth_slot.entry.width && depth.height == depth_slot.entry.height,
		"_gpu_3d_target_views: depth dimensions mismatch",
	)
	return color.view, depth.view, color_slot.entry.view, sample_count, true
}

create_gpu_3d_target :: proc(
	width, height: i32,
	antialiasing: Gpu_3D_Antialiasing = .None,
) -> (
	Gpu_3D_Target,
	bool,
) {
	return _gpu_3d_target_create(active_context(), width, height, antialiasing)
}

destroy_gpu_3d_target :: proc(target: ^Gpu_3D_Target) {
	_gpu_3d_target_destroy(active_context(), target)
}

gpu_3d_target_size :: proc(target: ^Gpu_3D_Target) -> (width, height: i32, ok: bool) {
	if target == nil do return 0, 0, false
	color := target.texture.texture
	depth := target.texture.depth
	if color.id == 0 || depth.id == 0 do return 0, 0, false
	if color.width <= 0 || color.height <= 0 do return 0, 0, false
	if color.width != depth.width || color.height != depth.height do return 0, 0, false
	return color.width, color.height, true
}

resize_gpu_3d_target :: proc(target: ^Gpu_3D_Target, width, height: i32) -> bool {
	assert(target != nil, "resize_gpu_3d_target: nil target")
	ctx := active_context()
	assert(
		ctx.resources.gpu_3d.active_pass_generation == 0,
		"resize_gpu_3d_target: active GPU 3D pass",
	)
	if width <= 0 || height <= 0 do return false
	if target.texture.texture.width == width && target.texture.texture.height == height do return true
	antialiasing := target.antialiasing
	replacement, ok := _gpu_3d_target_create(ctx, width, height, antialiasing)
	if !ok do return false
	_gpu_3d_target_destroy(ctx, target)
	target^ = replacement
	assert(target.texture.texture.width == width, "resize_gpu_3d_target: wrong width")
	assert(target.texture.texture.height == height, "resize_gpu_3d_target: wrong height")
	assert(target.antialiasing == antialiasing, "resize_gpu_3d_target: wrong antialiasing")
	return true
}

resize_gpu_3d_target_to_render_size :: proc(
	target: ^Gpu_3D_Target,
) -> Gpu_3D_Target_Resize_Result {
	assert(target != nil, "resize_gpu_3d_target_to_render_size: nil target")
	ctx := active_context()
	width := context_render_width(ctx)
	height := context_render_height(ctx)
	if width <= 0 || height <= 0 do return .Deferred
	current_width, current_height, ok := gpu_3d_target_size(target)
	if !ok do return .Failed
	if current_width == width && current_height == height do return .Unchanged
	if !resize_gpu_3d_target(target, width, height) do return .Failed
	return .Resized
}

@(private)
_gpu_3d_target_source_rectangle :: proc(target: ^Gpu_3D_Target) -> (Rectangle, bool) {
	assert(target != nil, "_gpu_3d_target_source_rectangle: nil target")
	width, height, ok := gpu_3d_target_size(target)
	if !ok do return {}, false
	return {0, 0, f32(width), f32(height)}, true
}

draw_gpu_3d_target :: proc(target: ^Gpu_3D_Target, destination: Rectangle, tint: Color = WHITE) {
	assert(target != nil, "draw_gpu_3d_target: nil target")
	ctx := active_context()
	assert(
		ctx.resources.gpu_3d.active_pass_generation == 0,
		"draw_gpu_3d_target: active GPU 3D pass",
	)
	source, ok := _gpu_3d_target_source_rectangle(target)
	if !ok do return
	DrawTexturePro(target.texture.texture, source, destination, {}, 0, tint)
}

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
		compat.target, target_ok = create_gpu_3d_target(width, height, .MSAA_4X)
	} else if resize_gpu_3d_target_to_render_size(&compat.target) == .Failed {
		return false
	}
	if compat.cube.id == 0 do compat.cube, _ = create_cube_mesh()
	if compat.cube_edges.id == 0 do compat.cube_edges, _ = create_cube_edge_mesh()
	return target_ok && compat.cube.id != 0 && compat.cube_edges.id != 0
}

@(private)
_gpu_3d_compat_begin :: proc(ctx: ^Context, camera: Camera3D) -> bool {
	assert(ctx != nil, "_gpu_3d_compat_begin: nil context")
	resources := &ctx.resources.gpu_3d
	compat := &resources.compat
	assert(!compat.pass_available, "_gpu_3d_compat_begin: pass already available")
	if !ctx.frame.has_frame || !_gpu_3d_compat_ensure(ctx) do return false
	compat.pass, compat.pass_available = begin_gpu_3d(&compat.target, camera)
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
	draw_gpu_3d_target(
		&compat.target,
		{0, 0, f32(GetScreenWidth()), f32(GetScreenHeight())},
		WHITE,
	)
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

create_cube_mesh :: proc() -> (Gpu_Mesh, bool) {
	vertices: [GPU_3D_CUBE_VERTEX_COUNT]Gpu_3D_Vertex
	indices: [GPU_3D_CUBE_INDEX_COUNT]u32
	_cube_mesh_geometry(&vertices, &indices)
	return create_gpu_mesh(vertices[:], indices[:], .Triangles)
}

create_cube_edge_mesh :: proc() -> (Gpu_Mesh, bool) {
	vertices: [GPU_3D_CUBE_CORNER_COUNT]Gpu_3D_Vertex
	indices: [GPU_3D_CUBE_EDGE_INDEX_COUNT]u32
	_cube_edge_mesh_geometry(&vertices, &indices)
	return create_gpu_mesh(vertices[:], indices[:], .Lines)
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
_gpu_3d_compat_grid :: proc(resources: ^Gpu_3D_Resources, slices: i32) -> (Gpu_Mesh, bool) {
	assert(resources != nil, "_gpu_3d_compat_grid: nil resources")
	assert(resources.compat.grid_count <= GPU_3D_COMPAT_GRID_CACHE_COUNT)
	for grid in resources.compat.grids[:resources.compat.grid_count] {
		if grid.slices == slices do return grid.mesh, true
	}
	if resources.compat.grid_count >= GPU_3D_COMPAT_GRID_CACHE_COUNT do return {}, false
	vertices: [GPU_3D_COMPAT_GRID_MAX_VERTICES]Gpu_3D_Vertex
	indices: [GPU_3D_COMPAT_GRID_MAX_INDICES]u32
	vertex_count, index_count, geometry_ok := _grid_mesh_geometry(slices, &vertices, &indices)
	if !geometry_ok do return {}, false
	mesh, mesh_ok := create_gpu_mesh(vertices[:vertex_count], indices[:index_count], .Lines)
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

create_sphere_mesh :: proc(radius: f32, rings, slices: u32) -> (Gpu_Mesh, bool) {
	assert(radius > 0)
	if !g.initialized || rings < 2 || slices < 3 do return {}, false
	resources := &g.resources.gpu_3d
	if resources.mesh_count >= GPU_3D_MAX_MESHES {
		// Pool full: operating condition - caller gets ok=false (counted).
		_stats_gpu3d_pool_exhaustion()
		return {}, false
	}

	vertices := make([dynamic]Gpu_3D_Vertex, 0, int((rings + 1) * (slices + 1)))
	indices := make([dynamic]u32, 0, int(rings * slices * 6))
	defer delete(vertices)
	defer delete(indices)
	_sphere_mesh_geometry(radius, rings, slices, &vertices, &indices)

	entry := new(Gpu_3D_Mesh_Entry)
	entry.vertex_buffer = _gpu_3d_buffer(
		raw_data(vertices),
		u64(len(vertices)) * size_of(Gpu_3D_Vertex),
		{.Vertex},
	)
	entry.index_buffer = _gpu_3d_buffer(
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
		return Gpu_Mesh{id = _resource_handle_make(index, slot.generation)}, true
	}
	assert(false, "create_sphere_mesh: count mismatch")
	return {}, false
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
create_plane_mesh :: proc(extent: f32, cells: u32) -> (Gpu_Mesh, bool) {
	assert(extent > 0, "create_plane_mesh: non-positive extent")
	// The context is read the same way create_gpu_mesh reads it, so a plane
	// built for an explicitly created context is not gated on the default one.
	ctx := active_context()
	if !ctx.initialized || cells < 1 || cells > GPU_3D_PLANE_MAX_CELLS do return {}, false

	vertices := make([dynamic]Gpu_3D_Vertex, int(plane_mesh_vertex_count(cells)))
	indices := make([dynamic]u32, int(plane_mesh_index_count(cells)))
	defer delete(vertices)
	defer delete(indices)
	vertex_count, index_count, ok := _plane_mesh_geometry(extent, cells, vertices[:], indices[:])
	if !ok do return {}, false
	assert(vertex_count == len(vertices), "create_plane_mesh: vertex storage mismatch")
	assert(index_count == len(indices), "create_plane_mesh: index storage mismatch")

	return create_gpu_mesh(vertices[:], indices[:], .Triangles)
}

create_gpu_mesh :: proc(
	vertices: []Gpu_3D_Vertex,
	indices: []u32,
	primitive: Gpu_Primitive = .Triangles,
) -> (
	Gpu_Mesh,
	bool,
) {
	ctx := active_context()
	if !ctx.initialized || !_gpu_3d_geometry_valid(vertices, indices, primitive) do return {}, false
	resources := &ctx.resources.gpu_3d
	if resources.mesh_count >= GPU_3D_MAX_MESHES {
		_stats_gpu3d_pool_exhaustion()
		return {}, false
	}
	entry := new(Gpu_3D_Mesh_Entry)
	entry.vertex_buffer = _gpu_3d_buffer(
		raw_data(vertices),
		u64(len(vertices)) * size_of(Gpu_3D_Vertex),
		{.Vertex},
	)
	entry.index_buffer = _gpu_3d_buffer(
		raw_data(indices),
		u64(len(indices)) * size_of(u32),
		{.Index},
	)
	entry.index_count = u32(len(indices))
	entry.vertex_count = u32(len(vertices))
	entry.primitive = primitive
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
		_stats_gpu3d_mesh_upload(ctx, entry.vertex_count, entry.index_count)
		return Gpu_Mesh{id = _resource_handle_make(index, slot.generation)}, true
	}
	assert(false, "create_gpu_mesh: count mismatch")
	return {}, false
}

// update_gpu_mesh_vertices rewrites an existing mesh's vertex buffer in place,
// keeping its index buffer, primitive, and handle. Deforming geometry - a water
// surface, a cloth, a morphing blend shape - changes positions and normals every
// frame while its topology never moves, so destroying and recreating the mesh
// would release and reallocate a GPU buffer per frame and burn a pool slot's
// generation for nothing.
//
// The vertex count is deliberately fixed at creation: a resize is a different
// mesh, and allowing one here would mean silently reallocating the buffer behind
// a caller that believes it is writing into the geometry it built.
update_gpu_mesh_vertices :: proc(mesh: Gpu_Mesh, vertices: []Gpu_3D_Vertex) -> bool {
	ctx := active_context()
	if !ctx.initialized || len(vertices) == 0 do return false
	entry := _gpu_3d_mesh(&ctx.resources.gpu_3d, mesh)
	if entry == nil do return false
	if u32(len(vertices)) != entry.vertex_count do return false
	assert(entry.vertex_buffer != nil, "update_gpu_mesh_vertices: mesh without a buffer")
	bytes := uint(len(vertices)) * size_of(Gpu_3D_Vertex)
	assert(bytes > 0, "update_gpu_mesh_vertices: empty write")
	wg.QueueWriteBuffer(ctx.queue, entry.vertex_buffer, 0, raw_data(vertices), bytes)
	_stats_gpu3d_mesh_upload(ctx, entry.vertex_count, entry.index_count)
	return true
}

destroy_gpu_mesh :: proc(mesh: ^Gpu_Mesh) {
	assert(mesh != nil)
	slot := _gpu_3d_mesh_slot(&g.resources.gpu_3d, mesh^)
	if slot == nil {
		mesh^ = {}
		return
	}
	_gpu_3d_mesh_entry_destroy(slot.entry)
	slot.entry = nil
	slot.occupied = false
	assert(g.resources.gpu_3d.mesh_count > 0, "destroy_gpu_mesh: count underflow")
	g.resources.gpu_3d.mesh_count -= 1
	mesh^ = {}
	assert(mesh.id == 0)
}

// create_gpu_3d_shader registers a custom WGSL module for use in
// Gpu_Material.shader. The code must declare the same bind groups, vertex
// attributes, and vs_main/fs_main entry points as GPU_3D_SHADER; pipeline
// validation failures surface as skipped draws, not crashes. Pool
// exhaustion is an operating condition: ok=false, counted.
create_gpu_3d_shader :: proc(code: string) -> (Gpu_3D_Shader, bool) {
	ctx := active_context()
	if !ctx.initialized || len(code) == 0 do return {}, false
	resources := &ctx.resources.gpu_3d
	if resources.shader_count >= GPU_3D_MAX_SHADERS {
		_stats_gpu3d_pool_exhaustion()
		return {}, false
	}
	module := wg.DeviceCreateShaderModule(
		ctx.device,
		&{nextInChain = &wg.ShaderSourceWGSL{chain = {sType = .ShaderSourceWGSL}, code = code}},
	)
	if module == nil do return {}, false
	for &slot, index in resources.shaders {
		if slot.occupied do continue
		slot.generation = _resource_generation_next(slot.generation)
		slot.module = module
		slot.occupied = true
		resources.shader_count += 1
		return Gpu_3D_Shader{id = _resource_handle_make(index, slot.generation)}, true
	}
	assert(false, "create_gpu_3d_shader: count mismatch")
	return {}, false
}

// destroy_gpu_3d_shader releases a custom shader module and every cached
// pipeline built from it. Zero or stale handles are a no-op; the handle is
// zeroed either way. Must not be called inside an active 3D pass.
destroy_gpu_3d_shader :: proc(shader: ^Gpu_3D_Shader) {
	assert(shader != nil, "destroy_gpu_3d_shader: nil shader")
	ctx := active_context()
	defer shader^ = {}
	if !ctx.initialized || shader.id == 0 do return
	resources := &ctx.resources.gpu_3d
	assert(resources.active_pass_generation == 0, "destroy_gpu_3d_shader: active pass")
	index, generation, ok := _resource_handle_decode(shader.id, len(resources.shaders))
	if !ok do return
	slot := &resources.shaders[index]
	if !slot.occupied || slot.generation != generation do return
	// Swap-remove cached pipelines built from this module; the cache is a
	// dense linear-scan array so order does not matter.
	pipeline_index := u32(0)
	for pipeline_index < resources.pipeline_count {
		entry := &resources.pipelines[pipeline_index]
		if entry.shader_id != shader.id {
			pipeline_index += 1
			continue
		}
		if entry.pipeline != nil do wg.RenderPipelineRelease(entry.pipeline)
		resources.pipeline_count -= 1
		entry^ = resources.pipelines[resources.pipeline_count]
		resources.pipelines[resources.pipeline_count] = {}
	}
	wg.ShaderModuleRelease(slot.module)
	slot.module = nil
	slot.occupied = false
	assert(resources.shader_count > 0, "destroy_gpu_3d_shader: count underflow")
	resources.shader_count -= 1
}

// _gpu_3d_shader_resolve maps a material's shader handle to the module used
// for pipeline creation. Zero or stale handles fall back to the built-in
// shader (nil module, id 0) - an operating condition matching the texture
// fallback policy.
@(private)
_gpu_3d_shader_resolve :: proc(
	resources: ^Gpu_3D_Resources,
	shader: Gpu_3D_Shader,
) -> (
	wg.ShaderModule,
	u32,
) {
	assert(resources != nil, "_gpu_3d_shader_resolve: nil resources")
	if shader.id == 0 do return nil, 0
	index, generation, ok := _resource_handle_decode(shader.id, len(resources.shaders))
	if !ok do return nil, 0
	assert(index >= 0 && index < len(resources.shaders), "_gpu_3d_shader_resolve: invalid index")
	slot := &resources.shaders[index]
	if !slot.occupied || slot.generation != generation do return nil, 0
	return slot.module, shader.id
}

begin_gpu_3d :: proc(
	target: ^Gpu_3D_Target,
	camera: Camera3D,
	load: Gpu_3D_Load_Action = .Clear,
) -> (
	Gpu_3D_Pass,
	bool,
) {
	assert(target != nil)
	ctx := active_context()
	resources := &ctx.resources.gpu_3d
	if resources.active_pass_generation != 0 do return {}, false
	if !ctx.initialized || target.texture.texture.id == 0 || target.texture.depth.id == 0 {
		return {}, false
	}
	color_view, depth_view, resolve_view, sample_count, views_ok := _gpu_3d_target_views(
		ctx,
		target,
	)
	if !views_ok do return {}, false
	owns_stream := !ctx.frame.has_frame
	if owns_stream && !_stream_slot_acquire(&ctx.rend, _submission_completed(&ctx.submissions)) {
		_stats_stream_slot_exhaustion(ctx)
		return {}, false
	}
	identity_offset, identity_ok := _gpu_3d_identity_instances_upload(&ctx.rend)
	if !identity_ok {
		// Uniform stream exhausted at pass start: operating condition - the
		// reservation failure is counted inside _uniform_upload, and a slot
		// acquired only for this pass must be handed back.
		if owns_stream do _stream_slot_abandon(&ctx.rend)
		return {}, false
	}

	color := wg.RenderPassColorAttachment {
		view          = color_view,
		resolveTarget = resolve_view,
		depthSlice    = wg.DEPTH_SLICE_UNDEFINED,
		loadOp        = load == .Clear ? .Clear : .Load,
		storeOp       = .Store,
		clearValue    = {0, 0, 0, 0},
	}
	depth := wg.RenderPassDepthStencilAttachment {
		view            = depth_view,
		depthLoadOp     = load == .Clear ? .Clear : .Load,
		depthStoreOp    = .Store,
		depthClearValue = 1,
		stencilLoadOp   = .Undefined,
		stencilStoreOp  = .Undefined,
	}
	encoder := wg.DeviceCreateCommandEncoder(ctx.device, nil)
	pass := wg.CommandEncoderBeginRenderPass(
		encoder,
		&{colorAttachmentCount = 1, colorAttachments = &color, depthStencilAttachment = &depth},
	)
	resources.next_pass_generation += 1
	if resources.next_pass_generation == 0 do resources.next_pass_generation = 1
	resources.active_pass_generation = resources.next_pass_generation
	_stats_render_pass(ctx)
	result := Gpu_3D_Pass {
		owner                     = ctx,
		epoch                     = ctx.epoch,
		encoder                   = encoder,
		pass                      = pass,
		target                    = target,
		light                     = GPU_3D_DEFAULT_LIGHT,
		camera_position           = camera.position,
		time                      = f32(context_time(ctx)),
		generation                = resources.active_pass_generation,
		active                    = true,
		sample_count              = sample_count,
		owns_stream               = owns_stream,
		identity_instances_offset = identity_offset,
	}
	_gpu_3d_set_camera(&result, camera)
	return result, true
}

// set_gpu_3d_light overrides the pass light for subsequent draw calls. The
// direction is normalized and intensities clamped to [0, 1] so the shader
// contract (unit direction, bounded factors) always holds.
set_gpu_3d_light :: proc(pass: ^Gpu_3D_Pass, light: Gpu_3D_Light) {
	assert(pass != nil, "set_gpu_3d_light: nil pass")
	normalized, ok := _light_normalize(light)
	assert(ok, "set_gpu_3d_light: degenerate light direction")
	pass.light = normalized
}

// _light_normalize is the pure core of set_gpu_3d_light, split out so the
// clamping and normalization contract is headless-testable.
@(private)
_light_normalize :: proc(light: Gpu_3D_Light) -> (Gpu_3D_Light, bool) {
	assert(_f32_is_finite(light.ambient), "_light_normalize: non-finite ambient")
	assert(_f32_is_finite(light.diffuse), "_light_normalize: non-finite diffuse")
	direction, direction_ok := _camera_vector_normalize(light.direction)
	if !direction_ok do return {}, false
	return {
			direction = direction,
			ambient = clamp(light.ambient, 0, 1),
			diffuse = clamp(light.diffuse, 0, 1),
		},
		true
}

begin_gpu_3d_pro :: proc(
	target: ^Gpu_3D_Target,
	view_projection: Matrix,
	load: Gpu_3D_Load_Action = .Clear,
) -> (
	Gpu_3D_Pass,
	bool,
) {
	assert(target != nil)
	assert(view_projection != (Matrix{}), "begin_gpu_3d_pro: zero view-projection")
	camera := Camera3D {
		position   = -CAMERA_WORLD_FORWARD,
		target     = {},
		up         = CAMERA_WORLD_UP,
		fovy       = 60,
		projection = .PERSPECTIVE,
	}
	pass, ok := begin_gpu_3d(target, camera, load)
	if ok do pass.view_projection = view_projection
	return pass, ok
}

draw_gpu_mesh :: proc(
	pass: ^Gpu_3D_Pass,
	mesh: Gpu_Mesh,
	transform: Matrix,
	material: Gpu_Material,
) {
	if pass == nil || !_gpu_3d_pass_current(&pass.owner.resources.gpu_3d, pass) do return
	entry := _gpu_3d_mesh(&pass.owner.resources.gpu_3d, mesh)
	if entry == nil do return
	// A skipped draw (pool or stream exhaustion) is the documented operating
	// behavior; the failure is counted inside the helper.
	_ = _gpu_3d_draw_indexed(pass, entry, material, transform, pass.identity_instances_offset, 1)
}

draw_gpu_mesh_outlined :: proc(
	pass: ^Gpu_3D_Pass,
	mesh, outline_mesh: Gpu_Mesh,
	transform: Matrix,
	material: Gpu_Material,
	outline_color: Color,
) {
	if pass == nil || !_gpu_3d_pass_current(&pass.owner.resources.gpu_3d, pass) do return
	solid_material := material
	solid_material.style = .Opaque
	draw_gpu_mesh(pass, mesh, transform, solid_material)
	draw_gpu_mesh(pass, outline_mesh, transform, {color = outline_color, style = .Opaque_Outline})
}

// draw_gpu_mesh_instanced draws one mesh under many model transforms. Input
// is chunked at GPU_3D_MAX_INSTANCES_PER_DRAW; each chunk is one uniform
// upload plus one indexed draw, which is the batching win over per-mesh
// draw_gpu_mesh calls.
draw_gpu_mesh_instanced :: proc(
	pass: ^Gpu_3D_Pass,
	mesh: Gpu_Mesh,
	transforms: []Matrix,
	material: Gpu_Material,
) {
	if pass == nil || !_gpu_3d_pass_current(&pass.owner.resources.gpu_3d, pass) do return
	// An empty transform list is a valid no-op, not a programmer error.
	if len(transforms) == 0 do return
	entry := _gpu_3d_mesh(&pass.owner.resources.gpu_3d, mesh)
	if entry == nil do return
	chunk_count := _gpu_3d_chunk_count(len(transforms))
	assert(chunk_count > 0, "draw_gpu_mesh_instanced: zero chunks for non-empty input")
	for chunk_index in 0 ..< chunk_count {
		start := chunk_index * GPU_3D_MAX_INSTANCES_PER_DRAW
		count := min(len(transforms) - start, GPU_3D_MAX_INSTANCES_PER_DRAW)
		assert(count > 0, "draw_gpu_mesh_instanced: empty chunk")
		assert(start + count <= len(transforms), "draw_gpu_mesh_instanced: chunk out of range")
		instances_offset, upload_ok := _gpu_3d_instance_upload(
			&pass.owner.rend,
			transforms[start:start + count],
		)
		if !upload_ok {
			// Uniform stream exhausted mid-batch: stop rather than draw with
			// stale instance data - counted inside _uniform_upload.
			return
		}
		// The chunk transforms carry the full model matrix, so the shared
		// uniform model slot is identity for instanced draws.
		if !_gpu_3d_draw_indexed(pass, entry, material, 1, instances_offset, u32(count)) do return
		_stats_gpu3d_instanced_draw(pass.owner)
	}
}

// _gpu_3d_chunk_count is the pure chunking rule for instanced draws, split
// out so the boundary arithmetic is headless-testable.
@(private)
_gpu_3d_chunk_count :: proc(transform_count: int) -> int {
	assert(transform_count >= 0, "_gpu_3d_chunk_count: negative count")
	count := (transform_count + GPU_3D_MAX_INSTANCES_PER_DRAW - 1) / GPU_3D_MAX_INSTANCES_PER_DRAW
	assert(
		count * GPU_3D_MAX_INSTANCES_PER_DRAW >= transform_count,
		"_gpu_3d_chunk_count: chunks too few",
	)
	return count
}

// _gpu_3d_instance_upload copies one chunk of instance transforms into the
// uniform stream. The full block size is reserved even for partial chunks
// because the bind group layout's minBindingSize covers the whole array.
@(private)
_gpu_3d_instance_upload :: proc(r: ^Renderer, transforms: []Matrix) -> (u32, bool) {
	assert(r != nil, "_gpu_3d_instance_upload: nil renderer")
	assert(len(transforms) > 0, "_gpu_3d_instance_upload: empty chunk")
	assert(
		len(transforms) <= GPU_3D_MAX_INSTANCES_PER_DRAW,
		"_gpu_3d_instance_upload: chunk exceeds GPU_3D_MAX_INSTANCES_PER_DRAW",
	)
	block: Gpu_3D_Instance_Uniforms
	copy(block.transforms[:len(transforms)], transforms)
	return _uniform_upload(r, &block, size_of(Gpu_3D_Instance_Uniforms))
}

@(private)
_gpu_3d_identity_block: Gpu_3D_Instance_Uniforms
@(private)
_gpu_3d_identity_block_ready: bool

// _gpu_3d_identity_instances_upload reserves the shared per-pass instance
// block. Every slot is identity so a hypothetical out-of-range instance
// index would render untransformed instead of collapsing geometry through a
// zero matrix.
@(private)
_gpu_3d_identity_instances_upload :: proc(r: ^Renderer) -> (u32, bool) {
	assert(r != nil, "_gpu_3d_identity_instances_upload: nil renderer")
	if !_gpu_3d_identity_block_ready {
		for index in 0 ..< GPU_3D_MAX_INSTANCES_PER_DRAW {
			_gpu_3d_identity_block.transforms[index] = 1
		}
		_gpu_3d_identity_block_ready = true
	}
	assert(
		_gpu_3d_identity_block.transforms[0] == Matrix(1),
		"_gpu_3d_identity_instances_upload: corrupted identity block",
	)
	return _uniform_upload(r, &_gpu_3d_identity_block, size_of(Gpu_3D_Instance_Uniforms))
}

// _gpu_3d_texture_bind resolves the material texture to a bind group. Stale
// or destroyed handles are an operating condition (a consumer may destroy a
// texture between frames): fall back to the neutral white texture instead of
// failing the draw, matching the 2D batch behavior.
@(private)
_gpu_3d_texture_bind :: proc(ctx: ^Context, material: Gpu_Material) -> (wg.BindGroup, bool) {
	assert(ctx != nil, "_gpu_3d_texture_bind: nil context")
	assert(ctx.initialized, "_gpu_3d_texture_bind: uninitialized context")
	assert(ctx.rend.neutral_bind != nil, "_gpu_3d_texture_bind: missing neutral texture")
	if material.texture.id != 0 {
		slot := _texture_slot_context(ctx.id, &ctx.resources.textures, material.texture.id)
		if slot != nil && slot.entry != nil && slot.entry.bind != nil {
			return slot.entry.bind, true
		}
	}
	return ctx.rend.neutral_bind, false
}

// _gpu_3d_draw_indexed encodes one indexed draw: uniforms, both bind groups,
// buffers, and stats. Shared by plain and instanced draws so the two paths
// cannot drift.
@(private)
_gpu_3d_draw_indexed :: proc(
	pass: ^Gpu_3D_Pass,
	entry: ^Gpu_3D_Mesh_Entry,
	material: Gpu_Material,
	transform: Matrix,
	instances_offset: u32,
	instance_count: u32,
) -> bool {
	assert(pass != nil, "_gpu_3d_draw_indexed: nil pass")
	assert(entry != nil, "_gpu_3d_draw_indexed: nil mesh entry")
	assert(instance_count >= 1, "_gpu_3d_draw_indexed: zero instances")
	assert(
		instance_count <= GPU_3D_MAX_INSTANCES_PER_DRAW,
		"_gpu_3d_draw_indexed: instance count exceeds GPU_3D_MAX_INSTANCES_PER_DRAW",
	)
	target_slot := _texture_slot_context(
		pass.owner.id,
		&pass.owner.resources.textures,
		pass.target.texture.texture.id,
	)
	if target_slot == nil || target_slot.entry == nil do return false
	shader_module, shader_id := _gpu_3d_shader_resolve(
		&pass.owner.resources.gpu_3d,
		material.shader,
	)
	pipeline := _gpu_3d_pipeline(
		pass.owner,
		target_slot.entry.wgformat,
		entry.primitive,
		material.style,
		pass.sample_count,
		shader_id,
		shader_module,
	)
	if pipeline == nil do return false
	texture_bind, textured := _gpu_3d_texture_bind(pass.owner, material)

	color_high := material.color_high
	if color_high == (Color{}) do color_high = material.color
	light := pass.light
	uniforms := Gpu_3D_Uniforms {
		view_projection = pass.view_projection,
		model           = transform,
		color           = col_f(material.color),
		color_high      = col_f(color_high),
		light_direction = {light.direction.x, light.direction.y, light.direction.z, 0},
		light_params    = {light.ambient, light.diffuse, material.depth_nudge, pass.time},
		camera_position = {
			pass.camera_position.x,
			pass.camera_position.y,
			pass.camera_position.z,
			0,
		},
		use_scalar      = u32(1) if material.use_scalar else 0,
		use_texture     = u32(1) if textured else 0,
	}
	offset, ok := _uniform_upload(&pass.owner.rend, &uniforms, size_of(uniforms))
	if !ok || pass.owner.rend.active_stream_slot < 0 do return false
	wg.RenderPassEncoderSetPipeline(pass.pass, pipeline)
	// Dynamic offsets follow binding order: shared uniforms then instances.
	offsets := [2]u32{offset, instances_offset}
	wg.RenderPassEncoderSetBindGroup(
		pass.pass,
		0,
		pass.owner.resources.gpu_3d.bind[pass.owner.rend.active_stream_slot],
		offsets[:],
	)
	wg.RenderPassEncoderSetBindGroup(pass.pass, 1, texture_bind)
	vertex_bytes := u64(entry.vertex_count) * size_of(Gpu_3D_Vertex)
	index_bytes := u64(entry.index_count) * size_of(u32)
	wg.RenderPassEncoderSetVertexBuffer(pass.pass, 0, entry.vertex_buffer, 0, vertex_bytes)
	wg.RenderPassEncoderSetIndexBuffer(pass.pass, entry.index_buffer, .Uint32, 0, index_bytes)
	wg.RenderPassEncoderDrawIndexed(pass.pass, entry.index_count, instance_count, 0, 0, 0)
	_stats_gpu3d_draw(
		pass.owner,
		entry.vertex_count * instance_count,
		entry.index_count * instance_count,
	)
	_stats_pipeline_switch()
	_stats_bind_group_switches(2)
	return true
}

end_gpu_3d :: proc(pass: ^Gpu_3D_Pass) {
	if !_gpu_3d_pass_current(&g.resources.gpu_3d, pass) do return
	wg.RenderPassEncoderEnd(pass.pass)
	wg.RenderPassEncoderRelease(pass.pass)
	retirement := u64(0)
	if pass.owns_stream do retirement = _submission_reserve(&g.submissions)
	allow_submit := !pass.owns_stream || retirement != 0
	if pass.owns_stream && allow_submit do assert(_stream_slot_upload(pass.owner, &g.rend))
	cmd, encode_elapsed, submit_elapsed := _stats_finish_submit(g, pass.encoder, allow_submit)
	if allow_submit && cmd != nil {
		_stats_queue_submission(pass.owner)
		if pass.owns_stream {
			assert(_submission_commit(&g.submissions, retirement))
			if !_stream_slot_submitted(&g.rend, retirement) {
				_stats_stream_retirement_failure(pass.owner)
			}
		}
	} else if pass.owns_stream {
		if retirement != 0 do assert(_submission_rollback(&g.submissions, retirement))
		_stream_slot_abandon(&g.rend)
		_stats_stream_retirement_failure(pass.owner)
	}
	_stats_cpu_times(0, encode_elapsed, submit_elapsed, 0)
	if cmd != nil do wg.CommandBufferRelease(cmd)
	wg.CommandEncoderRelease(pass.encoder)
	g.resources.gpu_3d.active_pass_generation = 0
	pass^ = {}
}

@(private)
_gpu_3d_set_camera :: proc(pass: ^Gpu_3D_Pass, camera: Camera3D) {
	assert(pass != nil)
	width := pass.target.texture.texture.width
	height := pass.target.texture.texture.height
	assert(width > 0 && height > 0)
	_, _, pass.view_projection = _camera_matrices(camera, width, height)
}

@(private)
_gpu_3d_mesh_slot :: proc(resources: ^Gpu_3D_Resources, mesh: Gpu_Mesh) -> ^Gpu_3D_Mesh_Slot {
	assert(resources != nil, "_gpu_3d_mesh_slot: nil resources")
	index, generation, ok := _resource_handle_decode(mesh.id, len(resources.meshes))
	if !ok do return nil
	slot := &resources.meshes[index]
	if !slot.occupied || slot.generation != generation do return nil
	return slot
}

@(private)
_gpu_3d_mesh :: proc(resources: ^Gpu_3D_Resources, mesh: Gpu_Mesh) -> ^Gpu_3D_Mesh_Entry {
	assert(resources != nil, "_gpu_3d_mesh: nil resources")
	slot := _gpu_3d_mesh_slot(resources, mesh)
	if slot == nil do return nil
	return slot.entry
}

@(private)
_gpu_3d_pass_current :: proc(resources: ^Gpu_3D_Resources, pass: ^Gpu_3D_Pass) -> bool {
	if resources == nil || pass == nil || !pass.active || pass.generation == 0 do return false
	ctx := active_context()
	if pass.owner != ctx || pass.epoch != ctx.epoch do return false
	return pass.generation == resources.active_pass_generation
}

@(private)
_gpu_3d_mesh_entry_destroy :: proc(entry: ^Gpu_3D_Mesh_Entry) {
	assert(entry != nil, "_gpu_3d_mesh_entry_destroy: nil entry")
	if entry.vertex_buffer != nil do wg.BufferRelease(entry.vertex_buffer)
	if entry.index_buffer != nil do wg.BufferRelease(entry.index_buffer)
	free(entry)
}

@(private)
_gpu_3d_geometry_valid :: proc(
	vertices: []Gpu_3D_Vertex,
	indices: []u32,
	primitive: Gpu_Primitive,
) -> bool {
	if len(vertices) == 0 || len(indices) == 0 do return false
	if len(vertices) > GPU_3D_MAX_VERTICES || len(indices) > GPU_3D_MAX_INDICES do return false
	bytes := u64(len(vertices)) * size_of(Gpu_3D_Vertex) + u64(len(indices)) * size_of(u32)
	if bytes > GPU_3D_MAX_MESH_BYTES do return false
	#partial switch primitive {
	case .Triangles:
		if len(indices) % 3 != 0 do return false
	case .Lines:
		if len(indices) % 2 != 0 do return false
	case .Points:
	}
	for index in indices {
		if int(index) >= len(vertices) do return false
	}
	return true
}

@(private)
_gpu_3d_buffer :: proc(data: rawptr, size: u64, usage: wg.BufferUsageFlags) -> wg.Buffer {
	assert(data != nil)
	assert(size > 0)
	buffer := wg.DeviceCreateBuffer(g.device, &{usage = usage | {.CopyDst}, size = size})
	if buffer == nil do return nil
	wg.QueueWriteBuffer(g.queue, buffer, 0, data, uint(size))
	_stats_buffer_created(false)
	return buffer
}

@(private)
_gpu_3d_primitive_topology :: proc(primitive: Gpu_Primitive) -> wg.PrimitiveTopology {
	#partial switch primitive {
	case .Triangles:
		return .TriangleList
	case .Lines:
		return .LineList
	case .Points:
		return .PointList
	}
	return .TriangleList
}

@(private)
_gpu_3d_pipeline :: proc(
	ctx: ^Context,
	format: wg.TextureFormat,
	primitive: Gpu_Primitive,
	style: Gpu_Material_Style,
	sample_count: u32,
	shader_id: u32 = 0,
	shader_module: wg.ShaderModule = nil,
) -> wg.RenderPipeline {
	assert(ctx != nil, "_gpu_3d_pipeline: nil context")
	assert(ctx.initialized, "_gpu_3d_pipeline: uninitialized context")
	assert(sample_count == 1 || sample_count == 4, "_gpu_3d_pipeline: unsupported sample count")
	assert(
		(shader_id == 0) == (shader_module == nil),
		"_gpu_3d_pipeline: shader id and module must agree",
	)
	resources := &ctx.resources.gpu_3d
	for index in 0 ..< resources.pipeline_count {
		entry := resources.pipelines[index]
		if _gpu_3d_pipeline_matches(entry, format, primitive, style, sample_count, shader_id) {
			return entry.pipeline
		}
	}
	if resources.pipeline_count >= GPU_3D_MAX_PIPELINES {
		_stats_gpu3d_pool_exhaustion()
		return nil
	}
	_gpu_3d_init_shared(ctx, resources)
	module := resources.shader
	if shader_module != nil do module = shader_module
	attrs := [4]wg.VertexAttribute {
		{format = .Float32x3, offset = 0, shaderLocation = 0},
		{format = .Float32x3, offset = u64(offset_of(Gpu_3D_Vertex, normal)), shaderLocation = 1},
		{format = .Float32, offset = u64(offset_of(Gpu_3D_Vertex, scalar)), shaderLocation = 2},
		{format = .Float32x2, offset = u64(offset_of(Gpu_3D_Vertex, uv)), shaderLocation = 3},
	}
	vertex_layout := wg.VertexBufferLayout {
		arrayStride    = size_of(Gpu_3D_Vertex),
		stepMode       = .Vertex,
		attributeCount = len(attrs),
		attributes     = raw_data(attrs[:]),
	}
	group_layouts := [2]wg.BindGroupLayout{resources.layout, ctx.rend.tex_layout}
	layout := wg.DeviceCreatePipelineLayout(
		ctx.device,
		&{bindGroupLayoutCount = 2, bindGroupLayouts = raw_data(group_layouts[:])},
	)
	policy := _gpu_3d_material_policy(style)
	if primitive != .Triangles do policy.depth_bias = 0
	blend := _blend_for(&ctx.rend, .Alpha)
	target := wg.ColorTargetState {
		format    = format,
		writeMask = wg.ColorWriteMaskFlags_All,
	}
	if policy.blend do target.blend = &blend
	depth := wg.DepthStencilState {
		format            = .Depth24Plus,
		depthWriteEnabled = .True if policy.depth_write else .False,
		depthCompare      = policy.depth_compare,
		stencilReadMask   = 0xff,
		stencilWriteMask  = 0xff,
		depthBias         = policy.depth_bias,
	}
	topology := _gpu_3d_primitive_topology(primitive)
	pipeline := wg.DeviceCreateRenderPipeline(
		ctx.device,
		&{
			layout = layout,
			vertex = {
				module = module,
				entryPoint = "vs_main",
				bufferCount = 1,
				buffers = &vertex_layout,
			},
			primitive = {topology = topology, frontFace = .CCW, cullMode = .None},
			depthStencil = &depth,
			multisample = {count = sample_count, mask = ~u32(0)},
			fragment = &wg.FragmentState {
				module = module,
				entryPoint = "fs_main",
				targetCount = 1,
				targets = &target,
			},
		},
	)
	wg.PipelineLayoutRelease(layout)
	index := resources.pipeline_count
	resources.pipelines[index] = {
		format       = format,
		primitive    = primitive,
		style        = style,
		sample_count = sample_count,
		shader_id    = shader_id,
		pipeline     = pipeline,
	}
	resources.pipeline_count += 1
	return pipeline
}

@(private)
_gpu_3d_init_shared :: proc(ctx: ^Context, resources: ^Gpu_3D_Resources) {
	assert(ctx != nil, "_gpu_3d_init_shared: nil context")
	assert(resources != nil, "_gpu_3d_init_shared: nil resources")
	// Renderer init precedes any 3D pass, so the shared 2D texture layout
	// must already exist - a nil here is a programmer error in init order.
	assert(ctx.rend.tex_layout != nil, "_gpu_3d_init_shared: missing renderer texture layout")
	if resources.shader != nil do return
	resources.shader = wg.DeviceCreateShaderModule(
		ctx.device,
		&{
			nextInChain = &wg.ShaderSourceWGSL {
				chain = {sType = .ShaderSourceWGSL},
				code = GPU_3D_SHADER,
			},
		},
	)
	layout_entries := [2]wg.BindGroupLayoutEntry {
		{
			binding = 0,
			visibility = {.Vertex, .Fragment},
			buffer = {
				type = .Uniform,
				hasDynamicOffset = true,
				minBindingSize = size_of(Gpu_3D_Uniforms),
			},
		},
		{
			binding = 1,
			visibility = {.Vertex},
			buffer = {
				type = .Uniform,
				hasDynamicOffset = true,
				minBindingSize = size_of(Gpu_3D_Instance_Uniforms),
			},
		},
	}
	resources.layout = wg.DeviceCreateBindGroupLayout(
		ctx.device,
		&{entryCount = 2, entries = raw_data(layout_entries[:])},
	)
	for &bind, index in resources.bind {
		bind_entries := [2]wg.BindGroupEntry {
			{
				binding = 0,
				buffer = ctx.rend.stream_slots[index].uniform_buffer,
				size = size_of(Gpu_3D_Uniforms),
			},
			{
				binding = 1,
				buffer = ctx.rend.stream_slots[index].uniform_buffer,
				size = size_of(Gpu_3D_Instance_Uniforms),
			},
		}
		bind = wg.DeviceCreateBindGroup(
			ctx.device,
			&{layout = resources.layout, entryCount = 2, entries = raw_data(bind_entries[:])},
		)
	}
	assert(resources.shader != nil)
	assert(resources.layout != nil)
}

@(private)
_gpu_3d_resources_destroy :: proc(ctx: ^Context, resources: ^Gpu_3D_Resources) {
	assert(ctx != nil, "_gpu_3d_resources_destroy: nil context")
	assert(resources != nil, "_gpu_3d_resources_destroy: nil resources")
	assert(resources.active_pass_generation == 0, "_gpu_3d_resources_destroy: active pass")
	compat := &resources.compat
	if compat.target.texture.texture.id != 0 do _gpu_3d_target_destroy(ctx, &compat.target)
	compat^ = {}
	for &slot in resources.meshes {
		if slot.occupied do _gpu_3d_mesh_entry_destroy(slot.entry)
	}
	for index in 0 ..< resources.pipeline_count {
		if resources.pipelines[index].pipeline != nil {
			wg.RenderPipelineRelease(resources.pipelines[index].pipeline)
		}
	}
	for &slot in resources.shaders {
		if slot.occupied && slot.module != nil do wg.ShaderModuleRelease(slot.module)
	}
	for bind in resources.bind {
		if bind != nil do wg.BindGroupRelease(bind)
	}
	if resources.layout != nil do wg.BindGroupLayoutRelease(resources.layout)
	if resources.shader != nil do wg.ShaderModuleRelease(resources.shader)
	resources^ = {}
}
