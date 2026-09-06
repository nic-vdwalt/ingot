package main

import "core:fmt"
import "core:math"
import "core:mem"
import rl "ingot:gfx"
import wg "vendor:wgpu"

OCEAN_SPECTRAL_CASCADE_COUNT :: 3
OCEAN_SPECTRAL_WORKGROUP_SIZE :: 8
OCEAN_SPECTRAL_UNIFORM_BYTES :: 64
OCEAN_SPECTRAL_UNIFORM_STRIDE :: 256
OCEAN_SPECTRAL_DISPATCHES_MAX :: 53
OCEAN_SPECTRAL_COMPUTE_BUFFER_MAX :: 128
OCEAN_SPECTRAL_RESOLUTION :: [OCEAN_SPECTRAL_CASCADE_COUNT]u32{256, 128, 128}
OCEAN_SPECTRAL_LENGTH_SCALE :: [OCEAN_SPECTRAL_CASCADE_COUNT]f32{197, 769, 2_897}
OCEAN_SPECTRAL_ENERGY_WEIGHT :: [OCEAN_SPECTRAL_CASCADE_COUNT]f32{0.55, 0.35, 0.10}
OCEAN_SPECTRAL_SWELL_ENERGY_WEIGHT :: [OCEAN_SPECTRAL_CASCADE_COUNT]f32{0.05, 0.25, 0.70}
OCEAN_SPECTRAL_WIND_CHOP_HEIGHT :: f32(0.35)
OCEAN_SPECTRAL_BINDINGS_MAX :: 6
OCEAN_SPECTRAL_JONSWAP_GAMMA :: f32(3.3)
OCEAN_SPECTRAL_TRANSITION_SECONDS :: f32(3)
OCEAN_SPECTRAL_UPDATE_INTERVAL :: f32(1.0 / 30.0)
OCEAN_SPECTRAL_MAX_DEFERRED :: f32(0.2)
#assert(OCEAN_SPECTRAL_RESOLUTION[0] % OCEAN_SPECTRAL_WORKGROUP_SIZE == 0)
#assert(OCEAN_SPECTRAL_DISPATCHES_MAX + 1 <= OCEAN_SPECTRAL_COMPUTE_BUFFER_MAX)

Ocean_Spectral_Stage :: enum u8 {
	Initialize,
	Evolve,
	Fft,
	Derive,
	Foam,
}

Ocean_Spectral_Pipeline :: struct {
	module:   rl.Gpu_Shader_Module,
	layout:   rl.Gpu_Bind_Group_Layout,
	pipeline: rl.Gpu_Compute_Pipeline,
}

Ocean_Spectral_Weather_Transition :: struct {
	source:     Ocean_Render_Spectrum,
	target:     Ocean_Render_Spectrum,
	queued:     Ocean_Render_Spectrum,
	progress:   f32,
	duration:   f32,
	active:     bool,
	has_queued: bool,
}

Ocean_Spectral_Runtime :: struct {
	uniform:                 rl.Gpu_Buffer,
	update_uniform:          rl.Gpu_Buffer,
	uniform_params:          [OCEAN_SPECTRAL_DISPATCHES_MAX][OCEAN_SPECTRAL_UNIFORM_STRIDE / size_of(
		u32,
	)]u32,
	update_groups:           [OCEAN_SPECTRAL_DISPATCHES_MAX]rl.Gpu_Bind_Group,
	foam_groups:             [OCEAN_SPECTRAL_CASCADE_COUNT]rl.Gpu_Bind_Group,
	update_group_count:      int,
	initialize:              Ocean_Spectral_Pipeline,
	evolve:                  Ocean_Spectral_Pipeline,
	fft:                     Ocean_Spectral_Pipeline,
	derive:                  Ocean_Spectral_Pipeline,
	foam:                    Ocean_Spectral_Pipeline,
	target_spectrum:         [OCEAN_SPECTRAL_CASCADE_COUNT]rl.Gpu_Texture,
	foam_history:            [OCEAN_SPECTRAL_CASCADE_COUNT][2]rl.Gpu_Texture,
	foam_index:              int,
	weather:                 Ocean_Spectral_Weather_Transition,
	dispatch_count:          u32,
	submission_count:        u32,
	uniform_write_count:     u32,
	bind_group_create_count: u32,
	stage_dispatch_count:    [Ocean_Spectral_Stage]u32,
	cascade_dispatch_count:  [OCEAN_SPECTRAL_CASCADE_COUNT]u32,
	memory_bytes:            u64,
	phase:                   f32,
	seed:                    u64,
	pending_weather:         Ocean_Render_Spectrum,
	has_pending_weather:     bool,
	ready:                   bool,
}

@(private)
ocean_spectral_pipeline_create :: proc(
	renderer: ^Ocean_Renderer,
	shader: string,
	bindings: []rl.Gpu_Binding_Desc,
) -> (
	Ocean_Spectral_Pipeline,
	bool,
) {
	assert(renderer != nil, "ocean_spectral_pipeline_create: nil renderer")
	module := rl.create_gpu_shader_module(shader)
	if module.id == 0 {
		renderer.spectral_failure_stage = .Shader_Module
		return {}, false
	}
	layout := rl.create_gpu_bind_group_layout(bindings)
	if layout.id == 0 {
		renderer.spectral_failure_stage = .Bind_Group_Layout
		rl.destroy_gpu_shader_module(&module)
		return {}, false
	}
	pipeline := rl.create_gpu_compute_pipeline(module, layout)
	if pipeline.id == 0 {
		renderer.spectral_failure_stage = .Compute_Pipeline
		rl.destroy_gpu_bind_group_layout(&layout)
		rl.destroy_gpu_shader_module(&module)
		return {}, false
	}
	return {module = module, layout = layout, pipeline = pipeline}, true
}

