package main

POST_PROCESS_SHADER :: `
struct Uniforms { projection: vec4<f32>, };
struct U {
    exposure: f32,
    quality: f32,
    time: f32,
    vibrance: f32,
    contrast: f32,
    bloom_strength: f32,
    bloom_threshold: f32,
    overview: f32,
    texel_size: vec2<f32>,
};
@group(0) @binding(0) var<uniform> u: Uniforms;
@group(1) @binding(0) var source_texture: texture_2d<f32>;
@group(1) @binding(1) var source_sampler: sampler;
@group(2) @binding(0) var<uniform> cu: U;
struct VertexOut {
    @builtin(position) position: vec4<f32>,
    @location(0) color: vec4<f32>,
    @location(1) uv: vec2<f32>,
};
@vertex
fn vs_main(
    @location(0) position: vec2<f32>,
    @location(1) color: vec4<f32>,
    @location(2) uv: vec2<f32>,
) -> VertexOut {
    var out: VertexOut;
    let screen_x = position.x * u.projection.x * 2.0 - 1.0;
    let screen_y = 1.0 - position.y * u.projection.y * 2.0;
    out.position = vec4<f32>(screen_x, screen_y * u.projection.z, 0.0, 1.0);
    out.color = color;
    out.uv = uv;
    return out;
}
fn aces(color: vec3<f32>) -> vec3<f32> {
    let a = 2.51;
    let b = 0.03;
    let c = 2.43;
    let d = 0.59;
    let e = 0.14;
    return clamp((color * (a * color + vec3<f32>(b))) / (color * (c * color + vec3<f32>(d)) + vec3<f32>(e)), vec3<f32>(0.0), vec3<f32>(1.0));
}
fn bloom_sample(uv: vec2<f32>) -> vec3<f32> {
    var sum = vec3<f32>(0.0);
    let radius = cu.texel_size * mix(1.5, 2.8, cu.overview);
    sum += textureSample(source_texture, source_sampler, uv + vec2<f32>(-radius.x, 0.0)).rgb;
    sum += textureSample(source_texture, source_sampler, uv + vec2<f32>(radius.x, 0.0)).rgb;
    sum += textureSample(source_texture, source_sampler, uv + vec2<f32>(0.0, -radius.y)).rgb;
    sum += textureSample(source_texture, source_sampler, uv + vec2<f32>(0.0, radius.y)).rgb;
    sum += textureSample(source_texture, source_sampler, uv).rgb * 2.0;
    let blurred = sum / 6.0;
    let peak = max(max(blurred.r, blurred.g), blurred.b);
    let knee = max(0.08, cu.bloom_threshold * 0.25);
    let bright = smoothstep(cu.bloom_threshold - knee, cu.bloom_threshold + knee, peak);
    return blurred * bright;
}
@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4<f32> {
    let source = textureSample(source_texture, source_sampler, in.uv).rgb;
    let bloom = bloom_sample(in.uv) * cu.bloom_strength * cu.quality * mix(0.7, 1.15, cu.overview);
    var color = aces((source + bloom) * cu.exposure);
    let luminance = dot(color, vec3<f32>(0.2126, 0.7152, 0.0722));
    let saturation = mix(cu.vibrance, cu.vibrance + 0.08, cu.overview);
    color = mix(vec3<f32>(luminance), color, saturation);
    let contrasted = (color - vec3<f32>(0.5)) * cu.contrast + vec3<f32>(0.5);
    color = max(contrasted, color);
    let shadow_weight = (1.0 - smoothstep(0.08, 0.35, luminance)) * cu.overview;
    let lifted_shadows = pow(max(color, vec3<f32>(0.0)), vec3<f32>(0.78));
    color = mix(color, lifted_shadows, shadow_weight * 0.45);
    color = mix(color * vec3<f32>(0.93, 0.98, 1.06), color * vec3<f32>(1.05, 0.98, 0.91), smoothstep(0.35, 0.82, luminance) * 0.18);
    let centered = in.uv * 2.0 - vec2<f32>(1.0);
    let vignette = 1.0 - dot(centered, centered) * 0.025 * cu.quality * (1.0 - cu.overview * 0.8);
    let dither = (fract(sin(dot(in.position.xy + cu.time, vec2<f32>(12.9898, 78.233))) * 43758.5453) - 0.5) / 255.0;
    color = color * vignette + dither;
    return vec4<f32>(clamp(color, vec3<f32>(0.0), vec3<f32>(1.0)), 1.0) * in.color;
}
`

// Custom WGSL shaders for the terrain and water surfaces, registered through
// ingot's create_gpu_3d_shader. Both must declare the exact same bind groups,
// vertex attributes, and vs_main/fs_main entry points as the engine's
// built-in GPU_3D_SHADER; only the shading logic differs. Fragment outputs
// are premultiplied alpha (rgb * a) to match the engine's blend state.
// light_params.w carries the pass time in seconds; camera_position.xyz is
// the world-space eye.

