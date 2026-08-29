// examples/box3d_water - graphics. The water surface is one static indexed
// grid; its custom vertex shader evaluates the same phase-driven analytical
// wave the fixed-step physics samples. That shared source is what makes the
// picture trustworthy: if the mesh and buoyancy ever disagreed, the cubes
// would visibly float in the wrong place.
package main

import rl "ingot:gfx"

WATER_COLOR_LOW :: rl.Color{18, 62, 112, 205}
WATER_COLOR_HIGH :: rl.Color{140, 210, 240, 205}
WATER_IOR :: f32(1.33)
WATER_FRESNEL_F0 :: ((WATER_IOR - 1) / (WATER_IOR + 1)) * ((WATER_IOR - 1) / (WATER_IOR + 1))
BOX_LIGHT :: rl.Gpu_3D_Light {
	direction = {-0.35, 0.45, 0.82},
	ambient   = 0.30,
	diffuse   = 0.70,
}

WATER_SHADER :: `
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
};
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
@group(3) @binding(2) var scene_color_texture: texture_2d<f32>;
@group(3) @binding(3) var scene_color_sampler: sampler;
@group(3) @binding(4) var scene_depth_texture: texture_depth_2d;
struct VertexOut {
    @builtin(position) position: vec4<f32>,
    @location(0) world: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) height_mix: f32,
};
@vertex
fn vs_main(
    @builtin(instance_index) index: u32,
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) scalar: f32,
    @location(3) uv: vec2<f32>,
) -> VertexOut {
    let model = u.model * instances.transforms[index];
    var world = (model * vec4<f32>(position, 1.0)).xyz;
    let phase = u.custom_params.x;
    let primary_angle = u.custom_params_2.x * world.x + phase;
    let cross_angle = u.custom_params_2.y * world.y + u.custom_params_2.z * phase;
    world.z = u.custom_params.w + u.custom_params.y * sin(primary_angle) +
        u.custom_params.z * sin(cross_angle);
    let slope_x = u.custom_params.y * u.custom_params_2.x * cos(primary_angle);
    let slope_y = u.custom_params.z * u.custom_params_2.y * cos(cross_angle);
    var out: VertexOut;
    out.world = world;
    out.normal = normalize(vec3<f32>(-slope_x, -slope_y, 1.0));
    out.height_mix = clamp(
        (world.z - u.custom_params.w) / (2.0 * u.custom_params_3.x) + 0.5,
        0.0,
        1.0);
    out.position = u.view_projection * vec4<f32>(world, 1.0);
    return out;
}
@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4<f32> {
    let view_delta = u.camera_position.xyz - in.world;
    let distance = length(view_delta);
    let view = view_delta / max(distance, 0.001);
    let light = normalize(u.light_direction.xyz);
    let detail_fade = 1.0 - smoothstep(28.0, 70.0, distance);
    let ripple = vec2<f32>(
        sin(in.world.x * 2.7 + in.world.y * 1.9 + u.custom_params.x * 1.7),
        cos(in.world.x * 1.6 - in.world.y * 2.3 - u.custom_params.x * 1.3));
    let surface_normal = normalize(
        in.normal + vec3<f32>(ripple * 0.055 * detail_fade, 0.0));
    let ndv = max(dot(surface_normal, view), 0.0);
    let fresnel = u.custom_params_2.w +
        (1.0 - u.custom_params_2.w) * pow(1.0 - ndv, 5.0);
    let reflected = reflect(-view, surface_normal);
    let sky = mix(
        vec3<f32>(0.18, 0.30, 0.42),
        vec3<f32>(0.025, 0.07, 0.14),
        pow(clamp(reflected.z, 0.0, 1.0), 0.45));
    var water = mix(u.color.rgb, u.color_high.rgb, in.height_mix);
    water = mix(water, sky, fresnel);
    let halfway = normalize(view + light);
    water += vec3<f32>(pow(max(dot(surface_normal, halfway), 0.0), 128.0) * 0.7);
    let alpha = mix(u.color.a, 0.96, fresnel);
    return vec4<f32>(water * alpha, alpha);
}
`

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
	target_ok, cube_ok, edges_ok, shader_ok: bool
	value.target, target_ok = rl.create_gpu_3d_target(
		rl.GetRenderWidth(),
		rl.GetRenderHeight(),
		.MSAA_4X,
	)
	value.cube, cube_ok = rl.create_cube_mesh()
	value.cube_edges, edges_ok = rl.create_cube_edge_mesh()
	value.water_shader, shader_ok = rl.create_gpu_3d_shader(WATER_SHADER)
	water_ok := water_mesh_create(value)
	value.graphics_ready = target_ok && cube_ok && edges_ok && shader_ok && water_ok
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
	return true
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
		{
			color           = WATER_COLOR_LOW,
			color_high      = WATER_COLOR_HIGH,
			shader          = value.water_shader,
			custom_params   = {value.phase, WATER_AMPLITUDE, WATER_CROSS_AMPLITUDE, WATER_BASE_Z},
			custom_params_2 = {
				WATER_WAVE_NUMBER_X,
				WATER_WAVE_NUMBER_Y,
				WATER_CROSS_PHASE_RATE,
				WATER_FRESNEL_F0,
			},
			custom_params_3 = {WATER_HEIGHT_SPAN, 0, 0, 0},
		},
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
