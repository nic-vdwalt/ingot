// Pinned WebGPU replay of one captured selected-window pass.
//
// Consumes a bundle written by tests/metal_timestamps/export_replay_bundle.py:
// the captured WGSL, per-draw vertex/index bytes, projection words, atlas
// pixels, retained pipeline descriptors, attachment clear words and the
// single-span submission topology. It opens a real window through ingot:gfx
// (the attachment the game timed is the swapchain texture), then re-encodes
// the pass itself against the pinned wgpu so no batch-renderer state is
// involved: one timed render pass, resolve + copy in the same encoder, one
// submit, one map request, exactly the recorded topology. Every iteration
// records command status, error-scope messages, the raw resolved ticks and
// the prior physical readback contents before the slot is reused.
//
// This is experiment 1 of the attribution step: an unpatched pinned replay.
// It is diagnostic only and must never be mistaken for a production path.
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:sync"
import "core:time"
import rl "ingot:gfx"
import wg "vendor:wgpu"

QUERY_COUNT :: 128
SLOTS :: 8
ATLAS_DIM :: 2048
// Bounded so an unresponsive device fails the run instead of hanging it.
DRAIN_POLLS :: 4096
VERTEX_STRIDE :: 36

SAMPLE_FORMAT ::
	`{{"kind":"sample","iteration":%d,"slot":%d,"submit":%d,"resolve_submit":%d,` +
	`"completion_status":%d,"status":%d,"mapped":%v,"begin":%d,"end":%d,` +
	`"indices":[0,1],"gpu_samples":[%d,%d],"cpu_samples":[%d,%d],` +
	`"prior_cpu_samples":[%d,%d],"prior_begin":%d,"prior_end":%d,` +
	`"prior_kind":"%s","class":"%s","final_drain":%v}}`
HEADER_FORMAT ::
	`{{"kind":"header","mode":%q,"experiment":%q,"bundle":%q,"frame":%d,` +
	`"iterations":%d,"fb_width":%d,"fb_height":%d,"format":%d,` +
	`"timestamp_period_ns":%v,"draws":%d,"started":%q}}`

Manifest_Attribute :: struct {
	format:          u32,
	offset:          u64,
	shader_location: u32,
}

Manifest_Blend :: struct {
	operation:  u32,
	src_factor: u32,
	dst_factor: u32,
}

Manifest_Pipeline :: struct {
	format:        u32,
	vertex_stride: u64,
	step_mode:     u32,
	attributes:    []Manifest_Attribute,
	topology:      u32,
	front_face:    u32,
	cull_mode:     u32,
	sample_count:  u32,
	sample_mask:   u32,
	blend_enabled: bool,
	blend_color:   Manifest_Blend,
	blend_alpha:   Manifest_Blend,
	write_mask:    u32,
}

Manifest_Atlas_Ref :: struct {
	atlas_id: u32,
	filter:   u32,
}

Manifest_Draw :: struct {
	vertices:       string,
	indices:        string,
	index_count:    u32,
	fragment_entry: string,
	pipeline:       Manifest_Pipeline,
	atlas:          Maybe(Manifest_Atlas_Ref),
	scissor:        [4]u32,
}

Manifest_Attachment :: struct {
	width:            u32,
	height:           u32,
	format:           u32,
	load:             u32,
	store:            u32,
	sample_count:     u32,
	color_clear_bits: [4]u64,
}

Manifest_Atlas :: struct {
	file:          string,
	width:         u32,
	height:        u32,
	upload_prefix: u32,
	sha256:        string,
}

Manifest :: struct {
	bundle_version:  u32,
	frame:           u64,
	slot_index:      u32,
	attachment:      Manifest_Attachment,
	projection_bits: [4]u32,
	shader:          string,
	shader_sha256:   string,
	atlases:         map[string]Manifest_Atlas,
	draws:           []Manifest_Draw,
}

// One map registration. Same ownership discipline as gfx: armed before the
// request, published by the callback with a release store, retired by the
// collector after consumption.
Map_Record :: struct {
	ticks:  [4]u64,
	status: wg.MapAsyncStatus,
	mapped: bool,
	armed:  bool,
	done:   bool,
}

