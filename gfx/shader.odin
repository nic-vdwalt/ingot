// ingot:gfx - custom shader objects (raylib Shader parity) over WebGPU. Backs
// LoadShaderFromMemory / GetShaderLocation / SetShaderValue* / BeginShaderMode
// for fullscreen post-process and custom 2D passes (the galaxy bloom/streak/
// composite/soft-particle pipeline).
//
// Convention (the ported WGSL modules follow it, and this reflects it):
//   - group(0) binding(0): the batch projection uniform  (var<uniform> u: Uniforms)
//   - group(1) binding(0/1): the primary source texture + sampler (DrawTexturePro)
//   - group(2) binding(0): `struct U { ... }; var<uniform> cu: U;` custom uniforms
//   - group(3) binding(k): extra sampled textures `var NAME: texture_2d<f32>;`
//     plus one shared sampler at binding = extra_count.
//   - @vertex vs_main (batch layout: pos, col, uv) and @fragment fs_main.
//
// GetShaderLocation(name) returns a uniform member index, or SHADER_TEX_LOC_BASE
// + slot for an extra texture. SetShaderValue writes into a CPU uniform shadow
// uploaded on flush; SetShaderValueTexture binds an extra texture.
package gfx

import "core:strings"
import wg "vendor:wgpu"

SHADER_TEX_LOC_BASE :: 1000
SHADER_MAX_TEX :: 4
MAX_SHADERS :: 256
SHADER_SOURCE_BYTES_MAX :: 1024 * 1024
SHADER_UNIFORMS_MAX :: 1024
SHADER_UNIFORM_BYTES_MAX :: 64 * 1024

@(private)
Shader_Uniform :: struct {
	name:   string,
	offset: u32,
	size:   u32,
}

@(private)
Shader_Entry :: struct {
	module:       wg.ShaderModule,
	uniforms:     []Shader_Uniform,
	ushadow:      []u8,
	u_layout:     wg.BindGroupLayout,
	u_bind:       [STREAM_SLOT_COUNT]wg.BindGroup,
	tex_names:    []string, // extra texture binding names (group 3)
	extra_count:  int,
	extra_layout: wg.BindGroupLayout,
	extra_bind:   wg.BindGroup,
	extra_tex:    [SHADER_MAX_TEX]u32,
	extra_dirty:  bool,

	// pipelines are colour-target-format specific; built lazily per format.
	pipe_fmt:     [8]wg.TextureFormat,
	pipe_obj:     [8]wg.RenderPipeline,
	pipe_n:       int,
}

@(private)
Shader_Slot :: struct {
	entry:      ^Shader_Entry,
	generation: u32,
	occupied:   bool,
}

Shader_Resources :: struct {
	slots:       [MAX_SHADERS]Shader_Slot,
	count:       u32,
	default_tex: u32,
}

@(private)
_shader_register :: proc(
	context_id: u32,
	resources: ^Shader_Resources,
	entry: ^Shader_Entry,
) -> u32 {
	assert(context_id != 0, "_shader_register: unassigned context id")
	assert(resources != nil && entry != nil, "_shader_register: invalid arguments")
	if resources.count >= MAX_SHADERS do return 0
	for &slot, index in resources.slots {
		if slot.occupied do continue
		slot.generation = _resource_generation_next(slot.generation)
		slot.entry = entry
		slot.occupied = true
		resources.count += 1
		return _resource_handle_make_context(context_id, index, slot.generation)
	}
	assert(false, "_shader_register: count mismatch")
	return 0
}

@(private)
_shader_slot :: proc(context_id: u32, resources: ^Shader_Resources, id: u32) -> ^Shader_Slot {
	assert(context_id != 0, "_shader_slot: unassigned context id")
	assert(resources != nil, "_shader_slot: nil resources")
	handle_context := (id >> RESOURCE_SLOT_BITS) & RESOURCE_CONTEXT_MASK
	if handle_context != context_id do return nil
	index, generation, ok := _resource_handle_decode(id, len(resources.slots))
	if !ok do return nil
	slot := &resources.slots[index]
	if !slot.occupied || slot.generation != generation do return nil
	return slot
}