@(private)
ocean_spectral_pipeline_destroy :: proc(value: ^Ocean_Spectral_Pipeline) {
	assert(value != nil, "ocean_spectral_pipeline_destroy: nil pipeline")
	rl.destroy_gpu_compute_pipeline(&value.pipeline)
	rl.destroy_gpu_bind_group_layout(&value.layout)
	rl.destroy_gpu_shader_module(&value.module)
	value^ = {}
}

@(private)
ocean_spectral_texture_create :: proc(
	resolution: u32,
	format: wg.TextureFormat,
) -> rl.Gpu_Texture {
	return rl.create_gpu_texture(
		{
			width = resolution,
			height = resolution,
			layers = 1,
			mip_count = 1,
			sample_count = 1,
			format = format,
			usage = {.StorageBinding, .TextureBinding, .CopyDst},
		},
	)
}

@(private)
ocean_spectral_cascade_create :: proc(cascade: ^Ocean_Spectral_Cascade, index: int) -> bool {
	assert(cascade != nil, "ocean_spectral_cascade_create: nil cascade")
	assert(
		index >= 0 && index < OCEAN_SPECTRAL_CASCADE_COUNT,
		"ocean_spectral_cascade_create: index",
	)
	length_scales := OCEAN_SPECTRAL_LENGTH_SCALE
	resolutions := OCEAN_SPECTRAL_RESOLUTION
	cascade^ = {
		length_scale = length_scales[index],
		resolution   = resolutions[index],
	}
	cascade.spectrum = ocean_spectral_texture_create(cascade.resolution, .RGBA32Float)
	for &frequency in cascade.frequency {
		frequency = ocean_spectral_texture_create(cascade.resolution, .RGBA32Float)
	}
	cascade.displacement = ocean_spectral_texture_create(cascade.resolution, .RGBA16Float)
	cascade.slope = ocean_spectral_texture_create(cascade.resolution, .RGBA16Float)
	cascade.foam = ocean_spectral_texture_create(cascade.resolution, .R32Float)
	return(
		cascade.spectrum.id != 0 &&
		cascade.frequency[0].id != 0 &&
		cascade.frequency[1].id != 0 &&
		cascade.displacement.id != 0 &&
		cascade.slope.id != 0 &&
		cascade.foam.id != 0 \
	)
}

@(private)
ocean_spectral_cascade_destroy :: proc(cascade: ^Ocean_Spectral_Cascade) {
	assert(cascade != nil, "ocean_spectral_cascade_destroy: nil cascade")
	rl.destroy_gpu_texture(&cascade.foam)
	rl.destroy_gpu_texture(&cascade.slope)
	rl.destroy_gpu_texture(&cascade.displacement)
	for &frequency in cascade.frequency do rl.destroy_gpu_texture(&frequency)
	rl.destroy_gpu_texture(&cascade.spectrum)
	cascade^ = {}
}

@(private)
ocean_spectral_bindings :: proc(
	stage: Ocean_Spectral_Stage,
	storage: ^[OCEAN_SPECTRAL_BINDINGS_MAX]rl.Gpu_Binding_Desc,
) -> []rl.Gpu_Binding_Desc {
	assert(storage != nil, "ocean_spectral_bindings: nil storage")
	compute := bit_set[rl.Gpu_Shader_Stage]{.Compute}
	storage[0] = {
		binding      = 0,
		visibility   = compute,
		kind         = .Uniform_Buffer,
		minimum_size = OCEAN_SPECTRAL_UNIFORM_BYTES,
	}
	if stage == .Initialize {
		storage[1] = {
			binding        = 1,
			visibility     = compute,
			kind           = .Storage_Texture,
			texture_format = .RGBA32Float,
		}
		return storage[:2]
	}
	storage[1] = {
		binding             = 1,
		visibility          = compute,
		kind                = .Sampled_Texture,
		texture_sample_type = .Unfilterable_Float,
	}
	if stage == .Evolve {
		storage[2] = {
			binding             = 2,
			visibility          = compute,
			kind                = .Sampled_Texture,
			texture_sample_type = .Unfilterable_Float,
		}
		storage[3] = {
			binding        = 3,
			visibility     = compute,
			kind           = .Storage_Texture,
			texture_format = .RGBA32Float,
		}
		return storage[:4]
	}
	if stage == .Fft {
		storage[2] = {
			binding        = 2,
			visibility     = compute,
			kind           = .Storage_Texture,
			texture_format = .RGBA32Float,
		}
		return storage[:3]
	}
	if stage == .Derive {
		storage[2] = {
			binding        = 2,
			visibility     = compute,
			kind           = .Storage_Texture,
			texture_format = .RGBA16Float,
		}
		storage[3] = {
			binding        = 3,
			visibility     = compute,
			kind           = .Storage_Texture,
			texture_format = .RGBA16Float,
		}
		storage[4] = {
			binding        = 4,
			visibility     = compute,
			kind           = .Storage_Texture,
			texture_format = .R32Float,
		}
		return storage[:5]
	}
	if stage == .Foam {
		storage[2] = {
			binding             = 2,
			visibility          = compute,
			kind                = .Sampled_Texture,
			texture_sample_type = .Unfilterable_Float,
		}
		storage[3] = {
			binding        = 3,
			visibility     = compute,
			kind           = .Storage_Texture,
			texture_format = .R32Float,
		}
		return storage[:4]
	}
	return nil
}

ocean_spectral_peak_omega :: proc(period: f32) -> f32 {
	if period <= 0 do return f32(math.TAU) / 8
	return f32(math.TAU) / period
}

ocean_spectral_deep_water_wavelength :: proc(period: f32) -> f32 {
	if period <= 0 do return 0
	return 9.81 * period * period / f32(math.TAU)
}

ocean_spectral_dispersion :: proc(k, depth: f32) -> f32 {
	if k <= 0 do return 0
	return math.sqrt(f32(9.81) * k * f32(math.tanh(f64(k * max(depth, f32(0.05))))))
}