Work_Record :: struct {
	status: wg.QueueWorkDoneStatus,
	armed:  bool,
	done:   bool,
}

Slot :: struct {
	readback:          wg.Buffer,
	record:            Map_Record,
	work:              Work_Record,
	iteration:         int,
	submit:            u64,
	resolve_submit:    u64,
	completion_status: wg.QueueWorkDoneStatus,
	prior:             [2]u64,
	prior_kind:        string,
}

Error_Scope :: struct {
	messages: [dynamic]string,
	done:     bool,
}

Replay :: struct {
	ctx:              ^rl.Context,
	manifest:         Manifest,
	completion_gated: bool,
	shader:           wg.ShaderModule,
	ubind_lay:        wg.BindGroupLayout,
	tex_lay:          wg.BindGroupLayout,
	ubuf:             wg.Buffer,
	ubind:            wg.BindGroup,
	neutral:          wg.BindGroup,
	atlas_bind:       map[u32]wg.BindGroup,
	pipelines:        []wg.RenderPipeline,
	vbufs:            []wg.Buffer,
	ibufs:            []wg.Buffer,
	query_set:        wg.QuerySet,
	resolve:          wg.Buffer,
	slots:            [SLOTS]Slot,
	out:              ^os.File,
	period:           f64,
	submits:          u64,
	errors:           Error_Scope,
}

work_done :: proc "c" (
	status: wg.QueueWorkDoneStatus,
	message: wg.StringView,
	userdata1, userdata2: rawptr,
) {
	record := cast(^Work_Record)userdata1
	if record == nil || !sync.atomic_load(&record.armed) || sync.atomic_load(&record.done) do return
	record.status = status
	sync.atomic_store_explicit(&record.done, true, .Release)
}

map_done :: proc "c" (
	status: wg.MapAsyncStatus,
	message: wg.StringView,
	userdata1, userdata2: rawptr,
) {
	record := cast(^Map_Record)userdata1
	if record == nil || !sync.atomic_load(&record.armed) || sync.atomic_load(&record.done) do return
	record.status = status
	record.mapped = false
	if status == .Success {
		slot := cast(^Slot)userdata2
		mapped := wg.BufferGetConstMappedRange(slot.readback, 0, 32)
		if mapped != nil && len(mapped) >= 32 {
			words := cast(^[4]u64)raw_data(mapped)
			record.ticks = words^
			record.mapped = true
		}
	}
	sync.atomic_store_explicit(&record.done, true, .Release)
}

error_popped :: proc "c" (
	status: wg.PopErrorScopeStatus,
	type: wg.ErrorType,
	message: wg.StringView,
	userdata1, userdata2: rawptr,
) {
	context = {}
	scope := cast(^Error_Scope)userdata1
	if scope == nil do return
	if type != .NoError {
		append(&scope.messages, fmt.aprintf("%v: %s", type, message))
	}
	scope.done = true
}

read_file :: proc(dir, name: string) -> []u8 {
	path := fmt.tprintf("%s/%s", dir, name)
	data, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil {
		fmt.eprintfln("replay: cannot read %s", path)
		os.exit(2)
	}
	return data
}

load_manifest :: proc(dir: string) -> Manifest {
	data := read_file(dir, "manifest.json")
	manifest: Manifest
	if err := json.unmarshal(data, &manifest); err != nil {
		fmt.eprintfln("replay: manifest parse failed: %v", err)
		os.exit(2)
	}
	if manifest.bundle_version != 1 || len(manifest.draws) == 0 {
		fmt.eprintln("replay: unsupported bundle")
		os.exit(2)
	}
	return manifest
}

