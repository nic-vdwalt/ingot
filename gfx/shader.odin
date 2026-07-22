// ingot:gfx — custom shader objects (raylib Shader parity) over WebGPU. Backs
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
	pipe_fmt:  [8]wg.TextureFormat,
	pipe_obj:  [8]wg.RenderPipeline,
	pipe_n:    int,
}

@(private) g_shaders: [dynamic]^Shader_Entry
@(private) g_default_tex: u32

@(private)
_shader_get :: proc(id: u32) -> ^Shader_Entry {
	if id == 0 do return nil
	idx := int(id - 1)
	if idx < 0 || idx >= len(g_shaders) do return nil
	return g_shaders[idx]
}

// _default_tex lazily creates a 1×1 white texture to fill unset extra slots.
@(private)
_default_tex :: proc() -> u32 {
	if g_default_tex != 0 do return g_default_tex
	px := [4]u8{255, 255, 255, 255}
	img := Image{data = raw_data(px[:]), width = 1, height = 1, mipmaps = 1, format = .UNCOMPRESSED_R8G8B8A8}
	t := LoadTextureFromImage(img)
	g_default_tex = t.id
	return g_default_tex
}

// --- WGSL uniform reflection ------------------------------------------------

@(private)
_wgsl_type_layout :: proc(t: string) -> (size, align: u32) {
	switch t {
	case "f32", "i32", "u32":                      return 4, 4
	case "vec2<f32>", "vec2<i32>", "vec2<u32>":    return 8, 8
	case "vec3<f32>", "vec3<i32>", "vec3<u32>":    return 12, 16
	case "vec4<f32>", "vec4<i32>", "vec4<u32>":    return 16, 16
	case "mat4x4<f32>":                            return 64, 16
	}
	return 4, 4
}

@(private)
_align_up :: proc(v, a: u32) -> u32 {
	if a == 0 do return v
	return (v + a - 1) / a * a
}

// _reflect_uniforms parses `struct U { name: type, ... }` into offset table.
@(private)
_reflect_uniforms :: proc(src: string) -> (out: []Shader_Uniform, total: u32) {
	list: [dynamic]Shader_Uniform
	si := strings.index(src, "struct U")
	if si < 0 do return list[:], 0
	ob := strings.index(src[si:], "{")
	if ob < 0 do return list[:], 0
	ob += si
	cb := strings.index(src[ob:], "}")
	if cb < 0 do return list[:], 0
	cb += ob
	body := src[ob + 1:cb]
	cursor: u32 = 0
	// members separated by ',' or newlines
	for raw in strings.split_multi(body, {",", "\n"}, context.temp_allocator) {
		m := strings.trim_space(raw)
		if len(m) == 0 do continue
		colon := strings.index(m, ":")
		if colon < 0 do continue
		name := strings.trim_space(m[:colon])
		typ := strings.trim_space(m[colon + 1:])
		// strip trailing tokens/comments
		if sp := strings.index(typ, " "); sp >= 0 do typ = typ[:sp]
		sz, al := _wgsl_type_layout(typ)
		off := _align_up(cursor, al)
		append(&list, Shader_Uniform{name = strings.clone(name), offset = off, size = sz})
		cursor = off + sz
	}
	total = _align_up(cursor, 16)
	if total == 0 do total = 16
	return list[:], total
}

// _reflect_textures finds group(3) texture_2d bindings, in binding order.
@(private)
_reflect_textures :: proc(src: string) -> []string {
	names: [dynamic]string
	rest := src
	for {
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
		if len(names) >= SHADER_MAX_TEX do break
	}
	return names[:]
}

// --- public API -------------------------------------------------------------

