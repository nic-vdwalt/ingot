package gfx

import "core:sync"

FRAME_DELIVERY_MAX :: 128
FRAME_DELIVERY_RETIRE_LAG :: 64
FRAME_DELIVERY_QUIESCE_POLLS :: 200
FRAME_DELIVERY_QUIESCE_SECONDS :: 0.005

Host_Frame_Timing :: struct {
	total_seconds:   f64,
	reload_seconds:  f64,
	refresh_seconds: f64,
	draw_seconds:    f64,
	prepare_seconds: f64,
	cursor_seconds:  f64,
}

Frame_Delivery_Timing :: struct {
	epoch:                           u64,
	presentation_supported:          bool,
	missing_gpu_callback:            bool,
	missing_present_callback:        bool,
	frame_index:                     u64,
	renderer_cpu_seconds:            f64,
	draw_cpu_seconds:                f64,
	pre_acquire_cpu_seconds:         f64,
	stream_acquire_cpu_seconds:      f64,
	acquire_cpu_seconds:             f64,
	post_acquire_cpu_seconds:        f64,
	flush_cpu_seconds:               f64,
	stream_upload_cpu_seconds:       f64,
	encode_cpu_seconds:              f64,
	submit_cpu_seconds:              f64,
	present_cpu_seconds:             f64,
	cleanup_cpu_seconds:             f64,
	input_cpu_seconds:               f64,
	frame_timing_cpu_seconds:        f64,
	host_cpu_seconds:                f64,
	host_reload_cpu_seconds:         f64,
	host_refresh_cpu_seconds:        f64,
	host_draw_cpu_seconds:           f64,
	host_prepare_cpu_seconds:        f64,
	host_cursor_cpu_seconds:         f64,
	host_unaccounted_seconds:        f64,
	pacer_wait_seconds:              f64,
	submissions_before_poll:         u32,
	submissions_after_poll:          u32,
	submissions_at_submit:           u32,
	submissions_high_water:          u32,
	oldest_submission_frame_age:     u64,
	intermediate_upload_count:       u32,
	intermediate_finish_count:       u32,
	intermediate_submit_count:       u32,
	final_upload_count:              u32,
	final_finish_count:              u32,
	final_submit_count:              u32,
	intermediate_upload_max_seconds: f64,
	intermediate_finish_max_seconds: f64,
	intermediate_submit_max_seconds: f64,
	final_upload_max_seconds:        f64,
	final_finish_max_seconds:        f64,
	final_submit_max_seconds:        f64,
	submit_timestamp:                f64,
	gpu_complete_timestamp:          f64,
	gpu_complete_seconds:            f64,
	presented_timestamp:             f64,
	presentation_seconds:            f64,
	cpu_valid:                       bool,
	gpu_complete_valid:              bool,
	presented_valid:                 bool,
}