@(private)
context_shader_get :: proc(ctx: ^Context, id: u32) -> ^Shader_Entry {
	assert(ctx != nil, "context_shader_get: nil context")
	slot := _shader_slot(ctx.id, &ctx.resources.shaders, id)
	if slot == nil do return nil
	return slot.entry
}

// _default_tex lazily creates a 1×1 white texture to fill unset extra slots.
@(private)
_default_tex :: proc(ctx: ^Context) -> u32 {
	assert(ctx != nil, "_default_tex: nil context")
	if ctx.resources.shaders.default_tex != 0 do return ctx.resources.shaders.default_tex
	px := [4]u8{255, 255, 255, 255}
	img := Image {
		data    = raw_data(px[:]),
		width   = 1,
		height  = 1,
		mipmaps = 1,
		format  = .UNCOMPRESSED_R8G8B8A8,
	}
	t := context_load_texture_from_image(ctx, img)
	ctx.resources.shaders.default_tex = t.id
	return ctx.resources.shaders.default_tex
}

// --- WGSL uniform reflection ------------------------------------------------

@(private)
_wgsl_type_layout :: proc(t: string) -> (size, alignment: u32, ok: bool) {
	switch t {
	case "f32", "i32", "u32":
		return 4, 4, true
	case "vec2<f32>", "vec2<i32>", "vec2<u32>":
		return 8, 8, true
	case "vec3<f32>", "vec3<i32>", "vec3<u32>":
		return 12, 16, true
	case "vec4<f32>", "vec4<i32>", "vec4<u32>":
		return 16, 16, true
	case "mat4x4<f32>":
		return 64, 16, true
	}
	return 0, 0, false
}

@(private)
_shader_checked_align :: proc(value, alignment: u32) -> (aligned: u32, ok: bool) {
	if alignment == 0 || alignment & (alignment - 1) != 0 do return 0, false
	padding := alignment - 1
	if value > max(u32) - padding do return 0, false
	return (value + padding) / alignment * alignment, true
}

@(private)
_shader_uniforms_destroy :: proc(uniforms: []Shader_Uniform) {
	assert(len(uniforms) <= SHADER_UNIFORMS_MAX, "_shader_uniforms_destroy: invalid length")
	for uniform in uniforms do delete(uniform.name)
	delete(uniforms)
}

@(private)
_reflect_uniform_member :: proc(
	raw: string,
	cursor: u32,
) -> (
	uniform: Shader_Uniform,
	end: u32,
	ok: bool,
) {
	member := strings.trim_space(raw)
	colon := strings.index(member, ":")
	if colon <= 0 do return {}, 0, false
	name := strings.trim_space(member[:colon])
	typ := strings.trim_space(member[colon + 1:])
	if len(name) == 0 || len(typ) == 0 do return {}, 0, false
	if space := strings.index(typ, " "); space >= 0 do typ = typ[:space]
	size, alignment, layout_ok := _wgsl_type_layout(typ)
	if !layout_ok do return {}, 0, false
	offset, aligned := _shader_checked_align(cursor, alignment)
	if !aligned || offset > SHADER_UNIFORM_BYTES_MAX do return {}, 0, false
	if size > SHADER_UNIFORM_BYTES_MAX - offset do return {}, 0, false
	uniform = {
		name   = strings.clone(name),
		offset = offset,
		size   = size,
	}
	return uniform, offset + size, true
}

// _reflect_uniforms parses `struct U { name: type, ... }` into offset table.
@(private)
_reflect_uniforms :: proc(src: string) -> (out: []Shader_Uniform, total: u32, ok: bool) {
	list: [dynamic]Shader_Uniform
	si := strings.index(src, "struct U")
	if si < 0 do return list[:], 16, true
	opening := strings.index(src[si:], "{")
	if opening < 0 do return nil, 0, false
	opening += si
	closing := strings.index(src[opening:], "}")
	if closing < 0 do return nil, 0, false
	closing += opening
	cursor: u32
	for raw in strings.split_multi(src[opening + 1:closing], {",", "\n"}, context.temp_allocator) {
		if len(strings.trim_space(raw)) == 0 do continue
		if len(list) >= SHADER_UNIFORMS_MAX {
			_shader_uniforms_destroy(list[:])
			return nil, 0, false
		}
		uniform, end, member_ok := _reflect_uniform_member(raw, cursor)
		if !member_ok {
			_shader_uniforms_destroy(list[:])
			return nil, 0, false
		}
		append(&list, uniform)
		cursor = end
	}
	aligned_total, aligned := _shader_checked_align(cursor, 16)
	if !aligned || aligned_total > SHADER_UNIFORM_BYTES_MAX {
		_shader_uniforms_destroy(list[:])
		return nil, 0, false
	}
	if aligned_total == 0 do aligned_total = 16
	return list[:], aligned_total, true
}

