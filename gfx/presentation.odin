package gfx

import "core:sync"

FRAME_DELIVERY_MAX :: 128

Frame_Delivery_Timing :: struct {
	frame_index:            u64,
	renderer_cpu_seconds:   f64,
	acquire_cpu_seconds:    f64,
	encode_cpu_seconds:     f64,
	submit_cpu_seconds:     f64,
	present_cpu_seconds:    f64,
	host_cpu_seconds:       f64,
	pacer_wait_seconds:     f64,
	submit_timestamp:       f64,
	gpu_complete_timestamp: f64,
	gpu_complete_seconds:   f64,
	presented_timestamp:    f64,
	presentation_seconds:   f64,
	cpu_valid:              bool,
	gpu_complete_valid:     bool,
	presented_valid:        bool,
}

Frame_Delivery_Slot :: struct {
	timing:      Frame_Delivery_Timing,
	epoch:       u64,
	active:      bool,
	gpu_done:    bool,
	present_done: bool,
}

Frame_Delivery_State :: struct {
	mutex:          sync.Mutex,
	slots:          [FRAME_DELIVERY_MAX]Frame_Delivery_Slot,
	last_presented: f64,
	dropped:        u64,
	supported:      bool,
	closing:        bool,
}

frame_delivery_supported :: proc() -> bool {
	return context_frame_delivery_supported(default_context())
}

context_frame_delivery_supported :: proc(ctx: ^Context) -> bool {
	if ctx == nil do return false
	return ctx.delivery.supported
}

frame_delivery_record_host :: proc(host_cpu_seconds, pacer_wait_seconds: f64) {
	context_frame_delivery_record_host(default_context(), host_cpu_seconds, pacer_wait_seconds)
}

context_frame_delivery_record_host :: proc(
	ctx: ^Context,
	host_cpu_seconds, pacer_wait_seconds: f64,
) {
	if ctx == nil || host_cpu_seconds < 0 || pacer_wait_seconds < 0 do return
	sync.mutex_lock(&ctx.delivery.mutex)
	defer sync.mutex_unlock(&ctx.delivery.mutex)
	frame_index := ctx.stats_latest.frame_index
	slot := _frame_delivery_slot(ctx, frame_index)
	if slot == nil || slot.epoch != ctx.epoch do return
	slot.timing.host_cpu_seconds = host_cpu_seconds
	slot.timing.pacer_wait_seconds = pacer_wait_seconds
}

frame_delivery_drain :: proc(out: []Frame_Delivery_Timing) -> (count: int, dropped: u64) {
	return context_frame_delivery_drain(default_context(), out)
}

context_frame_delivery_drain :: proc(
	ctx: ^Context,
	out: []Frame_Delivery_Timing,
) -> (count: int, dropped: u64) {
	if ctx == nil || len(out) == 0 do return 0, 0
	sync.mutex_lock(&ctx.delivery.mutex)
	defer sync.mutex_unlock(&ctx.delivery.mutex)
	dropped = ctx.delivery.dropped
	ctx.delivery.dropped = 0
	for &slot in ctx.delivery.slots {
		if count >= len(out) do break
		if !slot.active || !slot.timing.cpu_valid || !slot.gpu_done || !slot.present_done do continue
		if slot.timing.gpu_complete_valid && slot.timing.presented_valid {
			out[count] = slot.timing
			count += 1
		}
		slot = {}
	}
	return
}

@(private)
_frame_delivery_init :: proc(ctx: ^Context) {
	assert(ctx != nil, "_frame_delivery_init: nil context")
	ctx.delivery.supported = platform_frame_delivery_init(ctx)
}

@(private)
_frame_delivery_shutdown :: proc(ctx: ^Context) {
	assert(ctx != nil, "_frame_delivery_shutdown: nil context")
	sync.mutex_lock(&ctx.delivery.mutex)
	ctx.delivery.closing = true
	sync.mutex_unlock(&ctx.delivery.mutex)
	platform_frame_delivery_shutdown(ctx)
	sync.mutex_lock(&ctx.delivery.mutex)
	ctx.delivery.slots = {}
	ctx.delivery.supported = false
	sync.mutex_unlock(&ctx.delivery.mutex)
}