ocean_spectral_dispersion_jacobian :: proc(k, depth: f32) -> f32 {
	if k <= 0 do return 0
	kh := k * max(depth, f32(0.05))
	tanh_kh := f32(math.tanh(f64(kh)))
	omega := math.sqrt(f32(9.81) * k * tanh_kh)
	sech_squared := max(1 - tanh_kh * tanh_kh, f32(0))
	return f32(9.81) * (tanh_kh + kh * sech_squared) / max(2 * omega, f32(0.0001))
}

ocean_spectral_tma_factor_nondimensional :: proc(value: f32) -> f32 {
	x := max(value, f32(0))
	if x <= 1 do return 0.5 * x * x
	if x < 2 do return 1 - 0.5 * (2 - x) * (2 - x)
	return 1
}

ocean_spectral_tma_factor :: proc(omega, depth: f32) -> f32 {
	if omega <= 0 do return 0
	return ocean_spectral_tma_factor_nondimensional(
		omega * math.sqrt(max(depth, f32(0.05)) / f32(9.81)),
	)
}

ocean_spectral_jonswap_shape :: proc(omega, peak_omega, gamma, depth: f32) -> f32 {
	if omega <= 0 || peak_omega <= 0 do return 0
	sigma := f32(0.07) if omega <= peak_omega else f32(0.09)
	delta := omega - peak_omega
	peak := math.exp(
		-delta * delta / max(2 * sigma * sigma * peak_omega * peak_omega, f32(0.0001)),
	)
	base :=
		f32(9.81 * 9.81) * math.pow(omega, -5) * math.exp(-1.25 * math.pow(peak_omega / omega, 4))
	return base * math.pow(max(gamma, f32(1)), peak) * ocean_spectral_tma_factor(omega, depth)
}

ocean_spectral_cascade_alpha :: proc(
	weather: Ocean_Render_Spectrum,
	length_scale: f32,
	resolution: u32,
	energy_weight: f32,
	swell_energy_weight := f32(0),
) -> f32 {
	continuous_height := ocean_continuous_wave_height(
		weather.wind_sea_height,
		weather.swell_height,
	)
	if continuous_height <= 0 ||
	   length_scale <= 0 ||
	   resolution == 0 ||
	   energy_weight <= 0 && swell_energy_weight <= 0 {
		return 0
	}
	peak_omega := ocean_spectral_peak_omega(weather.peak_period)
	delta_k := f32(math.TAU) / length_scale
	wind := [2]f32{weather.direction.x, weather.direction.y}
	wind_length := math.sqrt(wind.x * wind.x + wind.y * wind.y)
	if wind_length <= 0.0001 do wind = {1, 0}
	else do wind /= wind_length
	sum := f64(0)
	half := i32(resolution / 2)
	for row in -half ..< half {
		for column in -half ..< half {
			kx := f32(column) * delta_k
			ky := f32(row) * delta_k
			k := math.sqrt(kx * kx + ky * ky)
			if k <= 0.0001 do continue
			alignment := max((kx * wind.x + ky * wind.y) / k, f32(0))
			directional := f32(0.63661977236) * alignment * alignment
			omega := ocean_spectral_dispersion(k, weather.depth)
			shape := ocean_spectral_jonswap_shape(
				omega,
				peak_omega,
				OCEAN_SPECTRAL_JONSWAP_GAMMA,
				weather.depth,
			)
			jacobian := ocean_spectral_dispersion_jacobian(k, weather.depth)
			sum += f64(shape * jacobian * directional / k * delta_k * delta_k)
		}
	}
	if sum <= 0 do return 0
	target_variance :=
		(weather.wind_sea_height * weather.wind_sea_height * energy_weight +
			weather.swell_height * weather.swell_height * swell_energy_weight) /
		16
	return target_variance / f32(sum)
}

@(private)
ocean_spectral_init_dispatch :: proc(
	renderer: ^Ocean_Renderer,
	runtime: ^Ocean_Spectral_Runtime,
	spectrum: rl.Gpu_Texture,
	cascade: ^Ocean_Spectral_Cascade,
	seed: u32,
	weather: Ocean_Render_Spectrum,
) -> bool {
	assert(renderer != nil, "ocean_spectral_init_dispatch: nil renderer")
	params := [16]u32{}
	params[0] = transmute(u32)weather.direction.x
	params[1] = transmute(u32)weather.direction.y
	cascade_index := 0
	length_scales := OCEAN_SPECTRAL_LENGTH_SCALE
	energy_weights := OCEAN_SPECTRAL_ENERGY_WEIGHT
	swell_energy_weights := OCEAN_SPECTRAL_SWELL_ENERGY_WEIGHT
	for length_scale, index in length_scales {
		if cascade.length_scale == length_scale {
			cascade_index = index
			break
		}
	}
	params[2] = transmute(u32)ocean_spectral_cascade_alpha(
		weather,
		cascade.length_scale,
		cascade.resolution,
		energy_weights[cascade_index],
		swell_energy_weights[cascade_index],
	)
	params[3] = transmute(u32)ocean_spectral_peak_omega(weather.peak_period)
	params[4] = transmute(u32)OCEAN_SPECTRAL_JONSWAP_GAMMA
	params[5] = transmute(u32)cascade.length_scale
	params[6] = transmute(u32)weather.depth
	params[7] = cascade.resolution
	params[8] = seed
	bytes := mem.slice_to_bytes(params[:])
	if !rl.write_gpu_buffer(runtime.uniform, 0, bytes) {
		renderer.spectral_failure_stage = .Uniform
		return false
	}
	group := rl.create_gpu_bind_group(
		runtime.initialize.layout,
		{
			{binding = 0, buffer = runtime.uniform, size = OCEAN_SPECTRAL_UNIFORM_BYTES},
			{binding = 1, texture = spectrum},
		},
	)
	if group.id == 0 {
		renderer.spectral_failure_stage = .Bind_Group
		return false
	}
	defer rl.destroy_gpu_bind_group(&group)
	commands, commands_ok := rl.context_begin_gpu_commands(rl.default_context())
	if !commands_ok {
		renderer.spectral_failure_stage = .Commands
		return false
	}
	pass, pass_ok := rl.begin_gpu_compute_pass(&commands)
	if !pass_ok {
		renderer.spectral_failure_stage = .Compute_Pass
		return false
	}
	ok := rl.compute_pass_set_pipeline(&pass, runtime.initialize.pipeline)
	ok = rl.compute_pass_set_bind_group(&pass, 0, group) && ok
	groups := cascade.resolution / OCEAN_SPECTRAL_WORKGROUP_SIZE
	ok = rl.compute_pass_dispatch(&pass, groups, groups, 1) && ok
	if !ok {
		renderer.spectral_failure_stage = .Pass_Setup
		return false
	}
	if !rl.end_gpu_compute_pass(&pass) {
		renderer.spectral_failure_stage = .Pass_End
		return false
	}
	if !rl.context_submit_gpu_commands(&commands) {
		renderer.spectral_failure_stage = .Submit
		return false
	}
	runtime.dispatch_count += 1
	return true
}