make_layouts :: proc(r: ^Replay) {
	device := r.ctx.device
	r.ubind_lay = wg.DeviceCreateBindGroupLayout(
		device,
		&{
			entryCount = 1,
			entries = &wg.BindGroupLayoutEntry {
				binding = 0,
				visibility = {.Vertex},
				buffer = {type = .Uniform, minBindingSize = size_of([4]f32)},
			},
		},
	)
	tex_entries := [2]wg.BindGroupLayoutEntry {
		{
			binding = 0,
			visibility = {.Vertex, .Fragment},
			texture = {sampleType = .Float, viewDimension = ._2D},
		},
		{binding = 1, visibility = {.Vertex, .Fragment}, sampler = {type = .Filtering}},
	}
	r.tex_lay = wg.DeviceCreateBindGroupLayout(
		device,
		&{entryCount = 2, entries = raw_data(tex_entries[:])},
	)
	r.ubuf = wg.DeviceCreateBuffer(device, &{usage = {.Uniform, .CopyDst}, size = 16})
	projection := r.manifest.projection_bits
	wg.QueueWriteBuffer(r.ctx.queue, r.ubuf, 0, &projection, 16)
	r.ubind = wg.DeviceCreateBindGroup(
		device,
		&{
			layout = r.ubind_lay,
			entryCount = 1,
			entries = &wg.BindGroupEntry{binding = 0, buffer = r.ubuf, size = 16},
		},
	)
	assert(r.ubind_lay != nil && r.tex_lay != nil && r.ubuf != nil && r.ubind != nil)
}

make_texture_bind :: proc(
	r: ^Replay,
	format: wg.TextureFormat,
	width, height: u32,
	pixels: []u8,
	bytes_per_row: u32,
	filter: wg.FilterMode,
) -> wg.BindGroup {
	device := r.ctx.device
	texture := wg.DeviceCreateTexture(
		device,
		&{
			usage = {.TextureBinding, .CopyDst},
			dimension = ._2D,
			size = {width, height, 1},
			format = format,
			mipLevelCount = 1,
			sampleCount = 1,
		},
	)
	assert(texture != nil, "replay: texture creation failed")
	wg.QueueWriteTexture(
		r.ctx.queue,
		&{texture = texture},
		raw_data(pixels),
		uint(len(pixels)),
		&{bytesPerRow = bytes_per_row, rowsPerImage = height},
		&{width, height, 1},
	)
	view := wg.TextureCreateView(texture, nil)
	sampler := wg.DeviceCreateSampler(
		device,
		&{
			magFilter = filter,
			minFilter = filter,
			mipmapFilter = .Nearest,
			addressModeU = .ClampToEdge,
			addressModeV = .ClampToEdge,
			addressModeW = .ClampToEdge,
			maxAnisotropy = 1,
		},
	)
	entries := [2]wg.BindGroupEntry {
		{binding = 0, textureView = view},
		{binding = 1, sampler = sampler},
	}
	bind := wg.DeviceCreateBindGroup(
		device,
		&{layout = r.tex_lay, entryCount = 2, entries = raw_data(entries[:])},
	)
	assert(bind != nil, "replay: bind group creation failed")
	return bind
}

make_textures :: proc(r: ^Replay, dir: string) {
	white := [4]u8{255, 255, 255, 255}
	r.neutral = make_texture_bind(r, .RGBA8Unorm, 1, 1, white[:], 4, .Nearest)
	r.atlas_bind = make(map[u32]wg.BindGroup)
	for draw in r.manifest.draws {
		ref, textured := draw.atlas.?
		if !textured do continue
		if ref.atlas_id in r.atlas_bind do continue
		entry, known := r.manifest.atlases[fmt.tprintf("%d", ref.atlas_id)]
		if !known || entry.width != ATLAS_DIM || entry.height != ATLAS_DIM {
			fmt.eprintln("replay: atlas missing from bundle")
			os.exit(2)
		}
		pixels := read_file(dir, entry.file)
		assert(len(pixels) == ATLAS_DIM * ATLAS_DIM, "replay: atlas byte count")
		// Filter 0 is POINT in the batch renderer; anything else samples linearly.
		filter: wg.FilterMode = ref.filter == 0 ? .Nearest : .Linear
		r.atlas_bind[ref.atlas_id] = make_texture_bind(
			r,
			.R8Unorm,
			ATLAS_DIM,
			ATLAS_DIM,
			pixels,
			ATLAS_DIM,
			filter,
		)
	}
}

blend_component :: proc(blend: Manifest_Blend) -> wg.BlendComponent {
	return {
		operation = wg.BlendOperation(blend.operation),
		srcFactor = wg.BlendFactor(blend.src_factor),
		dstFactor = wg.BlendFactor(blend.dst_factor),
	}
}