// _reflect_textures finds group(3) texture_2d bindings, in binding order.
@(private)
_reflect_textures :: proc(src: string) -> []string {
	names: [dynamic]string
	rest := src
	for _ in 0 ..< SHADER_MAX_TEX {
		i := strings.index(rest, "@group(3)")
		if i < 0 do break
		line_end := strings.index(rest[i:], ";")
		if line_end < 0 do break
		line := rest[i:i + line_end]
		rest = rest[i + line_end + 1:]
		if !strings.contains(line, "texture_2d") do continue
		// var NAME: texture_2d...
		vk := strings.index(line, "var")
		if vk < 0 do continue
		after := strings.trim_space(line[vk + 3:])
		colon := strings.index(after, ":")
		if colon < 0 do continue
		name := strings.trim_space(after[:colon])
		append(&names, strings.clone(name))
	}
	return names[:]
}

// --- public API -------------------------------------------------------------

@(private)
_shader_source_size_valid :: proc(vertex, fragment: string, combined: bool) -> bool {
	if len(vertex) > SHADER_SOURCE_BYTES_MAX || len(fragment) > SHADER_SOURCE_BYTES_MAX do return false
	separator := 1 if combined else 0
	if len(vertex) > SHADER_SOURCE_BYTES_MAX - separator do return false
	return len(fragment) <= SHADER_SOURCE_BYTES_MAX - separator - len(vertex)
}

@(private)
_shader_uniforms_valid :: proc(uniforms: []Shader_Uniform, total: u32) -> bool {
	if total < 16 || total > SHADER_UNIFORM_BYTES_MAX || total % 16 != 0 do return false
	for uniform in uniforms {
		if uniform.offset > total do return false
		if uniform.size > total - uniform.offset do return false
	}
	return true
}

@(private)
_shader_extra_layout_init :: proc(
	device: wg.Device,
	entry: ^Shader_Entry,
	source: string,
) -> bool {
	assert(device != nil, "_shader_extra_layout_init: nil device")
	assert(entry != nil, "_shader_extra_layout_init: nil entry")
	entry.tex_names = _reflect_textures(source)
	entry.extra_count = len(entry.tex_names)
	if entry.extra_count == 0 do return true
	entries := make([]wg.BindGroupLayoutEntry, entry.extra_count + 1, context.temp_allocator)
	for index in 0 ..< entry.extra_count {
		entries[index] = {
			binding = u32(index),
			visibility = {.Fragment},
			texture = {sampleType = .Float, viewDimension = ._2D},
		}
	}
	entries[entry.extra_count] = {
		binding = u32(entry.extra_count),
		visibility = {.Fragment},
		sampler = {type = .Filtering},
	}
	entry.extra_layout = wg.DeviceCreateBindGroupLayout(
		device,
		&{entryCount = uint(entry.extra_count + 1), entries = raw_data(entries)},
	)
	entry.extra_dirty = entry.extra_layout != nil
	return entry.extra_dirty
}

