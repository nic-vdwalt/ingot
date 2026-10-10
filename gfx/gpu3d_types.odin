package gfx

import wg "vendor:wgpu"

// Fixed pools (Tiger Style: every pool has a static upper bound). Exhaustion
// is an operating condition, not a programmer error: create_sphere_mesh
// returns ok=false and draw_gpu_mesh skips draws once the pipeline pool is
// full - both are counted in renderer_stats().gpu3d_pool_exhaustions.
// The mesh pool matches RESOURCE_SLOT_COUNT so chunked worlds (hundreds of
// static terrain meshes) plus procedural flora and marine libraries fit
// without touching the packed handle layout.
GPU_3D_MAX_MESHES :: RESOURCE_SLOT_COUNT
GPU_3D_MAX_PIPELINES :: 48
GPU_3D_MAX_SHADERS :: 16
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
GPU_3D_SCENE_BINDS_PER_PASS :: 64
// Group 3 layout: b0 roughness/AO, b1 sampler, b2 scene colour, b3 sampler,
// b4 scene depth, b5/b6 extra filterable textures, b7 extra sampler, b8/b9
// extra unfilterable data textures. Shaders may declare any subset.
GPU_3D_SCENE_BINDING_COUNT :: 11

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
	Transparent,
	Opaque,
	Opaque_Overlay,
	Opaque_Outline,
	Silhouette_Outline,
}