make_pipeline :: proc(r: ^Replay, draw: Manifest_Draw) -> wg.RenderPipeline {
	device := r.ctx.device
	descriptor := draw.pipeline
	assert(descriptor.vertex_stride == VERTEX_STRIDE, "replay: vertex stride")
	assert(len(descriptor.attributes) == 4, "replay: attribute count")
	attrs: [4]wg.VertexAttribute
	for attribute, index in descriptor.attributes {
		attrs[index] = {
			format         = wg.VertexFormat(attribute.format),
			offset         = attribute.offset,
			shaderLocation = attribute.shader_location,
		}
	}
	vbl := wg.VertexBufferLayout {
		arrayStride    = descriptor.vertex_stride,
		stepMode       = wg.VertexStepMode(descriptor.step_mode),
		attributeCount = 4,
		attributes     = raw_data(attrs[:]),
	}
	blend := wg.BlendState {
		color = blend_component(descriptor.blend_color),
		alpha = blend_component(descriptor.blend_alpha),
	}
	target := wg.ColorTargetState {
		format    = wg.TextureFormat(descriptor.format),
		writeMask = transmute(wg.ColorWriteMaskFlags)u64(descriptor.write_mask),
	}
	if descriptor.blend_enabled do target.blend = &blend
	layouts := [2]wg.BindGroupLayout{r.ubind_lay, r.tex_lay}
	layout := wg.DeviceCreatePipelineLayout(
		device,
		&{bindGroupLayoutCount = 2, bindGroupLayouts = raw_data(layouts[:])},
	)
	assert(layout != nil, "replay: pipeline layout")
	pipeline := wg.DeviceCreateRenderPipeline(
		device,
		&{
			layout = layout,
			vertex = {module = r.shader, entryPoint = "vs_main", bufferCount = 1, buffers = &vbl},
			primitive = {
				topology = wg.PrimitiveTopology(descriptor.topology),
				frontFace = wg.FrontFace(descriptor.front_face),
				cullMode = wg.CullMode(descriptor.cull_mode),
			},
			multisample = {count = descriptor.sample_count, mask = descriptor.sample_mask},
			fragment = &wg.FragmentState {
				module = r.shader,
				entryPoint = draw.fragment_entry,
				targetCount = 1,
				targets = &target,
			},
		},
	)
	wg.PipelineLayoutRelease(layout)
	assert(pipeline != nil, "replay: pipeline creation failed")
	return pipeline
}

make_geometry :: proc(r: ^Replay, dir: string) {
	device := r.ctx.device
	count := len(r.manifest.draws)
	r.pipelines = make([]wg.RenderPipeline, count)
	r.vbufs = make([]wg.Buffer, count)
	r.ibufs = make([]wg.Buffer, count)
	for draw, index in r.manifest.draws {
		vertices := read_file(dir, draw.vertices)
		indices := read_file(dir, draw.indices)
		assert(len(indices) == int(draw.index_count) * 4, "replay: index byte count")
		assert(len(vertices) % VERTEX_STRIDE == 0, "replay: vertex byte count")
		r.vbufs[index] = wg.DeviceCreateBuffer(
			device,
			&{usage = {.Vertex, .CopyDst}, size = u64(len(vertices))},
		)
		r.ibufs[index] = wg.DeviceCreateBuffer(
			device,
			&{usage = {.Index, .CopyDst}, size = u64(len(indices))},
		)
		wg.QueueWriteBuffer(
			r.ctx.queue,
			r.vbufs[index],
			0,
			raw_data(vertices),
			uint(len(vertices)),
		)
		wg.QueueWriteBuffer(r.ctx.queue, r.ibufs[index], 0, raw_data(indices), uint(len(indices)))
		r.pipelines[index] = make_pipeline(r, draw)
	}
}

make_queries :: proc(r: ^Replay) {
	device := r.ctx.device
	r.query_set = wg.DeviceCreateQuerySet(device, &{type = .Timestamp, count = QUERY_COUNT})
	r.resolve = wg.DeviceCreateBuffer(
		device,
		&{usage = {.QueryResolve, .CopySrc}, size = QUERY_COUNT * size_of(u64)},
	)
	for &slot in r.slots {
		slot.readback = wg.DeviceCreateBuffer(
			device,
			&{usage = {.CopyDst, .MapRead}, size = QUERY_COUNT * size_of(u64)},
		)
		assert(slot.readback != nil)
	}
	assert(r.query_set != nil && r.resolve != nil)
}