SHADER_PREAMBLE :: `
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
    clip_padding: vec3<u32>,
    secondary_light_direction: vec4<f32>,
    secondary_light_params: vec4<f32>,
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

fn cutaway_clipped(world_position: vec3<f32>) -> bool {
    return u.clip_enabled != 0u &&
        dot(u.clip_plane.xyz, world_position) > u.clip_plane.w;
}

fn hash21(p: vec2<f32>) -> f32 {
    var q = fract(p * vec2<f32>(123.34, 456.21));
    q += dot(q, q + 45.32);
    return fract(q.x * q.y);
}

fn value_noise2(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let s = f * f * (3.0 - 2.0 * f);
    let a = hash21(i);
    let b = hash21(i + vec2<f32>(1.0, 0.0));
    let c = hash21(i + vec2<f32>(0.0, 1.0));
    let d = hash21(i + vec2<f32>(1.0, 1.0));
    return mix(mix(a, b, s.x), mix(c, d, s.x), s.y);
}

// Fractal noise, 3 octaves, roughly [0, 1] centred near 0.47.
fn fbm3(p: vec2<f32>) -> f32 {
    var q = p;
    var v = 0.0;
    var a = 0.5;
    for (var i = 0; i < 3; i++) {
        v += a * value_noise2(q);
        q = q * 2.17 + vec2<f32>(11.3, 7.9);
        a *= 0.5;
    }
    return v / 0.875;
}

// Fractal noise, 4 octaves, for surfaces that need the extra fine layer.
fn fbm4(p: vec2<f32>) -> f32 {
    var q = p;
    var v = 0.0;
    var a = 0.5;
    for (var i = 0; i < 4; i++) {
        v += a * value_noise2(q);
        q = q * 2.17 + vec2<f32>(11.3, 7.9);
        a *= 0.5;
    }
    return v / 0.9375;
}

// XY normal perturbation from noise height gradients (finite differences);
// add the result to a normal before renormalising.
fn noise_normal(p: vec2<f32>, freq: f32, strength: f32) -> vec2<f32> {
    let e = 0.35 / freq;
    let h0 = fbm3(p * freq);
    let hx = fbm3((p + vec2<f32>(e, 0.0)) * freq);
    let hy = fbm3((p + vec2<f32>(0.0, e)) * freq);
    return vec2<f32>(h0 - hx, h0 - hy) * (strength / e);
}

fn atmosphere_cloud_projection(ray: vec3<f32>, offset: vec2<f32>, scale: f32) -> f32 {
    let weights = max(abs(ray) - vec3<f32>(0.12), vec3<f32>(0.0));
    let weight_sum = max(weights.x + weights.y + weights.z, 0.001);
    let on_x = fbm3((ray.yz * scale + offset) * vec2<f32>(1.0, 0.92));
    let on_y = fbm3((ray.xz * scale + offset * vec2<f32>(-0.87, 1.0)) * vec2<f32>(0.94, 1.0));
    let on_z = fbm3((ray.xy * scale + offset * vec2<f32>(1.0, -0.83)) * vec2<f32>(1.0, 0.96));
    return (on_x * weights.x + on_y * weights.y + on_z * weights.z) / weight_sum;
}

fn atmosphere_cloud(ray: vec3<f32>, t: f32, wind: vec2<f32>) -> vec2<f32> {
    let advection = wind * 0.00018 * t + vec2<f32>(t * 0.0012, t * 0.0005);
    let warp = atmosphere_cloud_projection(ray, advection * 0.35, 2.6) - 0.5;
    let body = atmosphere_cloud_projection(ray, advection + vec2<f32>(warp * 0.20), 5.2);
    let detail = atmosphere_cloud_projection(ray, -advection * 1.7 + vec2<f32>(11.3, 7.9), 13.5);
    return vec2<f32>(body, detail);
}

fn storm_flash(t: f32, storm: f32) -> f32 {
    let epoch = floor(t / 47.0);
    let epoch_modulo = epoch - floor(epoch / 5.0) * 5.0;
    let cycle = 9.0 + epoch_modulo * 1.7;
    let local = t - floor(t / cycle) * cycle;
    let first = exp(-pow((local - 0.18) * 17.0, 2.0));
    let return_stroke = exp(-pow((local - 0.43) * 24.0, 2.0));
    let afterglow = exp(-max(local - 0.43, 0.0) * 5.5) * step(0.43, local);
    return clamp((first * 0.72 + return_stroke + afterglow * 0.18) * smoothstep(0.28, 0.82, storm), 0.0, 1.0);
}

fn storm_light_direction(radial: vec3<f32>, t: f32) -> vec3<f32> {
    let axis = select(vec3<f32>(0.0, 0.0, 1.0), vec3<f32>(0.0, 1.0, 0.0), abs(radial.z) > 0.88);
    let east = normalize(cross(axis, radial));
    let north = normalize(cross(radial, east));
    let heading = floor(t / 47.0) * 1.61803398875 + 0.73;
    return normalize(radial * 0.48 + east * cos(heading) * 0.74 + north * sin(heading) * 0.74);
}

fn planet_solar_factor(radial: vec3<f32>, light: vec3<f32>) -> f32 {
    return smoothstep(-0.18, 0.12, dot(radial, light));
}

fn planet_ambient_light(normal: vec3<f32>, radial: vec3<f32>, light: vec3<f32>) -> vec3<f32> {
    let hemisphere = mix(
        vec3<f32>(0.20, 0.16, 0.13),
        vec3<f32>(0.30, 0.39, 0.50),
        dot(normal, radial) * 0.5 + 0.5);
    let local_level = mix(0.40, 1.0, planet_solar_factor(radial, light));
    return hemisphere * (u.light_params.x * 2.2) * local_level;
}

fn planet_moon_light(normal: vec3<f32>, radial: vec3<f32>, light: vec3<f32>) -> vec3<f32> {
    let moon_direction = normalize(u.secondary_light_direction.xyz);
    let moon_above_horizon = smoothstep(-0.02, 0.06, dot(radial, moon_direction));
    let night = 1.0 - planet_solar_factor(radial, light);
    let moon = vec3<f32>(0.48, 0.62, 0.90);
    return moon * (u.secondary_light_params.y * max(dot(normal, moon_direction), 0.0) *
        moon_above_horizon * night);
}

fn planet_direct_light(normal: vec3<f32>, radial: vec3<f32>, light: vec3<f32>) -> vec3<f32> {
    let sun = vec3<f32>(1.0, 0.93, 0.82);
    return sun * (u.light_params.y * max(dot(normal, light), 0.0)) +
        planet_moon_light(normal, radial, light);
}

fn planet_light_level(normal: vec3<f32>, radial: vec3<f32>, light: vec3<f32>) -> f32 {
    let combined = planet_ambient_light(normal, radial, light) +
        planet_direct_light(normal, radial, light);
    return dot(combined, vec3<f32>(0.2126, 0.7152, 0.0722));
}

// Fog models the view path through the planet's thin atmosphere shell
// rather than raw eye distance: the optical path is capped by the shell's
// scale height over the view angle, so orbit views stay crisp against
// space while near-surface grazing views still haze out with distance.
fn atmosphere_optical_depth(world: vec3<f32>, dist: f32, view: vec3<f32>, density: f32, falloff: f32) -> f32 {
    let shell_radius = 1380.0;
    let ray = normalize(view);
    let b = dot(world, ray);
    let c = dot(world, world) - shell_radius * shell_radius;
    let discriminant = b * b - c;
    if discriminant <= 0.0 {
        return 0.0;
    }
    let shell_exit = max(-b + sqrt(discriminant), 0.0);
    let segment_length = min(max(dist, 0.0), shell_exit);
    let step_length = segment_length / 8.0;
    var integrated_density = 0.0;
    for (var sample_index = 0u; sample_index < 8u; sample_index += 1u) {
        let sample_distance = (f32(sample_index) + 0.5) * step_length;
        let sample_position = world + ray * sample_distance;
        let sample_altitude = max(length(sample_position) - 1080.0, 0.0);
        integrated_density += exp(-sample_altitude * falloff) * step_length;
    }
    return integrated_density * density;
}

fn atmosphere_fog(world: vec3<f32>, dist: f32, view: vec3<f32>, light: vec3<f32>) -> vec4<f32> {
    let up = normalize(world);
    let configured_density = u.custom_params_4.z;
    let configured_falloff = u.custom_params_4.w;
    let falloff = select(0.055, configured_falloff, configured_falloff > 0.0);
    let base_density = select(0.0085, configured_density, configured_density > 0.0);
    let optical_depth = atmosphere_optical_depth(world, dist, view, base_density, falloff);
    let fog = clamp(1.0 - exp(-optical_depth), 0.0, 0.92);
    let fog_daylight = planet_solar_factor(up, light);
    let forward_scatter = pow(max(dot(-view, light), 0.0), 8.0) * fog_daylight;
    let day_fog = mix(vec3<f32>(0.30, 0.42, 0.58), vec3<f32>(0.62, 0.56, 0.46), forward_scatter * 0.28);
    let night_fog = vec3<f32>(0.035, 0.055, 0.105);
    let fog_color = mix(night_fog, day_fog, fog_daylight);
    return vec4<f32>(fog_color, fog);
}

fn underwater_apply(color: vec3<f32>, dist: f32, light: vec3<f32>, normal: vec3<f32>) -> vec3<f32> {
    let blend = clamp(u.custom_params_5.w, 0.0, 1.0);
    let absorption = max(u.custom_params_5.xyz, vec3<f32>(0.0));
    let scattering = max(u.custom_params_6.xyz, vec3<f32>(0.0));
    let turbidity = clamp(u.custom_params_6.w, 0.0, 1.0);
    let path = min(dist, mix(90.0, 24.0, turbidity));
    let transmittance = exp(-absorption * path * 0.035);
    let radial = normalize(normal);
    let illumination = planet_light_level(radial, radial, light);
    let inscatter = scattering * illumination * (vec3<f32>(1.0) - transmittance) * (1.0 + turbidity);
    return mix(color, color * transmittance + inscatter, blend);
}

fn atmosphere_apply(color: vec3<f32>, world: vec3<f32>, dist: f32, view: vec3<f32>, light: vec3<f32>) -> vec3<f32> {
    let fog = atmosphere_fog(world, dist, view, light);
    let underwater = clamp(u.custom_params_5.w, 0.0, 1.0);
    let fogged = mix(color, fog.rgb, fog.a * (1.0 - underwater));
    let radial = normalize(world);
    return underwater_apply(fogged, dist, light, radial);
}

// Analytic atmosphere: two max-combined terms over the space backdrop.
// An inside-shell dome guarantees a blue sky in every direction while the
// camera sits below the space-fade band (the same 180..420 altitude band
// the terrain fog uses), and a thin exponential limb rim (shell top 1380,
// scale height 95) hugs the whole globe from orbit. Day/night dims the
// colour only, never the coverage, so the night limb stays a visible
// dark-blue rim instead of vanishing.
fn atmosphere_sky(cam: vec3<f32>, ray: vec3<f32>, light: vec3<f32>) -> vec4<f32> {
    let planet_r = 1080.0;
    let shell_top = 1380.0;
    let scale_h = 95.0;
    let k = 0.0028;
    let cam_r = max(length(cam), 0.001);
    let cam_altitude = max(cam_r - planet_r, 0.0);
    // Orbital limb rim: chord of the ray through the shell, density from
    // the chord's closest approach to the planet centre.
    var rim_alpha = 0.0;
    var mu = 1.0;
    var up = cam / cam_r;
    let b = dot(cam, ray);
    let c = dot(cam, cam) - shell_top * shell_top;
    let disc = b * b - c;
    if disc > 0.0 {
        let s = sqrt(disc);
        let t0 = max(-b - s, 0.0);
        let t1 = -b + s;
        if t1 > t0 {
            let t_mid = clamp(-b, t0, t1);
            let sample = cam + ray * t_mid;
            let sample_r = max(length(sample), 0.001);
            up = sample / sample_r;
            mu = abs(dot(ray, up));
            let closest_alt = max(sample_r - planet_r, 0.0);
            let optical = k * exp(-closest_alt / scale_h) * (t1 - t0);
            rim_alpha = 1.0 - exp(-optical);
        }
    }
    // Inside-shell dome: full-sky coverage that fades out across the same
    // altitude band the terrain fog's space fade uses.
    let presence = 1.0 - smoothstep(180.0, 420.0, cam_altitude);
    let horizon_blend = smoothstep(0.55, 0.02, mu);
    let dome_alpha = presence * mix(0.65, 0.95, horizon_blend);
    let alpha = max(rim_alpha, dome_alpha);
    // Horizon-heavy paths pick up the paler horizon blue; overhead views
    // keep the deep zenith blue.
    var sky = mix(vec3<f32>(0.18, 0.40, 0.82), vec3<f32>(0.56, 0.71, 0.90), horizon_blend);
    // Day/night dims the colour: deep navy on the night side, unchanged by
    // day. Warm dusk tint near the terminator, forward-scatter sun glow.
    let sun_dot = dot(up, light);
    let day = planet_solar_factor(up, light);
    let dusk = (1.0 - smoothstep(0.02, 0.30, sun_dot)) * day;
    sky = mix(sky, vec3<f32>(0.86, 0.54, 0.34), dusk * 0.45);
    sky *= mix(0.22, 1.0, day);
    let glow = pow(max(dot(ray, light), 0.0), 12.0);
    sky += vec3<f32>(0.95, 0.80, 0.60) * glow * 0.35 * day;
    return vec4<f32>(sky, clamp(alpha, 0.0, 1.0));
}
`

WIND_VISUAL_SHADER ::
	SHADER_PREAMBLE +
	`
struct VertexIn {
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) scalar: f32,
    @location(3) uv: vec2<f32>,
};
struct VertexOut {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) world_position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) scalar: f32,
    @location(3) uv: vec2<f32>,
};
@vertex
fn vs_main(in: VertexIn, @builtin(instance_index) instance_index: u32) -> VertexOut {
    let model = u.model * instances.transforms[instance_index];
    let world = model * vec4<f32>(in.position, 1.0);
    var out: VertexOut;
    out.clip_position = u.view_projection * world;
    out.world_position = world.xyz;
    out.normal = normalize((model * vec4<f32>(in.normal, 0.0)).xyz);
    out.scalar = in.scalar;
    out.uv = in.uv;
    return out;
}
@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4<f32> {
    if cutaway_clipped(in.world_position) { discard; }
    let distance_to_eye = distance(u.camera_position.xyz, in.world_position);
    let view = normalize(in.world_position - u.camera_position.xyz);
    let edge = 1.0 - smoothstep(0.72, 1.0, abs(in.uv.y));
    let phase = fract(in.uv.x - u.light_params.w * u.custom_params.y);
    let pulse = exp(-pow((phase - 0.72) * 7.5, 2.0));
    let intensity = clamp(0.28 + in.scalar * 0.72 + pulse * u.custom_params.z, 0.0, 1.0);
    let base = mix(u.color.rgb, u.color_high.rgb, intensity);
    let fog = atmosphere_fog(in.world_position, distance_to_eye, view, normalize(-u.light_direction.xyz));
    let visibility = 1.0 - fog.a;
    let alpha = u.custom_params.x * edge * intensity * visibility;
    return vec4<f32>(base * alpha, alpha);
}
`

ATMOSPHERE_OBJECT_SHADER ::
	SHADER_PREAMBLE +
	`
struct VertexOut {
    @builtin(position) position: vec4<f32>,
    @location(0) world_position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) scalar: f32,
    @location(3) uv: vec2<f32>,
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
    out.position.z -= u.light_params.z * out.position.w;
    out.world_position = world.xyz;
    out.normal = normalize((model * vec4<f32>(normal, 0.0)).xyz);
    out.scalar = scalar;
    out.uv = uv;
    return out;
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4<f32> {
    if cutaway_clipped(in.world_position) { discard; }
    let normal = normalize(in.normal);
    let light = normalize(u.light_direction.xyz);
    let to_camera = u.camera_position.xyz - in.world_position;
    let dist = length(to_camera);
    let view = to_camera / max(dist, 0.001);
    var base = u.color;
    if u.use_scalar != 0u {
        base = mix(u.color, u.color_high, clamp(in.scalar, 0.0, 1.0));
    }
    let texel = textureSample(mesh_texture, mesh_sampler, in.uv);
    base = mix(base, base * texel, f32(u.use_texture));
    let radial = normalize(in.world_position);
    var color = base.rgb * (
        planet_ambient_light(normal, radial, light) + planet_direct_light(normal, radial, light));
    color = atmosphere_apply(color, in.world_position, dist, view, light);
    return vec4<f32>(color * base.a, base.a);
}
`

