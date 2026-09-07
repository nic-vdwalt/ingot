package main

import "core:math"
import rl "ingot:gfx"

Atmosphere_Quality :: enum u8 {
	Low,
	High,
	Ultra,
}

Atmosphere_Preset :: enum u8 {
	Clear_Dusk,
	Dark_Overcast,
	Heavy_Fog,
	Orbital_Day,
}

Atmosphere :: struct {
	quality:              Atmosphere_Quality,
	preset:               Atmosphere_Preset,
	zenith_color:         [3]f32,
	horizon_color:        [3]f32,
	ground_color:         [3]f32,
	fog_color:            [3]f32,
	sun_color:            [3]f32,
	sun_direction:        [3]f32,
	sun_intensity:        f32,
	ambient_intensity:    f32,
	exposure:             f32,
	vibrance:             f32,
	contrast:             f32,
	bloom_strength:       f32,
	bloom_threshold:      f32,
	overview_weight:      f32,
	fog_density:          f32,
	fog_height_falloff:   f32,
	fog_base_height:      f32,
	cloud_coverage:       f32,
	cloud_speed:          f32,
	cloud_wind:           [2]f32,
	storm_intensity:      f32,
	sky_mesh:             rl.Gpu_Mesh,
	sky_shader:           rl.Gpu_3D_Shader,
	object_shader:        rl.Gpu_3D_Shader,
	post_shader:          rl.Shader,
	post_exposure:        i32,
	post_quality:         i32,
	post_time:            i32,
	post_vibrance:        i32,
	post_contrast:        i32,
	post_bloom_strength:  i32,
	post_bloom_threshold: i32,
	post_overview:        i32,
	post_texel_size:      i32,
	sky_ready:            bool,
	object_ready:         bool,
	post_ready:           bool,
	ready:                bool,
}

atmosphere_default_quality :: proc() -> Atmosphere_Quality {
	when ODIN_OS == .JS do return .Low
	return .High
}

atmosphere_preset :: proc(preset: Atmosphere_Preset, quality: Atmosphere_Quality) -> Atmosphere {
	value := Atmosphere {
		quality            = quality,
		preset             = preset,
		zenith_color       = {0.025, 0.045, 0.075},
		horizon_color      = {0.22, 0.29, 0.36},
		ground_color       = {0.12, 0.105, 0.095},
		fog_color          = {0.26, 0.32, 0.39},
		sun_color          = {0.92, 0.72, 0.52},
		sun_direction      = {-0.42, 0.54, 0.73},
		sun_intensity      = 0.62,
		ambient_intensity  = 0.42,
		exposure           = 1.08,
		vibrance           = 1.10,
		contrast           = 1.04,
		bloom_strength     = 0.08,
		bloom_threshold    = 0.82,
		fog_density        = 0.0085,
		fog_height_falloff = 0.055,
		fog_base_height    = 5,
		cloud_coverage     = 0.76,
		cloud_speed        = 0.32,
	}
	switch preset {
	case .Clear_Dusk:
		value.zenith_color = {0.055, 0.12, 0.24}
		value.horizon_color = {0.54, 0.38, 0.28}
		value.fog_color = {0.38, 0.31, 0.30}
		value.sun_color = {1.0, 0.82, 0.62}
		value.sun_intensity = 0.92
		value.ambient_intensity = 0.34
		value.exposure = 1.12
		value.vibrance = 1.14
		value.contrast = 1.05
		value.bloom_strength = 0.10
		value.fog_density = 0.0045
		value.cloud_coverage = 0.28
	case .Dark_Overcast:
	case .Heavy_Fog:
		value.zenith_color = {0.018, 0.03, 0.045}
		value.horizon_color = {0.16, 0.20, 0.23}
		value.fog_color = {0.22, 0.27, 0.31}
		value.sun_intensity = 0.38
		value.ambient_intensity = 0.34
		value.exposure = 1.0
		value.vibrance = 1.04
		value.contrast = 1.01
		value.bloom_strength = 0.04
		value.fog_density = 0.021
		value.fog_height_falloff = 0.085
		value.cloud_coverage = 0.92
	case .Orbital_Day:
		// Planet seen from space: black sky, a strong white-warm sun, and a
		// thin blue haze that only exists near the surface.
		value.zenith_color = {0, 0, 0}
		value.horizon_color = {0.02, 0.03, 0.05}
		value.fog_color = {0.30, 0.42, 0.58}
		value.sun_color = {1.0, 0.93, 0.82}
		value.sun_direction = _atmosphere_normalize({0.45, 0.30, 0.84})
		value.sun_intensity = 1.0
		value.ambient_intensity = 0.34
		value.exposure = 1.08
		value.vibrance = 1.18
		value.contrast = 1.08
		value.bloom_strength = 0.12
		value.bloom_threshold = 0.86
		value.fog_density = 0.0085
		value.cloud_coverage = 0
	}
	return value
}

