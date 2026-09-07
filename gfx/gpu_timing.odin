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

// A slot walks this machine and only the submitting/collecting thread moves
// it; the backend callback never touches a slot.
//
//   Free -> Recording -> Sample_Pending -> Resolve_Submitted -> Map_Pending
//   Sample_Pending -> Sample_Failed -> Free            (collector retires)
//   Map_Pending -> Result_Ready | Map_Failed -> Free   (collector retires)
//   Sample_Pending | Map_Pending -> Quarantined        (retire unproved at close)
//   Quarantined -> Free                                (terminal callback observed later)
Gpu_Timing_Phase :: enum u8 {
	Free,
	Recording,
	Resolved,
	Sample_Pending,
	Resolve_Submitted,
	Sample_Failed,
	Map_Pending,
	Result_Ready,
	Map_Failed,
	Quarantined,
}

Gpu_Timing_Sample_Request :: struct {
	slot_index: u32,
	generation: u64,
	submission: u64,
	status:     wg.QueueWorkDoneStatus,
	armed:      bool,
	done:       bool,
	stray:      u32,
}

Gpu_Timing_Sample_Transition :: enum u8 {
	Pending,
	Resolve_Ready,
	Failed,
	Stale,
}

// One backend map registration. The submitter writes the identity and arms
// the record before BufferMapAsync; the backend callback is the only writer of
// the result fields and publishes them with a release store on `done`; the
// collector acquires `done`, consumes the results and retires the record.
// Records live in Gpu_Timing_State for the whole context lifetime and are
// never released while armed, so a late callback only ever reaches live
// storage. A callback that finds its record unarmed or already done is
// outside the backend's one-terminal-callback contract and is only counted.
Gpu_Timing_Map_Request :: struct {
	slot_index:  u32,
	generation:  u64,
	submission:  u64,
	query_count: u32,
	readback:    wg.Buffer,
	ticks:       [GPU_TIMING_QUERY_COUNT]u64,
	status:      wg.MapAsyncStatus,
	mapped:      bool,
	armed:       bool,
	done:        bool,
	stray:       u32,
}

Gpu_Timing_Slot :: struct {
	phase:         Gpu_Timing_Phase,
	generation:    u64,
	submission:    u64,
	epoch:         u64,
	query_set:     wg.QuerySet,
	resolve:       wg.Buffer,
	readback:      wg.Buffer,
	frame_index:   u64,
	query_count:   u32,
	labels:        [GPU_TIMING_MAX_SPANS]Gpu_Timing_Label,
	ticks:         [GPU_TIMING_QUERY_COUNT]u64,
	sample_status: wg.QueueWorkDoneStatus,
	map_status:    wg.MapAsyncStatus,
}

Gpu_Timing_Invalid_Pair :: struct {
	generation:  u64,
	submission:  u64,
	begin_tick:  u64,
	end_tick:    u64,
	slot_index:  u32,
	query_begin: u32,
	query_end:   u32,
	epoch:       u64,
	frame_index: u64,
	pair_index:  u32,
	label:       Gpu_Timing_Label,
	valid:       bool,
}

// stray_callbacks counts backend callbacks (timing, submission and screenshot
// registrations) that arrived for a record already retired or never armed.
// closed_rejections counts frames refused a timing slot after close began.
Gpu_Timing_Health :: struct {
	overflow:              u64,
	no_free_slot:          u64,
	pair_exhaustion:       u64,
	map_failure:           u64,
	sample_failure:        u64,
	resolve_failure:       u64,
	group_truncation:      u64,
	invalid_timestamps:    u64,
	stray_callbacks:       u64,
	closed_rejections:     u64,
	completion_occupancy:  u32,
	completion_high_water: u32,
	first_invalid_pair:    Gpu_Timing_Invalid_Pair,
}

