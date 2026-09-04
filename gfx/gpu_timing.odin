package gfx

import "base:runtime"
import "core:mem"
import "core:sync"
import wg "vendor:wgpu"

GPU_TIMING_FRAME_SLOTS :: 8
GPU_TIMING_MAX_SPANS :: 64
GPU_TIMING_QUERY_COUNT :: GPU_TIMING_MAX_SPANS * 2
GPU_TIMING_BUFFER_BYTES :: u64(GPU_TIMING_QUERY_COUNT * size_of(u64))
GPU_TIMING_SHUTDOWN_POLLS :: 4096

Gpu_Timing_Token :: struct {
	query_begin: u32,
	query_end:   u32,
	valid:       bool,
}

Gpu_Frame_Timing :: struct {
	frame_index: u64,
	seconds:     f64,
	valid:       bool,
}

Gpu_Timing_Slot :: struct {
	query_set:   wg.QuerySet,
	resolve:     wg.Buffer,
	readback:    wg.Buffer,
	frame_index: u64,
	query_count: u32,
	ticks:       [GPU_TIMING_QUERY_COUNT]u64,
	map_done:    bool,
	map_ok:      bool,
	in_flight:   bool,
}

Gpu_Timing_State :: struct {
	slots:            [GPU_TIMING_FRAME_SLOTS]Gpu_Timing_Slot,
	active_slot:      int,
	timestamp_period: f64,
	latest:           Gpu_Frame_Timing,
	available:        bool,
}

_gpu_timing_init :: proc(ctx: ^Context) -> bool {
	assert(ctx != nil, "_gpu_timing_init: nil context")
	ctx.gpu_timing.active_slot = -1
	when !RENDER_STATS_ENABLED do return false
	when ODIN_OS == .JS do return false
	if !wg.DeviceHasFeature(ctx.device, .TimestampQuery) do return false
	period := f64(wg.QueueGetTimestampPeriod(ctx.queue))
	if period <= 0 do return false
	for &slot in ctx.gpu_timing.slots {
		slot.query_set = wg.DeviceCreateQuerySet(
			ctx.device,
			&{type = .Timestamp, count = GPU_TIMING_QUERY_COUNT},
		)
		slot.resolve = wg.DeviceCreateBuffer(
			ctx.device,
			&{usage = {.QueryResolve, .CopySrc}, size = GPU_TIMING_BUFFER_BYTES},
		)
		slot.readback = wg.DeviceCreateBuffer(
			ctx.device,
			&{usage = {.CopyDst, .MapRead}, size = GPU_TIMING_BUFFER_BYTES},
		)
		if slot.query_set == nil || slot.resolve == nil || slot.readback == nil {
			_gpu_timing_shutdown(ctx)
			return false
		}
	}
	ctx.gpu_timing.timestamp_period = period
	ctx.gpu_timing.available = true
	return true
}

_gpu_timing_shutdown :: proc(ctx: ^Context) {
	assert(ctx != nil, "_gpu_timing_shutdown: nil context")
	when ODIN_OS != .JS {
		for _ in 0 ..< GPU_TIMING_SHUTDOWN_POLLS {
			_gpu_timing_collect(ctx)
			busy := false
			for &slot in ctx.gpu_timing.slots do busy = busy || slot.in_flight
			if !busy do break
			if ctx.device == nil do break
			wg.DevicePoll(ctx.device, true, nil)
		}
	}
	for &slot in ctx.gpu_timing.slots {
		if slot.readback != nil {
			if wg.BufferGetMapState(slot.readback) == .Mapped do wg.BufferUnmap(slot.readback)
			wg.BufferDestroy(slot.readback)
			wg.BufferRelease(slot.readback)
		}
		if slot.resolve != nil {
			wg.BufferDestroy(slot.resolve)
			wg.BufferRelease(slot.resolve)
		}
		if slot.query_set != nil {
			wg.QuerySetDestroy(slot.query_set)
			wg.QuerySetRelease(slot.query_set)
		}
		slot = {}
	}
	ctx.gpu_timing = {}
	ctx.gpu_timing.active_slot = -1
}

_gpu_timing_frame_begin :: proc(ctx: ^Context) {
	assert(ctx != nil, "_gpu_timing_frame_begin: nil context")
	ctx.gpu_timing.active_slot = -1
	if !ctx.gpu_timing.available do return
	for &slot, index in ctx.gpu_timing.slots {
		if slot.in_flight do continue
		assert(wg.BufferGetMapState(slot.readback) == .Unmapped)
		slot.frame_index = ctx.stats_current.frame_index
		slot.query_count = 0
		slot.map_done = false
		slot.map_ok = false
		ctx.gpu_timing.active_slot = index
		return
	}
}

_gpu_timing_pair_reserve :: proc(state: ^Gpu_Timing_State) -> Gpu_Timing_Token {
	if state == nil || !state.available do return {}
	if state.active_slot < 0 || state.active_slot >= GPU_TIMING_FRAME_SLOTS do return {}
	slot := &state.slots[state.active_slot]
	if slot.in_flight || slot.query_count > GPU_TIMING_QUERY_COUNT - 2 do return {}
	token := Gpu_Timing_Token {
		query_begin = slot.query_count,
		query_end   = slot.query_count + 1,
		valid       = true,
	}
	slot.query_count += 2
	return token
}

