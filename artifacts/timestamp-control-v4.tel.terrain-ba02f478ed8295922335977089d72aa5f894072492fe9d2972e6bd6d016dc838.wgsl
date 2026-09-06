
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