Gpu_Timing_State :: struct {
	diagnostics:      [int(GPU_TIMING_DIAGNOSTICS)]Gpu_Timing_Diagnostics,
	generation:       u64,
	submission:       u64,
	completed:        [GPU_TIMING_COMPLETION_CAPACITY]Gpu_Frame_Timing_Detail,
	completed_head:   u32,
	completed_count:  u32,
	health:           Gpu_Timing_Health,
	slots:            [GPU_TIMING_FRAME_SLOTS]Gpu_Timing_Slot,
	sample_requests:  [GPU_TIMING_FRAME_SLOTS]Gpu_Timing_Sample_Request,
	requests:         [GPU_TIMING_FRAME_SLOTS]Gpu_Timing_Map_Request,
	active_slot:      int,
	timestamp_period: f64,
	latest:           Gpu_Frame_Timing,
	latest_detail:    Gpu_Frame_Timing_Detail,
	quarantined:      u32,
	available:        bool,
	closing:          bool,
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
			// No map was ever registered on a fresh state, so this cannot refuse.
			closed := _gpu_timing_shutdown(ctx)
			assert(closed, "_gpu_timing_init: fresh timing state refused to close")
			return false
		}
	}
	ctx.gpu_timing.timestamp_period = period
	ctx.gpu_timing.available = true
	return true
}

// _gpu_timing_slot_in_flight reports a slot whose map registration is armed
// with the backend and has not been retired by the collector.
_gpu_timing_slot_in_flight :: proc(slot: ^Gpu_Timing_Slot) -> bool {
	assert(slot != nil)
	return(
		slot.phase == .Sample_Pending ||
		slot.phase == .Resolve_Submitted ||
		slot.phase == .Map_Pending ||
		slot.phase == .Quarantined \
	)
}

_gpu_timing_pending_count :: proc(state: ^Gpu_Timing_State) -> u32 {
	assert(state != nil)
	pending := u32(0)
	for &slot, index in state.slots {
		sample_armed := sync.atomic_load(&state.sample_requests[index].armed)
		map_armed := sync.atomic_load(&state.requests[index].armed)
		assert(!(sample_armed && map_armed), "gpu timing: slot has two callback owners")
		if sample_armed || map_armed do pending += 1
		assert(
			!sample_armed || slot.phase == .Sample_Pending || slot.phase == .Quarantined,
			"gpu timing: sample record phase disagreement",
		)
		assert(
			!map_armed || slot.phase == .Map_Pending || slot.phase == .Quarantined,
			"gpu timing: map record phase disagreement",
		)
	}
	return pending
}

// _gpu_timing_quiesce drives every armed map registration to its terminal
// callback with bounded device polls, without closing the state. Returns
// false when a registration is still unproved after the bound.
_gpu_timing_quiesce :: proc(ctx: ^Context) -> bool {
	assert(ctx != nil, "_gpu_timing_quiesce: nil context")
	when ODIN_OS != .JS {
		for _ in 0 ..< GPU_TIMING_SHUTDOWN_POLLS {
			_gpu_timing_collect(ctx)
			if _gpu_timing_pending_count(&ctx.gpu_timing) == 0 do return true
			if ctx.device == nil do break
			wg.DevicePoll(ctx.device, true, nil)
		}
	}
	return _gpu_timing_pending_count(&ctx.gpu_timing) == 0
}

// _gpu_timing_retire rejects new frames, then makes bounded progress and a
// cancel attempt on every armed registration. Cancel is a request, not a
// join: the pinned backend answers Unmap on a waiting buffer with an inline
// Aborted callback, but only an observed terminal callback proves the
// registration retired. Unproved registrations are quarantined with their
// storage and buffers retained, and the caller must refuse destruction.
_gpu_timing_retire :: proc(ctx: ^Context) -> bool {
	assert(ctx != nil, "_gpu_timing_retire: nil context")
	state := &ctx.gpu_timing
	state.closing = true
	_gpu_timing_frame_abandon(ctx)
	if !_gpu_timing_quiesce(ctx) {
		when ODIN_OS != .JS {
			for &slot in state.slots {
				if slot.phase != .Map_Pending || slot.readback == nil do continue
				if ctx.device != nil do wg.BufferUnmap(slot.readback)
			}
		}
		_gpu_timing_collect(ctx)
	}
	state.quarantined = 0
	for &slot in state.slots {
		if slot.phase == .Map_Pending do slot.phase = .Quarantined
		if slot.phase == .Quarantined do state.quarantined += 1
	}
	return state.quarantined == 0
}