Gpu_Material :: struct {
	color:                Color,
	color_high:           Color,
	use_scalar:           bool,
	style:                Gpu_Material_Style,
	// depth_nudge shifts fragments toward the camera by a constant NDC
	// offset. Unlike pipeline depthBias - which WebGPU forbids on line and
	// point topologies - it works on every primitive, so overlays (wire
	// grids, point clouds) can sit on coplanar surfaces without z-fighting.
	depth_nudge:          f32,
	// texture with a zero id means untextured: the draw binds the shared
	// neutral white texture and the shader multiplies by pure white.
	texture:              Texture2D,
	normal_texture:       Texture2D,
	roughness_ao_texture: Texture2D,
	scene_color_texture:  Texture2D,
	scene_depth_texture:  Texture2D,
	// Optional group-3 extras for custom shaders: extra_texture_0/1 bind at
	// b5/b6 (filterable float, sampled with the engine-owned linear/repeat
	// sampler at b7); extra_data_texture/_1 bind at b8/b9 as unfilterable
	// float (textureLoad only). Zero ids bind neutral textures.
	extra_texture_0:      Texture2D,
	extra_texture_1:      Texture2D,
	extra_data_texture:   Texture2D,
	extra_data_texture_1: Texture2D,
	extra_data_texture_2: Texture2D,
	custom_params:        [4]f32,
	custom_params_2:      [4]f32,
	custom_params_3:      [4]f32,
	custom_params_4:      [4]f32,
	custom_params_5:      [4]f32,
	custom_params_6:      [4]f32,
	custom_params_7:      [4]f32,
	custom_params_8:      [4]f32,
	custom_params_9:      [4]f32,
	custom_params_10:     [4]f32,
	custom_params_11:     [4]f32,
	custom_params_12:     [4]f32,
	custom_params_13:     [4]f32,
	custom_params_14:     [4]f32,
	custom_params_15:     [4]f32,
	custom_params_16:     [4]f32,
	custom_params_17:     [4]f32,
	custom_params_18:     [4]f32,
	custom_params_19:     [4]f32,
	custom_params_20:     [4]f32,
	custom_params_21:     [4]f32,
	custom_params_22:     [4]f32,
	custom_params_23:     [4]f32,
	custom_params_24:     [4]f32,
	custom_params_25:     [4]f32,
	custom_params_26:     [4]f32,
	custom_params_27:     [4]f32,
	custom_params_28:     [4]f32,
	custom_params_29:     [4]f32,
	custom_params_30:     [4]f32,
	custom_params_31:     [4]f32,
	// shader with a zero id means the built-in GPU_3D_SHADER; a custom
	// handle from create_gpu_3d_shader replaces both shader stages. Stale
	// handles fall back to the built-in shader (operating condition).
	shader:               Gpu_3D_Shader,
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

GPU_3D_DEFAULT_SECONDARY_LIGHT :: Gpu_3D_Light {
	direction = {0.4, 0.8, 0.3},
}

Gpu_3D_Load_Action :: enum {
	Clear,
	Preserve,
}

@(private)
Gpu_3D_Scene_Bind_Key :: struct {
	roughness_texture: u32,
	color_texture:     u32,
	depth_texture:     u32,
	extra_0:           u32,
	extra_1:           u32,
	extra_data_0:      u32,
	extra_data_1:      u32,
	extra_data_2:      u32,
}

@(private)
Gpu_3D_Scene_Bind_Entry :: struct {
	key:  Gpu_3D_Scene_Bind_Key,
	bind: wg.BindGroup,
}

Gpu_3D_Pass :: struct {
	owner:                     ^Context,
	epoch:                     u64,
	encoder:                   wg.CommandEncoder,
	timing:                    Gpu_Timing_Token,
	// Query written by the render pass's own end-of-pass timestamp; spans
	// encoded after the pass on the same encoder are anchored to it.
	pass_end_query:            u32,
	pass_timed:                bool,
	pass:                      wg.RenderPassEncoder,
	target:                    ^Gpu_3D_Target,
	view_projection:           Matrix,
	light:                     Gpu_3D_Light,
	secondary_light:           Gpu_3D_Light,
	// World-space camera eye fed to shaders for view-dependent shading.
	// begin_gpu_3d fills it from the camera; begin_gpu_3d_pro supplies a
	// synthetic camera, so callers wanting meaningful view-dependent
	// shading there must set this field themselves after begin.
	camera_position:           Vector3,
	// Pass start time in seconds since context start, fed to shaders via
	// light_params.w for animation.
	time:                      f32,
	underwater_primary:        [4]f32,
	underwater_secondary:      [4]f32,
	// Pass-owned participating medium for custom shaders that declare the
	// trailing atmosphere_0..2 uniforms. Zero means the shader's legacy path.
	atmosphere:                [3][4]f32,
	clip_plane:                [4]f32,
	clip_enabled:              u32,
	generation:                u64,
	active:                    bool,
	sample_count:              u32,
	owns_stream:               bool,
	// Offset of the shared identity instance block uploaded once per pass;
	// plain draw_gpu_mesh calls reuse it so the instance binding's
	// minBindingSize cost is paid once per pass, not once per draw.
	identity_instances_offset: u32,
	scene_binds:               [GPU_3D_SCENE_BINDS_PER_PASS]Gpu_3D_Scene_Bind_Entry,
	scene_bind_count:          u32,
}

Gpu_3D_Vertex :: struct {
	position: [3]f32,
	normal:   [3]f32,
	scalar:   f32,
	uv:       [2]f32,
}

Gpu_3D_Uniforms :: struct {
	view_projection:           Matrix,
	model:                     Matrix,
	color:                     [4]f32,
	color_high:                [4]f32,
	light_direction:           [4]f32, // xyz direction toward the light, w unused
	light_params:              [4]f32, // x ambient, y diffuse, z depth_nudge, w time seconds
	camera_position:           [4]f32, // xyz world-space camera position, w unused
	custom_params:             [4]f32,
	custom_params_2:           [4]f32,
	custom_params_3:           [4]f32,
	custom_params_4:           [4]f32,
	use_scalar:                u32,
	use_texture:               u32,
	use_normal:                u32,
	use_roughness_ao:          u32,
	custom_params_5:           [4]f32,
	custom_params_6:           [4]f32,
	custom_params_7:           [4]f32,
	custom_params_8:           [4]f32,
	custom_params_9:           [4]f32,
	custom_params_10:          [4]f32,
	custom_params_11:          [4]f32,
	custom_params_12:          [4]f32,
	custom_params_13:          [4]f32,
	custom_params_14:          [4]f32,
	custom_params_15:          [4]f32,
	custom_params_16:          [4]f32,
	custom_params_17:          [4]f32,
	custom_params_18:          [4]f32,
	custom_params_19:          [4]f32,
	clip_plane:                [4]f32,
	clip_enabled:              u32,
	clip_padding:              [3]u32,
	secondary_light_direction: [4]f32,
	secondary_light_params:    [4]f32,
	custom_params_20:          [4]f32,
	custom_params_21:          [4]f32,
	custom_params_22:          [4]f32,
	custom_params_23:          [4]f32,
	custom_params_24:          [4]f32,
	custom_params_25:          [4]f32,
	custom_params_26:          [4]f32,
	custom_params_27:          [4]f32,
	custom_params_28:          [4]f32,
	custom_params_29:          [4]f32,
	custom_params_30:          [4]f32,
	custom_params_31:          [4]f32,
	atmosphere_0:              [4]f32,
	atmosphere_1:              [4]f32,
	atmosphere_2:              [4]f32,
}

// Per-instance model transforms for draw_gpu_mesh_instanced, read by the
// shader through @builtin(instance_index). The block is copied raw into the
// uniform stream, so the Odin layout must match the WGSL
// array<mat4x4<f32>, N> stride of 64 bytes exactly on every target.
Gpu_3D_Instance_Uniforms :: struct {
	transforms: [GPU_3D_MAX_INSTANCES_PER_DRAW]Matrix,
}

// The dynamic-offset uniform bind group declares minBindingSize =
// size_of(Gpu_3D_Uniforms). The WGSL view ends with two appended secondary-light
// vectors; Odin may append tail padding (matrix alignment is target-dependent),
// and WebGPU permits a binding larger than the shader view. Lock the invariants
// a struct edit could silently break: never smaller than the shader view, always
// 16-byte aligned as dynamic offsets require.
#assert(size_of(Gpu_3D_Uniforms) >= 784)
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
		blend = style == .Default || style == .Transparent,
		depth_write = style != .Transparent &&
		style != .Opaque_Overlay &&
		style != .Opaque_Outline &&
		style != .Silhouette_Outline,
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
	neutral_normal_tex:     wg.Texture,
	neutral_normal_view:    wg.TextureView,
	neutral_normal_sampler: wg.Sampler,
	neutral_normal_bind:    wg.BindGroup,
	scene_layout:           wg.BindGroupLayout,
	neutral_depth_tex:      wg.Texture,
	neutral_depth_view:     wg.TextureView,
	neutral_data_tex:       wg.Texture,
	neutral_data_view:      wg.TextureView,
	extra_sampler:          wg.Sampler,
	neutral_scene_bind:     wg.BindGroup,
	next_pass_generation:   u64,
	active_pass_generation: u64,
	identity_block:         Gpu_3D_Instance_Uniforms,
	identity_block_ready:   bool,
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
    custom_params: vec4<f32>,
    custom_params_2: vec4<f32>,
    custom_params_3: vec4<f32>,
    custom_params_4: vec4<f32>,
    use_scalar: u32,
    use_texture: u32,
    use_normal: u32,
    use_roughness_ao: u32,
    custom_params_5: vec4<f32>,
    custom_params_6: vec4<f32>,
    custom_params_7: vec4<f32>,
    custom_params_8: vec4<f32>,
    custom_params_9: vec4<f32>,
    custom_params_10: vec4<f32>,
    custom_params_11: vec4<f32>,
    custom_params_12: vec4<f32>,
    custom_params_13: vec4<f32>,
    custom_params_14: vec4<f32>,
    custom_params_15: vec4<f32>,
    custom_params_16: vec4<f32>,
    custom_params_17: vec4<f32>,
    custom_params_18: vec4<f32>,
    custom_params_19: vec4<f32>,
    clip_plane: vec4<f32>,
    clip_enabled: u32,
    clip_padding_0: u32,
    clip_padding_1: u32,
    clip_padding_2: u32,
    secondary_light_direction: vec4<f32>,
    secondary_light_params: vec4<f32>,
    custom_params_20: vec4<f32>,
    custom_params_21: vec4<f32>,
    custom_params_22: vec4<f32>,
    custom_params_23: vec4<f32>,
    custom_params_24: vec4<f32>,
    custom_params_25: vec4<f32>,
    custom_params_26: vec4<f32>,
    custom_params_27: vec4<f32>,
    custom_params_28: vec4<f32>,
    custom_params_29: vec4<f32>,
    custom_params_30: vec4<f32>,
    custom_params_31: vec4<f32>,
};
// Array length mirrors GPU_3D_MAX_INSTANCES_PER_DRAW.
struct Instances {
    transforms: array<mat4x4<f32>, 256>,
};
@group(0) @binding(0) var<uniform> u: Uniforms;
@group(0) @binding(1) var<uniform> instances: Instances;
@group(1) @binding(0) var mesh_texture: texture_2d<f32>;
@group(1) @binding(1) var mesh_sampler: sampler;
@group(2) @binding(0) var mesh_normal_texture: texture_2d<f32>;
@group(2) @binding(1) var mesh_normal_sampler: sampler;
@group(3) @binding(0) var mesh_roughness_ao_texture: texture_2d<f32>;
@group(3) @binding(1) var mesh_roughness_ao_sampler: sampler;

