package gfx

import "base:runtime"
import "core:mem"
import "core:sync"
import wg "vendor:wgpu"

GPU_TIMING_COMPLETION_CAPACITY :: 128
GPU_TIMING_FRAME_SLOTS :: 8
GPU_TIMING_MAX_SPANS :: 64
GPU_TIMING_MAX_GROUPS :: 16
GPU_TIMING_LABEL_MAX :: 32
GPU_TIMING_QUERY_COUNT :: GPU_TIMING_MAX_SPANS * 2
GPU_TIMING_BUFFER_BYTES :: u64(GPU_TIMING_QUERY_COUNT * size_of(u64))
GPU_TIMING_SHUTDOWN_POLLS :: 4096

Gpu_Timing_Label :: struct {
	bytes:  [GPU_TIMING_LABEL_MAX]u8,
	length: u8,
}

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

Gpu_Timing_Group :: struct {
	label:   Gpu_Timing_Label,
	seconds: f64,
	count:   u32,
}

Gpu_Frame_Timing_Detail :: struct {
	epoch:            u64,
	groups_truncated: u32,
	frame_index:      u64,
	seconds:          f64,
	groups:           [GPU_TIMING_MAX_GROUPS]Gpu_Timing_Group,
	group_count:      u32,
	valid:            bool,
}

Gpu_Timing_Slot :: struct {
	epoch:       u64,
	query_set:   wg.QuerySet,
	resolve:     wg.Buffer,
	readback:    wg.Buffer,
	frame_index: u64,
	query_count: u32,
	labels:      [GPU_TIMING_MAX_SPANS]Gpu_Timing_Label,
	ticks:       [GPU_TIMING_QUERY_COUNT]u64,
	map_done:    bool,
	map_ok:      bool,
	in_flight:   bool,
}

Gpu_Timing_Invalid_Pair :: struct {
	epoch:       u64,
	frame_index: u64,
	pair_index:  u32,
	label:       Gpu_Timing_Label,
	valid:       bool,
}

Gpu_Timing_Health :: struct {
	overflow:              u64,
	no_free_slot:          u64,
	pair_exhaustion:       u64,
	map_failure:           u64,
	group_truncation:      u64,
	invalid_timestamps:    u64,
	completion_occupancy:  u32,
	completion_high_water: u32,
	first_invalid_pair:    Gpu_Timing_Invalid_Pair,
}

Gpu_Timing_State :: struct {
	completed:        [GPU_TIMING_COMPLETION_CAPACITY]Gpu_Frame_Timing_Detail,
	completed_head:   u32,
	completed_count:  u32,
	health:           Gpu_Timing_Health,
	slots:            [GPU_TIMING_FRAME_SLOTS]Gpu_Timing_Slot,
	active_slot:      int,
	timestamp_period: f64,
	latest:           Gpu_Frame_Timing,
	latest_detail:    Gpu_Frame_Timing_Detail,
	available:        bool,
}

_gpu_timing_init :: proc(ctx: ^Context) -> bool {
	assert(ctx != nil, "_gpu_timing_init: nil context")
	ctx.gpu_timing.active_slot = -1
	when !RENDER_STATS_ENABLED do return false
	when ODIN_OS == .JS do return false
	if !wg.DeviceHasFeature(ctx.device, .TimestampQuery) ||
	   !wg.DeviceHasFeature(ctx.device, .TimestampQueryInsideEncoders) {
		return false
	}
	period: f64
	when ODIN_OS != .JS {
		period = f64(wg.QueueGetTimestampPeriod(ctx.queue))
	}
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
			wg.BufferDestroy(slot.readback)
			wg.BufferRelease(slot.readback)
		}
		if slot.resolve != nil {
			wg.BufferDestroy(slot.resolve)
			wg.BufferRelease(slot.resolve)
		}
		if slot.query_set != nil {
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
		slot.frame_index = ctx.stats_current.frame_index
		slot.epoch = ctx.epoch
		slot.query_count = 0
		slot.map_done = false
		slot.map_ok = false
		ctx.gpu_timing.active_slot = index
		return
	}
	ctx.gpu_timing.health.no_free_slot += 1
}