@(private)
ocean_spectral_group_create :: proc(
	runtime: ^Ocean_Spectral_Runtime,
	pipeline: Ocean_Spectral_Pipeline,
	slot: int,
	bindings: []rl.Gpu_Bind_Entry,
) -> bool {
	assert(runtime != nil, "ocean spectral group create: nil runtime")
	assert(slot >= 0 && slot < OCEAN_SPECTRAL_DISPATCHES_MAX, "ocean spectral group create: slot")
	group := rl.create_gpu_bind_group(pipeline.layout, bindings)
	if group.id == 0 do return false
	runtime.update_groups[slot] = group
	runtime.bind_group_create_count += 1
	return true
}

@(private)
ocean_spectral_update_groups_create :: proc(renderer: ^Ocean_Renderer) -> bool {
	assert(renderer != nil, "ocean spectral groups create: nil renderer")
	runtime := &renderer.spectral
	slot := 0
	for &cascade, cascade_index in renderer.cascades {
		offset := u64(slot * OCEAN_SPECTRAL_UNIFORM_STRIDE)
		if !ocean_spectral_group_create(
			runtime,
			runtime.evolve,
			slot,
			{
				{
					binding = 0,
					buffer = runtime.update_uniform,
					offset = offset,
					size = OCEAN_SPECTRAL_UNIFORM_BYTES,
				},
				{binding = 1, texture = cascade.spectrum},
				{binding = 2, texture = runtime.target_spectrum[cascade_index]},
				{binding = 3, texture = cascade.frequency[0]},
			},
		) {
			return false
		}
		slot += 1
		source := 0
		for _ in 0 ..< 2 {
			for _ in u32(0) ..< ocean_spectral_log2(cascade.resolution) {
				destination := 1 - source
				offset = u64(slot * OCEAN_SPECTRAL_UNIFORM_STRIDE)
				if !ocean_spectral_group_create(
					runtime,
					runtime.fft,
					slot,
					{
						{
							binding = 0,
							buffer = runtime.update_uniform,
							offset = offset,
							size = OCEAN_SPECTRAL_UNIFORM_BYTES,
						},
						{binding = 1, texture = cascade.frequency[source]},
						{binding = 2, texture = cascade.frequency[destination]},
					},
				) {
					return false
				}
				slot += 1
				source = destination
			}
		}
		offset = u64(slot * OCEAN_SPECTRAL_UNIFORM_STRIDE)
		if !ocean_spectral_group_create(
			runtime,
			runtime.derive,
			slot,
			{
				{
					binding = 0,
					buffer = runtime.update_uniform,
					offset = offset,
					size = OCEAN_SPECTRAL_UNIFORM_BYTES,
				},
				{binding = 1, texture = cascade.frequency[source]},
				{binding = 2, texture = cascade.displacement},
				{binding = 3, texture = cascade.slope},
				{binding = 4, texture = cascade.foam},
			},
		) {
			return false
		}
		slot += 1
		offset = u64(slot * OCEAN_SPECTRAL_UNIFORM_STRIDE)
		if !ocean_spectral_group_create(
			runtime,
			runtime.foam,
			slot,
			{
				{
					binding = 0,
					buffer = runtime.update_uniform,
					offset = offset,
					size = OCEAN_SPECTRAL_UNIFORM_BYTES,
				},
				{binding = 1, texture = runtime.foam_history[cascade_index][0]},
				{binding = 2, texture = cascade.foam},
				{binding = 3, texture = runtime.foam_history[cascade_index][1]},
			},
		) {
			return false
		}
		alternate := rl.create_gpu_bind_group(
			runtime.foam.layout,
			{
				{
					binding = 0,
					buffer = runtime.update_uniform,
					offset = offset,
					size = OCEAN_SPECTRAL_UNIFORM_BYTES,
				},
				{binding = 1, texture = runtime.foam_history[cascade_index][1]},
				{binding = 2, texture = cascade.foam},
				{binding = 3, texture = runtime.foam_history[cascade_index][0]},
			},
		)
		if alternate.id == 0 do return false
		runtime.foam_groups[cascade_index] = alternate
		runtime.bind_group_create_count += 1
		slot += 1
	}
	runtime.update_group_count = slot
	return slot == OCEAN_SPECTRAL_DISPATCHES_MAX
}

Ocean_Spectral_Init_Action :: enum u8 {
	None,
	Wait,
	Unsupported,
	Initialize,
}