SKY_SHADER ::
	SHADER_PREAMBLE +
	`
struct VertexOut {
    @builtin(position) position: vec4<f32>,
    @location(0) ray: vec3<f32>,
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
    let world = (model * vec4<f32>(position, 1.0)).xyz;
    out.position = u.view_projection * vec4<f32>(world, 1.0);
    out.position.z = out.position.w * 0.9999;
    out.ray = normalize(world - u.camera_position.xyz);
    return out;
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4<f32> {
    let ray = normalize(in.ray);
    let light = normalize(u.light_direction.xyz);
    // Black space with a sparse star field, overlaid by the analytic
    // atmosphere shell: blue sky when the camera is low, a thin blue limb
    // from orbit, stars back through the shell on the night side. The sun
    // disk and glow draw on top so it stays visible through the haze.
    var color = vec3<f32>(0.0);
    let cell = floor(ray * 220.0);
    let star_hash = hash21(cell.xy * 3.1 + vec2<f32>(cell.z * 7.7, cell.z * 3.3));
    let star = step(0.9985, star_hash) * (0.25 + 0.55 * hash21(cell.yz + vec2<f32>(cell.x, cell.x * 1.7)));
    color += vec3<f32>(star);
    let atmos = atmosphere_sky(u.camera_position.xyz, ray, light);
    color = mix(color, atmos.rgb, atmos.a);
    let camera_altitude = max(length(u.camera_position.xyz) - 1080.0, 0.0);
    let cloud_presence = (1.0 - smoothstep(160.0, 520.0, camera_altitude)) * u.custom_params.x;
    let storm = clamp(u.custom_params_3.z, 0.0, 1.0);
    let cloud_time = u.light_params.w * max(u.custom_params.y, 0.01);
    let cloud_noise = atmosphere_cloud(ray, cloud_time, u.custom_params_3.xy);
    let threshold = mix(0.72, 0.38, cloud_presence);
    let body = smoothstep(threshold - 0.10, threshold + 0.08, cloud_noise.x);
    let erosion = smoothstep(0.30, 0.72, cloud_noise.y);
    let cloud = clamp(body * mix(0.72, 1.0, erosion) * cloud_presence, 0.0, 1.0);
    let cloud_edge = clamp(body - smoothstep(threshold + 0.03, threshold + 0.16, cloud_noise.x), 0.0, 1.0);
    let camera_radial = normalize(u.camera_position.xyz);
    let horizon = smoothstep(0.02, 0.32, abs(dot(ray, camera_radial)));
    let cloud_day = planet_solar_factor(camera_radial, light);
    let cloud_base = mix(vec3<f32>(0.27, 0.31, 0.37), vec3<f32>(0.10, 0.13, 0.18), storm);
    var cloud_light = mix(cloud_base, vec3<f32>(0.88, 0.90, 0.92), cloud_day * (1.0 - storm * 0.45));
    cloud_light += vec3<f32>(0.15, 0.16, 0.17) * cloud_edge * cloud_day;
    let flash = storm_flash(u.light_params.w, storm);
    let flash_direction = storm_light_direction(normalize(u.camera_position.xyz), u.light_params.w);
    let flash_focus = pow(max(dot(ray, flash_direction), 0.0), 10.0);
    let cloud_flash = flash * cloud * (0.32 + cloud_edge * 0.68) * (0.35 + flash_focus * 1.65);
    cloud_light += vec3<f32>(0.72, 0.84, 1.0) * cloud_flash * 1.8;
    color = mix(color, cloud_light, cloud * horizon * 0.92);
    color += vec3<f32>(0.48, 0.62, 0.90) * flash * flash_focus * cloud * 0.45;
    let sun_alignment = max(dot(ray, light), 0.0);
    let sun_visibility = 1.0 - cloud * mix(0.78, 0.96, storm);
    let sun_glow = pow(sun_alignment, 350.0) * 0.30;
    let sun_disk = smoothstep(0.99945, 0.99985, sun_alignment) * 1.6;
    color += vec3<f32>(1.0, 0.93, 0.82) * (sun_glow + sun_disk) * sun_visibility;
    let underwater = underwater_apply(color, 80.0, light, normalize(u.camera_position.xyz));
    return vec4<f32>(underwater, 1.0);
}
`

OCEAN_SPECTRUM_INIT_SHADER :: `
struct Spectrum_Params {
    wind: vec2<f32>, amplitude: f32, peak_omega: f32, gamma: f32,
    length_scale: f32, depth: f32, resolution: u32, seed: u32,
};
@group(0) @binding(0) var<uniform> params: Spectrum_Params;
@group(0) @binding(1) var spectrum: texture_storage_2d<rgba32float, write>;
fn hash(value: vec2<u32>) -> f32 {
    var bits = value.x * 1664525u + value.y * 1013904223u + params.seed;
    bits = (bits ^ (bits >> 16u)) * 2246822519u;
    return max(f32(bits & 0x00ffffffu) / 16777216.0, 0.000001);
}
@compute @workgroup_size(8, 8)
fn cs_main(@builtin(global_invocation_id) id: vec3<u32>) {
    if (id.x >= params.resolution || id.y >= params.resolution) { return; }
    let half = f32(params.resolution) * 0.5;
    let k = (vec2<f32>(id.xy) - vec2<f32>(half)) * 6.28318530718 / params.length_scale;
    let raw_k_length = length(k);
    if (raw_k_length <= 0.0001) {
        textureStore(spectrum, vec2<i32>(id.xy), vec4<f32>(0.0));
        return;
    }
    let k_length = max(raw_k_length, 0.0001);
    let depth = max(params.depth, 0.05);
    let kh = k_length * depth;
    let tanh_kh = tanh(kh);
    let omega = sqrt(9.81 * k_length * tanh_kh);
    let sigma = select(0.09, 0.07, omega <= params.peak_omega);
    let exponent = -pow(omega - params.peak_omega, 2.0) /
        max(2.0 * sigma * sigma * params.peak_omega * params.peak_omega, 0.0001);
    let peak = pow(params.gamma, exp(exponent));
    let jonswap = params.amplitude * 9.81 * 9.81 * pow(max(omega, 0.01), -5.0) *
        exp(-1.25 * pow(params.peak_omega / max(omega, 0.01), 4.0)) * peak;
    let nondimensional = omega * sqrt(depth / 9.81);
    let tma_low = 0.5 * nondimensional * nondimensional;
    let tma_middle = 1.0 - 0.5 * pow(2.0 - nondimensional, 2.0);
    let tma = select(select(1.0, tma_middle, nondimensional < 2.0), tma_low, nondimensional <= 1.0);
    let sech_squared = max(1.0 - tanh_kh * tanh_kh, 0.0);
    let domega_dk = 9.81 * (tanh_kh + kh * sech_squared) / max(2.0 * omega, 0.0001);
    let wind_length = max(length(params.wind), 0.0001);
    let alignment = max(dot(k / k_length, params.wind / wind_length), 0.0);
    let directional = 0.63661977236 * alignment * alignment;
    let delta_k = 6.28318530718 / params.length_scale;
    let density = jonswap * tma * domega_dk * directional / k_length;
    let radius = sqrt(-2.0 * log(hash(id.xy)));
    let phase = 6.28318530718 * hash(id.yx + vec2<u32>(17u, 41u));
    let gaussian = radius * vec2<f32>(cos(phase), sin(phase));
    let discrete_scale = f32(params.resolution * params.resolution);
    let h0 = gaussian * sqrt(max(density * delta_k * delta_k, 0.0) * 0.5) * discrete_scale;
    textureStore(spectrum, vec2<i32>(id.xy), vec4<f32>(h0, omega, k_length));
}
`

OCEAN_SPECTRUM_EVOLVE_SHADER :: `
struct Time_Params {
    time: f32, blend: f32, resolution: u32, log_resolution: u32,
    source_choppiness: f32, target_choppiness: f32, pad_0: f32, pad_1: f32,
};
@group(0) @binding(0) var<uniform> params: Time_Params;
@group(0) @binding(1) var source_initial: texture_2d<f32>;
@group(0) @binding(2) var target_initial: texture_2d<f32>;
@group(0) @binding(3) var frequency: texture_storage_2d<rgba32float, write>;
fn cmul(a: vec2<f32>, b: vec2<f32>) -> vec2<f32> {
    return vec2<f32>(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x);
}
fn reverse_bits(value: u32) -> u32 {
    return reverseBits(value) >> (32u - params.log_resolution);
}
fn evolve_pair(initial: texture_2d<f32>, p: vec2<u32>, mirror: vec2<u32>) -> vec2<f32> {
    let h0 = textureLoad(initial, vec2<i32>(p), 0);
    let mirrored = textureLoad(initial, vec2<i32>(mirror), 0);
    let phase = h0.z * params.time;
    let rotation = vec2<f32>(cos(phase), sin(phase));
    return cmul(h0.xy, rotation) +
        cmul(vec2<f32>(mirrored.x, -mirrored.y), vec2<f32>(rotation.x, -rotation.y));
}
@compute @workgroup_size(8, 8)
fn cs_main(@builtin(global_invocation_id) id: vec3<u32>) {
    if (id.x >= params.resolution || id.y >= params.resolution) { return; }
    let p = id.xy;
    let mirror = (vec2<u32>(params.resolution) - p) % vec2<u32>(params.resolution);
    let source_h0 = textureLoad(source_initial, vec2<i32>(p), 0);
    let target_h0 = textureLoad(target_initial, vec2<i32>(p), 0);
    let source_height = evolve_pair(source_initial, p, mirror);
    let target_height = evolve_pair(target_initial, p, mirror);
    let s = params.blend * params.blend * (3.0 - 2.0 * params.blend);
    let height = mix(source_height, target_height, s);
    let choppiness = mix(params.source_choppiness, params.target_choppiness, s);
    let wave_number = mix(source_h0.w, target_h0.w, s);
    let destination_coord = vec2<i32>(i32(reverse_bits(p.x)), i32(reverse_bits(p.y)));
    textureStore(frequency, destination_coord, vec4<f32>(height, wave_number * choppiness, 0.0));
}
`

OCEAN_STOCKHAM_SHADER :: `
struct FFT_Params { stage: u32, horizontal: u32, resolution: u32, normalize: u32 };
@group(0) @binding(0) var<uniform> params: FFT_Params;
@group(0) @binding(1) var source: texture_2d<f32>;
@group(0) @binding(2) var destination: texture_storage_2d<rgba32float, write>;
@compute @workgroup_size(8, 8)
fn cs_main(@builtin(global_invocation_id) id: vec3<u32>) {
    if (id.x >= params.resolution || id.y >= params.resolution) { return; }
    let span = 1u << params.stage;
    let block = span << 1u;
    let coordinate = select(id.y, id.x, params.horizontal == 1u);
    let offset = coordinate & (block - 1u);
    let base = coordinate - offset;
    let lane = offset & (span - 1u);
    let low_coordinate = base + lane;
    let high_coordinate = low_coordinate + span;
    let low_p = select(vec2<u32>(id.x, low_coordinate), vec2<u32>(low_coordinate, id.y), params.horizontal == 1u);
    let high_p = select(vec2<u32>(id.x, high_coordinate), vec2<u32>(high_coordinate, id.y), params.horizontal == 1u);
    let a = textureLoad(source, vec2<i32>(low_p), 0);
    let b = textureLoad(source, vec2<i32>(high_p), 0);
    let angle = 6.28318530718 * f32(lane) / f32(block);
    let twiddle = vec2<f32>(cos(angle), sin(angle));
    let rotated = vec2<f32>(b.x * twiddle.x - b.y * twiddle.y, b.x * twiddle.y + b.y * twiddle.x);
    let sign = select(1.0, -1.0, offset >= span);
    var value = vec4<f32>(a.xy + sign * rotated, a.zw);
    if (params.normalize == 1u) {
        let normalized = value.xy / f32(params.resolution * params.resolution);
        value = vec4<f32>(normalized, value.zw);
    }
    textureStore(destination, vec2<i32>(id.xy), value);
}
`