_gpu_timing_label :: proc(name: string) -> Gpu_Timing_Label {
	result: Gpu_Timing_Label
	length := min(len(name), GPU_TIMING_LABEL_MAX)
	if length > 0 do copy(result.bytes[:length], transmute([]u8)name[:length])
	result.length = u8(length)
	return result
}

_gpu_timing_label_equal :: proc(a, b: Gpu_Timing_Label) -> bool {
	if a.length != b.length do return false
	for index in 0 ..< int(a.length) {
		if a.bytes[index] != b.bytes[index] do return false
	}
	return true
}

_gpu_timing_pair_reserve :: proc(
	state: ^Gpu_Timing_State,
	name: string = "gpu3d",
) -> Gpu_Timing_Token {
	if state == nil || !state.available do return {}
	if state.active_slot < 0 || state.active_slot >= GPU_TIMING_FRAME_SLOTS do return {}
	slot := &state.slots[state.active_slot]
	if slot.in_flight do return {}
	if slot.query_count > GPU_TIMING_QUERY_COUNT - 2 {
		state.health.pair_exhaustion += 1
		return {}
	}
	token := Gpu_Timing_Token {
		query_begin = slot.query_count,
		query_end   = slot.query_count + 1,
		valid       = true,
	}
	slot.labels[slot.query_count / 2] = _gpu_timing_label(name)
	slot.query_count += 2
	return token
}

_gpu_timing_pass_writes :: proc(state: ^Gpu_Timing_State, name: string) -> wg.PassTimestampWrites {
	assert(state != nil)
	token := _gpu_timing_pair_reserve(state, name)
	if !token.valid do return {}
	assert(state.active_slot >= 0 && state.active_slot < GPU_TIMING_FRAME_SLOTS)
	return {
		querySet = state.slots[state.active_slot].query_set,
		beginningOfPassWriteIndex = token.query_begin,
		endOfPassWriteIndex = token.query_end,
	}
}