// _gpu_timing_release destroys the query and readback objects. Only legal once
// every registration is retired: a destroyed readback buffer aborts a waiting
// map inline today, but the storage the callback publishes into goes away here.
_gpu_timing_release :: proc(ctx: ^Context) {
	assert(ctx != nil, "_gpu_timing_release: nil context")
	assert(
		_gpu_timing_pending_count(&ctx.gpu_timing) == 0,
		"_gpu_timing_release: map registrations still armed",
	)
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

// _gpu_timing_shutdown retires and releases. A false return leaves the state
// intact (closing, with quarantined slots) so the caller can retry later.
_gpu_timing_shutdown :: proc(ctx: ^Context) -> bool {
	assert(ctx != nil, "_gpu_timing_shutdown: nil context")
	if !_gpu_timing_retire(ctx) do return false
	_gpu_timing_release(ctx)
	return true
}

_gpu_timing_frame_begin :: proc(ctx: ^Context) {
	assert(ctx != nil, "_gpu_timing_frame_begin: nil context")
	// A frame that never reached submit (surface unavailable, acquire failed)
	// leaves its slot recording; that slot is free again, not in flight.
	_gpu_timing_frame_abandon(ctx)
	if !ctx.gpu_timing.available do return
	if ctx.gpu_timing.closing {
		ctx.gpu_timing.health.closed_rejections += 1
		return
	}
	for &slot, index in ctx.gpu_timing.slots {
		if slot.phase != .Free do continue
		assert(slot.query_count == 0, "gpu timing: free slot retained queries")
		ctx.gpu_timing.generation += 1
		assert(ctx.gpu_timing.generation != 0)
		slot.generation = ctx.gpu_timing.generation
		when GPU_TIMING_DIAGNOSTICS {
			ctx.gpu_timing.diagnostics[0].bindings[index] = {}
			ctx.gpu_timing.diagnostics[0].resolve_encoder[index] = nil
			ctx.gpu_timing.diagnostics[0].resolve_ordinal[index] = 0
		}
		slot.phase = .Recording
		slot.submission = 0
		slot.frame_index = ctx.stats_current.frame_index
		slot.epoch = ctx.epoch
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
	if slot.phase != .Recording do return {}
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
	when GPU_TIMING_DIAGNOSTICS {
		_gpu_timing_diagnostic_bind(
			&ctx.gpu_timing.diagnostics[0],
			u32(ctx.gpu_timing.active_slot),
			token.query_begin / 2,
			encoder,
			nil,
			.Undefined,
			.Undefined,
		)
	}
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
	assert(slot.phase == .Recording, "gpu timing: resolve outside recording")
	slot.phase = .Resolved
	when GPU_TIMING_DIAGNOSTICS {
		ctx.gpu_timing.diagnostics[0].resolve_encoder[ctx.gpu_timing.active_slot] = encoder
	}
	bytes := u64(slot.query_count) * size_of(u64)
	wg.CommandEncoderResolveQuerySet(encoder, slot.query_set, 0, slot.query_count, slot.resolve, 0)
	wg.CommandEncoderCopyBufferToBuffer(encoder, slot.resolve, 0, slot.readback, 0, bytes)
}

// _gpu_timing_frame_submitted arms the slot's map record and registers it.
// The record is fully written and armed before BufferMapAsync because the
// pinned backend may run the callback inline (validation failure now, or any
// later QueueSubmit/DevicePoll), and the callback only trusts an armed record.
_gpu_timing_frame_submitted :: proc(ctx: ^Context) {
	if ctx == nil || ctx.gpu_timing.active_slot < 0 do return
	index := ctx.gpu_timing.active_slot
	slot := &ctx.gpu_timing.slots[index]
	ctx.gpu_timing.active_slot = -1
	if slot.query_count == 0 {
		slot.phase = .Free
		return
	}
	assert(slot.phase == .Resolved, "gpu timing: submit before resolve")
	assert(slot.query_count <= GPU_TIMING_QUERY_COUNT && slot.query_count % 2 == 0)
	ctx.gpu_timing.submission += 1
	assert(ctx.gpu_timing.submission != 0)
	slot.submission = ctx.gpu_timing.submission
	record := &ctx.gpu_timing.requests[index]
	assert(!record.armed && !record.done, "gpu timing: free slot with a live map record")
	_gpu_timing_fold_stray(&ctx.gpu_timing, record)
	record^ = {
		slot_index  = u32(index),
		generation  = slot.generation,
		submission  = slot.submission,
		query_count = slot.query_count,
		readback    = slot.readback,
	}
	slot.phase = .Map_Pending
	sync.atomic_store_explicit(&record.armed, true, .Release)
	wg.BufferMapAsync(
		slot.readback,
		{.Read},
		0,
		uint(u64(slot.query_count) * size_of(u64)),
		{mode = .AllowSpontaneos, callback = _gpu_timing_map_done, userdata1 = record},
	)
}

_gpu_timing_frame_abandon :: proc(ctx: ^Context) {
	if ctx == nil || ctx.gpu_timing.active_slot < 0 do return
	slot := &ctx.gpu_timing.slots[ctx.gpu_timing.active_slot]
	assert(!_gpu_timing_slot_in_flight(slot), "gpu timing: abandoning an armed slot")
	slot.query_count = 0
	slot.phase = .Free
	ctx.gpu_timing.active_slot = -1
}

_gpu_timing_fold_stray :: proc(state: ^Gpu_Timing_State, record: ^Gpu_Timing_Map_Request) {
	assert(state != nil && record != nil)
	state.health.stray_callbacks += u64(sync.atomic_exchange(&record.stray, 0))
}

_gpu_timing_fold_sample_stray :: proc(
	state: ^Gpu_Timing_State,
	record: ^Gpu_Timing_Sample_Request,
) {
	assert(state != nil && record != nil)
	state.health.stray_callbacks += u64(sync.atomic_exchange(&record.stray, 0))
}

_gpu_timing_sample_record_matches_slot :: proc(
	record: Gpu_Timing_Sample_Request,
	slot: ^Gpu_Timing_Slot,
	slot_index: int,
) -> bool {
	if slot == nil do return false
	return(
		record.armed &&
		slot.phase == .Sample_Pending &&
		record.slot_index == u32(slot_index) &&
		record.generation == slot.generation &&
		record.submission == slot.submission &&
		record.generation != 0 &&
		record.submission != 0 \
	)
}

_gpu_timing_sample_transition :: proc(
	record: Gpu_Timing_Sample_Request,
	slot: ^Gpu_Timing_Slot,
	slot_index: int,
) -> Gpu_Timing_Sample_Transition {
	if !_gpu_timing_sample_record_matches_slot(record, slot, slot_index) do return .Stale
	if !record.done do return .Pending
	if record.status != .Success do return .Failed
	return .Resolve_Ready
}

_gpu_timing_sample_retire :: proc(
	state: ^Gpu_Timing_State,
	slot_index: int,
) -> Gpu_Timing_Sample_Transition {
	if state == nil || slot_index < 0 || slot_index >= GPU_TIMING_FRAME_SLOTS do return .Stale
	slot := &state.slots[slot_index]
	record := &state.sample_requests[slot_index]
	transition := _gpu_timing_sample_transition(record^, slot, slot_index)
	if transition == .Pending || transition == .Stale do return transition
	slot.sample_status = record.status
	record^ = {}
	if transition == .Failed {
		slot.phase = .Sample_Failed
		state.health.sample_failure += 1
	} else {
		slot.phase = .Resolve_Submitted
	}
	return transition
}

_gpu_timing_sample_arm :: proc(state: ^Gpu_Timing_State, slot_index: int) -> bool {
	if state == nil || slot_index < 0 || slot_index >= GPU_TIMING_FRAME_SLOTS do return false
	slot := &state.slots[slot_index]
	record := &state.sample_requests[slot_index]
	if slot.phase != .Recording || slot.query_count == 0 || record.armed || record.done do return false
	state.submission += 1
	if state.submission == 0 do return false
	slot.submission = state.submission
	record^ = {
		slot_index = u32(slot_index),
		generation = slot.generation,
		submission = slot.submission,
	}
	slot.phase = .Sample_Pending
	sync.atomic_store_explicit(&record.armed, true, .Release)
	return true
}

_gpu_timing_sample_done :: proc "c" (
	status: wg.QueueWorkDoneStatus,
	message: wg.StringView,
	userdata1, userdata2: rawptr,
) {
	context = runtime.default_context()
	_ = message
	record := cast(^Gpu_Timing_Sample_Request)userdata1
	submission := u64(uintptr(userdata2))
	if record == nil do return
	if !sync.atomic_load_explicit(&record.armed, .Acquire) ||
	   sync.atomic_load(&record.done) ||
	   submission == 0 ||
	   submission != record.submission {
		sync.atomic_add(&record.stray, 1)
		return
	}
	record.status = status
	sync.atomic_store_explicit(&record.done, true, .Release)
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

// _gpu_timing_collect is the only retirer of map records. It consumes each
// published result into the slot, then clears the record; a callback arriving
// after that point is stray by the backend contract and only counted.
_gpu_timing_collect :: proc(ctx: ^Context) {
	if ctx == nil || !ctx.gpu_timing.available do return
	for &slot, slot_index in ctx.gpu_timing.slots {
		record := &ctx.gpu_timing.requests[slot_index]
		_gpu_timing_fold_sample_stray(&ctx.gpu_timing, &ctx.gpu_timing.sample_requests[slot_index])
		_gpu_timing_fold_stray(&ctx.gpu_timing, record)
		if !_gpu_timing_slot_in_flight(&slot) do continue
		if !sync.atomic_load_explicit(&record.done, .Acquire) do continue
		assert(
			_gpu_timing_record_matches_slot(record^, &slot, slot_index),
			"gpu timing: map record identity diverged from its slot",
		)
		slot.map_status = record.status
		if record.mapped {
			slot.phase = .Result_Ready
			copy(slot.ticks[:record.query_count], record.ticks[:record.query_count])
			_gpu_timing_diagnostic_collect(ctx, slot_index)
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
				_gpu_timing_record_invalid(&ctx.gpu_timing, &slot, slot_index)
			}
		} else {
			slot.phase = .Map_Failed
			ctx.gpu_timing.health.map_failure += 1
		}
		// Only a Success status left the range mapped; unmapping anything else
		// would raise a backend validation error for a buffer that never mapped.
		if record.status == .Success && slot.readback != nil do wg.BufferUnmap(slot.readback)
		record^ = {}
		slot.query_count = 0
		slot.phase = .Free
	}
}

_gpu_timing_record_invalid :: proc(
	state: ^Gpu_Timing_State,
	slot: ^Gpu_Timing_Slot,
	slot_index: int,
) {
	assert(state != nil && slot != nil)
	state.health.invalid_timestamps += 1
	pair_index, invalid := _gpu_timing_invalid_pair(slot.ticks[:], slot.query_count / 2)
	if !invalid || state.health.first_invalid_pair.valid do return
	assert(int(pair_index) * 2 + 1 < len(slot.ticks), "gpu timing: invalid pair index")
	state.health.first_invalid_pair = {
		generation  = slot.generation,
		submission  = slot.submission,
		begin_tick  = slot.ticks[pair_index * 2],
		end_tick    = slot.ticks[pair_index * 2 + 1],
		slot_index  = u32(slot_index),
		query_begin = pair_index * 2,
		query_end   = pair_index * 2 + 1,
		epoch       = slot.epoch,
		frame_index = slot.frame_index,
		pair_index  = pair_index,
		label       = slot.labels[pair_index],
		valid       = true,
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

_gpu_timing_record_matches_slot :: proc(
	record: Gpu_Timing_Map_Request,
	slot: ^Gpu_Timing_Slot,
	slot_index: int,
) -> bool {
	if slot == nil do return false
	return(
		record.armed &&
		_gpu_timing_slot_in_flight(slot) &&
		record.slot_index == u32(slot_index) &&
		slot.generation == record.generation &&
		slot.submission == record.submission &&
		slot.query_count == record.query_count &&
		slot.readback == record.readback &&
		record.query_count > 0 &&
		record.query_count <= GPU_TIMING_QUERY_COUNT &&
		record.query_count % 2 == 0 \
	)
}

// _gpu_timing_map_done publishes into its own record and nothing else. It may
// run inline from BufferMapAsync, QueueSubmit, DevicePoll or BufferUnmap on
// the pinned backend, so it never inspects slot or context state.
_gpu_timing_map_done :: proc "c" (
	status: wg.MapAsyncStatus,
	message: wg.StringView,
	userdata1, userdata2: rawptr,
) {
	context = runtime.default_context()
	_ = message
	_ = userdata2
	record := cast(^Gpu_Timing_Map_Request)userdata1
	if record == nil do return
	if !sync.atomic_load_explicit(&record.armed, .Acquire) || sync.atomic_load(&record.done) {
		sync.atomic_add(&record.stray, 1)
		return
	}
	ok := status == .Success
	if ok {
		bytes := uint(u64(record.query_count) * size_of(u64))
		mapped := wg.BufferGetConstMappedRange(record.readback, 0, bytes)
		if mapped == nil {
			ok = false
		} else {
			mem.copy(raw_data(record.ticks[:]), raw_data(mapped), int(bytes))
		}
	}
	record.status = status
	record.mapped = ok
	sync.atomic_store_explicit(&record.done, true, .Release)
}