ocean_spectral_init_action :: proc(
	state: Ocean_Spectral_Init_State,
	compute, storage_textures, frame_open: bool,
) -> Ocean_Spectral_Init_Action {
	if state != .Pending do return .None
	if frame_open do return .Wait
	if !compute || !storage_textures do return .Unsupported
	return .Initialize
}

ocean_spectral_retry :: proc(renderer: ^Ocean_Renderer) -> bool {
	assert(renderer != nil, "ocean_spectral_retry: nil renderer")
	if renderer.spectral_init_state != .Failed || renderer.spectral.ready do return false
	renderer.spectral_failure_stage = .None
	renderer.spectral_failure_cascade = 0
	renderer.spectral_init_state = .Pending
	return true
}

ocean_spectral_ensure_initialized :: proc(renderer: ^Ocean_Renderer, seed: u64) {
	assert(renderer != nil, "ocean_spectral_ensure_initialized: nil renderer")
	capabilities := rl.capabilities()
	action := ocean_spectral_init_action(
		renderer.spectral_init_state,
		capabilities.compute,
		capabilities.storage_textures,
		rl.context_frame_available(rl.default_context()),
	)
	switch action {
	case .None, .Wait:
		return
	case .Unsupported:
		renderer.spectral_init_state = .Unsupported
	case .Initialize:
		if ocean_spectral_init(renderer, seed) {
			renderer.spectral_init_state = .Ready
			fmt.eprintfln("[planetforger] ocean spectral init: ready")
		} else {
			renderer.spectral_init_state = .Failed
			fmt.eprintfln(
				"[planetforger] ocean spectral init: failed stage=%v cascade=%d count=%d",
				renderer.spectral_failure_stage,
				renderer.spectral_failure_cascade,
				renderer.spectral_failure_count,
			)
		}
	}
}

ocean_spectral_step_due :: proc(pending_dt: f32) -> (elapsed, remainder: f32, due: bool) {
	if pending_dt + 0.000001 < OCEAN_SPECTRAL_UPDATE_INTERVAL do return 0, pending_dt, false
	steps := math.floor(pending_dt / OCEAN_SPECTRAL_UPDATE_INTERVAL)
	elapsed = steps * OCEAN_SPECTRAL_UPDATE_INTERVAL
	remainder = max(pending_dt - elapsed, f32(0))
	return elapsed, remainder, true
}

ocean_spectral_update_admitted :: proc(pending_dt: f32, budget_available: bool) -> bool {
	return budget_available || pending_dt >= OCEAN_SPECTRAL_MAX_DEFERRED
}

ocean_spectral_prepare :: proc(renderer: ^Ocean_Renderer, seed: u64, budget_available := true) {
	assert(renderer != nil, "ocean_spectral_prepare: nil renderer")
	ocean_spectral_ensure_initialized(renderer, seed)
	if !renderer.spectral.ready do return
	if renderer.spectral.has_pending_weather {
		weather := renderer.spectral.pending_weather
		renderer.spectral.has_pending_weather = false
		ocean_spectral_apply_weather(renderer, weather)
	}
	elapsed, remainder, due := ocean_spectral_step_due(renderer.spectral_pending_dt)
	if !due || !ocean_spectral_update_admitted(renderer.spectral_pending_dt, budget_available) do return
	ocean_spectral_update(renderer, renderer.macro.time, elapsed)
	renderer.spectral_pending_dt = remainder
}

