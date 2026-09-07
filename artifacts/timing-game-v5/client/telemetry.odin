#+build !js
package main

import shared "../shared"
import "core:fmt"
import "core:os"
import "core:strings"
import rl "ingot:gfx"

// Sidecar writer for aesir's live profiler. aesir samples us from outside with
// ps and sample, which can see resident memory and thread stacks but nothing
// about where a frame actually goes. This appends the phase profiler's own
// numbers, plus ingot's renderer counters, to the path aesir passes in
// AESIR_TELEMETRY; aesir tails the file and folds each line into its recording.
//
// Absent the environment variable this is a pair of no-ops, so a plain run pays
// nothing and never creates a file.

TELEMETRY_ENV :: "AESIR_TELEMETRY"
// One line per second. The profiler's own 120-frame window already carries the
// hitch information in its peak column, so a faster cadence adds cost, not data.
TELEMETRY_INTERVAL :: f64(1)
TELEMETRY_GPU_GROUPS_MAX :: rl.GPU_TIMING_MAX_GROUPS
TELEMETRY_DELIVERY_MAX :: 32
TELEMETRY_GPU_FRAME_MAX :: 16
TELEMETRY_DRAIN_CHUNKS_MAX ::
	(rl.GPU_TIMING_COMPLETION_CAPACITY + TELEMETRY_GPU_FRAME_MAX - 1) / TELEMETRY_GPU_FRAME_MAX
FORGE_FRAME_PACING_MODE :: #config(FORGE_FRAME_PACING_MODE, 0)

Telemetry_GPU_Group :: struct {
	label:   rl.Gpu_Timing_Label,
	last_ms: f64,
	sum_ms:  f64,
	peak_ms: f64,
	count:   u32,
}

Telemetry :: struct {
	handle:           ^os.File,
	open:             bool,
	next_at:          f64,
	frame:            u64,
	raw_sequence:     u64,
	gpu_epoch:        u64,
	gpu_frame:        u64,
	gpu_seen:         bool,
	gpu_detail_epoch: u64,
	gpu_detail_frame: u64,
	gpu_detail_seen:  bool,
	gpu_last_ms:      f64,
	gpu_sum_ms:       f64,
	gpu_peak_ms:      f64,
	gpu_count:        u32,
	gpu_groups:       [TELEMETRY_GPU_GROUPS_MAX]Telemetry_GPU_Group,
	gpu_group_count:  u32,
	delivery:         [TELEMETRY_DELIVERY_MAX]rl.Frame_Delivery_Timing,
	delivery_count:   u32,
	delivery_dropped: u64,
	gpu_frames:       [TELEMETRY_GPU_FRAME_MAX]rl.Gpu_Frame_Timing_Detail,
	gpu_frame_count:  u32,
	gpu_health:       rl.Gpu_Timing_Health,
	write_failures:   u64,
	pump_exhausted:   u64,
}

telemetry_init :: proc(value: ^Telemetry) {
	assert(value != nil, "telemetry_init: nil telemetry")
	when PROFILE_ENABLED {
		path := os.get_env(TELEMETRY_ENV, context.temp_allocator)
		if len(path) == 0 do return
		handle, open_error := os.open(path, os.O_WRONLY | os.O_CREATE | os.O_APPEND)
		if open_error != nil do return
		value.handle = handle
		value.open = true
		value.raw_sequence = 1
	}
}

telemetry_shutdown :: proc(value: ^Telemetry) {
	assert(value != nil, "telemetry_shutdown: nil telemetry")
	when PROFILE_ENABLED {
		if !value.open do return
		_ = telemetry_records_pump(value)
		telemetry_records_write(value)
		telemetry_diagnostics_shutdown()
		_ = os.close(value.handle)
		value.handle = nil
		value.open = false
	}
}