OCEAN_DERIVE_SHADER :: `
struct Derive_Params { resolution: u32, inverse_size: f32, choppiness: f32, pad: f32 };
@group(0) @binding(0) var<uniform> params: Derive_Params;
@group(0) @binding(1) var height: texture_2d<f32>;
@group(0) @binding(2) var displacement: texture_storage_2d<rgba16float, write>;
@group(0) @binding(3) var slope: texture_storage_2d<rgba16float, write>;
@group(0) @binding(4) var foam: texture_storage_2d<r32float, write>;
fn spatial_height(p: vec2<i32>) -> f32 {
    let parity = (p.x + p.y) & 1;
    let fft_shift = select(1.0, -1.0, parity == 1);
    return textureLoad(height, p, 0).x * fft_shift;
}
@compute @workgroup_size(8, 8)
fn cs_main(@builtin(global_invocation_id) id: vec3<u32>) {
    if (id.x >= params.resolution || id.y >= params.resolution) { return; }
    let size = i32(params.resolution);
    let p = vec2<i32>(id.xy);
    let left = spatial_height(vec2<i32>((p.x - 1 + size) % size, p.y));
    let right = spatial_height(vec2<i32>((p.x + 1) % size, p.y));
    let down = spatial_height(vec2<i32>(p.x, (p.y - 1 + size) % size));
    let up = spatial_height(vec2<i32>(p.x, (p.y + 1) % size));
    let center = spatial_height(p);
    let gradient = vec2<f32>(right - left, up - down) * 0.5 * params.inverse_size;
    let laplacian = (right + left + up + down - 4.0 * center) *
        params.inverse_size * params.inverse_size;
    let texel_size = 1.0 / max(params.inverse_size, 0.0001);
    let jacobian = clamp(
        1.0 - params.choppiness * texel_size * max(-laplacian, 0.0),
        -4.0,
        4.0);
    textureStore(displacement, p, vec4<f32>(center, 0.0, 0.0, jacobian));
    textureStore(slope, p, vec4<f32>(gradient, dot(gradient, gradient), 1.0));
    textureStore(foam, p, vec4<f32>(max(1.0 - jacobian, 0.0), 0.0, 0.0, 1.0));
}
`

OCEAN_FOAM_HISTORY_SHADER :: `
struct Foam_Params { decay: f32, injection: f32, resolution: u32 };
@group(0) @binding(0) var<uniform> params: Foam_Params;
@group(0) @binding(1) var previous_foam: texture_2d<f32>;
@group(0) @binding(2) var crest_foam: texture_2d<f32>;
@group(0) @binding(3) var next_foam: texture_storage_2d<r32float, write>;
@compute @workgroup_size(8, 8)
fn cs_main(@builtin(global_invocation_id) id: vec3<u32>) {
    if (id.x >= params.resolution || id.y >= params.resolution) { return; }
    let p = vec2<i32>(id.xy);
    let previous = textureLoad(previous_foam, p, 0).x * params.decay;
    let crest = textureLoad(crest_foam, p, 0).x * params.injection;
    textureStore(next_foam, p, vec4<f32>(max(previous, crest), 0.0, 0.0, 1.0));
}
`

FAR_WATER_SHADER ::
	SHADER_PREAMBLE +
	`
struct VertexOut {
    @builtin(position) position: vec4<f32>,
    @location(0) world_position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) shallow: f32,
    @location(3) depth: f32,
    @location(4) coverage: f32,
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
    let world = (model * vec4<f32>(position, 1.0)).xyz;
    out.position = u.view_projection * vec4<f32>(world, 1.0);
    out.world_position = world;
    out.normal = normalize((model * vec4<f32>(normal, 0.0)).xyz);
    out.shallow = scalar;
    out.depth = uv.x;
    out.coverage = uv.y;
    return out;
}

fn far_water_beyond_horizon(world_position: vec3<f32>, radial: vec3<f32>) -> bool {
    let eye = u.camera_position.xyz;
    if length(eye) <= length(world_position) { return false; }
    return dot(eye - world_position, radial) < 0.0;
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4<f32> {
    if cutaway_clipped(in.world_position) { discard; }
    let radial = normalize(in.world_position);
    if far_water_beyond_horizon(in.world_position, radial) { discard; }
    let edge_width = max(fwidth(in.coverage), 0.001);
    let edge = smoothstep(0.5 - edge_width, 0.5 + edge_width, in.coverage);
    if edge <= 0.001 { discard; }
    let eye = u.camera_position.xyz;
    let to_camera = eye - in.world_position;
    let distance = length(to_camera);
    let view = to_camera / max(distance, 0.001);
    let light = normalize(u.light_direction.xyz);
    let normal = normalize(mix(in.normal, radial, 0.72));
    let ndv = max(dot(normal, view), 0.0);
    let ndl = max(dot(normal, light), 0.0);
    let fresnel = 0.02037 + 0.97963 * pow(1.0 - ndv, 5.0);
    let depth_factor = clamp(max(in.depth / 6.0, 1.0 - in.shallow), 0.0, 1.0);
    let water = mix(u.color_high.rgb, u.color.rgb, smoothstep(0.18, 0.9, depth_factor));
    let absorption = exp(-vec3<f32>(0.42, 0.16, 0.07) * min(in.depth, 8.0) * 0.18);
    let transmitted = water * absorption * (0.30 + 0.70 * ndl);
    let reflected = reflect(-view, normal);
    let sky = atmosphere_sky(in.world_position, reflected, light).rgb;
    let storm = clamp(u.custom_params_3.z, 0.0, 1.0);
    let roughness = clamp(u.custom_params_2.y + storm * 0.12, 0.08, 0.72);
    let reflection_weight = clamp(fresnel + roughness * 0.06, 0.0, 0.92);
    let lit = atmosphere_apply(
        mix(transmitted, sky, reflection_weight),
        in.world_position,
        distance,
        view,
        light);
    return vec4<f32>(lit * edge, edge);
}
`

