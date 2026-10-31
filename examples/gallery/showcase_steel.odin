package main

import gfx "ingot:gfx"

// Showcase_Look selects how the Showcase model is shaded. Steel is first so
// the zero value is the default.
Showcase_Look :: enum i32 {
	Steel,
	Textured,
}

SHOWCASE_LOOK_NAMES := []string{"Steel", "Textured"}

// Forged tool steel, display-referred. The rim takes the cortex teal from
// the cc-php-app landing page so the model still sits in the brand palette.
STEEL_BASE :: [3]f32{0.42, 0.44, 0.46}
STEEL_POLISH :: [3]f32{0.78, 0.80, 0.82}
STEEL_RIM :: [3]f32{0.38, 0.62, 0.66}
// Noise cells across the model's radius: coarse mill scale and fine
// hammer marks.
STEEL_SCALE_CELLS :: f32(4)
STEEL_HAMMER_CELLS :: f32(46)

showcase_color :: proc(rgb: [3]f32) -> gfx.Color {
	return {
		u8(clamp(rgb.x, 0, 1) * 255 + 0.5),
		u8(clamp(rgb.y, 0, 1) * 255 + 0.5),
		u8(clamp(rgb.z, 0, 1) * 255 + 0.5),
		255,
	}
}

// SHOWCASE_STEEL_SHADER shades the model as forged steel: the pass's key and
// rim lights with a Blinn-Phong lobe, a procedural studio reflection, a
// polished working face, and object-space mill scale and hammer marks so the surface detail turns with
// the model. Normals are faced toward the viewer, so a flipped triangle
// cannot read as a hole. The uniform layout mirrors GPU_3D_SHADER.
//
// Inputs: color = base steel, color_high = polished steel, custom_params.rgb
// = rim tint, custom_params_2 = {scale cells, hammer cells, z low, z high} in
// object units.

SHOWCASE_STEEL_SHADER :: `
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
    @location(1) world_position: vec3<f32>,
    @location(2) object_position: vec3<f32>,
    @location(3) object_normal: vec3<f32>,
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
    out.normal = normalize((model * vec4<f32>(normal, 0.0)).xyz);
    out.world_position = world.xyz;
    out.object_position = position;
    out.object_normal = normal;
    return out;
}

fn hash3(p: vec3<f32>) -> f32 {
    let q = fract(p * vec3<f32>(0.1031, 0.1030, 0.0973));
    let r = q + dot(q, q.yxz + 33.33);
    return fract((r.x + r.y) * r.z);
}

fn value_noise(p: vec3<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let w = f * f * (3.0 - 2.0 * f);
    let a = mix(hash3(i), hash3(i + vec3<f32>(1.0, 0.0, 0.0)), w.x);
    let b = mix(hash3(i + vec3<f32>(0.0, 1.0, 0.0)), hash3(i + vec3<f32>(1.0, 1.0, 0.0)), w.x);
    let c = mix(hash3(i + vec3<f32>(0.0, 0.0, 1.0)), hash3(i + vec3<f32>(1.0, 0.0, 1.0)), w.x);
    let d = mix(hash3(i + vec3<f32>(0.0, 1.0, 1.0)), hash3(i + vec3<f32>(1.0, 1.0, 1.0)), w.x);
    return mix(mix(a, b, w.y), mix(c, d, w.y), w.z);
}

fn fbm(p: vec3<f32>) -> f32 {
    var sum = 0.0;
    var amplitude = 0.5;
    var q = p;
    for (var octave = 0; octave < 4; octave++) {
        sum += amplitude * value_noise(q);
        q = q * 2.03 + vec3<f32>(17.0, 5.3, 11.7);
        amplitude *= 0.5;
    }
    return sum / 0.9375;
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4<f32> {
    let v = normalize(u.camera_position.xyz - in.world_position);
    var n = normalize(in.normal);
    var on = normalize(in.object_normal);
    if dot(n, v) < 0.0 {
        n = -n;
        on = -on;
    }
    let p = in.object_position;
    let mill = fbm(p * u.custom_params_2.x);
    let hammer = fbm(p * u.custom_params_2.y);
    let height = clamp((p.z - u.custom_params_2.z) /
        max(u.custom_params_2.w - u.custom_params_2.z, 0.0001), 0.0, 1.0);
    // The anvil face: upward-facing and in the top band of the model.
    let face = smoothstep(0.7, 0.95, on.z) * smoothstep(0.6, 0.85, height);
    let base = u.color.rgb * (0.78 + 0.32 * mill) * (0.93 + 0.14 * hammer);
    let albedo = mix(base, u.color_high.rgb, face * 0.85);
    let roughness = clamp(mix(0.42 + 0.2 * mill, 0.16, face) +
        0.08 * (hammer - 0.5), 0.08, 0.95);
    let shininess = 2.0 / max(roughness * roughness * roughness * roughness, 0.0005) - 2.0;
    let ndv = max(dot(n, v), 0.0);
    let fresnel = 0.56 + 0.44 * pow(1.0 - ndv, 5.0);
    let key = normalize(u.light_direction.xyz);
    let fill = normalize(u.secondary_light_direction.xyz);
    let key_ndl = max(dot(n, key), 0.0);
    let fill_ndl = max(dot(n, fill), 0.0);
    let key_spec = pow(max(dot(n, normalize(v + key)), 0.0), shininess) * (shininess + 8.0) / 25.0;
    let fill_spec = pow(max(dot(n, normalize(v + fill)), 0.0), shininess) * (shininess + 8.0) / 25.0;
    // Studio reflection: dark floor, bright softbox overhead, a cool horizon.
    let r = reflect(-v, n);
    let blur = roughness * roughness;
    let sky = smoothstep(-0.35, 0.8, r.z);
    let softbox = smoothstep(0.55, 0.85, r.z) * (1.0 - blur);
    let horizon = exp(-abs(r.z) * 7.0) * (1.0 - blur);
    let environment = mix(vec3<f32>(0.10, 0.11, 0.12), vec3<f32>(0.62, 0.66, 0.70), sky) +
        vec3<f32>(0.5) * softbox + u.custom_params.rgb * horizon * 0.4;
    let ambient = u.light_params.x + u.secondary_light_params.x;
    let diffuse = albedo * 0.4 * (ambient + u.light_params.y * key_ndl +
        u.secondary_light_params.y * fill_ndl);
    let reflection = albedo * environment * fresnel * 1.25;
    let highlight = fresnel * (key_spec * u.light_params.y * key_ndl +
        fill_spec * u.secondary_light_params.y * fill_ndl);
    let rim = u.custom_params.rgb * pow(1.0 - ndv, 3.0) * 0.45;
    let color = diffuse + reflection + vec3<f32>(highlight) + rim;
    return vec4<f32>(min(color, vec3<f32>(1.0)), 1.0);
}
`