LoadShaderFromMemory :: proc(vsCode, fsCode: cstring) -> Shader {
	if !g.initialized do return Shader{}
	// Build the full WGSL module source. Fullscreen passes provide the whole
	// module in fsCode; 3D shaders provide vs+fs which are concatenated.
	src: string
	if vsCode != nil && fsCode != nil {
		src = strings.concatenate({string(vsCode), "\n", string(fsCode)}, context.temp_allocator)
	} else if fsCode != nil {
		src = string(fsCode)
	} else if vsCode != nil {
		src = string(vsCode)
	} else {
		return Shader{}
	}

	e := new(Shader_Entry)
	src_clone := strings.clone(src)
	e.module = wg.DeviceCreateShaderModule(g.device, &{
		nextInChain = &wg.ShaderSourceWGSL{
			chain = {sType = .ShaderSourceWGSL},
			code  = src_clone,
		},
	})
	e.uniforms, _ = _reflect_uniforms(src)
	total: u32 = 16
	for u in e.uniforms {
		if u.offset + u.size > total do total = u.offset + u.size
	}
	total = _align_up(total, 16)
	e.ushadow = make([]u8, int(total))

	e.u_layout = wg.DeviceCreateBindGroupLayout(g.device, &{
		entryCount = 1,
		entries = &wg.BindGroupLayoutEntry{
			binding = 0,
			visibility = {.Vertex, .Fragment},
			buffer = {
				type = .Uniform,
				hasDynamicOffset = true,
				minBindingSize = u64(total),
			},
		},
	})
	for &bind, index in e.u_bind {
		bind = wg.DeviceCreateBindGroup(g.device, &{
			layout = e.u_layout,
			entryCount = 1,
			entries = &wg.BindGroupEntry{
				binding = 0,
				buffer = g.rend.stream_slots[index].uniform_buffer,
				size = u64(total),
			},
		})
	}

	e.tex_names = _reflect_textures(src)
	e.extra_count = len(e.tex_names)
	if e.extra_count > 0 {
		entries := make([]wg.BindGroupLayoutEntry, e.extra_count + 1, context.temp_allocator)
		for i in 0 ..< e.extra_count {
			entries[i] = {
				binding = u32(i),
				visibility = {.Fragment},
				texture = {sampleType = .Float, viewDimension = ._2D},
			}
		}
		entries[e.extra_count] = {
			binding = u32(e.extra_count),
			visibility = {.Fragment},
			sampler = {type = .Filtering},
		}
		e.extra_layout = wg.DeviceCreateBindGroupLayout(g.device, &{
			entryCount = uint(e.extra_count + 1), entries = raw_data(entries),
		})
		e.extra_dirty = true
	}

	append(&g_shaders, e)
	id := u32(len(g_shaders))
	return Shader{id = id}
}

UnloadShader :: proc(shader: Shader) {
	e := _shader_get(shader.id)
	if e == nil do return
	for i in 0 ..< e.pipe_n {
		if e.pipe_obj[i] != nil do wg.RenderPipelineRelease(e.pipe_obj[i])
	}
	if e.extra_bind != nil do wg.BindGroupRelease(e.extra_bind)
	if e.extra_layout != nil do wg.BindGroupLayoutRelease(e.extra_layout)
	for bind in e.u_bind {
		if bind != nil do wg.BindGroupRelease(bind)
	}
	if e.u_layout != nil do wg.BindGroupLayoutRelease(e.u_layout)
	if e.module != nil do wg.ShaderModuleRelease(e.module)
	delete(e.ushadow)
	g_shaders[shader.id - 1] = nil
	free(e)
}