telemetry_gpu_record :: proc(value: ^Telemetry, gpu: rl.Gpu_Frame_Timing_Detail) {
	assert(value != nil, "telemetry_gpu_record: nil telemetry")
	if !gpu.valid do return
	if value.gpu_seen && gpu.epoch == value.gpu_epoch && gpu.frame_index == value.gpu_frame do return
	value.gpu_epoch = gpu.epoch
	value.gpu_frame = gpu.frame_index
	value.gpu_seen = true
	value.gpu_last_ms = gpu.seconds * 1_000
	value.gpu_sum_ms += value.gpu_last_ms
	value.gpu_peak_ms = max(value.gpu_peak_ms, value.gpu_last_ms)
	value.gpu_count += 1
}

telemetry_gpu_detail_record :: proc(value: ^Telemetry, gpu: rl.Gpu_Frame_Timing_Detail) {
	assert(value != nil, "telemetry_gpu_detail_record: nil telemetry")
	if !gpu.valid do return
	if value.gpu_detail_seen &&
	   gpu.epoch == value.gpu_detail_epoch &&
	   gpu.frame_index == value.gpu_detail_frame {
		return
	}
	value.gpu_detail_epoch = gpu.epoch
	value.gpu_detail_frame = gpu.frame_index
	value.gpu_detail_seen = true
	for group_index in 0 ..< int(gpu.group_count) {
		group := gpu.groups[group_index]
		index := -1
		for existing in 0 ..< int(value.gpu_group_count) {
			if value.gpu_groups[existing].label == group.label {
				index = existing
				break
			}
		}
		if index < 0 {
			if value.gpu_group_count >= TELEMETRY_GPU_GROUPS_MAX do continue
			index = int(value.gpu_group_count)
			value.gpu_groups[index].label = group.label
			value.gpu_group_count += 1
		}
		milliseconds := group.seconds * 1_000
		value.gpu_groups[index].last_ms = milliseconds
		value.gpu_groups[index].sum_ms += milliseconds
		value.gpu_groups[index].peak_ms = max(value.gpu_groups[index].peak_ms, milliseconds)
		value.gpu_groups[index].count += 1
	}
}

telemetry_gpu_health_add :: proc(value: ^Telemetry, health: rl.Gpu_Timing_Health) {
	assert(value != nil)
	value.gpu_health.overflow += health.overflow
	value.gpu_health.no_free_slot += health.no_free_slot
	value.gpu_health.pair_exhaustion += health.pair_exhaustion
	value.gpu_health.map_failure += health.map_failure
	value.gpu_health.group_truncation += health.group_truncation
	value.gpu_health.invalid_timestamps += health.invalid_timestamps
	value.gpu_health.completion_occupancy = health.completion_occupancy
	value.gpu_health.completion_high_water = max(
		value.gpu_health.completion_high_water,
		health.completion_high_water,
	)
	if !value.gpu_health.first_invalid_pair.valid && health.first_invalid_pair.valid {
		value.gpu_health.first_invalid_pair = health.first_invalid_pair
	}
}

telemetry_records_collect :: proc(value: ^Telemetry) {
	assert(value != nil)
	gpu_count, health := rl.context_renderer_gpu_timing_drain(
		rl.default_context(),
		value.gpu_frames[value.gpu_frame_count:],
	)
	value.gpu_frame_count += u32(gpu_count)
	telemetry_gpu_health_add(value, health)
	for detail in value.gpu_frames[value.gpu_frame_count - u32(gpu_count):value.gpu_frame_count] {
		telemetry_gpu_record(value, detail)
		telemetry_gpu_detail_record(value, detail)
	}
	available := TELEMETRY_DELIVERY_MAX - int(value.delivery_count)
	if available <= 0 do return
	count, dropped := rl.context_frame_delivery_drain(
		rl.default_context(),
		value.delivery[value.delivery_count:],
	)
	value.delivery_count += u32(count)
	value.delivery_dropped += dropped
}