emit :: proc(r: ^Replay, line: string) {
	os.write_string(r.out, line)
	os.write_string(r.out, "\n")
}

classify :: proc(begin, end: u64, prior: [2]u64) -> string {
	if end == 0 do return "zero_end"
	if end < begin {
		if end == prior[1] || end == prior[0] do return "reversed_prior_slot_value"
		return "reversed_nonzero"
	}
	if end == prior[1] do return "ordered_but_stale"
	return "ordered"
}

collect :: proc(r: ^Replay, final: bool) {
	for &slot, index in r.slots {
		record := &slot.record
		if !record.armed || !sync.atomic_load_explicit(&record.done, .Acquire) do continue
		if record.status == .Success do wg.BufferUnmap(slot.readback)
		class := "map_failed"
		if record.mapped do class = classify(record.ticks[0], record.ticks[1], slot.prior)
		line := fmt.tprintf(
			SAMPLE_FORMAT,
			slot.iteration,
			index,
			slot.submit,
			slot.resolve_submit,
			int(slot.completion_status),
			int(record.status),
			record.mapped,
			record.ticks[0],
			record.ticks[1],
			record.ticks[0],
			record.ticks[1],
			record.ticks[2],
			record.ticks[3],
			slot.prior[0],
			slot.prior[1],
			slot.prior[0],
			slot.prior[1],
			slot.prior_kind,
			class,
			final,
		)
		emit(r, line)
		if record.mapped {
			slot.prior = {record.ticks[0], record.ticks[1]}
			slot.prior_kind = "mapped"
		} else {
			slot.prior_kind = "unmapped"
		}
		record^ = {}
	}
}

free_slot :: proc(r: ^Replay) -> int {
	for &slot, index in r.slots do if !slot.record.armed do return index
	return -1
}

wait_for_sample :: proc(r: ^Replay, slot: ^Slot) -> bool {
	slot.work = {}
	sync.atomic_store_explicit(&slot.work.armed, true, .Release)
	wg.QueueOnSubmittedWorkDone(
		r.ctx.queue,
		{mode = .AllowSpontaneos, callback = work_done, userdata1 = &slot.work},
	)
	for _ in 0 ..< DRAIN_POLLS {
		if sync.atomic_load_explicit(&slot.work.done, .Acquire) do break
		wg.DevicePoll(r.ctx.device, true, nil)
	}
	if !sync.atomic_load_explicit(&slot.work.done, .Acquire) do return false
	slot.completion_status = slot.work.status
	return slot.work.status == .Success
}

submit_resolve :: proc(r: ^Replay, slot: ^Slot) -> bool {
	encoder := wg.DeviceCreateCommandEncoder(r.ctx.device, &{label = "replay.resolve.completed"})
	if encoder == nil do return false
	wg.CommandEncoderResolveQuerySet(encoder, r.query_set, 0, 2, r.resolve, 0)
	wg.CommandEncoderResolveQuerySet(encoder, r.query_set, 0, 2, r.resolve, 256)
	wg.CommandEncoderCopyBufferToBuffer(encoder, r.resolve, 0, slot.readback, 0, 16)
	wg.CommandEncoderCopyBufferToBuffer(encoder, r.resolve, 256, slot.readback, 16, 16)
	command := wg.CommandEncoderFinish(encoder, nil)
	wg.CommandEncoderRelease(encoder)
	if command == nil do return false
	wg.QueueSubmit(r.ctx.queue, {command})
	wg.CommandBufferRelease(command)
	r.submits += 1
	slot.resolve_submit = r.submits
	return true
}