_gpu_timing_encoder_begin :: proc(ctx: ^Context, encoder: wg.CommandEncoder) -> Gpu_Timing_Token {
	if ctx == nil || encoder == nil do return {}
	token := _gpu_timing_pair_reserve(&ctx.gpu_timing)
	if !token.valid do return {}
	slot := &ctx.gpu_timing.slots[ctx.gpu_timing.active_slot]
	wg.CommandEncoderWriteTimestamp(encoder, slot.query_set, token.query_begin)
	return token
}

_gpu_timing_encoder_end :: proc(
	ctx: ^Context,
	encoder: wg.CommandEncoder,
	token: Gpu_Timing_Token,
) {
	if ctx == nil || encoder == nil || !token.valid do return
	if ctx.gpu_timing.active_slot < 0 do return
	slot := &ctx.gpu_timing.slots[ctx.gpu_timing.active_slot]
	wg.CommandEncoderWriteTimestamp(encoder, slot.query_set, token.query_end)
}

_gpu_timing_frame_resolve :: proc(ctx: ^Context, encoder: wg.CommandEncoder) {
	if ctx == nil || encoder == nil || ctx.gpu_timing.active_slot < 0 do return
	slot := &ctx.gpu_timing.slots[ctx.gpu_timing.active_slot]
	if slot.query_count == 0 do return
	bytes := u64(slot.query_count) * size_of(u64)
	wg.CommandEncoderResolveQuerySet(encoder, slot.query_set, 0, slot.query_count, slot.resolve, 0)
	wg.CommandEncoderCopyBufferToBuffer(encoder, slot.resolve, 0, slot.readback, 0, bytes)
}

_gpu_timing_frame_submitted :: proc(ctx: ^Context) {
	if ctx == nil || ctx.gpu_timing.active_slot < 0 do return
	slot := &ctx.gpu_timing.slots[ctx.gpu_timing.active_slot]
	ctx.gpu_timing.active_slot = -1
	if slot.query_count == 0 do return
	slot.in_flight = true
	wg.BufferMapAsync(
		slot.readback,
		{.Read},
		0,
		uint(u64(slot.query_count) * size_of(u64)),
		{mode = .AllowSpontaneos, callback = _gpu_timing_map_done, userdata1 = slot},
	)
}

_gpu_timing_frame_abandon :: proc(ctx: ^Context) {
	if ctx == nil || ctx.gpu_timing.active_slot < 0 do return
	slot := &ctx.gpu_timing.slots[ctx.gpu_timing.active_slot]
	slot.query_count = 0
	ctx.gpu_timing.active_slot = -1
}

_gpu_timing_seconds :: proc(ticks: []u64, span_count: u32, period_ns: f64) -> (f64, bool) {
	if period_ns <= 0 || span_count == 0 || int(span_count) * 2 > len(ticks) do return 0, false
	total: u64
	for span in 0 ..< int(span_count) {
		begin := ticks[span * 2]
		end := ticks[span * 2 + 1]
		if end < begin do return 0, false
		total += end - begin
	}
	return f64(total) * period_ns * 1e-9, true
}

_gpu_timing_collect :: proc(ctx: ^Context) {
	if ctx == nil || !ctx.gpu_timing.available do return
	for &slot in ctx.gpu_timing.slots {
		if !slot.in_flight || !sync.atomic_load(&slot.map_done) do continue
		if sync.atomic_load(&slot.map_ok) {
			seconds, ok := _gpu_timing_seconds(
				slot.ticks[:],
				slot.query_count / 2,
				ctx.gpu_timing.timestamp_period,
			)
			if ok && slot.frame_index >= ctx.gpu_timing.latest.frame_index {
				ctx.gpu_timing.latest = {
					frame_index = slot.frame_index,
					seconds     = seconds,
					valid       = true,
				}
			}
		}
		wg.BufferUnmap(slot.readback)
		slot.in_flight = false
		slot.query_count = 0
		slot.map_done = false
		slot.map_ok = false
	}
}

_gpu_timing_map_done :: proc "c" (
	status: wg.MapAsyncStatus,
	message: wg.StringView,
	userdata1, userdata2: rawptr,
) {
	context = runtime.default_context()
	_ = message
	_ = userdata2
	slot := cast(^Gpu_Timing_Slot)userdata1
	if slot == nil do return
	ok := status == .Success
	if ok {
		bytes := uint(u64(slot.query_count) * size_of(u64))
		mapped := wg.BufferGetConstMappedRange(slot.readback, 0, bytes)
		if mapped == nil {
			ok = false
		} else {
			mem.copy(raw_data(slot.ticks[:]), raw_data(mapped), int(bytes))
		}
	}
	sync.atomic_store(&slot.map_ok, ok)
	sync.atomic_store(&slot.map_done, true)
}