context_load_shader_from_memory :: proc(ctx: ^Context, vsCode, fsCode: cstring) -> Shader {
	assert(ctx != nil, "context_load_shader_from_memory: nil context")
	if !ctx.initialized do return Shader{}
	vertex := string(vsCode) if vsCode != nil else ""
	fragment := string(fsCode) if fsCode != nil else ""
	combined := vsCode != nil && fsCode != nil
	if vsCode == nil && fsCode == nil do return {}
	if !_shader_source_size_valid(vertex, fragment, combined) do return {}
	src := fragment if vsCode == nil else vertex
	if combined do src = strings.concatenate({vertex, "\n", fragment}, context.temp_allocator)
	uniforms, total, reflected := _reflect_uniforms(src)
	if !reflected || !_shader_uniforms_valid(uniforms, total) {
		_shader_uniforms_destroy(uniforms)
		return {}
	}

	e := new(Shader_Entry)
	e.uniforms = uniforms
	e.ushadow = make([]u8, int(total))
	src_clone := strings.clone(src)
	e.module = wg.DeviceCreateShaderModule(
		ctx.device,
		&{
			nextInChain = &wg.ShaderSourceWGSL {
				chain = {sType = .ShaderSourceWGSL},
				code = src_clone,
			},
		},
	)
	delete(src_clone)
	if e.module == nil {
		_shader_entry_destroy(e)
		return {}
	}

	e.u_layout = wg.DeviceCreateBindGroupLayout(
		ctx.device,
		&{
			entryCount = 1,
			entries = &wg.BindGroupLayoutEntry {
				binding = 0,
				visibility = {.Vertex, .Fragment},
				buffer = {type = .Uniform, hasDynamicOffset = true, minBindingSize = u64(total)},
			},
		},
	)
	if e.u_layout == nil {
		_shader_entry_destroy(e)
		return {}
	}
	for &bind, index in e.u_bind {
		bind = wg.DeviceCreateBindGroup(
			ctx.device,
			&{
				layout = e.u_layout,
				entryCount = 1,
				entries = &wg.BindGroupEntry {
					binding = 0,
					buffer = ctx.rend.stream_slots[index].uniform_buffer,
					size = u64(total),
				},
			},
		)
		if bind == nil {
			_shader_entry_destroy(e)
			return {}
		}
	}

	if !_shader_extra_layout_init(ctx.device, e, src) {
		_shader_entry_destroy(e)
		return {}
	}

	id := _shader_register(ctx.id, &ctx.resources.shaders, e)
	if id == 0 {
		_shader_entry_destroy(e)
		return {}
	}
	return Shader{id = id}
}

LoadShaderFromMemory :: proc(vsCode, fsCode: cstring) -> Shader {
	return context_load_shader_from_memory(default_context(), vsCode, fsCode)
}

@(private)
_shader_entry_destroy :: proc(entry: ^Shader_Entry) {
	assert(entry != nil, "_shader_entry_destroy: nil entry")
	for index in 0 ..< entry.pipe_n {
		if entry.pipe_obj[index] != nil do wg.RenderPipelineRelease(entry.pipe_obj[index])
	}
	if entry.extra_bind != nil do wg.BindGroupRelease(entry.extra_bind)
	if entry.extra_layout != nil do wg.BindGroupLayoutRelease(entry.extra_layout)
	for bind in entry.u_bind {
		if bind != nil do wg.BindGroupRelease(bind)
	}
	if entry.u_layout != nil do wg.BindGroupLayoutRelease(entry.u_layout)
	if entry.module != nil do wg.ShaderModuleRelease(entry.module)
	for uniform in entry.uniforms do delete(uniform.name)
	for name in entry.tex_names do delete(name)
	delete(entry.uniforms)
	delete(entry.tex_names)
	delete(entry.ushadow)
	free(entry)
}

@(private)
_shader_resources_destroy :: proc(resources: ^Shader_Resources) {
	assert(resources != nil, "_shader_resources_destroy: nil resources")
	for &slot in resources.slots {
		if !slot.occupied do continue
		_shader_entry_destroy(slot.entry)
		slot.entry = nil
		slot.occupied = false
	}
	resources^ = {}
}

context_unload_shader :: proc(ctx: ^Context, shader: Shader) {
	assert(ctx != nil, "context_unload_shader: nil context")
	slot := _shader_slot(ctx.id, &ctx.resources.shaders, shader.id)
	if slot == nil do return
	_shader_entry_destroy(slot.entry)
	slot.entry = nil
	slot.occupied = false
	assert(ctx.resources.shaders.count > 0, "context_unload_shader: count underflow")
	ctx.resources.shaders.count -= 1
}

UnloadShader :: proc(shader: Shader) {
	context_unload_shader(default_context(), shader)
}

context_get_shader_location :: proc(ctx: ^Context, shader: Shader, uniformName: cstring) -> i32 {
	assert(ctx != nil, "context_get_shader_location: nil context")
	e := context_shader_get(ctx, shader.id)
	if e == nil do return -1
	name := string(uniformName)
	for u, i in e.uniforms {
		if u.name == name do return i32(i)
	}
	for t, i in e.tex_names {
		if t == name do return i32(SHADER_TEX_LOC_BASE + i)
	}
	return -1
}