ocean_spectral_init :: proc(renderer: ^Ocean_Renderer, seed: u64) -> bool {
	assert(renderer != nil, "ocean_spectral_init: nil renderer")
	assert(!rl.context_frame_available(rl.default_context()), "ocean_spectral_init: frame open")
	runtime := &renderer.spectral
	runtime^ = {}
	runtime.seed = seed
	renderer.spectral_failure_stage = .None
	renderer.spectral_failure_cascade = 0
	default_weather := Ocean_Render_Spectrum {
		direction          = {1, 0, 0},
		significant_height = OCEAN_SPECTRAL_WIND_CHOP_HEIGHT,
		wind_sea_height    = OCEAN_SPECTRAL_WIND_CHOP_HEIGHT,
		peak_period        = 8,
		depth              = 64,
	}
	runtime.weather = {
		source   = default_weather,
		target   = default_weather,
		duration = OCEAN_SPECTRAL_TRANSITION_SECONDS,
	}
	runtime.uniform = rl.create_gpu_buffer(
		{size = OCEAN_SPECTRAL_UNIFORM_BYTES, usage = {.Uniform, .CopyDst}},
	)
	runtime.update_uniform = rl.create_gpu_buffer(
		{
			size = OCEAN_SPECTRAL_DISPATCHES_MAX * OCEAN_SPECTRAL_UNIFORM_STRIDE,
			usage = {.Uniform, .CopyDst},
		},
	)
	if runtime.uniform.id == 0 || runtime.update_uniform.id == 0 {
		renderer.spectral_failure_stage = .Uniform
		renderer.spectral_failure_count += 1
		ocean_spectral_deinit(renderer)
		return false
	}
	binding_storage: [OCEAN_SPECTRAL_BINDINGS_MAX]rl.Gpu_Binding_Desc
	initialize, init_ok := ocean_spectral_pipeline_create(
		renderer,
		OCEAN_SPECTRUM_INIT_SHADER,
		ocean_spectral_bindings(.Initialize, &binding_storage),
	)
	if !init_ok {
		ocean_spectral_deinit(renderer)
		return false
	}
	runtime.initialize = initialize
	evolve, evolve_ok := ocean_spectral_pipeline_create(
		renderer,
		OCEAN_SPECTRUM_EVOLVE_SHADER,
		ocean_spectral_bindings(.Evolve, &binding_storage),
	)
	if !evolve_ok {
		ocean_spectral_deinit(renderer)
		return false
	}
	runtime.evolve = evolve
	fft, fft_ok := ocean_spectral_pipeline_create(
		renderer,
		OCEAN_STOCKHAM_SHADER,
		ocean_spectral_bindings(.Fft, &binding_storage),
	)
	if !fft_ok {
		ocean_spectral_deinit(renderer)
		return false
	}
	runtime.fft = fft
	derive, derive_ok := ocean_spectral_pipeline_create(
		renderer,
		OCEAN_DERIVE_SHADER,
		ocean_spectral_bindings(.Derive, &binding_storage),
	)
	if !derive_ok {
		ocean_spectral_deinit(renderer)
		return false
	}
	runtime.derive = derive
	foam, foam_ok := ocean_spectral_pipeline_create(
		renderer,
		OCEAN_FOAM_HISTORY_SHADER,
		ocean_spectral_bindings(.Foam, &binding_storage),
	)
	if !foam_ok {
		ocean_spectral_deinit(renderer)
		return false
	}
	runtime.foam = foam
	for &cascade, index in renderer.cascades {
		renderer.spectral_failure_cascade = i32(index)
		if !ocean_spectral_cascade_create(&cascade, index) {
			renderer.spectral_failure_stage = .Textures
			renderer.spectral_failure_count += 1
			ocean_spectral_deinit(renderer)
			return false
		}
		rl.SetTextureFilter(rl.gpu_texture_as_texture_2d(cascade.displacement), .BILINEAR)
		runtime.target_spectrum[index] = ocean_spectral_texture_create(
			cascade.resolution,
			.RGBA32Float,
		)
		for &history in runtime.foam_history[index] {
			history = ocean_spectral_texture_create(cascade.resolution, .R32Float)
		}
		if runtime.target_spectrum[index].id == 0 ||
		   runtime.foam_history[index][0].id == 0 ||
		   runtime.foam_history[index][1].id == 0 {
			renderer.spectral_failure_stage = .Textures
			renderer.spectral_failure_count += 1
			ocean_spectral_deinit(renderer)
			return false
		}
		if !ocean_spectral_init_dispatch(
			   renderer,
			   runtime,
			   cascade.spectrum,
			   &cascade,
			   u32(seed) + u32(index) * 977,
			   default_weather,
		   ) ||
		   !ocean_spectral_init_dispatch(
				   renderer,
				   runtime,
				   runtime.target_spectrum[index],
				   &cascade,
				   u32(seed) + u32(index) * 977,
				   default_weather,
			   ) {
			renderer.spectral_failure_count += 1
			ocean_spectral_deinit(renderer)
			return false
		}
		pixels := u64(cascade.resolution) * u64(cascade.resolution)
		runtime.memory_bytes += pixels * (16 * 4 + 8 * 2 + 4 * 3)
	}
	if !ocean_spectral_update_groups_create(renderer) {
		renderer.spectral_failure_stage = .Bind_Group
		renderer.spectral_failure_count += 1
		ocean_spectral_deinit(renderer)
		return false
	}
	runtime.ready = true
	renderer.wave_source = .Spectral
	return true
}

ocean_spectral_choppiness :: proc(spectrum: Ocean_Render_Spectrum) -> f32 {
	wind := clamp((spectrum.wind_speed - 4) / 28, f32(0), f32(1))
	sea := clamp(spectrum.wind_sea_height / 6, f32(0), f32(1))
	breaking := clamp(spectrum.breaking, f32(0), f32(1))
	forcing := max(wind * (0.65 + sea * 0.35), max(sea * 0.75, breaking))
	return 0.35 + forcing * 1.15
}

ocean_spectral_weather_changed :: proc(a, b: Ocean_Render_Spectrum) -> bool {
	if abs(a.wind_sea_height - b.wind_sea_height) >= 0.2 do return true
	if abs(a.swell_height - b.swell_height) >= 0.2 do return true
	if abs(a.peak_period - b.peak_period) >= 0.35 do return true
	if abs(a.wind_speed - b.wind_speed) >= 2 do return true
	if abs(a.breaking - b.breaking) >= 0.08 do return true
	if abs(a.depth - b.depth) >= max(a.depth * 0.08, f32(0.5)) do return true
	return a.direction.x * b.direction.x + a.direction.y * b.direction.y < 0.985
}

ocean_spectral_weather_initialize :: proc(
	renderer: ^Ocean_Renderer,
	weather: Ocean_Render_Spectrum,
) -> bool {
	runtime := &renderer.spectral
	for &cascade, index in renderer.cascades {
		if !ocean_spectral_init_dispatch(
			renderer,
			runtime,
			runtime.target_spectrum[index],
			&cascade,
			u32(runtime.seed) + u32(index) * 977,
			weather,
		) {
			return false
		}
	}
	return true
}

ocean_spectral_apply_weather :: proc(renderer: ^Ocean_Renderer, supplied: Ocean_Render_Spectrum) {
	assert(renderer != nil, "ocean_spectral_apply_weather: nil renderer")
	weather := supplied
	runtime := &renderer.spectral
	if !runtime.ready do return
	direction := [2]f32 {
		weather.direction.x * renderer.focus_east.x +
		weather.direction.y * renderer.focus_east.y +
		weather.direction.z * renderer.focus_east.z,
		weather.direction.x * renderer.focus_north.x +
		weather.direction.y * renderer.focus_north.y +
		weather.direction.z * renderer.focus_north.z,
	}
	length := math.sqrt(direction.x * direction.x + direction.y * direction.y)
	if length <= 0.0001 do direction = {1, 0}
	else do direction /= length
	weather.direction = {direction.x, direction.y, 0}
	if rl.context_frame_available(rl.default_context()) {
		runtime.pending_weather = weather
		runtime.has_pending_weather = true
		return
	}
	if runtime.weather.active {
		if ocean_spectral_weather_changed(runtime.weather.target, weather) {
			runtime.weather.queued = weather
			runtime.weather.has_queued = true
		}
		return
	}
	if !ocean_spectral_weather_changed(runtime.weather.source, weather) do return
	if !ocean_spectral_weather_initialize(renderer, weather) do return
	runtime.weather.target = weather
	runtime.weather.progress = 0
	runtime.weather.active = true
}