telemetry_records_write :: proc(value: ^Telemetry) -> bool {
	assert(value != nil)
	if !value.open do return false
	if value.gpu_frame_count == 0 &&
	   value.delivery_count == 0 &&
	   value.delivery_dropped == 0 &&
	   value.gpu_health == {} {
		return true
	}
	builder := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&builder, `{{"rt":1,"sq":%d,"gfd":[`, value.raw_sequence)
	for detail, detail_index in value.gpu_frames[:value.gpu_frame_count] {
		if detail_index > 0 do strings.write_byte(&builder, ',')
		fmt.sbprintf(
			&builder,
			`{{"e":%d,"i":%d,"ms":%.4f,"v":%v,"tg":%d,"g":[`,
			detail.epoch,
			detail.frame_index,
			detail.seconds * 1_000,
			detail.valid,
			detail.groups_truncated,
		)
		for group_index in 0 ..< int(detail.group_count) {
			if group_index > 0 do strings.write_byte(&builder, ',')
			group := detail.groups[group_index]
			label := rl.gpu_timing_label_string(&group.label)
			fmt.sbprintf(
				&builder,
				`{{"n":"%s","ms":%.4f,"c":%d}}`,
				label,
				group.seconds * 1_000,
				group.count,
			)
		}
		strings.write_string(&builder, "]}")
	}
	invalid := value.gpu_health.first_invalid_pair
	invalid_label := rl.gpu_timing_label_string(&invalid.label)
	fmt.sbprintf(
		&builder,
		`],"gh":{{"o":%d,"s":%d,"q":%d,"m":%d,"g":%d,"t":%d,"co":%d,"ch":%d,"iv":%v,"ie":%d,"ii":%d,"ip":%d,"il":"%s","ib":%d,"it":%d,"is":%d,"iqb":%d,"iqe":%d,"ign":%d,"isu":%d}},"fd":[`,
		value.gpu_health.overflow,
		value.gpu_health.no_free_slot,
		value.gpu_health.pair_exhaustion,
		value.gpu_health.map_failure,
		value.gpu_health.group_truncation,
		value.gpu_health.invalid_timestamps,
		value.gpu_health.completion_occupancy,
		value.gpu_health.completion_high_water,
		invalid.valid,
		invalid.epoch,
		invalid.frame_index,
		invalid.pair_index,
		invalid_label,
		invalid.begin_tick,
		invalid.end_tick,
		invalid.slot_index,
		invalid.query_begin,
		invalid.query_end,
		invalid.generation,
		invalid.submission,
	)
	for delivery, index in value.delivery[:value.delivery_count] {
		if index > 0 do strings.write_byte(&builder, ',')
		flags := u8(1)
		if delivery.gpu_complete_valid do flags |= 2
		if delivery.presented_valid do flags |= 4
		fmt.sbprintf(
			&builder,
			`{{"e":%d,"i":%d,"rc":%.4f,"hc":%.4f,"aq":%.4f,"en":%.4f,"sb":%.4f,"ps":%.4f,"pw":%.4f,"st":%.9f,"gt":%.9f,"gc":%.4f,"pt":%.9f,"pi":%.4f,"v":%d,"su":%v,"mg":%v,"mp":%v}}`,
			delivery.epoch,
			delivery.frame_index,
			delivery.renderer_cpu_seconds * 1_000,
			delivery.host_cpu_seconds * 1_000,
			delivery.acquire_cpu_seconds * 1_000,
			delivery.encode_cpu_seconds * 1_000,
			delivery.submit_cpu_seconds * 1_000,
			delivery.present_cpu_seconds * 1_000,
			delivery.pacer_wait_seconds * 1_000,
			delivery.submit_timestamp,
			delivery.gpu_complete_timestamp,
			delivery.gpu_complete_seconds * 1_000,
			delivery.presented_timestamp,
			delivery.presentation_seconds * 1_000,
			flags,
			delivery.presentation_supported,
			delivery.missing_gpu_callback,
			delivery.missing_present_callback,
		)
	}
	fmt.sbprintf(
		&builder,
		`],"fdd":%d,"wf":%d,"px":%d}}`,
		value.delivery_dropped,
		value.write_failures,
		value.pump_exhausted,
	)
	strings.write_byte(&builder, '\n')
	data := transmute([]u8)strings.to_string(builder)
	written, write_error := os.write(value.handle, data)
	if write_error != nil || written != len(data) {
		value.write_failures += 1
		return false
	}
	value.raw_sequence += 1
	value.gpu_frame_count = 0
	value.gpu_health = {}
	value.delivery_count = 0
	value.delivery_dropped = 0
	return true
}