GetShaderLocation :: proc(shader: Shader, uniformName: cstring) -> i32 {
	return context_get_shader_location(default_context(), shader, uniformName)
}

context_set_shader_value :: proc(
	ctx: ^Context,
	shader: Shader,
	#any_int locIndex: i32,
	value: rawptr,
	uniformType: ShaderUniformDataType,
) {
	context_set_shader_value_v(ctx, shader, locIndex, value, uniformType, 1)
}

SetShaderValue :: proc(
	shader: Shader,
	#any_int locIndex: i32,
	value: rawptr,
	uniformType: ShaderUniformDataType,
) {
	context_set_shader_value(default_context(), shader, locIndex, value, uniformType)
}

context_set_shader_value_v :: proc(
	ctx: ^Context,
	shader: Shader,
	#any_int locIndex: i32,
	value: rawptr,
	uniformType: ShaderUniformDataType,
	count: i32,
) {
	assert(ctx != nil, "context_set_shader_value_v: nil context")
	if value == nil do return
	e := context_shader_get(ctx, shader.id)
	if e == nil || locIndex < 0 || int(locIndex) >= len(e.uniforms) do return
	element_size, type_ok := _uniform_type_size(uniformType)
	if !type_ok do return
	uniform := e.uniforms[locIndex]
	offset := int(uniform.offset)
	if offset > len(e.ushadow) do return
	if int(uniform.size) > len(e.ushadow) - offset do return
	elements := u64(max(count, 1))
	copy_size := u64(uniform.size)
	if elements <= copy_size / u64(element_size) do copy_size = elements * u64(element_size)
	destination := raw_data(e.ushadow[offset:])
	source := ([^]u8)(value)
	for index in 0 ..< int(copy_size) {
		([^]u8)(destination)[index] = source[index]
	}
}

SetShaderValueV :: proc(
	shader: Shader,
	#any_int locIndex: i32,
	value: rawptr,
	uniformType: ShaderUniformDataType,
	count: i32,
) {
	context_set_shader_value_v(default_context(), shader, locIndex, value, uniformType, count)
}

context_set_shader_value_matrix :: proc(
	ctx: ^Context,
	shader: Shader,
	#any_int locIndex: i32,
	mat: Matrix,
) {
	assert(ctx != nil, "context_set_shader_value_matrix: nil context")
	e := context_shader_get(ctx, shader.id)
	if e == nil || locIndex < 0 || int(locIndex) >= len(e.uniforms) do return
	u := e.uniforms[locIndex]
	if u.size < 64 do return
	m := mat
	src := ([^]u8)(&m)
	dst := raw_data(e.ushadow[u.offset:])
	for i in 0 ..< 64 {
		([^]u8)(dst)[i] = src[i]
	}
}

SetShaderValueMatrix :: proc(shader: Shader, #any_int locIndex: i32, mat: Matrix) {
	context_set_shader_value_matrix(default_context(), shader, locIndex, mat)
}

context_set_shader_value_texture :: proc(
	ctx: ^Context,
	shader: Shader,
	#any_int locIndex: i32,
	texture: Texture2D,
) {
	assert(ctx != nil, "context_set_shader_value_texture: nil context")
	e := context_shader_get(ctx, shader.id)
	if e == nil do return
	slot := int(locIndex) - SHADER_TEX_LOC_BASE
	if slot < 0 || slot >= e.extra_count do return
	if texture.id != 0 && context_get_texture(ctx, texture.id) == nil do return
	if e.extra_tex[slot] != texture.id {
		e.extra_tex[slot] = texture.id
		e.extra_dirty = true
	}
}

SetShaderValueTexture :: proc(shader: Shader, #any_int locIndex: i32, texture: Texture2D) {
	context_set_shader_value_texture(default_context(), shader, locIndex, texture)
}

context_begin_shader_mode :: proc(ctx: ^Context, shader: Shader) {
	assert(ctx != nil, "context_begin_shader_mode: nil context")
	if context_active_pass_begun(ctx) {
		renderer_flush(ctx, &ctx.rend, context_active_pass(ctx), .Shader)
	}
	ctx.rend.active_shader = shader.id
}

