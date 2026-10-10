// ingot:gfx - flushing accumulated batch geometry into the active render
// pass: high-water marks, overflow reporting, and the transient/streamed
// upload paths that pack vertices and indices into GPU buffers.
package gfx

import "core:fmt"
import "core:mem"
import wg "vendor:wgpu"

// _batch_record_peak folds one flush's batch size into the renderer's
// high-water marks. Split out from renderer_flush so it can be tested without
// a live GPU pass: renderer_flush needs a real RenderPassEncoder, which would
// leave the only measurement that justifies BATCH_MAX_VERTICES unverified.
@(private)
_batch_record_peak :: proc(r: ^Renderer, vertex_count, index_count: int) {
	assert(r != nil, "_batch_record_peak: nil renderer")
	assert(vertex_count >= 0 && index_count >= 0, "_batch_record_peak: negative count")
	r.peak_verts = max(r.peak_verts, vertex_count)
	r.peak_indices = max(r.peak_indices, index_count)
	assert(r.peak_verts >= vertex_count, "_batch_record_peak: peak below sample")
}

@(private)
_stream_record_peak :: proc(r: ^Renderer, geometry_bytes, uniform_bytes: u64) {
	assert(r != nil, "_stream_record_peak: nil renderer")
	assert(geometry_bytes <= r.geometry_bytes, "_stream_record_peak: geometry exceeds capacity")
	assert(uniform_bytes <= r.uniform_bytes, "_stream_record_peak: uniform exceeds capacity")
	r.peak_geometry_bytes = max(r.peak_geometry_bytes, geometry_bytes)
	r.peak_uniform_bytes = max(r.peak_uniform_bytes, uniform_bytes)
	assert(r.peak_geometry_bytes <= r.geometry_bytes)
	assert(r.peak_uniform_bytes <= r.uniform_bytes)
}

@(private = "package")
renderer_flush :: proc(
	ctx: ^Context,
	r: ^Renderer,
	pass: wg.RenderPassEncoder,
	cause: Flush_Cause = .Manual,
) {
	assert(ctx != nil, "renderer_flush: nil context")
	assert(r == &ctx.rend, "renderer_flush: foreign renderer")
	n := len(r.verts)
	if n == 0 do return

	index_count := len(r.indices)
	assert(index_count > 0)
	// Record before the buffers are cleared below: this is the whole batch
	// that accumulated since the last flush, which is exactly the quantity
	// BATCH_MAX_VERTICES has to cover.
	_batch_record_peak(r, n, index_count)
	layout := _batch_upload_layout(n, index_count)
	vertex_bytes := layout.vertex_bytes
	index_bytes := layout.index_bytes
	vertex_buffer, index_buffer: wg.Buffer
	vertex_offset, index_offset: u64
	if STREAMED_RENDERER_ENABLED {
		buffer, uploaded_vertex_offset, uploaded_index_offset, upload_ok := _geometry_upload_batch(
			ctx,
			r,
			layout,
			r.verts[:],
			r.indices[:],
		)
		if upload_ok {
			vertex_buffer, index_buffer = buffer, buffer
			vertex_offset, index_offset = uploaded_vertex_offset, uploaded_index_offset
		} else {
			vertex_buffer, index_buffer = _geometry_upload_transient(ctx, r, layout)
		}
	} else {
		vertex_buffer, index_buffer = _geometry_upload_transient(ctx, r, layout)
	}
	if vertex_buffer == nil || index_buffer == nil {
		clear(&r.verts)
		clear(&r.indices)
		return
	}
	_stats_flush(ctx, u64(n), vertex_bytes + index_bytes, cause)
	when RENDER_STATS_ENABLED {
		ctx.stats_current.indices_uploaded += u64(index_count)
	}

	// Custom-shader path: an active shader overrides the pipeline + bind groups
	// for the current draw (fullscreen post-process / custom 2D passes).
	if r.active_shader != 0 {
		if _shader_flush(
			ctx,
			r,
			pass,
			vertex_buffer,
			vertex_offset,
			index_buffer,
			index_offset,
			layout.index_format,
			u32(index_count),
		) {
			clear(&r.verts)
			clear(&r.indices)
			return
		}
	}

	pipe := _pipe_for(ctx, r, r.cur_kind, r.cur_blend)
	if pipe == nil {
		clear(&r.verts)
		clear(&r.indices)
		return
	}
	wg.RenderPassEncoderSetPipeline(pass, pipe)
	_stats_pipeline_switch(ctx)
	wg.RenderPassEncoderSetBindGroup(pass, 0, r.cur_u != nil ? r.cur_u : r.ubind)
	_stats_bind_group_switches(ctx, 1)
	if r.cur_bind != nil {
		wg.RenderPassEncoderSetBindGroup(pass, 1, r.cur_bind)
		_stats_bind_group_switches(ctx, 1)
	}
	wg.RenderPassEncoderSetVertexBuffer(pass, 0, vertex_buffer, vertex_offset, vertex_bytes)
	wg.RenderPassEncoderSetIndexBuffer(
		pass,
		index_buffer,
		layout.index_format,
		index_offset,
		index_bytes,
	)
	wg.RenderPassEncoderDrawIndexed(pass, u32(index_count), 1, 0, 0, 0)
	when GPU_TIMING_DIAGNOSTICS {
		_gpu_timing_diagnostic_batch_draw(ctx, r, pass, u32(index_count))
	}
	clear(&r.verts)
	clear(&r.indices)
}