iteration :: proc(r: ^Replay, iteration: int) -> bool {
	ctx := r.ctx
	collect(r, false)
	index := free_slot(r)
	if index < 0 {
		emit(r, fmt.tprintf(`{{"kind":"no_free_slot","iteration":%d}}`, iteration))
		wg.DevicePoll(ctx.device, true, nil)
		return true
	}
	slot := &r.slots[index]
	surface := wg.SurfaceGetCurrentTexture(ctx.surface)
	if surface.status != .SuccessOptimal && surface.status != .SuccessSuboptimal {
		emit(
			r,
			fmt.tprintf(
				`{{"kind":"acquire","iteration":%d,"status":%d}}`,
				iteration,
				int(surface.status),
			),
		)
		if surface.texture != nil do wg.TextureRelease(surface.texture)
		return true
	}
	view := wg.TextureCreateView(surface.texture, nil)
	wg.DevicePushErrorScope(ctx.device, .Validation)
	encoder := wg.DeviceCreateCommandEncoder(ctx.device, &{label = "replay"})
	writes := wg.PassTimestampWrites {
		querySet                  = r.query_set,
		beginningOfPassWriteIndex = 0,
		endOfPassWriteIndex       = 1,
	}
	attachment := r.manifest.attachment
	clear_value: [4]f64
	for word, i in attachment.color_clear_bits do clear_value[i] = transmute(f64)word
	pass := wg.CommandEncoderBeginRenderPass(
		encoder,
		&{
			label = "window",
			timestampWrites = &writes,
			colorAttachmentCount = 1,
			colorAttachments = &wg.RenderPassColorAttachment {
				view = view,
				depthSlice = wg.DEPTH_SLICE_UNDEFINED,
				loadOp = wg.LoadOp(attachment.load),
				storeOp = wg.StoreOp(attachment.store),
				clearValue = clear_value,
			},
		},
	)
	for draw, i in r.manifest.draws {
		wg.RenderPassEncoderSetScissorRect(
			pass,
			draw.scissor[0],
			draw.scissor[1],
			draw.scissor[2],
			draw.scissor[3],
		)
		wg.RenderPassEncoderSetPipeline(pass, r.pipelines[i])
		wg.RenderPassEncoderSetBindGroup(pass, 0, r.ubind)
		bind := r.neutral
		if ref, textured := draw.atlas.?; textured do bind = r.atlas_bind[ref.atlas_id]
		wg.RenderPassEncoderSetBindGroup(pass, 1, bind)
		wg.RenderPassEncoderSetVertexBuffer(pass, 0, r.vbufs[i], 0, wg.WHOLE_SIZE)
		wg.RenderPassEncoderSetIndexBuffer(pass, r.ibufs[i], .Uint32, 0, wg.WHOLE_SIZE)
		wg.RenderPassEncoderDrawIndexed(pass, draw.index_count, 1, 0, 0, 0)
	}
	wg.RenderPassEncoderEnd(pass)
	wg.RenderPassEncoderRelease(pass)
	if !r.completion_gated {
		wg.CommandEncoderResolveQuerySet(encoder, r.query_set, 0, 2, r.resolve, 0)
		wg.CommandEncoderCopyBufferToBuffer(encoder, r.resolve, 0, slot.readback, 0, 16)
	}
	command := wg.CommandEncoderFinish(encoder, nil)
	ok := command != nil
	if ok {
		wg.QueueSubmit(ctx.queue, {command})
		wg.CommandBufferRelease(command)
		r.submits += 1
		slot.submit = r.submits
	}
	wg.CommandEncoderRelease(encoder)
	if ok && r.completion_gated {
		ok = wait_for_sample(r, slot) && submit_resolve(r, slot)
	}
	r.errors.done = false
	wg.DevicePopErrorScope(
		ctx.device,
		{mode = .AllowProcessEvents, callback = error_popped, userdata1 = &r.errors},
	)
	for !r.errors.done do wg.InstanceProcessEvents(ctx.instance)
	if len(r.errors.messages) > 0 {
		for message in r.errors.messages {
			emit(
				r,
				fmt.tprintf(`{{"kind":"error","iteration":%d,"message":%q}}`, iteration, message),
			)
		}
		clear(&r.errors.messages)
		ok = false
	}
	if ok {
		slot.iteration = iteration
		if !r.completion_gated {
			slot.resolve_submit = slot.submit
			slot.completion_status = .Success
		}
		slot.record = {}
		sync.atomic_store_explicit(&slot.record.armed, true, .Release)
		wg.BufferMapAsync(
			slot.readback,
			{.Read},
			0,
			32,
			{
				mode = .AllowSpontaneos,
				callback = map_done,
				userdata1 = &slot.record,
				userdata2 = slot,
			},
		)
	} else {
		emit(r, fmt.tprintf(`{{"kind":"command_failed","iteration":%d}}`, iteration))
	}
	wg.SurfacePresent(ctx.surface)
	wg.TextureViewRelease(view)
	wg.TextureRelease(surface.texture)
	return ok
}