BeginShaderMode :: proc(shader: Shader) {
	context_begin_shader_mode(default_context(), shader)
}

context_end_shader_mode :: proc(ctx: ^Context) {
	assert(ctx != nil, "context_end_shader_mode: nil context")
	if context_active_pass_begun(ctx) {
		renderer_flush(ctx, &ctx.rend, context_active_pass(ctx), .Shader)
	}
	ctx.rend.active_shader = 0
}

EndShaderMode :: proc() {
	context_end_shader_mode(default_context())
}

// ShaderBindRaw / ShaderUnbindRaw back rlgl.EnableShader/DisableShader: the raw
// program id equals the registry id assigned by LoadShaderFromMemory.
context_shader_bind_raw :: proc(ctx: ^Context, id: u32) {
	assert(ctx != nil, "context_shader_bind_raw: nil context")
	if context_active_pass_begun(ctx) {
		renderer_flush(ctx, &ctx.rend, context_active_pass(ctx), .Shader)
	}
	ctx.rend.active_shader = id
}

ShaderBindRaw :: proc(id: u32) {
	context_shader_bind_raw(default_context(), id)
}

context_shader_unbind_raw :: proc(ctx: ^Context) {
	assert(ctx != nil, "context_shader_unbind_raw: nil context")
	if context_active_pass_begun(ctx) {
		renderer_flush(ctx, &ctx.rend, context_active_pass(ctx), .Shader)
	}
	ctx.rend.active_shader = 0
}

ShaderUnbindRaw :: proc() {
	context_shader_unbind_raw(default_context())
}

@(private)
_uniform_type_size :: proc(t: ShaderUniformDataType) -> (size: u32, ok: bool) {
	switch t {
	case .FLOAT, .INT:
		return 4, true
	case .VEC2, .IVEC2:
		return 8, true
	case .VEC3, .IVEC3:
		return 12, true
	case .VEC4, .IVEC4:
		return 16, true
	case .SAMPLER2D:
		return 4, true
	}
	return 0, false
}

// _shader_pipeline returns (building if needed) the pipeline for `fmt`.
@(private)
_shader_pipeline :: proc(
	ctx: ^Context,
	e: ^Shader_Entry,
	format: wg.TextureFormat,
) -> wg.RenderPipeline {
	assert(ctx != nil, "_shader_pipeline: nil context")
	for i in 0 ..< e.pipe_n {
		if e.pipe_fmt[i] == format do return e.pipe_obj[i]
	}
	if e.pipe_n >= len(e.pipe_obj) do return nil

	attrs := [4]wg.VertexAttribute {
		{format = .Float32x2, offset = 0, shaderLocation = 0},
		{format = .Float32x4, offset = u64(offset_of(Vertex, col)), shaderLocation = 1},
		{format = .Float32x2, offset = u64(offset_of(Vertex, uv)), shaderLocation = 2},
		{format = .Uint32, offset = u64(offset_of(Vertex, mode)), shaderLocation = 3},
	}
	vbl := wg.VertexBufferLayout {
		arrayStride    = size_of(Vertex),
		stepMode       = .Vertex,
		attributeCount = 4,
		attributes     = raw_data(attrs[:]),
	}
	blend := _blend_for(&ctx.rend, ctx.rend.cur_blend)
	target := wg.ColorTargetState {
		format    = format,
		writeMask = wg.ColorWriteMaskFlags_All,
	}
	if _format_blendable(format) do target.blend = &blend

	layouts: [4]wg.BindGroupLayout
	n_layouts := 3
	layouts[0] = ctx.rend.ubind_layout
	layouts[1] = ctx.rend.tex_layout
	layouts[2] = e.u_layout
	if e.extra_count > 0 {
		layouts[3] = e.extra_layout
		n_layouts = 4
	}
	pl := wg.DeviceCreatePipelineLayout(
		ctx.device,
		&{bindGroupLayoutCount = uint(n_layouts), bindGroupLayouts = raw_data(layouts[:])},
	)
	pipe := wg.DeviceCreateRenderPipeline(
		ctx.device,
		&{
			layout = pl,
			vertex = {module = e.module, entryPoint = "vs_main", bufferCount = 1, buffers = &vbl},
			primitive = {topology = .TriangleList, frontFace = .CCW, cullMode = .None},
			multisample = {count = 1, mask = ~u32(0)},
			fragment = &wg.FragmentState {
				module = e.module,
				entryPoint = "fs_main",
				targetCount = 1,
				targets = &target,
			},
		},
	)
	wg.PipelineLayoutRelease(pl)
	e.pipe_fmt[e.pipe_n] = format
	e.pipe_obj[e.pipe_n] = pipe
	e.pipe_n += 1
	return pipe
}