@(private = "file")
_atmosphere_normalize :: proc(value: [3]f32) -> [3]f32 {
	length := math.sqrt(value.x * value.x + value.y * value.y + value.z * value.z)
	assert(length > 0, "_atmosphere_normalize: zero vector")
	return value / length
}

// atmosphere_apply_preset swaps the lighting/fog values for another preset
// while preserving the GPU resources and readiness flags, so the debug panel
// can switch presets on a live atmosphere without re-creating shaders.
atmosphere_apply_preset :: proc(value: ^Atmosphere, preset: Atmosphere_Preset) {
	assert(value != nil, "atmosphere_apply_preset: nil atmosphere")
	fresh := atmosphere_preset(preset, value.quality)
	fresh.sky_mesh = value.sky_mesh
	fresh.sky_shader = value.sky_shader
	fresh.object_shader = value.object_shader
	fresh.post_shader = value.post_shader
	fresh.post_exposure = value.post_exposure
	fresh.post_quality = value.post_quality
	fresh.post_time = value.post_time
	fresh.post_vibrance = value.post_vibrance
	fresh.post_contrast = value.post_contrast
	fresh.post_bloom_strength = value.post_bloom_strength
	fresh.post_bloom_threshold = value.post_bloom_threshold
	fresh.post_overview = value.post_overview
	fresh.post_texel_size = value.post_texel_size
	fresh.sky_ready = value.sky_ready
	fresh.object_ready = value.object_ready
	fresh.post_ready = value.post_ready
	fresh.ready = value.ready
	value^ = fresh
}

atmosphere_light :: proc(value: ^Atmosphere) -> rl.Gpu_3D_Light {
	assert(value != nil, "atmosphere_light: nil atmosphere")
	return {
		direction = {value.sun_direction.x, value.sun_direction.y, value.sun_direction.z},
		ambient = value.ambient_intensity,
		diffuse = value.sun_intensity,
	}
}

atmosphere_fog_transmittance :: proc(value: ^Atmosphere, distance, height: f32) -> f32 {
	assert(value != nil, "atmosphere_fog_transmittance: nil atmosphere")
	fog_distance := max(distance, 0)
	height_density := math.exp(-max(height - value.fog_base_height, 0) * value.fog_height_falloff)
	density_scale := f32(0.32) + f32(0.68) * height_density
	optical_depth: f32 = value.fog_density * fog_distance * density_scale
	return clamp(math.exp(-optical_depth), f32(0), f32(1))
}

atmosphere_sky_color :: proc(value: ^Atmosphere, direction: [3]f32) -> [3]f32 {
	assert(value != nil, "atmosphere_sky_color: nil atmosphere")
	length := math.sqrt(
		direction.x * direction.x + direction.y * direction.y + direction.z * direction.z,
	)
	if length <= 0 do return value.horizon_color
	ray := direction / length
	horizon := math.pow(clamp(ray.z, 0, 1), f32(0.38))
	color := value.horizon_color * (1 - horizon) + value.zenith_color * horizon
	sun_dot := clamp(
		ray.x * value.sun_direction.x +
		ray.y * value.sun_direction.y +
		ray.z * value.sun_direction.z,
		0,
		1,
	)
	glow := math.pow(sun_dot, f32(48)) * value.sun_intensity * (1 - value.cloud_coverage * 0.72)
	return color + value.sun_color * glow
}