// GEOMETRY_OVERFLOW_REPORTS_MAX bounds how many overflow frames are reported.
// A scene that overflows usually overflows every frame, and an unbounded log
// would itself become the performance problem (and would flood the on-page
// crash panel on web, hiding the first occurrence).
GEOMETRY_OVERFLOW_REPORTS_MAX :: 4

// _renderer_report_overflow logs, at most GEOMETRY_OVERFLOW_REPORTS_MAX times,
// that this frame's geometry did not fit the stream and fell back to one-shot
// buffers. Silence here was a cliff: the fallback quietly allocates up to
// BATCH_TRANSIENT_BUFFERS_MAX buffers per frame, which on a memory-constrained
// device (a phone) ends as a killed tab with no diagnostic at all.
@(private)
_renderer_report_overflow :: proc(r: ^Renderer) {
	assert(r != nil, "_renderer_report_overflow: nil renderer")
	if r.overflow_draws == 0 do return
	if r.overflow_reports >= GEOMETRY_OVERFLOW_REPORTS_MAX do return
	r.overflow_reports += 1
	final := r.overflow_reports == GEOMETRY_OVERFLOW_REPORTS_MAX
	fmt.eprintfln(
		"gfx: geometry stream overflow - %d draw(s), %d KiB spilled (stream %d KiB)%s",
		r.overflow_draws,
		r.overflow_bytes / 1024,
		r.geometry_bytes / 1024,
		" [further reports suppressed]" if final else "",
	)
}

// _geometry_upload_transient is the fallback path when indexed streaming has
// no room: it creates one-shot vertex and index buffers that live until the
// owning stream slot is reused.
//
// The device is passed in rather than read from the active-context global, so
// this leaf stays pure and its caller owns the context lookup (the same shape
// as _neutral_texture_init).
@(private)
_geometry_upload_transient :: proc(
	ctx: ^Context,
	r: ^Renderer,
	layout: Batch_Upload_Layout,
) -> (
	wg.Buffer,
	wg.Buffer,
) {
	assert(ctx != nil, "_geometry_upload_transient: nil context")
	assert(r == &ctx.rend, "_geometry_upload_transient: foreign renderer")
	// Record the overflow before attempting the allocation: a scene reaching
	// this path at all is the signal worth reporting, whether or not the
	// fallback itself succeeds.
	r.overflow_bytes += layout.vertex_bytes + layout.index_bytes
	r.overflow_draws += 1
	// Two buffers are appended below, so stop one pair short of the cap.
	if len(r.transient_buffers) > BATCH_TRANSIENT_BUFFERS_MAX - 2 do return nil, nil
	vertex_data := make([]byte, int(layout.vertex_bytes), context.temp_allocator)
	index_data := make([]byte, int(layout.index_bytes), context.temp_allocator)
	if vertex_data == nil || index_data == nil do return nil, nil
	_batch_pack(layout, r.verts[:], r.indices[:], vertex_data, index_data)
	vertex_buffer := wg.DeviceCreateBufferWithData(ctx.device, &{usage = {.Vertex}}, vertex_data)
	if vertex_buffer == nil do return nil, nil
	index_buffer := wg.DeviceCreateBufferWithData(ctx.device, &{usage = {.Index}}, index_data)
	if index_buffer == nil {
		wg.BufferRelease(vertex_buffer)
		return nil, nil
	}
	append(&r.transient_buffers, vertex_buffer, index_buffer)
	assert(len(r.transient_buffers) <= BATCH_TRANSIENT_BUFFERS_MAX)
	_stats_buffer_created(ctx, false)
	_stats_buffer_created(ctx, false)
	return vertex_buffer, index_buffer
}