telemetry_records_pump :: proc(value: ^Telemetry) -> bool {
	assert(value != nil)
	for _ in 0 ..< TELEMETRY_DRAIN_CHUNKS_MAX {
		telemetry_records_collect(value)
		full :=
			value.gpu_frame_count == TELEMETRY_GPU_FRAME_MAX ||
			value.delivery_count == TELEMETRY_DELIVERY_MAX
		backlogged := value.gpu_health.completion_occupancy > 0
		if !full && !backlogged do return true
		if !telemetry_records_write(value) do return false
	}
	if value.gpu_health.completion_occupancy > 0 {
		value.pump_exhausted += 1
		return false
	}
	return true
}

// telemetry_publish writes one line once the interval has elapsed. Phases with
// no recorded time are still emitted: a zero row is information (the phase was
// skipped this window), and a stable key set keeps recordings comparable.
//
// The write result is deliberately discarded. A full disk or a sidecar deleted
// underneath us must never disturb the frame it was measuring.
telemetry_publish :: proc(
	value: ^Telemetry,
	profiler: ^Profiler,
	performance: ^Performance_State,
	now: f64,
	target: ^rl.Gpu_3D_Target = nil,
	opaque_mode: u32 = 0,
	opaque_draw_mask: u32 = 0,
) {
	assert(
		value != nil && profiler != nil && performance != nil,
		"telemetry_publish: nil argument",
	)
	when PROFILE_ENABLED {
		if !value.open do return
		if !telemetry_records_pump(value) do return
		if now < value.next_at do return
		if !telemetry_records_write(value) do return
		value.next_at = now + TELEMETRY_INTERVAL
		if profiler.filled == 0 do return
		value.frame += 1
		total := profile_summary(profiler.totals[:], profiler.filled, profiler.frame)
		stats := rl.renderer_stats()
		// The previous frame's complete presentation timeline: the profiler
		// only sees game_frame, so drawable acquisition, encoding, queue
		// submission and present waits are reported from ingot separately.
		latest := rl.renderer_stats_latest()
		builder := strings.builder_make(context.temp_allocator)
		width, height := rl.GetRenderWidth(), rl.GetRenderHeight()
		target_width, target_height := width, height
		if target != nil {
			measured_width, measured_height, valid := rl.gpu_3d_target_size(target)
			target_width, target_height = 0, 0
			if valid do target_width, target_height = measured_width, measured_height
		}
		fmt.sbprintf(
			&builder,
			`{{"i":%d,"fl":%.4f,"fm":%.4f,"fp":%.4f,"f50":%.4f,"f95":%.4f,"f99":%.4f,"gv":%v,"gl":%.4f,"gm":%.4f,"gp":%.4f,"d":%d,"di":%d,"vd":%d,"rp":%d,"sbc":%d,"hz":%d,"bt":%.4f,"rs":%.2f,"ww":%d,"wh":%d,"tw":%d,"th":%d,"mc":%d,"mr":%.6f,"pr":%.3f,"pm":%d,"sm":%d,"gg":[`,
			value.frame,
			total.last,
			total.mean,
			total.peak,
			total.p50,
			total.p95,
			total.p99,
			value.gpu_count > 0,
			value.gpu_last_ms,
			value.gpu_sum_ms / f64(max(value.gpu_count, 1)),
			value.gpu_peak_ms,
			stats.gpu3d_draws,
			stats.gpu3d_instanced_draws,
			stats.gpu3d_vertices_drawn,
			stats.render_passes,
			stats.gpu3d_scene_bind_creations,
			performance.refresh_rate,
			performance.target_seconds * 1_000,
			performance.render_scale,
			width,
			height,
			target_width,
			target_height,
			performance.total_misses,
			performance_miss_ratio(performance),
			performance.pressure,
			FORGE_FRAME_PACING_MODE,
			int(rl.context_surface_present_mode(rl.default_context())),
		)
		for &group, index in value.gpu_groups[:value.gpu_group_count] {
			if index > 0 do strings.write_byte(&builder, ',')
			label := rl.gpu_timing_label_string(&group.label)
			fmt.sbprintf(
				&builder,
				`{{"n":"%s","l":%.4f,"m":%.4f,"k":%.4f,"c":%d}}`,
				label,
				group.last_ms,
				group.sum_ms / f64(max(group.count, 1)),
				group.peak_ms,
				group.count,
			)
		}
		fmt.sbprintf(
			&builder,
			`],"om":%d,"odm":%d,"wf":%d,"p":[`,
			opaque_mode,
			opaque_draw_mask,
			value.write_failures,
		)
		names := PROFILE_PHASE_NAMES
		first := true
		for phase in Profile_Phase {
			if phase == .None do continue
			summary := profile_summary(profiler.samples[phase][:], profiler.filled, profiler.frame)
			if !first do strings.write_byte(&builder, ',')
			first = false
			fmt.sbprintf(
				&builder,
				`{{"n":"%s","l":%.4f,"m":%.4f,"k":%.4f}}`,
				names[phase],
				summary.last,
				summary.mean,
				summary.peak,
			)
		}
		strings.write_string(&builder, "],")
		// Authoritative tick breakdown: "tc" ticks so far, "tl"/"tk" last and
		// peak-since-last-line total, "s" per-stage last/peak. Peaks reset per
		// line so a spike in the previous second is attributable to a stage.
		stage_names := shared.SIM_STAGE_NAMES
		fmt.sbprintf(
			&builder,
			`"tc":%d,"tl":%.4f,"tk":%.4f,"pc":%d,"pf":%d,"pk":%.4f,"aq":%.4f,"en":%.4f,"sb":%.4f,"ps":%.4f,"fc":%.4f,"ca":%d,"cg":%d,"cp":%d,"cr":%d,"cw":%d,"cv":%d,"cu":%d,"s":[`,
			profiler.tick.count,
			profiler.tick.last.total_ms,
			profiler.tick.peak_total,
			profiler.tick.prepared_commits,
			profiler.tick.prepared_fallbacks,
			profiler.tick.prepared_peak,
			latest.acquire_cpu_seconds * 1_000,
			latest.encode_cpu_seconds * 1_000,
			latest.submit_cpu_seconds * 1_000,
			latest.present_cpu_seconds * 1_000,
			latest.frame_cpu_seconds * 1_000,
			profiler.clipmap.anchor_changes,
			profiler.clipmap.generations_started,
			profiler.clipmap.generations_published,
			profiler.clipmap.rings_filled,
			profiler.clipmap.rows_filled,
			profiler.clipmap.vertices_filled,
			profiler.clipmap.gpu_uploads,
		)
		first = true
		for stage in shared.Sim_Stage {
			if !first do strings.write_byte(&builder, ',')
			first = false
			fmt.sbprintf(
				&builder,
				`{{"n":"%s","l":%.4f,"k":%.4f}}`,
				stage_names[stage],
				profiler.tick.last.stage_ms[stage],
				profiler.tick.peak_stage[stage],
			)
		}
		strings.write_string(&builder, "]}\n")
		data := transmute([]u8)strings.to_string(builder)
		written, write_error := os.write(value.handle, data)
		if write_error != nil || written != len(data) {
			value.write_failures += 1
			return
		}
		value.gpu_sum_ms = 0
		value.gpu_peak_ms = 0
		value.gpu_count = 0
		for &group in value.gpu_groups do group = {}
		value.gpu_group_count = 0
		profile_tick_reset_peaks(profiler)
		profile_clipmap_reset(profiler)
	}
}