atmosphere_expose :: proc(color: [3]f32, exposure: f32) -> [3]f32 {
	exposed := color * max(exposure, 0)
	return exposed / (exposed + [3]f32{1, 1, 1})
}

atmosphere_post_scale :: proc(quality: Atmosphere_Quality) -> f32 {
	switch quality {
	case .Low:
		return 0
	case .High:
		return 0.5
	case .Ultra:
		return 0.5
	}
	return 0
}

atmosphere_shadow_size :: proc(quality: Atmosphere_Quality) -> i32 {
	if quality == .Ultra do return 2048
	return 0
}

atmosphere_shadow_transform :: proc(
	value: ^Atmosphere,
	position: [3]f32,
	east, north, up: [3]f32,
	width, height: f32,
) -> rl.Matrix {
	assert(value != nil, "atmosphere_shadow_transform: nil atmosphere")
	stretch := f32(1.45) if value.quality == .Ultra else f32(1)
	offset := f32(0.24) if value.quality == .Ultra else f32(0.08)
	sun := value.sun_direction
	sun_east := sun.x * east.x + sun.y * east.y + sun.z * east.z
	sun_north := sun.x * north.x + sun.y * north.y + sun.z * north.z
	center := position - (east * sun_east + north * sun_north) * offset + up * 0.025
	return(
		rl.MatrixTranslate(center.x, center.y, center.z) *
		_frame_matrix(east, north, up) *
		rl.MatrixScale(width * stretch, height, 0.05) \
	)
}

atmosphere_init :: proc(value: ^Atmosphere) -> bool {
	assert(value != nil, "atmosphere_init: nil atmosphere")
	if value.ready && value.post_ready do return true
	if value.sky_mesh.id == 0 do value.sky_mesh, _ = rl.create_sphere_mesh(420, 20, 40)
	if value.sky_shader.id == 0 do value.sky_shader, value.sky_ready = rl.create_gpu_3d_shader(SKY_SHADER)
	if value.object_shader.id == 0 do value.object_shader, value.object_ready = rl.create_gpu_3d_shader(ATMOSPHERE_OBJECT_SHADER)
	if value.post_shader.id == 0 do value.post_shader = rl.LoadShaderFromMemory(nil, POST_PROCESS_SHADER)
	value.sky_ready = value.sky_mesh.id != 0 && value.sky_shader.id != 0
	value.object_ready = value.object_shader.id != 0
	value.post_ready = value.post_shader.id != 0
	if value.post_ready {
		value.post_exposure = rl.GetShaderLocation(value.post_shader, "exposure")
		value.post_quality = rl.GetShaderLocation(value.post_shader, "quality")
		value.post_time = rl.GetShaderLocation(value.post_shader, "time")
		value.post_vibrance = rl.GetShaderLocation(value.post_shader, "vibrance")
		value.post_contrast = rl.GetShaderLocation(value.post_shader, "contrast")
		value.post_bloom_strength = rl.GetShaderLocation(value.post_shader, "bloom_strength")
		value.post_bloom_threshold = rl.GetShaderLocation(value.post_shader, "bloom_threshold")
		value.post_overview = rl.GetShaderLocation(value.post_shader, "overview")
		value.post_texel_size = rl.GetShaderLocation(value.post_shader, "texel_size")
	}
	value.ready = value.sky_ready && value.object_ready
	return value.ready
}