@(private)
_frame_delivery_slot :: proc(ctx: ^Context, frame_index: u64) -> ^Frame_Delivery_Slot {
	assert(ctx != nil && frame_index > 0, "_frame_delivery_slot: invalid argument")
	for &slot in ctx.delivery.slots {
		if slot.active && slot.timing.frame_index == frame_index do return &slot
	}
	return nil
}

@(private)
_frame_delivery_begin :: proc(ctx: ^Context, frame_index: u64) {
	if ctx == nil || !ctx.delivery.supported || frame_index == 0 do return
	sync.mutex_lock(&ctx.delivery.mutex)
	defer sync.mutex_unlock(&ctx.delivery.mutex)
	if ctx.delivery.closing do return
	for &slot in ctx.delivery.slots {
		if slot.active do continue
		slot = {
			timing = {frame_index = frame_index},
			epoch = ctx.epoch,
			active = true,
		}
		return
	}
	ctx.delivery.dropped += 1
}

@(private)
_frame_delivery_submitted :: proc(ctx: ^Context, frame_index: u64, timestamp: f64) {
	if ctx == nil || timestamp <= 0 do return
	sync.mutex_lock(&ctx.delivery.mutex)
	defer sync.mutex_unlock(&ctx.delivery.mutex)
	slot := _frame_delivery_slot(ctx, frame_index)
	if slot == nil || slot.epoch != ctx.epoch do return
	slot.timing.submit_timestamp = timestamp
}

@(private)
_frame_delivery_cpu :: proc(ctx: ^Context, stats: Renderer_Stats) {
	if ctx == nil || stats.frame_index == 0 do return
	sync.mutex_lock(&ctx.delivery.mutex)
	defer sync.mutex_unlock(&ctx.delivery.mutex)
	slot := _frame_delivery_slot(ctx, stats.frame_index)
	if slot == nil || slot.epoch != ctx.epoch do return
	slot.timing.renderer_cpu_seconds = stats.frame_cpu_seconds
	slot.timing.acquire_cpu_seconds = stats.acquire_cpu_seconds
	slot.timing.encode_cpu_seconds = stats.encode_cpu_seconds
	slot.timing.submit_cpu_seconds = stats.submit_cpu_seconds
	slot.timing.present_cpu_seconds = stats.present_cpu_seconds
	slot.timing.cpu_valid = true
}

@(private)
_frame_delivery_gpu_complete :: proc(ctx: ^Context, frame_index: u64, timestamp: f64, valid: bool) {
	if ctx == nil || frame_index == 0 do return
	sync.mutex_lock(&ctx.delivery.mutex)
	defer sync.mutex_unlock(&ctx.delivery.mutex)
	slot := _frame_delivery_slot(ctx, frame_index)
	if slot == nil || slot.epoch != ctx.epoch do return
	slot.gpu_done = true
	if valid && timestamp >= slot.timing.submit_timestamp && slot.timing.submit_timestamp > 0 {
		slot.timing.gpu_complete_timestamp = timestamp
		slot.timing.gpu_complete_seconds = timestamp - slot.timing.submit_timestamp
		slot.timing.gpu_complete_valid = true
	}
}

@(private)
_frame_delivery_presented :: proc(ctx: ^Context, frame_index: u64, timestamp: f64) {
	if ctx == nil || frame_index == 0 do return
	sync.mutex_lock(&ctx.delivery.mutex)
	defer sync.mutex_unlock(&ctx.delivery.mutex)
	slot := _frame_delivery_slot(ctx, frame_index)
	if slot == nil || slot.epoch != ctx.epoch do return
	slot.present_done = true
	if timestamp <= 0 do return
	slot.timing.presented_timestamp = timestamp
	slot.timing.presented_valid = true
	if timestamp > ctx.delivery.last_presented && ctx.delivery.last_presented > 0 {
		slot.timing.presentation_seconds = timestamp - ctx.delivery.last_presented
	}
	if timestamp > ctx.delivery.last_presented do ctx.delivery.last_presented = timestamp
}