ocean_spectral_apply_state :: proc(renderer: ^Ocean_Renderer, spectrum: Ocean_Render_Spectrum) {
	assert(renderer != nil, "ocean_spectral_apply_state: nil renderer")
	ocean_spectral_apply_weather(renderer, spectrum)
}

@(private)
ocean_spectral_record :: proc(
	runtime: ^Ocean_Spectral_Runtime,
	cascade: ^Ocean_Spectral_Cascade,
	pipeline: Ocean_Spectral_Pipeline,
	pass: ^rl.Gpu_Compute_Pass,
	group: rl.Gpu_Bind_Group,
	stage: Ocean_Spectral_Stage,
	cascade_index: int,
) -> bool {
	assert(runtime != nil && cascade != nil && pass != nil, "ocean_spectral_record: nil input")
	if group.id == 0 do return false
	ok := rl.compute_pass_set_pipeline(pass, pipeline.pipeline)
	ok = rl.compute_pass_set_bind_group(pass, 0, group) && ok
	groups := cascade.resolution / OCEAN_SPECTRAL_WORKGROUP_SIZE
	ok = rl.compute_pass_dispatch(pass, groups, groups, 1) && ok
	if ok {
		runtime.dispatch_count += 1
		runtime.stage_dispatch_count[stage] += 1
		runtime.cascade_dispatch_count[cascade_index] += 1
	}
	return ok
}

@(private)
ocean_spectral_cascade_update :: proc(
	runtime: ^Ocean_Spectral_Runtime,
	cascade: ^Ocean_Spectral_Cascade,
	cascade_index: int,
	pass: ^rl.Gpu_Compute_Pass,
	slot_index: ^int,
) -> bool {
	assert(slot_index != nil, "ocean_spectral_cascade_update: nil slot")
	assert(
		slot_index^ + int(2 * ocean_spectral_log2(cascade.resolution)) + 3 <=
		len(runtime.update_groups),
		"ocean_spectral_cascade_update: uniform overflow",
	)
	log_resolution := ocean_spectral_log2(cascade.resolution)
	params := [16]u32{}
	params[0] = transmute(u32)runtime.phase
	params[1] = transmute(u32)runtime.weather.progress
	params[2] = cascade.resolution
	params[3] = log_resolution
	params[4] = transmute(u32)ocean_spectral_choppiness(runtime.weather.source)
	params[5] = transmute(u32)ocean_spectral_choppiness(runtime.weather.target)
	slot := slot_index^
	copy(runtime.uniform_params[slot][:16], params[:])
	slot_index^ += 1
	evolved := ocean_spectral_record(
		runtime,
		cascade,
		runtime.evolve,
		pass,
		runtime.update_groups[slot],
		.Evolve,
		cascade_index,
	)
	if !evolved do return false
	source := 0
	for axis in 0 ..< 2 {
		for stage in u32(0) ..< log_resolution {
			params = {}
			params[0] = stage
			params[1] = u32(1) if axis == 0 else u32(0)
			params[2] = cascade.resolution
			params[3] = u32(1) if axis == 1 && stage + 1 == log_resolution else u32(0)
			slot = slot_index^
			copy(runtime.uniform_params[slot][:16], params[:])
			slot_index^ += 1
			destination := 1 - source
			transformed := ocean_spectral_record(
				runtime,
				cascade,
				runtime.fft,
				pass,
				runtime.update_groups[slot],
				.Fft,
				cascade_index,
			)
			if !transformed do return false
			source = destination
		}
	}
	params = {}
	params[0] = cascade.resolution
	params[1] = transmute(u32)(f32(cascade.resolution) / cascade.length_scale)
	blend :=
		runtime.weather.progress * runtime.weather.progress * (3 - 2 * runtime.weather.progress)
	source_choppiness := ocean_spectral_choppiness(runtime.weather.source)
	target_choppiness := ocean_spectral_choppiness(runtime.weather.target)
	choppiness := source_choppiness + (target_choppiness - source_choppiness) * blend
	params[2] = transmute(u32)choppiness
	slot = slot_index^
	copy(runtime.uniform_params[slot][:16], params[:])
	slot_index^ += 1
	derived := ocean_spectral_record(
		runtime,
		cascade,
		runtime.derive,
		pass,
		runtime.update_groups[slot],
		.Derive,
		cascade_index,
	)
	if !derived do return false
	params = {}
	params[0] = transmute(u32)f32(0.965)
	params[1] = transmute(u32)f32(1)
	params[2] = cascade.resolution
	slot = slot_index^
	copy(runtime.uniform_params[slot][:16], params[:])
	slot_index^ += 1
	group := runtime.update_groups[slot]
	if runtime.foam_index == 1 do group = runtime.foam_groups[cascade_index]
	return ocean_spectral_record(runtime, cascade, runtime.foam, pass, group, .Foam, cascade_index)
}