// Water: vertex-stage sine waves with analytic normals, per-pixel scrolling
// ripple normals, depth-graded absorption from the shallowness scalar, sky
// gradient fresnel reflection, sun glint with sparkle, and noise-eroded
// shoreline foam.
WATER_SHADER ::
	SHADER_PREAMBLE +
	`
struct VertexOut {
    @builtin(position) position: vec4<f32>,
    @location(0) world_position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) shallow: f32,
    @location(3) depth: f32,
    @location(4) coverage: f32,
    @location(5) wave_data: vec3<f32>,
    @location(6) spectral_position: vec3<f32>,
    @location(7) radial_displacement: f32,
};

struct WaveSample {
    displacement: vec3<f32>,
    compression: f32,
    envelope: f32,
};

struct SpectralSample {
    displacement: vec3<f32>,
    slope: vec2<f32>,
    jacobian: f32,
    foam: f32,
};

struct WaterVolumeSample {
    transmittance: vec3<f32>,
    inscatter: vec3<f32>,
    darkening: f32,
};

fn wave_direction(radial: vec3<f32>) -> vec3<f32> {
    let supplied = u.custom_params.yzw;
    let projected = supplied - radial * dot(supplied, radial);
    let fallback_axis = select(vec3<f32>(0.0, 0.0, 1.0), vec3<f32>(0.0, 1.0, 0.0), abs(radial.z) > 0.9);
    let fallback = normalize(cross(fallback_axis, radial));
    return select(fallback, projected / max(length(projected), 0.0001), length(projected) > 0.0001);
}

fn wrapped_phase(value: f32) -> f32 {
    return value - floor(value / 6.28318530718) * 6.28318530718;
}

// A cascade tile only carries information down to its texel; past the
// distance where a tile spans a few vertices (vertex stage) or a texel spans
// a pixel (fragment stage) the sample is noise, so each cascade fades out on
// its own scale instead of aliasing into speckle from orbit.
fn cascade_distance_resolved(scale: f32, dist: f32) -> f32 {
    return 1.0 - smoothstep(scale * 12.0, scale * 40.0, dist);
}

fn cascade_pixel_resolved(coordinates: vec2<f32>, scale: f32, resolution: f32) -> f32 {
    let footprint = max(fwidth(coordinates.x), fwidth(coordinates.y)) / scale * resolution;
    return 1.0 - smoothstep(0.5, 1.5, footprint);
}

fn spectral_coordinates(world: vec3<f32>, primary: vec3<f32>, secondary: vec3<f32>) -> vec2<f32> {
    return vec2<f32>(dot(world, primary), dot(world, secondary));
}

fn spectral_sample(texture: texture_2d<f32>, world: vec3<f32>, primary: vec3<f32>, secondary: vec3<f32>, scale: f32, resolved: f32) -> SpectralSample {
    let coordinates = spectral_coordinates(world, primary, secondary);
    let sampled = textureSampleLevel(texture, mesh_sampler, fract(coordinates / scale), 0.0);
    let finite = all(abs(sampled) <= vec4<f32>(1000.0));
    let packed = select(vec4<f32>(0.0, 0.0, 0.0, 1.0), sampled, finite);
    let weight = clamp(resolved, 0.0, 1.0);
    return SpectralSample(
        normalize(world) * packed.x * weight,
        vec2<f32>(0.0),
        mix(1.0, packed.w, weight),
        max(1.0 - packed.w, 0.0) * weight);
}

fn wave_amplitude(depth: f32, coverage: f32) -> f32 {
    let significant_height = clamp(u.custom_params.x, 0.0, 20.0);
    let target_rms = significant_height * 0.25;
    let wet = smoothstep(0.04, 0.42, coverage);
    let finite_depth = max(depth, 0.04);
    let shoaling = clamp(sqrt(3.5 / finite_depth), 1.0, 2.4);
    let breaker_limit = finite_depth * 0.78;
    let set_up = u.custom_params_3.w * smoothstep(2.2, 0.18, finite_depth) * 0.18;
    return min(target_rms * shoaling + set_up, breaker_limit) * wet;
}

fn wind_sea_field(world: vec3<f32>, radial: vec3<f32>, amplitude: f32, t: f32, dist: f32) -> WaveSample {
    let primary = wave_direction(radial);
    let secondary = normalize(cross(radial, primary));
    let period = max(u.custom_params_7.x, 2.0);
    let omega = 6.28318530718 / period;
    let wave_number = omega * omega / 9.81 * 25.0;
    let wavelength = 6.28318530718 / wave_number;
    let resolved_amplitude = amplitude * cascade_distance_resolved(wavelength, dist);
    let supplied = normalize(u.custom_params.yzw);
    let phase_coordinate = dot(world, supplied);
    let carrier = wrapped_phase(phase_coordinate * wave_number - omega * t);
    let crossing = wrapped_phase(phase_coordinate * wave_number * 1.17 - omega * 1.08 * t);
    let carrier_shape = sin(carrier) * 0.70 + sin(carrier * 2.0) * 0.14;
    let crossing_shape = sin(crossing) * 0.16;
    let height = (carrier_shape + crossing_shape) * resolved_amplitude;
    let displacement = radial * height;
    return WaveSample(displacement, max(sin(carrier) * resolved_amplitude * wave_number, 0.0), 0.0);
}

fn packet_center_height(packet_index: u32) -> vec4<f32> {
    switch packet_index {
        case 0u: { return u.custom_params_8; }
        case 1u: { return u.custom_params_11; }
        case 2u: { return u.custom_params_14; }
        default: { return u.custom_params_17; }
    }
}

fn packet_direction_period(packet_index: u32) -> vec4<f32> {
    switch packet_index {
        case 0u: { return u.custom_params_9; }
        case 1u: { return u.custom_params_12; }
        case 2u: { return u.custom_params_15; }
        default: { return u.custom_params_18; }
    }
}

fn packet_envelope_phase(packet_index: u32) -> vec4<f32> {
    switch packet_index {
        case 0u: { return u.custom_params_10; }
        case 1u: { return u.custom_params_13; }
        case 2u: { return u.custom_params_16; }
        default: { return u.custom_params_19; }
    }
}

fn wave_packet_field(packet_index: u32, world: vec3<f32>, radial: vec3<f32>, depth: f32, coverage: f32, t: f32) -> WaveSample {
    let center_height = packet_center_height(packet_index);
    let direction_period = packet_direction_period(packet_index);
    let envelope_phase = packet_envelope_phase(packet_index);
    let packet_center = center_height.xyz;
    let packet_height = clamp(center_height.w, 0.0, 20.0);
    let packet_period = max(direction_period.w, 0.25);
    let packet_length = max(envelope_phase.x, 1.0);
    let packet_width = max(envelope_phase.y, 1.0);
    let phase_epoch = envelope_phase.z;
    let wind_primary = wave_direction(radial);
    let supplied_world = direction_period.xyz;
    let supplied = supplied_world - radial * dot(supplied_world, radial);
    let packet_center_radial = normalize(packet_center);
    let centre_tangent = supplied_world - packet_center_radial * dot(supplied_world, packet_center_radial);
    let radial_packet = length(supplied_world) > 0.0001 && length(centre_tangent) <= 0.001 * length(supplied_world);
    var primary = select(wind_primary, supplied / max(length(supplied), 0.0001), length(supplied) > 0.0001);
    let center_dot = clamp(dot(radial, packet_center_radial), -1.0, 1.0);
    let outward = radial * center_dot - packet_center_radial;
    primary = select(primary, outward / max(length(outward), 0.0001), radial_packet && length(outward) > 0.0001);
    let secondary = normalize(cross(radial, primary));
    let offset = world - packet_center;
    let directional_travel = max(-envelope_phase.w, 0.0) * max(t - phase_epoch, 0.0);
    let longitudinal = dot(offset, primary) - directional_travel;
    let lateral = dot(offset, secondary);
    let directional_within = select(
        0.0,
        1.0,
        abs(longitudinal) < packet_length * 3.0 &&
        abs(lateral) < packet_width * 3.0);
    let directional_envelope = exp(
        -longitudinal * longitudinal / (packet_length * packet_length) -
        lateral * lateral / (packet_width * packet_width)) * directional_within;
    let radial_distance = 2.0 * asin(min(length(radial - packet_center_radial) * 0.5, 1.0)) * 1080.0;
    let front_speed = length(supplied_world);
    let ring_front = envelope_phase.x + front_speed * max(t - phase_epoch, 0.0);
    let ring_offset = radial_distance - ring_front;
    let radial_envelope = exp(-ring_offset * ring_offset / (packet_width * packet_width)) *
        select(0.0, 1.0, abs(ring_offset) <= packet_width * 2.0);
    let envelope = select(directional_envelope, radial_envelope, radial_packet);
    let target_rms = packet_height * 0.25;
    let wet = smoothstep(0.04, 0.42, coverage);
    let finite_depth = max(depth, 0.04);
    let shoaling = clamp(sqrt(3.5 / finite_depth), 1.0, 2.4);
    let packet_limit = min(target_rms * shoaling, finite_depth * 0.78) * wet;
    let debug_packet = envelope_phase.w < 0.0;
    let debug_limit = 0.5 * min(packet_height, max(depth, 0.0) * 0.78) * wet;
    let packet_amplitude = select(packet_limit, debug_limit, debug_packet) * envelope;
    let omega = 6.28318530718 / packet_period;
    let debug_wave_number = select(length(supplied_world), -envelope_phase.w, radial_packet);
    let wave_number = select(omega * omega / 9.81 * 25.0, debug_wave_number, debug_packet);
    let carrier_time = select(t, max(t - phase_epoch, 0.0), debug_packet);
    let directional_coordinate = select(dot(world, primary), dot(offset, primary), envelope_phase.w < 0.0);
    let carrier_coordinate = select(directional_coordinate, radial_distance, radial_packet);
    let carrier = wrapped_phase(carrier_coordinate * wave_number - omega * carrier_time);
    let sideband = wrapped_phase(carrier_coordinate * wave_number * 1.08 - omega * 1.04 * carrier_time);
    let height = select(sin(carrier) * 0.78 + sin(sideband) * 0.22, sin(carrier), debug_packet) * packet_amplitude;
    let displacement = radial * height + primary * cos(carrier) * packet_amplitude * 0.48;
    let active_envelope = envelope * smoothstep(0.001, 0.05, target_rms) * wet;
    return WaveSample(
        displacement,
        max(sin(carrier) * packet_amplitude * wave_number, 0.0),
        active_envelope);
}

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
    var world = (model * vec4<f32>(position, 1.0)).xyz;
    let spectral_position = world;
    let surface_normal = normalize((model * vec4<f32>(normal, 0.0)).xyz);
    let radial = normalize(world);
    let primary = wave_direction(radial);
    let secondary = normalize(cross(radial, primary));
    let amplitude = wave_amplitude(uv.x, uv.y);
    let macro_time = u.custom_params_7.y;
    let camera_dist = length(u.camera_position.xyz - world);
    let wind_sea = wind_sea_field(world, radial, amplitude, macro_time, camera_dist);
    let params_7_w = u32(max(u.custom_params_7.w, 0.0));
    let packet_count = params_7_w & 7u;
    var packet_displacement = vec3<f32>(0.0);
    var packet_compression = 0.0;
    var packet_envelope_union = 0.0;
    var packet_weight_sum = 0.0;
    for (var packet_index = 0u; packet_index < 4u; packet_index += 1u) {
        let packet_active = f32(packet_index < packet_count);
        let packet = wave_packet_field(packet_index, world, radial, uv.x, uv.y, macro_time);
        packet_displacement += packet.displacement * packet_active;
        packet_compression += packet.compression * packet_active;
        packet_envelope_union = 1.0 -
            (1.0 - packet_envelope_union) * (1.0 - packet.envelope * packet_active);
        packet_weight_sum += packet.envelope * packet_active;
    }
    let packet_overlap_scale = min(1.0, 1.0 / max(packet_weight_sum, 1.0));
    packet_displacement *= packet_overlap_scale;
    packet_compression *= packet_overlap_scale;
    let cascade_0 = spectral_sample(mesh_texture, world, primary, secondary, 7.88,
        cascade_distance_resolved(7.88, camera_dist));
    let cascade_1 = spectral_sample(mesh_normal_texture, world, primary, secondary, 30.76,
        cascade_distance_resolved(30.76, camera_dist));
    let cascade_2 = spectral_sample(mesh_roughness_ao_texture, world, primary, secondary, 115.88,
        cascade_distance_resolved(115.88, camera_dist));
    let spectral_enabled = f32(u.use_texture * u.use_normal * u.use_roughness_ao);
    let spectral_wet = smoothstep(0.04, 0.42, uv.y);
    let radial_limit = min(max(u.custom_params.x, 0.0) * 0.25 * 1.35, max(uv.x * 0.72, 0.04)) * spectral_wet;
    let spectral_raw =
        cascade_0.displacement + cascade_1.displacement + cascade_2.displacement;
    let spectral_displacement =
        radial * clamp(dot(spectral_raw, radial), -radial_limit, radial_limit);
    let packet_mix = clamp(packet_envelope_union, 0.0, 1.0);
    let background_scale = sqrt(max(1.0 - packet_mix * packet_mix, 0.0));
    let macro_displacement =
        mix(wind_sea.displacement, spectral_displacement, spectral_enabled) * background_scale +
        packet_displacement;
    let displacement_mode = u.custom_params_7.z;
    let gpu_displacement = mix(
        spectral_displacement * spectral_enabled,
        macro_displacement,
        clamp(displacement_mode, 0.0, 1.0));
    let displacement = select(gpu_displacement, vec3<f32>(0.0), displacement_mode < 0.0);
    let spectral_compression = max(
        1.0 - min(cascade_0.jacobian, min(cascade_1.jacobian, cascade_2.jacobian)),
        0.0);
    let compression =
        mix(wind_sea.compression, spectral_compression, spectral_enabled) * background_scale +
        packet_compression;
    world += displacement;
    out.world_position = world;
    out.spectral_position = spectral_position;
    out.position = u.view_projection * vec4<f32>(world, 1.0);
    out.normal = surface_normal;
    out.shallow = scalar;
    out.depth = uv.x;
    out.coverage = uv.y;
    out.wave_data = vec3<f32>(
        dot(displacement, radial) / max(amplitude, 0.001),
        compression,
        packet_mix);
    out.radial_displacement = dot(displacement, radial);
    return out;
}

fn fresnel_schlick(cosine: f32, f0: vec3<f32>) -> vec3<f32> {
    return f0 + (vec3<f32>(1.0) - f0) * pow(1.0 - cosine, 5.0);
}

fn ggx_distribution(ndh: f32, roughness: f32) -> f32 {
    let alpha = roughness * roughness;
    let alpha2 = alpha * alpha;
    let denominator = ndh * ndh * (alpha2 - 1.0) + 1.0;
    return alpha2 / max(3.14159265 * denominator * denominator, 0.0001);
}

fn smith_visibility(ndv: f32, ndl: f32, roughness: f32) -> f32 {
    let k = (roughness + 1.0) * (roughness + 1.0) * 0.125;
    let view = ndv / max(ndv * (1.0 - k) + k, 0.0001);
    let light = ndl / max(ndl * (1.0 - k) + k, 0.0001);
    return view * light;
}

fn bubble_rings(local_position: vec2<f32>, t: f32, support: f32, strength: f32) -> f32 {
    let drifted = local_position + vec2<f32>(t * 0.18, t * -0.07);
    let cell = floor(drifted * 0.32);
    let local = fract(drifted * 0.32) - vec2<f32>(0.5);
    let seed = hash21(cell);
    let center = vec2<f32>(hash21(cell + vec2<f32>(7.0, 3.0)), hash21(cell + vec2<f32>(2.0, 11.0))) * 0.34 - 0.17;
    let age = fract(t * mix(0.10, 0.18, seed) + seed);
    let radius = mix(0.035, 0.16, age) * mix(0.7, 1.25, seed);
    let width = max(fwidth(length(local - center)), 0.008);
    let ring = 1.0 - smoothstep(width, width * 2.5, abs(length(local - center) - radius));
    let life = smoothstep(0.0, 0.16, age) * (1.0 - smoothstep(0.70, 1.0, age));
    let sparse = step(0.76, seed);
    return ring * life * sparse * clamp(support * strength, 0.0, 1.0);
}

fn water_screen_offset(
    world_position: vec3<f32>,
    geometry_normal: vec3<f32>,
    shaded_normal: vec3<f32>,
    dimensions: vec2<f32>,
    view_cosine: f32,
    distance: f32,
    pixel_scale: f32,
) -> vec2<f32> {
    let tangent_detail = shaded_normal - geometry_normal * dot(shaded_normal, geometry_normal);
    let detail_length = length(tangent_detail);
    let direction = tangent_detail / max(detail_length, 0.0001);
    let projected_detail = direction * min(detail_length, 0.65) * mix(0.18, 0.62, 1.0 - view_cosine);
    let base_clip = u.view_projection * vec4<f32>(world_position, 1.0);
    let detail_clip = u.view_projection * vec4<f32>(world_position + projected_detail, 1.0);
    let base_ndc = base_clip.xy / max(abs(base_clip.w), 0.0001);
    let detail_ndc = detail_clip.xy / max(abs(detail_clip.w), 0.0001);
    let projected_uv = (detail_ndc - base_ndc) * vec2<f32>(0.5, -0.5);
    let distance_fade = 1.0 - smoothstep(120.0, 720.0, distance);
    let pixel_limit = vec2<f32>(pixel_scale * mix(0.35, 1.0, distance_fade)) /
        max(dimensions, vec2<f32>(1.0));
    return clamp(projected_uv, -pixel_limit, pixel_limit);
}

fn scene_water_sample(
    position: vec4<f32>,
    world_position: vec3<f32>,
    geometry_normal: vec3<f32>,
    shaded_normal: vec3<f32>,
    view_cosine: f32,
    distance: f32,
    edge: f32,
) -> vec4<f32> {
    let dimensions = vec2<f32>(textureDimensions(scene_color_texture));
    let base_uv = position.xy / max(dimensions, vec2<f32>(1.0));
    let distortion = water_screen_offset(
        world_position,
        geometry_normal,
        shaded_normal,
        dimensions,
        view_cosine,
        distance,
        10.0) * edge;
    let refracted_uv = clamp(base_uv + distortion, vec2<f32>(0.002), vec2<f32>(0.998));
    let source_pixel = vec2<i32>(clamp(base_uv, vec2<f32>(0.0), vec2<f32>(0.9999)) * dimensions);
    let refracted_pixel = vec2<i32>(refracted_uv * dimensions);
    let source_depth = textureLoad(scene_depth_texture, source_pixel, 0);
    let refracted_depth = textureLoad(scene_depth_texture, refracted_pixel, 0);
    let depth_width = max(fwidth(position.z) * 2.0, 0.00025);
    let source_behind = smoothstep(depth_width, depth_width * 6.0, source_depth - position.z);
    let refracted_behind = smoothstep(depth_width, depth_width * 6.0, refracted_depth - position.z);
    let depth_continuity = 1.0 - smoothstep(
        depth_width * 8.0,
        depth_width * 64.0,
        abs(refracted_depth - source_depth));
    let screen_margin = min(
        min(refracted_uv.x, refracted_uv.y),
        min(1.0 - refracted_uv.x, 1.0 - refracted_uv.y));
    let screen_valid = smoothstep(0.002, 0.035, screen_margin);
    let shoreline_valid = smoothstep(0.08, 0.45, edge);
    let distortion_valid = 1.0 - smoothstep(0.0, 12.0, length(distortion * dimensions));
    let valid = source_behind * refracted_behind * depth_continuity * screen_valid *
        shoreline_valid * mix(1.0, distortion_valid, 0.35);
    let refracted = textureSample(scene_color_texture, scene_color_sampler, refracted_uv).rgb;
    return vec4<f32>(refracted, valid);
}

fn water_volume_integrate(column_depth: f32, view_cosine: f32, light_cosine: f32, shallow: f32) -> WaterVolumeSample {
    let grazing = smoothstep(0.08, 0.55, 1.0 - clamp(abs(view_cosine), 0.0, 1.0));
    let optical_path = column_depth * mix(1.0, 2.35, grazing);
    let step_length = optical_path / 6.0;
    let absorption = vec3<f32>(0.42, 0.16, 0.070) * u.custom_params_4.x;
    let scattering = vec3<f32>(0.016, 0.090, 0.125) * u.custom_params_4.y;
    let turbidity = clamp(shallow * 0.34 + u.custom_params_3.z * 0.12, 0.0, 1.0);
    var transmittance = vec3<f32>(1.0);
    var inscatter = vec3<f32>(0.0);
    var darkening = 1.0;
    for (var sample_index = 0u; sample_index < 6u; sample_index += 1u) {
        let sample_depth = (f32(sample_index) + 0.5) / 6.0;
        let density = mix(0.72, 1.38, sample_depth) * (1.0 + turbidity * 0.65);
        let extinction = absorption * density + scattering * (0.28 + turbidity * 0.42);
        let step_transmittance = exp(-extinction * step_length);
        let illumination = light_cosine * mix(1.0, 0.56, sample_depth);
        inscatter += transmittance * scattering * density * illumination * step_length;
        transmittance *= step_transmittance;
        darkening *= exp(-step_length * (0.055 + turbidity * 0.035) * density);
    }
    return WaterVolumeSample(transmittance, inscatter, darkening);
}

fn water_sky_sample(world_position: vec3<f32>, direction: vec3<f32>, radial: vec3<f32>, light: vec3<f32>) -> vec3<f32> {
    var sky = mix(
        vec3<f32>(0.10, 0.14, 0.20),
        vec3<f32>(0.008, 0.012, 0.020),
        pow(clamp(dot(direction, radial), 0.0, 1.0), 0.38));
    let atmosphere = atmosphere_sky(world_position, direction, light);
    return mix(sky, atmosphere.rgb, atmosphere.a);
}

fn water_environment_reflection(
    world_position: vec3<f32>,
    reflected: vec3<f32>,
    radial: vec3<f32>,
    light: vec3<f32>,
    roughness: f32,
) -> vec3<f32> {
    let sign_z = select(-1.0, 1.0, reflected.z >= 0.0);
    let basis_scale = -1.0 / (sign_z + reflected.z);
    let basis_mix = reflected.x * reflected.y * basis_scale;
    let tangent = vec3<f32>(
        1.0 + sign_z * reflected.x * reflected.x * basis_scale,
        sign_z * basis_mix,
        -sign_z * reflected.x);
    let bitangent = vec3<f32>(
        basis_mix,
        sign_z + reflected.y * reflected.y * basis_scale,
        -reflected.y);
    let spread = roughness * roughness * 0.36;
    let center = water_sky_sample(world_position, reflected, radial, light);
    let tangent_positive = water_sky_sample(
        world_position,
        normalize(reflected + tangent * spread),
        radial,
        light);
    let tangent_negative = water_sky_sample(
        world_position,
        normalize(reflected - tangent * spread),
        radial,
        light);
    let bitangent_positive = water_sky_sample(
        world_position,
        normalize(reflected + bitangent * spread),
        radial,
        light);
    let bitangent_negative = water_sky_sample(
        world_position,
        normalize(reflected - bitangent * spread),
        radial,
        light);
    return center * 0.40 +
        (tangent_positive + tangent_negative + bitangent_positive + bitangent_negative) * 0.15;
}

// water_beyond_horizon rejects the far hemisphere of the ocean sphere. For a
// surface point with outward radial n, an eye outside that point's radius can
// only see it when the normal faces the eye: dot(eye - p, n) >= 0. Points past
// the tangent horizon (dot < 0) are geometrically occluded by the globe, but
// the water is transparent and writes no depth, so without this test the back
// of the planet draws over the sky at a grazing near-zoom angle. The check is
// suppressed when the eye is inside the point's radius so the surface stays
// two-sided for underwater views.
fn water_beyond_horizon(world_position: vec3<f32>, radial: vec3<f32>) -> bool {
    let eye = u.camera_position.xyz;
    if length(eye) <= length(world_position) { return false; }
    return dot(eye - world_position, radial) < 0.0;
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4<f32> {
    if cutaway_clipped(in.world_position) { discard; }
    let radial = normalize(in.world_position);
    if water_beyond_horizon(in.world_position, radial) { discard; }
    let edge_width = max(fwidth(in.coverage), 0.001);
    let edge = smoothstep(0.5 - edge_width, 0.5 + edge_width, in.coverage);
    let t = u.custom_params_7.y;
    let primary = wave_direction(radial);
    let secondary = normalize(cross(radial, primary));
    let to_camera = u.camera_position.xyz - in.world_position;
    let dist = length(to_camera);
    let view = to_camera / max(dist, 0.001);
    let light = normalize(u.light_direction.xyz);
    let eye_altitude = max(length(u.camera_position.xyz) - 1080.0, 0.0);
    let storm = clamp(u.custom_params_3.z, 0.0, 1.0);
    let storm_surface_cleanup = smoothstep(0.05, 0.35, storm);
    let storm_surface_detail = 1.0 - storm_surface_cleanup;
    let breaker_surface = in.coverage > 1.5;
    let surface_reference = select(radial, normalize(in.normal), breaker_surface);
    let derivative_cross = cross(dpdx(in.world_position), dpdy(in.world_position));
    let derivative_length = length(derivative_cross);
    let derivative_normal = derivative_cross / max(derivative_length, 0.000001);
    let oriented_derivative = select(
        -derivative_normal,
        derivative_normal,
        dot(derivative_normal, surface_reference) >= 0.0);
    let fallback_normal = select(
        -normalize(in.normal),
        normalize(in.normal),
        dot(in.normal, surface_reference) >= 0.0);
    let displaced_geometry_normal = select(
        fallback_normal,
        oriented_derivative,
        derivative_length > 0.000001);
    let overview_normal_weight = smoothstep(120.0, 480.0, dist);
    let radial_normal_weight = select(max(storm_surface_cleanup, overview_normal_weight), 0.0, breaker_surface);
    let geometry_normal = normalize(mix(displaced_geometry_normal, radial, radial_normal_weight));
    let spectral_enabled = f32(u.use_texture * u.use_normal * u.use_roughness_ao);
    let spectral_uv = spectral_coordinates(in.spectral_position, primary, secondary);
    let resolved_0 = cascade_pixel_resolved(spectral_uv, 7.88, 256.0) *
        cascade_distance_resolved(7.88, dist);
    let resolved_1 = cascade_pixel_resolved(spectral_uv, 30.76, 128.0) *
        cascade_distance_resolved(30.76, dist);
    let resolved_2 = cascade_pixel_resolved(spectral_uv, 115.88, 128.0) *
        cascade_distance_resolved(115.88, dist);
    let spectral_0 = spectral_sample(mesh_texture, in.spectral_position, primary, secondary, 7.88, resolved_0);
    let spectral_1 = spectral_sample(mesh_normal_texture, in.spectral_position, primary, secondary, 30.76, resolved_1);
    let spectral_2 = spectral_sample(mesh_roughness_ao_texture, in.spectral_position, primary, secondary, 115.88, resolved_2);
    let params_7_w = u32(max(u.custom_params_7.w, 0.0));
    let proof_view = min(params_7_w >> 3u, 6u);
    if proof_view == 1u {
        let checker = f32((u32(abs(in.position.x) / 24.0) + u32(abs(in.position.y) / 24.0)) & 1u);
        return vec4<f32>(mix(vec3<f32>(1.0, 0.0, 0.8), vec3<f32>(0.0, 1.0, 1.0), checker), 1.0);
    }
    if proof_view >= 2u && proof_view <= 4u {
        var sample = spectral_0;
        if proof_view == 3u {
            sample = spectral_1;
        } else if proof_view == 4u {
            sample = spectral_2;
        }
        let height = clamp(dot(sample.displacement, radial) * 0.5 + 0.5, 0.0, 1.0);
        return vec4<f32>(height, 0.15, 1.0 - height, 1.0);
    }
    if proof_view == 5u {
        let foam = max(spectral_0.foam, max(spectral_1.foam, spectral_2.foam));
        return vec4<f32>(vec3<f32>(clamp(foam, 0.0, 1.0)), 1.0);
    }
    if proof_view == 6u {
        let spectral_height = abs(dot(spectral_0.displacement + spectral_1.displacement + spectral_2.displacement, radial));
        return vec4<f32>(clamp(in.wave_data.x, 0.0, 1.0), clamp(spectral_height, 0.0, 1.0), 1.0, 1.0);
    }
    let local_position = vec2<f32>(
        dot(in.world_position, primary),
        dot(in.world_position, secondary));
    if edge <= 0.001 { discard; }
    let normal = select(geometry_normal, -geometry_normal, breaker_surface && dot(geometry_normal, view) < 0.0);
    let halfway_sum = view + light;
    let halfway = halfway_sum / max(length(halfway_sum), 0.001);
    let ndv = max(dot(normal, view), 0.0);
    let geometry_ndv = max(dot(geometry_normal, view), 0.0);
    let filtered_view_cosine = clamp(mix(geometry_ndv, ndv, 0.28), 0.0, 1.0);
    let ndl = max(dot(normal, light), 0.0);
    let geometry_ndl = max(dot(geometry_normal, light), 0.0);
    let ndh = max(dot(normal, halfway), 0.0);
    let vdh = max(dot(view, halfway), 0.0);
    let f0 = vec3<f32>(0.02037);
    let view_fresnel_rgb = fresnel_schlick(filtered_view_cosine, f0);
    let specular_fresnel_rgb = fresnel_schlick(vdh, f0);
    let view_fresnel = max(
        view_fresnel_rgb.x,
        max(view_fresnel_rgb.y, view_fresnel_rgb.z));
    let stable_phase = dot(in.world_position - radial * 1080.0, primary) * 0.12;
    let mid = vec3<f32>(0.09, 0.32, 0.35);
    let refl = reflect(-view, normal);
    // Detail the cascades can no longer resolve becomes broad roughness
    // rather than per-pixel slope noise: an analytic mean-square-slope
    // estimate weighted by each cascade's energy share and how faded it is.
    let mean_square_slope = clamp(0.003 + 0.025 * u.custom_params.x, 0.0, 0.15);
    let spectral_unresolved = spectral_enabled * mean_square_slope *
        ((1.0 - resolved_0) * 0.55 + (1.0 - resolved_1) * 0.35 + (1.0 - resolved_2) * 0.10);
    let normal_dx = dpdx(normal);
    let normal_dy = dpdy(normal);
    let normal_variance = clamp(
        max(dot(normal_dx, normal_dx), dot(normal_dy, normal_dy)),
        0.0,
        0.35);
    let roughness = clamp(
        sqrt(u.custom_params_2.y * u.custom_params_2.y +
            spectral_unresolved * 0.35 + normal_variance * 0.32 + storm * storm * 0.025),
        0.055,
        0.78);
    let sky = water_environment_reflection(
        in.world_position,
        refl,
        radial,
        light,
        roughness);
    let distribution = ggx_distribution(ndh, roughness);
    let visibility = smith_visibility(ndv, ndl, roughness);
    let specular = specular_fresnel_rgb * distribution * visibility /
        max(4.0 * ndv * ndl, 0.001);
    let spec = min(max(specular.x, max(specular.y, specular.z)) * ndl, 0.45);
    let foam_band = smoothstep(0.78, 0.96, in.shallow);
    let macro_slope = 1.0 - clamp(dot(geometry_normal, radial), 0.0, 1.0);
    let crest_height = smoothstep(0.18, 0.62, in.wave_data.x);
    let crest_compression = smoothstep(0.055, 0.18, in.wave_data.y);
    let crest_slope = smoothstep(0.008, 0.075, macro_slope);
    let crest = crest_height * crest_compression * crest_slope *
        (0.45 + 0.55 * u.custom_params_3.w) * storm_surface_detail;
    let shore_break = foam_band * smoothstep(0.08, 0.45, in.coverage);
    let foam = (shore_break * u.custom_params_3.y +
        crest * u.custom_params_3.x) *
        edge * u.custom_params_2.w * (1.0 - smoothstep(260.0, 560.0, eye_altitude));
    let spectral_foam = max(spectral_0.foam, max(spectral_1.foam, spectral_2.foam));
    let close_spectral_foam = smoothstep(320.0, 900.0, eye_altitude);
    let spectral_crest = smoothstep(0.08, 0.35, spectral_foam) *
        smoothstep(0.04, 0.45, in.coverage) * u.custom_params_3.x *
        spectral_enabled * close_spectral_foam * storm_surface_detail;
    let foam_amount = clamp(
        1.0 - (1.0 - clamp(foam, 0.0, 1.0)) *
            (1.0 - clamp(spectral_crest, 0.0, 1.0)),
        0.0,
        1.0);
    let bubble_support = max(shore_break, crest) * edge *
        (1.0 - smoothstep(80.0, 220.0, dist));
    let bubbles = bubble_rings(
        local_position,
        t,
        bubble_support,
        u.custom_params_2.x * storm_surface_detail);
    let displaced_column_depth = select(
        0.0,
        max(in.depth + in.radial_displacement, 0.0),
        in.depth > 0.0);
    let vertical_depth = clamp(displaced_column_depth / 6.0, 0.0, 1.0);
    let depth_factor = clamp(max(vertical_depth, 1.0 - in.shallow), 0.0, 1.0);
    let shallow_palette = mix(u.color_high.rgb, mid, smoothstep(0.0, 0.58, depth_factor));
    let depth_palette = mix(shallow_palette, u.color.rgb, smoothstep(0.42, 1.0, depth_factor));
    let volume_illumination = planet_light_level(geometry_normal, radial, light);
    let volume = water_volume_integrate(
        displaced_column_depth,
        geometry_ndv,
        volume_illumination,
        in.shallow);
    let volume_physical = (depth_palette * volume.transmittance + volume.inscatter) * volume.darkening;
    let unresolved_energy = clamp(
        spectral_unresolved / max(mean_square_slope, 0.001),
        0.0,
        1.0);
    let depth_contrast_floor = mix(0.34, 0.52, unresolved_energy);
    let volume_color = mix(volume_physical, depth_palette, depth_contrast_floor);
    let scene_refraction = scene_water_sample(
        in.position,
        in.world_position,
        geometry_normal,
        normal,
        filtered_view_cosine,
        dist,
        edge);
    let transmitted_scene = (scene_refraction.rgb * volume.transmittance + volume.inscatter) *
        volume.darkening;
    let refraction_weight = scene_refraction.a * mix(0.46, 0.66, 1.0 - depth_factor);
    let ambient_water = planet_ambient_light(geometry_normal, radial, light);
    let direct_water = planet_direct_light(geometry_normal, radial, light);
    let environment_fill = depth_palette * ambient_water *
        roughness * 0.12 * (1.0 - view_fresnel) * mix(0.82, 0.48, depth_factor);
    let generated_transmission = volume_color * (ambient_water + direct_water) + environment_fill;
    let multiple_scatter = roughness * roughness * (1.0 - view_fresnel);
    let reflection_weight = clamp(
        (view_fresnel + multiple_scatter * 0.08) * 0.88 * u.custom_params_2.z,
        0.0,
        1.0);
    var color = mix(generated_transmission, sky, reflection_weight) + vec3<f32>(spec);
    let depth_chroma_support = (1.0 - view_fresnel) * (1.0 - foam_amount);
    let depth_chroma_weight = (0.16 + unresolved_energy * 0.12) * depth_chroma_support;
    color = mix(color, depth_palette * ambient_water, depth_chroma_weight);
    color = mix(color, vec3<f32>(0.93, 0.96, 0.97), foam_amount * 0.82);
    color = mix(color, vec3<f32>(0.88, 0.96, 1.0), bubbles * 0.72);
    let orbital_ring = smoothstep(600.0, 2400.0, eye_altitude) * clamp(in.wave_data.z, 0.0, 1.0) *
        0.12 * storm_surface_detail;
    color = mix(color, vec3<f32>(0.90, 0.95, 1.0), orbital_ring);
    let generated_lit = atmosphere_apply(color, in.world_position, dist, view, light);
    let scene_transmission_weight = refraction_weight * (1.0 - reflection_weight) *
        (1.0 - max(foam_amount, bubbles));
    let lit = mix(generated_lit, transmitted_scene, scene_transmission_weight);
    let alpha = clamp(edge, 0.0, 1.0);
    return vec4<f32>(lit * alpha, alpha);
}
`