drain :: proc(r: ^Replay) -> bool {
	for _ in 0 ..< DRAIN_POLLS {
		collect(r, true)
		if free_slot(r) == 0 {
			busy := false
			for slot in r.slots do busy = busy || slot.record.armed
			if !busy do return true
		}
		wg.DevicePoll(r.ctx.device, true, nil)
	}
	return false
}

main :: proc() {
	if len(os.args) < 4 || len(os.args) > 5 {
		fmt.eprintln(
			"usage: replay <bundle-dir> <iterations> <output.jsonl> [--completion-gated-resolve]",
		)
		os.exit(2)
	}
	dir := os.args[1]
	iterations, parsed := strconv.parse_int(os.args[2])
	if !parsed || iterations <= 0 || iterations > 100_000 do os.exit(2)
	out, err := os.open(os.args[3], {.Write, .Create, .Trunc})
	if err != nil do os.exit(2)
	r: Replay
	r.out = out
	if len(os.args) == 5 {
		if os.args[4] != "--completion-gated-resolve" do os.exit(2)
		r.completion_gated = true
	}
	r.manifest = load_manifest(dir)
	attachment := r.manifest.attachment
	rl.SetConfigFlags({.VSYNC_HINT, .WINDOW_HIGHDPI})
	rl.InitWindow(i32(attachment.width / 2), i32(attachment.height / 2), "timing replay")
	r.ctx = rl.default_context()
	assert(r.ctx.device != nil, "replay: no device")
	r.period = f64(wg.QueueGetTimestampPeriod(r.ctx.queue))
	if u32(r.ctx.fb_width) != attachment.width ||
	   u32(r.ctx.fb_height) != attachment.height ||
	   u32(r.ctx.format) != attachment.format {
		emit(
			&r,
			fmt.tprintf(
				`{{"kind":"attachment_mismatch","fb_width":%d,"fb_height":%d,"format":%d}}`,
				r.ctx.fb_width,
				r.ctx.fb_height,
				int(r.ctx.format),
			),
		)
		fmt.eprintln("replay: window attachment does not match the capture")
		os.exit(3)
	}
	source := read_file(dir, r.manifest.shader)
	r.shader = wg.DeviceCreateShaderModule(
		r.ctx.device,
		&{
			nextInChain = &wg.ShaderSourceWGSL {
				chain = {sType = .ShaderSourceWGSL},
				code = string(source),
			},
		},
	)
	assert(r.shader != nil, "replay: shader module")
	make_layouts(&r)
	make_textures(&r, dir)
	make_geometry(&r, dir)
	make_queries(&r)
	emit(
		&r,
		fmt.tprintf(
			HEADER_FORMAT,
			r.completion_gated ? "webgpu_completion_gated_replay" : "webgpu_pinned_replay",
			r.completion_gated ? "completion_gated_resolve" : "webgpu_pinned_replay",
			dir,
			r.manifest.frame,
			iterations,
			r.ctx.fb_width,
			r.ctx.fb_height,
			int(r.ctx.format),
			r.period,
			len(r.manifest.draws),
			fmt.tprintf("%v", time.now()),
		),
	)
	failures := 0
	for i in 0 ..< iterations {
		if !iteration(&r, i) do failures += 1
		if rl.WindowShouldClose() do break
	}
	drained := drain(&r)
	emit(
		&r,
		fmt.tprintf(
			`{{"kind":"footer","submits":%d,"command_failures":%d,"drained":%v}}`,
			r.submits,
			failures,
			drained,
		),
	)
	os.close(out)
	closed := rl.CloseWindow()
	if !drained || !closed do os.exit(1)
}