Frame_Delivery_Slot :: struct {
	timing:       Frame_Delivery_Timing,
	epoch:        u64,
	active:       bool,
	gpu_done:     bool,
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

context_frame_delivery_supported :: proc(ctx: ^Context) -> bool {
	if ctx == nil do return false
	return ctx.delivery.supported
}

context_frame_delivery_record_host_detail :: proc(
	ctx: ^Context,
	timing: Host_Frame_Timing,
	pacer_wait_seconds: f64,
) {
	accounted :=
		timing.reload_seconds +
		timing.refresh_seconds +
		timing.draw_seconds +
		timing.prepare_seconds +
		timing.cursor_seconds
	if ctx == nil || timing.total_seconds < 0 || pacer_wait_seconds < 0 || accounted < 0 do return
	if timing.reload_seconds < 0 || timing.refresh_seconds < 0 || timing.draw_seconds < 0 do return
	if timing.prepare_seconds < 0 || timing.cursor_seconds < 0 do return
	sync.mutex_lock(&ctx.delivery.mutex)
	defer sync.mutex_unlock(&ctx.delivery.mutex)
	frame_index := ctx.stats_latest.frame_index
	if frame_index == 0 do return
	slot := _frame_delivery_slot(ctx, frame_index)
	if slot == nil || slot.epoch != ctx.epoch do return
	slot.timing.host_cpu_seconds = timing.total_seconds
	slot.timing.host_reload_cpu_seconds = timing.reload_seconds
	slot.timing.host_refresh_cpu_seconds = timing.refresh_seconds
	slot.timing.host_draw_cpu_seconds = timing.draw_seconds
	slot.timing.host_prepare_cpu_seconds = timing.prepare_seconds
	slot.timing.host_cursor_cpu_seconds = timing.cursor_seconds
	slot.timing.host_unaccounted_seconds = max(timing.total_seconds - accounted, f64(0))
	slot.timing.pacer_wait_seconds = pacer_wait_seconds
}

context_frame_delivery_record_host :: proc(
	ctx: ^Context,
	host_cpu_seconds, pacer_wait_seconds: f64,
) {
	context_frame_delivery_record_host_detail(
		ctx,
		{total_seconds = host_cpu_seconds},
		pacer_wait_seconds,
	)
}

context_frame_delivery_drain :: proc(
	ctx: ^Context,
	out: []Frame_Delivery_Timing,
) -> (
	count: int,
	dropped: u64,
) {
	if ctx == nil || len(out) == 0 do return 0, 0
	sync.mutex_lock(&ctx.delivery.mutex)
	defer sync.mutex_unlock(&ctx.delivery.mutex)
	dropped = ctx.delivery.dropped
	ctx.delivery.dropped = 0
	latest_frame := ctx.stats_latest.frame_index
	for &slot in ctx.delivery.slots {
		if count >= len(out) do break
		if !slot.active || !slot.timing.cpu_valid do continue
		terminal := slot.gpu_done && slot.present_done
		stale :=
			latest_frame > slot.timing.frame_index &&
			latest_frame - slot.timing.frame_index >= FRAME_DELIVERY_RETIRE_LAG
		if !terminal && !stale do continue
		slot.timing.missing_gpu_callback = !slot.gpu_done
		slot.timing.missing_present_callback = !slot.present_done
		out[count] = slot.timing
		count += 1
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
	if ctx == nil || frame_index == 0 do return
	sync.mutex_lock(&ctx.delivery.mutex)
	defer sync.mutex_unlock(&ctx.delivery.mutex)
	if ctx.delivery.closing do return
	for &slot in ctx.delivery.slots {
		if slot.active do continue
		slot = {
			timing = {
				frame_index = frame_index,
				epoch = ctx.epoch,
				presentation_supported = ctx.delivery.supported,
			},
			epoch = ctx.epoch,
			active = true,
			present_done = !ctx.delivery.supported,
		}
		return
	}
	ctx.delivery.dropped += 1
}

@(private)
_frame_delivery_abandon :: proc(ctx: ^Context, frame_index: u64) {
	if ctx == nil || frame_index == 0 do return
	sync.mutex_lock(&ctx.delivery.mutex)
	defer sync.mutex_unlock(&ctx.delivery.mutex)
	slot := _frame_delivery_slot(ctx, frame_index)
	if slot == nil || slot.epoch != ctx.epoch do return
	slot^ = {}
}

@(private)
_frame_delivery_submitted :: proc(ctx: ^Context, frame_index: u64, timestamp: f64) {
	if ctx == nil || frame_index == 0 || timestamp <= 0 do return
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
	slot.timing.draw_cpu_seconds = stats.draw_cpu_seconds
	slot.timing.pre_acquire_cpu_seconds = stats.pre_acquire_cpu_seconds
	slot.timing.stream_acquire_cpu_seconds = stats.stream_acquire_cpu_seconds
	slot.timing.acquire_cpu_seconds = stats.acquire_cpu_seconds
	slot.timing.post_acquire_cpu_seconds = stats.post_acquire_cpu_seconds
	slot.timing.flush_cpu_seconds = stats.flush_cpu_seconds
	slot.timing.stream_upload_cpu_seconds = stats.stream_upload_cpu_seconds
	slot.timing.encode_cpu_seconds = stats.encode_cpu_seconds
	slot.timing.submit_cpu_seconds = stats.submit_cpu_seconds
	slot.timing.present_cpu_seconds = stats.present_cpu_seconds
	slot.timing.cleanup_cpu_seconds = stats.cleanup_cpu_seconds
	slot.timing.input_cpu_seconds = stats.input_cpu_seconds
	slot.timing.frame_timing_cpu_seconds = stats.frame_timing_cpu_seconds
	slot.timing.submissions_before_poll = stats.submissions_before_poll
	slot.timing.submissions_after_poll = stats.submissions_after_poll
	slot.timing.submissions_at_submit = stats.submissions_at_submit
	slot.timing.submissions_high_water = stats.submissions_high_water
	slot.timing.oldest_submission_frame_age = stats.oldest_submission_frame_age
	slot.timing.intermediate_upload_count = stats.intermediate_upload_count
	slot.timing.intermediate_finish_count = stats.intermediate_finish_count
	slot.timing.intermediate_submit_count = stats.intermediate_submit_count
	slot.timing.final_upload_count = stats.final_upload_count
	slot.timing.final_finish_count = stats.final_finish_count
	slot.timing.final_submit_count = stats.final_submit_count
	slot.timing.intermediate_upload_max_seconds = stats.intermediate_upload_max_seconds
	slot.timing.intermediate_finish_max_seconds = stats.intermediate_finish_max_seconds
	slot.timing.intermediate_submit_max_seconds = stats.intermediate_submit_max_seconds
	slot.timing.final_upload_max_seconds = stats.final_upload_max_seconds
	slot.timing.final_finish_max_seconds = stats.final_finish_max_seconds
	slot.timing.final_submit_max_seconds = stats.final_submit_max_seconds
	slot.timing.cpu_valid = true
}

@(private)
_frame_delivery_gpu_complete :: proc(
	ctx: ^Context,
	frame_index: u64,
	timestamp: f64,
	valid: bool,
) {
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