// Flora: trees, boulders, and scree. Vertex scalar 1 marks foliage, which
// sways in the wind by world-position phase; trunks and rocks (scalar 0)
// stay put. Fragment shading mirrors the terrain's hemisphere ambient, warm
// sun, and fog so scattered objects sit in the same light.
FLORA_SHADER ::
	SHADER_PREAMBLE +
	`
struct VertexOut {
    @builtin(position) position: vec4<f32>,
    @location(0) world_position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
    @location(3) flora_kind: f32,
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
    var world = (model * vec4<f32>(position, 1.0)).xyz;
    // Wind: foliage leans with a slow gust plus a faster flutter, amplitude
    // growing with height above the instance base so trunk joints stay
    // anchored. Phase varies by world position so trees never sway in sync.
    let t = floor(u.light_params.w * 10.0) * 0.1;
    let phase = world.x * 0.35 + world.y * 0.28;
    let gust = sin(t * 1.1 + phase) * 0.7 + sin(t * 2.7 + phase * 1.9) * 0.3;
    let grass = step(1.25, scalar);
    let anchor = smoothstep(0.08, 0.65, position.z);
    let sway = gust * mix(0.05 * max(position.z, 0.0), 0.12 * anchor, grass) * min(scalar, 1.0);
    world.x += sway;
    world.y += sway * 0.6;
    out.world_position = world;
    out.position = u.view_projection * vec4<f32>(world, 1.0);
    out.normal = normalize((model * vec4<f32>(normal, 0.0)).xyz);
    out.uv = uv;
    out.flora_kind = scalar;
    return out;
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4<f32> {
    if cutaway_clipped(in.world_position) { discard; }
    let normal = normalize(in.normal);
    let light = normalize(u.light_direction.xyz);
    let to_camera = u.camera_position.xyz - in.world_position;
    let dist = length(to_camera);
    let view = to_camera / max(dist, 0.001);
    let grass = step(1.25, in.flora_kind);
    let fade = 1.0 - smoothstep(90.0, 150.0, dist);
    let dither = fract(sin(dot(floor(in.position.xy), vec2<f32>(12.9898, 78.233))) * 43758.5453);
    if grass > 0.5 && dither > fade { discard; }
    let albedo = textureSample(mesh_texture, mesh_sampler, in.uv).rgb * u.color.rgb;
    // Same lighting family as the terrain so flora sits in the scene: cool
    // sky hemisphere above, warm bounce below, warm sun diffuse.
    let radial = normalize(in.world_position);
    var color = albedo * (
        planet_ambient_light(normal, radial, light) + planet_direct_light(normal, radial, light));
    color = atmosphere_apply(color, in.world_position, dist, view, light);
    return vec4<f32>(color, 1.0);
}
`