@(private)
_shader_rebuild_extra :: proc(ctx: ^Context, e: ^Shader_Entry) {
	assert(ctx != nil, "_shader_rebuild_extra: nil context")
	if e.extra_count == 0 do return
	if e.extra_bind != nil do wg.BindGroupRelease(e.extra_bind)
	entries := make([]wg.BindGroupEntry, e.extra_count + 1, context.temp_allocator)
	// shared sampler from the first bound (or default) texture
	samp: wg.Sampler
	for i in 0 ..< e.extra_count {
		id := e.extra_tex[i]
		if id == 0 do id = _default_tex(ctx)
		te := context_get_texture(ctx, id)
		if te == nil {te = context_get_texture(ctx, _default_tex(ctx))}
		entries[i] = {
			binding     = u32(i),
			textureView = te.view,
		}
		if samp == nil do samp = te.sampler
	}
	if samp == nil {
		dt := context_get_texture(ctx, _default_tex(ctx))
		if dt != nil do samp = dt.sampler
	}
	entries[e.extra_count] = {
		binding = u32(e.extra_count),
		sampler = samp,
	}
	e.extra_bind = wg.DeviceCreateBindGroup(
		ctx.device,
		&{
			layout = e.extra_layout,
			entryCount = uint(e.extra_count + 1),
			entries = raw_data(entries),
		},
	)
	e.extra_dirty = false
}

// _shader_flush records the pending run through the active custom shader.
// Returns true if it handled the draw.
@(private)
_shader_flush :: proc(
	ctx: ^Context,
	r: ^Renderer,
	pass: wg.RenderPassEncoder,
	vbuf: wg.Buffer,
	vertex_offset: u64,
	ibuf: wg.Buffer,
	index_offset: u64,
	index_count: u32,
) -> bool {
	assert(ctx != nil, "_shader_flush: nil context")
	assert(r == &ctx.rend, "_shader_flush: foreign renderer")
	e := context_shader_get(ctx, r.active_shader)
	if e == nil do return false
	format := _cur_target_format(ctx)
	pipe := _shader_pipeline(ctx, e, format)
	if pipe == nil do return false

	u_offset, ok := _uniform_upload(ctx, r, raw_data(e.ushadow), u64(len(e.ushadow)))
	if !ok do return false
	if e.extra_dirty do _shader_rebuild_extra(ctx, e)

	wg.RenderPassEncoderSetPipeline(pass, pipe)
	_stats_pipeline_switch(ctx)
	wg.RenderPassEncoderSetBindGroup(pass, 0, r.cur_u != nil ? r.cur_u : r.ubind)
	_stats_bind_group_switches(ctx, 1)
	if r.cur_bind != nil {
		wg.RenderPassEncoderSetBindGroup(pass, 1, r.cur_bind)
		_stats_bind_group_switches(ctx, 1)
	}
	if r.active_stream_slot < 0 do return false
	wg.RenderPassEncoderSetBindGroup(pass, 2, e.u_bind[r.active_stream_slot], {u_offset})
	_stats_bind_group_switches(ctx, 1)
	if e.extra_count > 0 && e.extra_bind != nil {
		wg.RenderPassEncoderSetBindGroup(pass, 3, e.extra_bind)
		_stats_bind_group_switches(ctx, 1)
	}
	wg.RenderPassEncoderSetVertexBuffer(pass, 0, vbuf, vertex_offset, wg.WHOLE_SIZE)
	wg.RenderPassEncoderSetIndexBuffer(pass, ibuf, .Uint32, index_offset, wg.WHOLE_SIZE)
	wg.RenderPassEncoderDrawIndexed(pass, index_count, 1, 0, 0, 0)
	return true
}