atmosphere_sky_material :: proc(value: ^Atmosphere) -> rl.Gpu_Material {
	assert(value != nil, "atmosphere sky material: nil atmosphere")
	wind := [2]f32{clamp(value.cloud_wind.x, -200, 200), clamp(value.cloud_wind.y, -200, 200)}
	return {
		color           = atmosphere_color(value.horizon_color, 255),
		color_high      = atmosphere_color(value.zenith_color, 255),
		style           = .Opaque,
		custom_params   = {
			clamp(value.cloud_coverage, 0, 1),
			clamp(value.cloud_speed, 0, 2),
			value.fog_density,
			value.fog_height_falloff,
		},
		custom_params_2 = {
			value.fog_color.x,
			value.fog_color.y,
			value.fog_color.z,
			value.fog_base_height,
		},
		custom_params_3 = {wind.x, wind.y, clamp(value.storm_intensity, 0, 1), 0},
		shader          = value.sky_shader,
	}
}

atmosphere_draw_sky :: proc(value: ^Atmosphere, pass: ^rl.Gpu_3D_Pass, camera: rl.Camera3D) {
	assert(value != nil, "atmosphere_draw_sky: nil atmosphere")
	assert(pass != nil, "atmosphere_draw_sky: nil pass")
	if !value.sky_ready do return
	transform := rl.MatrixTranslate(camera.position.x, camera.position.y, camera.position.z)
	rl.draw_gpu_mesh(pass, value.sky_mesh, transform, atmosphere_sky_material(value))
}

atmosphere_begin_post :: proc(value: ^Atmosphere, time: f32, width, height: i32) -> bool {
	assert(value != nil, "atmosphere_begin_post: nil atmosphere")
	if !value.post_ready || width <= 0 || height <= 0 do return false
	exposure := value.exposure
	quality := f32(1) if value.quality != .Low else f32(0)
	shader_time := time
	vibrance := value.vibrance
	contrast := value.contrast
	bloom_strength := value.bloom_strength
	when ODIN_OS == .JS do bloom_strength = 0
	if value.quality == .Low do bloom_strength = 0
	bloom_threshold := value.bloom_threshold
	overview := clamp(value.overview_weight, 0, 1)
	texel_size := [2]f32{1 / f32(width), 1 / f32(height)}
	rl.SetShaderValue(value.post_shader, value.post_exposure, &exposure, .FLOAT)
	rl.SetShaderValue(value.post_shader, value.post_quality, &quality, .FLOAT)
	rl.SetShaderValue(value.post_shader, value.post_time, &shader_time, .FLOAT)
	rl.SetShaderValue(value.post_shader, value.post_vibrance, &vibrance, .FLOAT)
	rl.SetShaderValue(value.post_shader, value.post_contrast, &contrast, .FLOAT)
	rl.SetShaderValue(value.post_shader, value.post_bloom_strength, &bloom_strength, .FLOAT)
	rl.SetShaderValue(value.post_shader, value.post_bloom_threshold, &bloom_threshold, .FLOAT)
	rl.SetShaderValue(value.post_shader, value.post_overview, &overview, .FLOAT)
	rl.SetShaderValue(value.post_shader, value.post_texel_size, &texel_size, .VEC2)
	rl.BeginShaderMode(value.post_shader)
	return true
}

atmosphere_end_post :: proc(value: ^Atmosphere, active: bool) {
	assert(value != nil, "atmosphere_end_post: nil atmosphere")
	if active do rl.EndShaderMode()
}

atmosphere_color :: proc(color: [3]f32, alpha: u8) -> rl.Color {
	return {
		u8(clamp(color.x * 255, 0, 255)),
		u8(clamp(color.y * 255, 0, 255)),
		u8(clamp(color.z * 255, 0, 255)),
		alpha,
	}
}

atmosphere_deinit :: proc(value: ^Atmosphere) {
	assert(value != nil, "atmosphere_deinit: nil atmosphere")
	if value.sky_mesh.id != 0 do rl.destroy_gpu_mesh(&value.sky_mesh)
	rl.destroy_gpu_3d_shader(&value.sky_shader)
	rl.destroy_gpu_3d_shader(&value.object_shader)
	if value.post_shader.id != 0 do rl.UnloadShader(value.post_shader)
	value.sky_mesh = {}
	value.post_shader = {}
	value.sky_ready = false
	value.object_ready = false
	value.post_ready = false
	value.ready = false
}