GetShaderLocation :: proc(shader: Shader, uniformName: cstring) -> i32 {
	e := _shader_get(shader.id)
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

SetShaderValue :: proc(shader: Shader, #any_int locIndex: i32, value: rawptr, uniformType: ShaderUniformDataType) {
	SetShaderValueV(shader, locIndex, value, uniformType, 1)
}

SetShaderValueV :: proc(shader: Shader, #any_int locIndex: i32, value: rawptr, uniformType: ShaderUniformDataType, count: i32) {
	e := _shader_get(shader.id)
	if e == nil || locIndex < 0 || int(locIndex) >= len(e.uniforms) do return
	u := e.uniforms[locIndex]
	sz := _uniform_type_size(uniformType) * u32(max(count, 1))
	if sz > u.size do sz = u.size
	dst := raw_data(e.ushadow[u.offset:])
	src := ([^]u8)(value)
	for i in 0 ..< int(sz) {
		([^]u8)(dst)[i] = src[i]
	}
}

SetShaderValueMatrix :: proc(shader: Shader, #any_int locIndex: i32, mat: Matrix) {
	e := _shader_get(shader.id)
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

SetShaderValueTexture :: proc(shader: Shader, #any_int locIndex: i32, texture: Texture2D) {
	e := _shader_get(shader.id)
	if e == nil do return
	slot := int(locIndex) - SHADER_TEX_LOC_BASE
	if slot < 0 || slot >= e.extra_count do return
	if e.extra_tex[slot] != texture.id {
		e.extra_tex[slot] = texture.id
		e.extra_dirty = true
	}
}

BeginShaderMode :: proc(shader: Shader) {
	if _active_pass_begun() do renderer_flush(&g.rend, active_pass(), .Shader)
	g.rend.active_shader = shader.id
}

EndShaderMode :: proc() {
	if _active_pass_begun() do renderer_flush(&g.rend, active_pass(), .Shader)
	g.rend.active_shader = 0
}

// ShaderBindRaw / ShaderUnbindRaw back rlgl.EnableShader/DisableShader: the raw
// program id equals the registry id assigned by LoadShaderFromMemory.
ShaderBindRaw :: proc(id: u32) {
	if _active_pass_begun() do renderer_flush(&g.rend, active_pass(), .Shader)
	g.rend.active_shader = id
}
ShaderUnbindRaw :: proc() {
	if _active_pass_begun() do renderer_flush(&g.rend, active_pass(), .Shader)
	g.rend.active_shader = 0
}

@(private)
_uniform_type_size :: proc(t: ShaderUniformDataType) -> u32 {
	switch t {
	case .FLOAT, .INT:            return 4
	case .VEC2, .IVEC2:          return 8
	case .VEC3, .IVEC3:          return 12
	case .VEC4, .IVEC4:          return 16
	case .SAMPLER2D:             return 4
	}
	return 4
}

// _shader_pipeline returns (building if needed) the pipeline for `fmt`.
@(private)
_shader_pipeline :: proc(e: ^Shader_Entry, format: wg.TextureFormat) -> wg.RenderPipeline {
	for i in 0 ..< e.pipe_n {
		if e.pipe_fmt[i] == format do return e.pipe_obj[i]
	}
	if e.pipe_n >= len(e.pipe_obj) do return nil

	attrs := [3]wg.VertexAttribute{
		{format = .Float32x2, offset = 0, shaderLocation = 0},
		{format = .Float32x4, offset = u64(offset_of(Vertex, col)), shaderLocation = 1},
		{format = .Float32x2, offset = u64(offset_of(Vertex, uv)), shaderLocation = 2},
	}
	vbl := wg.VertexBufferLayout{
		arrayStride = size_of(Vertex), stepMode = .Vertex,
		attributeCount = 3, attributes = raw_data(attrs[:]),
	}
	blend := _blend_for(&g.rend, g.rend.cur_blend)
	target := wg.ColorTargetState{format = format, writeMask = wg.ColorWriteMaskFlags_All}
	if _format_blendable(format) do target.blend = &blend

	layouts: [4]wg.BindGroupLayout
	n_layouts := 3
	layouts[0] = g.rend.ubind_layout
	layouts[1] = g.rend.tex_layout
	layouts[2] = e.u_layout
	if e.extra_count > 0 {
		layouts[3] = e.extra_layout
		n_layouts = 4
	}
	pl := wg.DeviceCreatePipelineLayout(g.device, &{
		bindGroupLayoutCount = uint(n_layouts),
		bindGroupLayouts = raw_data(layouts[:]),
	})
	pipe := wg.DeviceCreateRenderPipeline(g.device, &{
		layout = pl,
		vertex = {module = e.module, entryPoint = "vs_main", bufferCount = 1, buffers = &vbl},
		primitive = {topology = .TriangleList, frontFace = .CCW, cullMode = .None},
		multisample = {count = 1, mask = ~u32(0)},
		fragment = &wg.FragmentState{module = e.module, entryPoint = "fs_main", targetCount = 1, targets = &target},
	})
	e.pipe_fmt[e.pipe_n] = format
	e.pipe_obj[e.pipe_n] = pipe
	e.pipe_n += 1
	return pipe
}

@(private)
_shader_rebuild_extra :: proc(e: ^Shader_Entry) {
	if e.extra_count == 0 do return
	if e.extra_bind != nil do wg.BindGroupRelease(e.extra_bind)
	entries := make([]wg.BindGroupEntry, e.extra_count + 1, context.temp_allocator)
	// shared sampler from the first bound (or default) texture
	samp: wg.Sampler
	for i in 0 ..< e.extra_count {
		id := e.extra_tex[i]
		if id == 0 do id = _default_tex()
		te := get_texture(id)
		if te == nil { te = get_texture(_default_tex()) }
		entries[i] = {binding = u32(i), textureView = te.view}
		if samp == nil do samp = te.sampler
	}
	if samp == nil {
		dt := get_texture(_default_tex())
		if dt != nil do samp = dt.sampler
	}
	entries[e.extra_count] = {binding = u32(e.extra_count), sampler = samp}
	e.extra_bind = wg.DeviceCreateBindGroup(g.device, &{
		layout = e.extra_layout, entryCount = uint(e.extra_count + 1), entries = raw_data(entries),
	})
	e.extra_dirty = false
}

// _shader_flush records the pending run through the active custom shader.
// Returns true if it handled the draw.
@(private)
_shader_flush :: proc(
	r: ^Renderer,
	pass: wg.RenderPassEncoder,
	vbuf: wg.Buffer,
	vertex_offset: u64,
	ibuf: wg.Buffer,
	index_offset: u64,
	index_count: u32,
) -> bool {
	e := _shader_get(r.active_shader)
	if e == nil do return false
	format := _cur_target_format()
	pipe := _shader_pipeline(e, format)
	if pipe == nil do return false

	u_offset, ok := _uniform_upload(r, raw_data(e.ushadow), u64(len(e.ushadow)))
	if !ok do return false
	if e.extra_dirty do _shader_rebuild_extra(e)

	wg.RenderPassEncoderSetPipeline(pass, pipe)
	_stats_pipeline_switch()
	wg.RenderPassEncoderSetBindGroup(pass, 0, r.cur_u != nil ? r.cur_u : r.ubind)
	_stats_bind_group_switches(1)
	if r.cur_bind != nil {
		wg.RenderPassEncoderSetBindGroup(pass, 1, r.cur_bind)
		_stats_bind_group_switches(1)
	}
	if r.active_stream_slot < 0 do return false
	wg.RenderPassEncoderSetBindGroup(pass, 2, e.u_bind[r.active_stream_slot], {u_offset})
	_stats_bind_group_switches(1)
	if e.extra_count > 0 && e.extra_bind != nil {
		wg.RenderPassEncoderSetBindGroup(pass, 3, e.extra_bind)
		_stats_bind_group_switches(1)
	}
	wg.RenderPassEncoderSetVertexBuffer(pass, 0, vbuf, vertex_offset, wg.WHOLE_SIZE)
	wg.RenderPassEncoderSetIndexBuffer(pass, ibuf, .Uint32, index_offset, wg.WHOLE_SIZE)
	wg.RenderPassEncoderDrawIndexed(pass, index_count, 1, 0, 0, 0)
	return true
}