_gpu_timing_encoder_begin :: proc(
	ctx: ^Context,
	encoder: wg.CommandEncoder,
	name: string = "gpu3d",
) -> Gpu_Timing_Token {
	if ctx == nil || encoder == nil do return {}
	token := _gpu_timing_pair_reserve(&ctx.gpu_timing, name)
	if !token.valid do return {}
	assert(ctx.gpu_timing.active_slot >= 0)
	assert(ctx.gpu_timing.active_slot < GPU_TIMING_FRAME_SLOTS)
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

_gpu_timing_invalid_pair :: proc(ticks: []u64, span_count: u32) -> (u32, bool) {
	if span_count == 0 || int(span_count) * 2 > len(ticks) do return 0, false
	for span in 0 ..< int(span_count) {
		if ticks[span * 2 + 1] < ticks[span * 2] do return u32(span), true
	}
	return 0, false
}

_gpu_timing_seconds :: proc(ticks: []u64, span_count: u32, period_ns: f64) -> (f64, bool) {
	if period_ns <= 0 || span_count == 0 || int(span_count) * 2 > len(ticks) do return 0, false
	if _, invalid := _gpu_timing_invalid_pair(ticks, span_count); invalid do return 0, false
	total: u64
	for span in 0 ..< int(span_count) {
		begin := ticks[span * 2]
		end := ticks[span * 2 + 1]
		total += end - begin
	}
	return f64(total) * period_ns * 1e-9, true
}

_gpu_timing_detail :: proc(
	ticks: []u64,
	labels: []Gpu_Timing_Label,
	span_count: u32,
	period_ns: f64,
) -> (
	Gpu_Frame_Timing_Detail,
	bool,
) {
	seconds, ok := _gpu_timing_seconds(ticks, span_count, period_ns)
	if !ok || int(span_count) > len(labels) do return {}, false
	result := Gpu_Frame_Timing_Detail {
		seconds = seconds,
		valid   = true,
	}
	for span in 0 ..< int(span_count) {
		label := labels[span]
		group_index := -1
		for index in 0 ..< int(result.group_count) {
			if _gpu_timing_label_equal(result.groups[index].label, label) {
				group_index = index
				break
			}
		}
		if group_index < 0 {
			if result.group_count >= GPU_TIMING_MAX_GROUPS {
				result.groups_truncated += 1
				continue
			}
			group_index = int(result.group_count)
			result.groups[group_index].label = label
			result.group_count += 1
		}
		delta := ticks[span * 2 + 1] - ticks[span * 2]
		result.groups[group_index].seconds += f64(delta) * period_ns * 1e-9
		result.groups[group_index].count += 1
	}
	return result, true
}

_gpu_timing_collect :: proc(ctx: ^Context) {
	if ctx == nil || !ctx.gpu_timing.available do return
	for &slot in ctx.gpu_timing.slots {
		if !slot.in_flight || !sync.atomic_load(&slot.map_done) do continue
		if sync.atomic_load(&slot.map_ok) {
			detail, ok := _gpu_timing_detail(
				slot.ticks[:],
				slot.labels[:],
				slot.query_count / 2,
				ctx.gpu_timing.timestamp_period,
			)
			if ok {
				detail.frame_index = slot.frame_index
				detail.epoch = slot.epoch
				_gpu_timing_enqueue(&ctx.gpu_timing, detail)
			} else {
				ctx.gpu_timing.health.invalid_timestamps += 1
				pair_index, invalid := _gpu_timing_invalid_pair(
					slot.ticks[:],
					slot.query_count / 2,
				)
				if invalid && !ctx.gpu_timing.health.first_invalid_pair.valid {
					ctx.gpu_timing.health.first_invalid_pair = {
						epoch       = slot.epoch,
						frame_index = slot.frame_index,
						pair_index  = pair_index,
						label       = slot.labels[pair_index],
						valid       = true,
					}
				}
			}
		} else {
			ctx.gpu_timing.health.map_failure += 1
		}
		if slot.readback != nil do wg.BufferUnmap(slot.readback)
		slot.in_flight = false
		slot.query_count = 0
		slot.map_done = false
		slot.map_ok = false
	}
}

_gpu_timing_enqueue :: proc(state: ^Gpu_Timing_State, detail: Gpu_Frame_Timing_Detail) {
	assert(state != nil)
	assert(state.completed_count <= GPU_TIMING_COMPLETION_CAPACITY)
	assert(state.completed_head < GPU_TIMING_COMPLETION_CAPACITY)
	state.health.group_truncation += u64(detail.groups_truncated)
	if detail.frame_index >= state.latest.frame_index {
		state.latest = {
			frame_index = detail.frame_index,
			seconds     = detail.seconds,
			valid       = detail.valid,
		}
		state.latest_detail = detail
	}
	if state.completed_count == GPU_TIMING_COMPLETION_CAPACITY {
		state.health.overflow += 1
		return
	}
	index := (state.completed_head + state.completed_count) % GPU_TIMING_COMPLETION_CAPACITY
	state.completed[index] = detail
	state.completed_count += 1
	state.health.completion_high_water = max(
		state.health.completion_high_water,
		state.completed_count,
	)
}

_gpu_timing_drain :: proc(
	state: ^Gpu_Timing_State,
	output: []Gpu_Frame_Timing_Detail,
) -> (
	int,
	Gpu_Timing_Health,
) {
	assert(state != nil)
	assert(state.completed_count <= GPU_TIMING_COMPLETION_CAPACITY)
	assert(state.completed_head < GPU_TIMING_COMPLETION_CAPACITY)
	count := min(len(output), int(state.completed_count))
	for index in 0 ..< count {
		output[index] = state.completed[state.completed_head]
		state.completed_head = (state.completed_head + 1) % GPU_TIMING_COMPLETION_CAPACITY
	}
	state.completed_count -= u32(count)
	health := state.health
	health.completion_occupancy = state.completed_count
	state.health = {
		completion_high_water = state.completed_count,
	}
	return count, health
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