// Batch_Upload_Layout is the packed GPU form of one flushed run: 24-byte
// vertices and 16-bit indices whenever the run's vertices fit them. Index
// values are run-relative (DrawIndexed uses base vertex 0), so the check on the
// vertex count is exact. The index byte size is padded to 4 because
// writeBuffer requires a 4-byte multiple; the pad is never read because the
// draw uses the index count.
Batch_Upload_Layout :: struct {
	vertex_bytes: u64,
	index_bytes:  u64,
	index_format: wg.IndexFormat,
}

BATCH_U16_VERTICES_MAX :: 65536

@(private)
_batch_upload_layout :: proc "contextless" (
	vertex_count, index_count: int,
) -> Batch_Upload_Layout {
	layout := Batch_Upload_Layout {
		vertex_bytes = u64(vertex_count) * size_of(Gpu_Vertex),
		index_format = .Uint32,
	}
	index_size := u64(size_of(u32))
	if vertex_count <= BATCH_U16_VERTICES_MAX {
		layout.index_format = .Uint16
		index_size = size_of(u16)
	}
	layout.index_bytes = (u64(index_count) * index_size + 3) &~ u64(3)
	return layout
}

// _batch_pack writes verts and indices into destination buffers in the GPU
// layout. Both destinations must be exactly the sizes from layout.
@(private)
_batch_pack :: proc(
	layout: Batch_Upload_Layout,
	verts: []Vertex,
	indices: []u32,
	vertex_out: []byte,
	index_out: []byte,
) {
	assert(u64(len(vertex_out)) == layout.vertex_bytes, "_batch_pack: vertex size")
	assert(u64(len(index_out)) == layout.index_bytes, "_batch_pack: index size")
	gpu_verts := ([^]Gpu_Vertex)(raw_data(vertex_out))[:len(verts)]
	for v, i in verts do gpu_verts[i] = _pack_vertex(v)
	if layout.index_format == .Uint16 {
		gpu_indices := ([^]u16)(raw_data(index_out))[:len(indices)]
		for index, i in indices {
			assert(index < BATCH_U16_VERTICES_MAX, "_batch_pack: index exceeds u16 range")
			gpu_indices[i] = u16(index)
		}
		if len(indices) % 2 == 1 {
			([^]u16)(raw_data(index_out))[len(indices)] = 0
		}
	} else {
		mem.copy(raw_data(index_out), raw_data(indices), len(indices) * size_of(u32))
	}
}

@(private)
_geometry_upload_batch :: proc(
	ctx: ^Context,
	r: ^Renderer,
	layout: Batch_Upload_Layout,
	verts: []Vertex,
	indices: []u32,
) -> (
	wg.Buffer,
	u64,
	u64,
	bool,
) {
	assert(ctx != nil)
	assert(r == &ctx.rend)
	assert(len(verts) > 0)
	assert(len(indices) > 0)
	vertex_bytes := layout.vertex_bytes
	index_bytes := layout.index_bytes
	assert(vertex_bytes > 0)
	assert(index_bytes > 0)
	if r.active_stream_slot < 0 do return nil, 0, 0, false
	assert(r.active_stream_slot < len(r.stream_slots))
	slot := &r.stream_slots[r.active_stream_slot]
	write_before := slot.geometry_write
	vertex_offset, index_offset, ok := _stream_slot_reserve_indexed(
		slot,
		vertex_bytes,
		index_bytes,
		r.geometry_bytes,
	)
	if !ok {
		_stats_reservation_failure(ctx, false)
		return nil, 0, 0, false
	}

	copy_started := platform_now()
	if !_stream_shadow_ensure(&slot.geometry_shadow, slot.geometry_write, r.geometry_bytes) {
		slot.geometry_write = write_before
		_stats_reservation_failure(ctx, false)
		return nil, 0, 0, false
	}
	_batch_pack(
		layout,
		verts,
		indices,
		slot.geometry_shadow[vertex_offset:vertex_offset + vertex_bytes],
		slot.geometry_shadow[index_offset:index_offset + index_bytes],
	)
	_stream_record_peak(r, slot.geometry_write, r.peak_uniform_bytes)
	_stats_stream_copy(ctx, platform_now() - copy_started)
	when RENDER_STATS_ENABLED {
		ctx.stats_current.peak_geometry_arena_bytes = max(
			ctx.stats_current.peak_geometry_arena_bytes,
			slot.geometry_write,
		)
	}
	return slot.geometry_buffer, vertex_offset, index_offset, true
}