ocean_spectral_update :: proc(renderer: ^Ocean_Renderer, simulation_time, transition_dt: f32) {
	assert(renderer != nil, "ocean_spectral_update: nil renderer")
	assert(simulation_time >= 0 && transition_dt >= 0, "ocean_spectral_update: negative time")
	if !renderer.spectral.ready do return
	if rl.context_frame_available(rl.default_context()) do return
	runtime := &renderer.spectral
	runtime.phase = simulation_time
	if runtime.weather.active {
		runtime.weather.progress = min(
			runtime.weather.progress + transition_dt / max(runtime.weather.duration, f32(0.001)),
			f32(1),
		)
	}
	commands, commands_ok := rl.context_begin_gpu_commands(rl.default_context())
	if !commands_ok {
		renderer.spectral_failure_stage = .Commands
		renderer.spectral_failure_count += 1
		ocean_spectral_deinit(renderer)
		return
	}
	slot_index := 0
	recorded := true
	pass, pass_ok := rl.begin_gpu_compute_pass(&commands)
	if !pass_ok do recorded = false
	for &cascade, index in renderer.cascades {
		if !recorded ||
		   !ocean_spectral_cascade_update(runtime, &cascade, index, &pass, &slot_index) {
			recorded = false
			renderer.spectral_failure_cascade = i32(index)
			break
		}
	}
	if pass.active do recorded = rl.end_gpu_compute_pass(&pass) && recorded
	if recorded {
		recorded = rl.write_gpu_buffer(
			runtime.update_uniform,
			0,
			mem.slice_to_bytes(runtime.uniform_params[:]),
		)
		if recorded do runtime.uniform_write_count += 1
	}
	if !recorded {
		renderer.spectral_failure_stage = .Dispatch
		renderer.spectral_failure_count += 1
		ocean_spectral_deinit(renderer)
		return
	}
	if !rl.context_submit_gpu_commands(&commands) {
		renderer.spectral_failure_stage = .Submit
		renderer.spectral_failure_count += 1
		ocean_spectral_deinit(renderer)
		return
	}
	runtime.submission_count += 1
	renderer.spectral_update_serial += 1
	runtime.foam_index = 1 - runtime.foam_index
	if runtime.weather.active && runtime.weather.progress >= 1 {
		for &cascade, index in renderer.cascades {
			cascade.spectrum, runtime.target_spectrum[index] =
				runtime.target_spectrum[index], cascade.spectrum
		}
		runtime.weather.source = runtime.weather.target
		runtime.weather.progress = 0
		runtime.weather.active = false
		if runtime.weather.has_queued {
			queued := runtime.weather.queued
			runtime.weather.has_queued = false
			if ocean_spectral_weather_initialize(renderer, queued) {
				runtime.weather.target = queued
				runtime.weather.active = true
			}
		}
	}
}

ocean_spectral_displacement_texture :: proc(
	renderer: ^Ocean_Renderer,
	cascade_index: int,
) -> rl.Texture2D {
	assert(renderer != nil, "ocean_spectral_displacement_texture: nil renderer")
	assert(
		cascade_index >= 0 && cascade_index < OCEAN_SPECTRAL_CASCADE_COUNT,
		"ocean_spectral_displacement_texture: index",
	)
	if renderer.wave_source != .Spectral || !renderer.spectral.ready do return {}
	return rl.gpu_texture_as_texture_2d(renderer.cascades[cascade_index].displacement)
}

ocean_spectral_deinit :: proc(renderer: ^Ocean_Renderer) {
	assert(renderer != nil, "ocean_spectral_deinit: nil renderer")
	for &history in renderer.spectral.foam_history {
		for &texture in history do rl.destroy_gpu_texture(&texture)
	}
	for &group in renderer.spectral.foam_groups do rl.destroy_gpu_bind_group(&group)
	for &group in renderer.spectral.update_groups do rl.destroy_gpu_bind_group(&group)
	for &texture in renderer.spectral.target_spectrum do rl.destroy_gpu_texture(&texture)
	for &cascade in renderer.cascades do ocean_spectral_cascade_destroy(&cascade)
	ocean_spectral_pipeline_destroy(&renderer.spectral.foam)
	ocean_spectral_pipeline_destroy(&renderer.spectral.derive)
	ocean_spectral_pipeline_destroy(&renderer.spectral.fft)
	ocean_spectral_pipeline_destroy(&renderer.spectral.evolve)
	ocean_spectral_pipeline_destroy(&renderer.spectral.initialize)
	rl.destroy_gpu_buffer(&renderer.spectral.update_uniform)
	rl.destroy_gpu_buffer(&renderer.spectral.uniform)
	renderer.spectral = {}
	renderer.wave_source = .Gerstner
	if renderer.spectral_init_state == .Ready do renderer.spectral_init_state = .Failed
}

ocean_spectral_target_height :: proc(significant_height, amplitude_scale: f32) -> f32 {
	if amplitude_scale <= 0 do return 0
	return clamp(max(significant_height, 0) * amplitude_scale, 0, 7.5)
}

ocean_spectral_compute_pass_count :: proc() -> int {
	return 1
}

ocean_spectral_update_dispatch_count :: proc() -> int {
	result := 0
	for resolution in OCEAN_SPECTRAL_RESOLUTION {
		result += 1 + 2 * int(ocean_spectral_log2(resolution)) + 2
	}
	assert(result <= OCEAN_SPECTRAL_DISPATCHES_MAX, "ocean spectral dispatch pool too small")
	return result
}

ocean_spectral_log2 :: proc(value: u32) -> u32 {
	assert(value > 0 && (value & (value - 1)) == 0, "ocean_spectral_log2: not power of two")
	result: u32
	current := value
	for current > 1 {
		current >>= 1
		result += 1
	}
	return result
}

ocean_spectral_gaussian :: proc(seed, x, y: u32) -> [2]f32 {
	first := seed ~ (x * 1664525 + y * 1013904223)
	second := first ~ u32(0x9e3779b9)
	first = (first ~ (first >> 16)) * 2246822519
	second = (second ~ (second >> 13)) * 3266489917
	u1 := max(f32(first & 0x00ffffff) / 16777216, f32(0.000001))
	u2 := f32(second & 0x00ffffff) / 16777216
	radius := math.sqrt(f32(-2) * math.ln(u1))
	phase := f32(math.TAU) * u2
	return {radius * math.cos(phase), radius * math.sin(phase)}
}