PLANET_SECTION_SHADER ::
	SHADER_PREAMBLE +
	`
struct VertexOut {
    @builtin(position) position: vec4<f32>,
    @location(0) scalar: f32,
    @location(1) data: vec2<f32>,
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
    let world = u.model * instances.transforms[instance_index] * vec4<f32>(position, 1.0);
    out.position = u.view_projection * world;
    out.position.z -= 0.0004 * out.position.w;
    out.scalar = scalar;
    out.data = uv;
    return out;
}
@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4<f32> {
    var color = u.color.rgb;
    if in.scalar < 0.5 { color = u.custom_params.rgb; }
    else if in.scalar < 1.5 { color = u.custom_params_2.rgb; }
    else if in.scalar < 2.5 { color = u.custom_params_3.rgb; }
    else if in.scalar < 3.5 { color = u.custom_params_4.rgb; }
    else { color = u.custom_params_7.rgb; }
    let data_light = 0.82 + 0.18 * clamp(in.data.x, 0.0, 1.0);
    let edge = smoothstep(0.0, 0.045, min(in.data.y, 1.0 - in.data.y));
    color = mix(u.custom_params_8.rgb, color * data_light, edge);
    return vec4<f32>(color, 1.0);
}
`

// Terrain: the baked albedo acts as a low-frequency colour and biome guide
// (terraform scars, beaches, snow line stay authoritative) while per-pixel
// procedural grass/rock/sand/snow materials supply the close-range detail
// the 1024px bake cannot hold. Detail normals, hemisphere ambient, and a
// cavity AO term replace the flat lighting; distance fades keep mid-zoom
// frames shimmer-free and the fog matches the previous tuning.
TERRAIN_SHADER ::
	SHADER_PREAMBLE +
	`
struct VertexOut {
    @builtin(position) position: vec4<f32>,
    @location(0) world_position: vec3<f32>,
    @location(1) normal: vec3<f32>,
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
    let world = (model * vec4<f32>(position, 1.0)).xyz;
    out.world_position = world;
    out.position = u.view_projection * vec4<f32>(world, 1.0);
    out.normal = normalize((model * vec4<f32>(normal, 0.0)).xyz);
    out.uv = uv;
    return out;
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4<f32> {
    if cutaway_clipped(in.world_position) { discard; }
    let normal_geo = normalize(in.normal);
    let light = normalize(u.light_direction.xyz);
    let to_camera = u.camera_position.xyz - in.world_position;
    let dist = length(to_camera);
    let view = to_camera / max(dist, 0.001);
    let radial = normalize(in.world_position);
    let altitude = length(in.world_position) - 1080.0;
    let upness = dot(normal_geo, radial);
    let p_xy = in.world_position.xy;
    let p_xz = in.world_position.xz;
    let p_yz = in.world_position.yz;
    let material_size = vec2<f32>(textureDimensions(mesh_texture));
    let material_uv = (clamp(in.uv, vec2<f32>(0.0), vec2<f32>(1.0)) * (material_size - vec2<f32>(2.0)) + vec2<f32>(1.0)) / material_size;
    let baked_xy = textureSample(mesh_texture, mesh_sampler, material_uv).rgb * u.color.rgb;
    let weight_square = abs(normal_geo) * abs(normal_geo);
    let weight_power = weight_square * weight_square;
    let weights = weight_power / max(weight_power.x + weight_power.y + weight_power.z, 0.001);
    let top = smoothstep(0.25, 0.75, upness) * max(weights.x, max(weights.y, weights.z));
    let underside = smoothstep(-0.15, -0.8, upness);
    let cliff_tint = mix(vec3<f32>(0.38, 0.34, 0.31), vec3<f32>(0.58, 0.52, 0.45), max(weights.x, max(weights.y, weights.z)));
    let geological = mix(cliff_tint, baked_xy, top);
    let baked = mix(geological, vec3<f32>(0.30, 0.27, 0.25), underside);
    let slope = 1.0 - clamp(upness, 0.0, 1.0);
    let raw_controls = clamp(textureSample(mesh_normal_texture, mesh_normal_sampler, material_uv).rgb, vec3<f32>(0.0), vec3<f32>(1.0));
    let controls = raw_controls / max(dot(raw_controls, vec3<f32>(1.0)), 1.0);
    let veg = controls.r;
    let roughness_ao_mask = textureSample(mesh_roughness_ao_texture, mesh_roughness_ao_sampler, material_uv).rgb;
    let snow = roughness_ao_mask.b;
    let edge = fbm3(p_yz * 0.22) * weights.x +
        fbm3(p_xz * 0.22) * weights.y + fbm3(p_xy * 0.22) * weights.z - 0.47;
    var w_rock = smoothstep(0.20, 0.68, slope + edge * 0.24) * (1.0 - snow * 0.35);
    var w_snow = snow * (1.0 - w_rock * 0.45);
    var w_grass = veg * (1.0 - w_rock - w_snow);
    let substrate = max(1.0 - w_rock - w_snow, 0.0);
    var w_sand = controls.b * substrate;
    let w_organic = controls.g * substrate;
    let w_soil = max(1.0 - dot(controls, vec3<f32>(1.0)), 0.0) * substrate;
    let w_sum = max(w_rock + w_snow + w_grass + w_sand + w_organic + w_soil, 0.001);
    let camera_altitude = max(length(u.camera_position.xyz) - 1080.0, 0.0);
    let overview_detail = 1.0 - smoothstep(240.0, 520.0, camera_altitude);
    let fade_mid = (1.0 - smoothstep(120.0, 320.0, dist)) * overview_detail;
    let fade_near = (1.0 - smoothstep(30.0, 110.0, dist)) * overview_detail;
    let material_texture_size = vec2<f32>(textureDimensions(mesh_normal_texture, 0));
    let material_footprint = max(
        length(dpdx(in.uv) * material_texture_size),
        length(dpdy(in.uv) * material_texture_size));
    let material_resolved = 1.0 - smoothstep(0.75, 2.0, material_footprint);
    let sunlight_detail = mix(0.20, 1.0, planet_solar_factor(radial, light));
    let mapped_detail = fade_mid * material_resolved;
    let f_lo = fbm3(p_yz * 0.72) * weights.x +
        fbm3(p_xz * 0.72) * weights.y + fbm3(p_xy * 0.72) * weights.z;
    let f_hi = fbm4(p_yz * 8.0) * weights.x +
        fbm4(p_xz * 8.0) * weights.y + fbm4(p_xy * 8.0) * weights.z;
    let d_lo = (f_lo - 0.47) * fade_mid;
    let d_hi = (f_hi - 0.47) * fade_near;
    let patch_offset = vec2<f32>(31.7, 17.3);
    let patch_hue = fbm3(p_yz * 0.8 + patch_offset) * weights.x +
        fbm3(p_xz * 0.8 + patch_offset) * weights.y +
        fbm3(p_xy * 0.8 + patch_offset) * weights.z;
    var grass_col = mix(vec3<f32>(0.26, 0.42, 0.17), vec3<f32>(0.44, 0.51, 0.22), patch_hue);
    grass_col *= 1.0 + d_lo * 0.35 + d_hi * 0.45;
    let warp = vec2<f32>(fbm3(p_xy * 0.055 + vec2<f32>(9.1, 4.7)),
        fbm3(p_xy * 0.055 + vec2<f32>(2.3, 13.8))) - vec2<f32>(0.47);
    let warped_z = altitude * 0.16 + warp.x * 2.8 + f_lo * 1.7;
    let strata = smoothstep(0.18, 0.82,
        fbm3(vec2<f32>(warped_z, p_xy.x * 0.035 + warp.y)));
    let fracture_signal = abs(
        fbm3(p_yz * 0.34 + vec2<f32>(17.0, 3.0)) * weights.x +
        fbm3(p_xz * 0.34 + vec2<f32>(17.0, 3.0)) * weights.y +
        fbm3(p_xy * 0.34 + vec2<f32>(17.0, 3.0)) * weights.z - 0.50);
    let fractures = 1.0 - smoothstep(0.025, 0.10, fracture_signal);
    // Close-up cliffs read as bedded rock: strata and fracture contrast
    // widen where rock dominates, keeping the same distance fades.
    let rocky = smoothstep(0.5, 0.8, w_rock);
    let strata_wide = mix(strata, smoothstep(0.30, 0.70, strata), rocky * 0.2);
    var rock_col = mix(vec3<f32>(0.33, 0.32, 0.30), vec3<f32>(0.57, 0.53, 0.47), strata_wide);
    rock_col *= 1.0 + d_lo * 0.52 + d_hi * 0.32 - fractures * (0.18 + rocky * 0.036) * fade_mid;
    var sand_col = vec3<f32>(0.71, 0.63, 0.46) * (1.0 + d_lo * 0.18 + d_hi * 0.20);
    var snow_col = vec3<f32>(0.92, 0.94, 0.97) * (1.0 + d_hi * 0.10);
    let soil_col = vec3<f32>(0.42, 0.32, 0.23) * (1.0 + d_lo * 0.4 + d_hi * 0.3);
    let organic_col = vec3<f32>(0.23, 0.19, 0.12) * (1.0 + d_lo * 0.3 + d_hi * 0.5);
    let material = (grass_col * w_grass + rock_col * w_rock + sand_col * w_sand + snow_col * w_snow + soil_col * w_soil + organic_col * w_organic) / w_sum;
    let material_fade = (1.0 - smoothstep(150.0, 400.0, dist)) * overview_detail;
    let detailed = clamp(material * baked * 2.35, vec3<f32>(0.0), vec3<f32>(1.0));
    var albedo = mix(baked, detailed, 0.30 + 0.55 * material_fade);
    let encoded_normal = vec3<f32>(0.0, 0.0, 1.0);
    let ref_axis = select(vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(1.0, 0.0, 0.0), abs(normal_geo.y) > 0.9);
    let world_tangent = normalize(cross(normal_geo, ref_axis));
    let world_bitangent = normalize(cross(normal_geo, world_tangent));
    let mapped_top = normalize(mat3x3<f32>(world_tangent, world_bitangent, normal_geo) * encoded_normal);
    let mapped_normal = normalize(mix(normal_geo, mapped_top, top * mapped_detail * sunlight_detail));
    let rockiness = w_rock / w_sum;
    let detail_strength = mix(0.025, 0.12, rockiness) * (1.0 - smoothstep(45.0, 140.0, dist)) * overview_detail;
    let bump_xy = noise_normal(p_xy, 6.0, detail_strength);
    let bump_xz = noise_normal(p_xz, 6.0, detail_strength);
    let bump_yz = noise_normal(p_yz, 6.0, detail_strength);
    let world_bump = vec3<f32>(0.0, bump_yz.x, bump_yz.y) * weights.x +
        vec3<f32>(bump_xz.x, 0.0, bump_xz.y) * weights.y +
        vec3<f32>(bump_xy.x, bump_xy.y, 0.0) * weights.z;
    let normal = normalize(mapped_normal + world_bump);
    let roughness = mix(0.86, clamp(roughness_ao_mask.r, 0.08, 1.0), top * mapped_detail);
    let ao = mix(1.0, roughness_ao_mask.g, top * mapped_detail * sunlight_detail);
    let ndl = max(dot(normal, light), 0.0);
    let ambient_light = planet_ambient_light(normal, radial, light) * ao;
    let direct_light = planet_direct_light(normal, radial, light);
    var color = albedo * (ambient_light + direct_light);
    let halfway = normalize(view + light);
    let ndv = max(dot(normal, view), 0.001);
    let ndh = max(dot(normal, halfway), 0.0);
    let vdh = max(dot(view, halfway), 0.0);
    let alpha = roughness * roughness;
    let alpha2 = alpha * alpha;
    let denominator = ndh * ndh * (alpha2 - 1.0) + 1.0;
    let distribution = alpha2 / max(3.14159265 * denominator * denominator, 0.0001);
    let k = (roughness + 1.0) * (roughness + 1.0) / 8.0;
    let visibility = ndv / (ndv * (1.0 - k) + k) * ndl / (ndl * (1.0 - k) + k);
    let fresnel = vec3<f32>(0.04) + vec3<f32>(0.96) * pow(1.0 - vdh, 5.0);
    color += distribution * visibility * fresnel / max(4.0 * ndv * max(ndl, 0.001), 0.001) * ndl;
    color = atmosphere_apply(color, in.world_position, dist, view, light);
    return vec4<f32>(color, 1.0);
}
`