struct VertexOut {
    @builtin(position) position: vec4<f32>,
    @location(0) normal: vec3<f32>,
    @location(1) scalar: f32,
    @location(2) uv: vec2<f32>,
    @location(3) world_position: vec3<f32>,
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
    let world = model * vec4<f32>(position, 1.0);
    out.position = u.view_projection * world;
    // Nudge NDC depth after projection; multiplying by w keeps the offset a
    // constant NDC shift after the perspective divide, which lets overlay
    // materials win the depth test on line and point topologies where
    // WebGPU forbids pipeline depthBias.
    out.position.z -= u.light_params.z * out.position.w;
    out.normal = normalize((model * vec4<f32>(normal, 0.0)).xyz);
    out.scalar = scalar;
    out.uv = uv;
    out.world_position = world.xyz;
    return out;
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4<f32> {
    if u.clip_enabled != 0u &&
        dot(u.clip_plane.xyz, in.world_position) > u.clip_plane.w {
        discard;
    }
    let light = normalize(u.light_direction.xyz);
    let secondary_light = normalize(u.secondary_light_direction.xyz);
    let geometric_normal = normalize(in.normal);
    let world_dx = dpdx(in.world_position);
    let world_dy = dpdy(in.world_position);
    let uv_dx = dpdx(in.uv);
    let uv_dy = dpdy(in.uv);
    let determinant = uv_dx.x * uv_dy.y - uv_dx.y * uv_dy.x;
    let tangent = normalize(
        (world_dx * uv_dy.y - world_dy * uv_dx.y) /
        max(abs(determinant), 0.00001));
    let bitangent = normalize(cross(geometric_normal, tangent)) *
        select(-1.0, 1.0, determinant >= 0.0);
    let sampled_normal = textureSample(
        mesh_normal_texture, mesh_normal_sampler, in.uv).xyz * 2.0 - 1.0;
    let mapped_normal = normalize(
        mat3x3<f32>(tangent, bitangent, geometric_normal) * sampled_normal);
    let normal = normalize(mix(geometric_normal, mapped_normal, f32(u.use_normal)));
    // Sample unconditionally and select by flag: textureSample requires
    // uniform control flow, and the unconditional form is trivially uniform.
    let texel = textureSample(mesh_texture, mesh_sampler, in.uv);
    let roughness_ao = textureSample(
        mesh_roughness_ao_texture,
        mesh_roughness_ao_sampler,
        in.uv).rg;
    let roughness = mix(1.0, clamp(roughness_ao.r, 0.04, 1.0), f32(u.use_roughness_ao));
    let ao = mix(1.0, roughness_ao.g, f32(u.use_roughness_ao));
    var base = u.color;
    if u.use_scalar != 0u {
        base = mix(u.color, u.color_high, clamp(in.scalar, 0.0, 1.0));
    }
    base = mix(base, base * texel, f32(u.use_texture));
    let view = normalize(u.camera_position.xyz - in.world_position);
    let halfway = normalize(view + light);
    let secondary_halfway = normalize(view + secondary_light);
    let ndl = max(dot(normal, light), 0.0);
    let secondary_ndl = max(dot(normal, secondary_light), 0.0);
    let ndv = max(dot(normal, view), 0.001);
    let ndh = max(dot(normal, halfway), 0.0);
    let secondary_ndh = max(dot(normal, secondary_halfway), 0.0);
    let vdh = max(dot(view, halfway), 0.0);
    let secondary_vdh = max(dot(view, secondary_halfway), 0.0);
    let alpha = roughness * roughness;
    let alpha2 = alpha * alpha;
    let denominator = ndh * ndh * (alpha2 - 1.0) + 1.0;
    let distribution = alpha2 / max(3.14159265 * denominator * denominator, 0.0001);
    let k = (roughness + 1.0) * (roughness + 1.0) / 8.0;
    let visibility = ndv / (ndv * (1.0 - k) + k) * ndl / (ndl * (1.0 - k) + k);
    let fresnel = vec3<f32>(0.04) + vec3<f32>(0.96) * pow(1.0 - vdh, 5.0);
    let specular = distribution * visibility * fresnel / max(4.0 * ndv * max(ndl, 0.001), 0.001);
    let secondary_denominator = secondary_ndh * secondary_ndh * (alpha2 - 1.0) + 1.0;
    let secondary_distribution = alpha2 /
        max(3.14159265 * secondary_denominator * secondary_denominator, 0.0001);
    let secondary_visibility = ndv / (ndv * (1.0 - k) + k) *
        secondary_ndl / (secondary_ndl * (1.0 - k) + k);
    let secondary_fresnel = vec3<f32>(0.04) +
        vec3<f32>(0.96) * pow(1.0 - secondary_vdh, 5.0);
    let secondary_specular = secondary_distribution * secondary_visibility * secondary_fresnel /
        max(4.0 * ndv * max(secondary_ndl, 0.001), 0.001);
    let diffuse = base.rgb * (u.light_params.x * ao + u.light_params.y * ndl +
        u.secondary_light_params.x * ao + u.secondary_light_params.y * secondary_ndl);
    let color = diffuse + specular * u.light_params.y * ndl +
        secondary_specular * u.secondary_light_params.y * secondary_ndl;
    let underwater_blend = clamp(u.custom_params_5.w, 0.0, 1.0);
    let underwater_distance = length(u.camera_position.xyz - in.world_position);
    let underwater_range = mix(90.0, 24.0, clamp(u.custom_params_6.w, 0.0, 1.0));
    let underwater_path = min(underwater_distance, underwater_range);
    let absorption = max(u.custom_params_5.xyz, vec3<f32>(0.0));
    let underwater_transmittance = exp(-absorption * underwater_path * 0.035);
    let scatter_color = max(u.custom_params_6.xyz, vec3<f32>(0.0));
    let underwater_scatter = scatter_color * (vec3<f32>(1.0) - underwater_transmittance);
    let medium_color = color * underwater_transmittance + underwater_scatter;
    let final_color = mix(color, medium_color, underwater_blend);
    return vec4<f32>(final_color * base.a, base.a);
}
`
