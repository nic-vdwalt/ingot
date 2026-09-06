package main

import shared "../shared"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import rl "ingot:gfx"

// The sidecar is the only part of the profiler another program parses, so its
// shape is pinned here. aesir decodes these exact keys in
// aesir/src/memwatch/memwatch.odin (Telemetry / Phase_Timing).

@(private = "file")
Decoded_Phase :: struct {
	name: string `json:"n"`,
	last: f64 `json:"l"`,
	mean: f64 `json:"m"`,
	peak: f64 `json:"k"`,
}

@(private = "file")
Decoded_GPU_Group :: struct {
	name:  string `json:"n"`,
	last:  f64 `json:"l"`,
	mean:  f64 `json:"m"`,
	peak:  f64 `json:"k"`,
	count: u32 `json:"c"`,
}

@(private = "file")
Decoded_Stage :: struct {
	name: string `json:"n"`,
	last: f64 `json:"l"`,
	peak: f64 `json:"k"`,
}

Decoded_Delivery :: struct {
	epoch:                  u64 `json:"e"`,
	frame:                  u64 `json:"i"`,
	renderer_cpu:           f64 `json:"rc"`,
	host_cpu:               f64 `json:"hc"`,
	gpu_complete:           f64 `json:"gc"`,
	presented_at:           f64 `json:"pt"`,
	interval:               f64 `json:"pi"`,
	valid:                  u8 `json:"v"`,
	presentation_supported: bool `json:"su"`,
	missing_gpu:            bool `json:"mg"`,
	missing_present:        bool `json:"mp"`,
}

Decoded_Raw_GPU :: struct {
	epoch:            u64 `json:"e"`,
	frame:            u64 `json:"i"`,
	milliseconds:     f64 `json:"ms"`,
	valid:            bool `json:"v"`,
	truncated_groups: u32 `json:"tg"`,
	groups:           []Decoded_GPU_Group `json:"g"`,
}

Decoded_GPU_Health :: struct {
	overflow:              u64 `json:"o"`,
	no_slot:               u64 `json:"s"`,
	pair_exhaustion:       u64 `json:"q"`,
	map_failure:           u64 `json:"m"`,
	group_truncation:      u64 `json:"g"`,
	invalid_timestamps:    u64 `json:"t"`,
	completion_occupancy:  u32 `json:"co"`,
	completion_high_water: u32 `json:"ch"`,
	invalid_valid:         bool `json:"iv"`,
	invalid_epoch:         u64 `json:"ie"`,
	invalid_frame:         u64 `json:"ii"`,
	invalid_pair:          u32 `json:"ip"`,
	invalid_label:         string `json:"il"`,
	invalid_begin_tick:    u64 `json:"ib"`,
	invalid_end_tick:      u64 `json:"it"`,
	invalid_slot:          u32 `json:"is"`,
	invalid_query_begin:   u32 `json:"iqb"`,
	invalid_query_end:     u32 `json:"iqe"`,
	invalid_generation:    u64 `json:"ign"`,
	invalid_submission:    u64 `json:"isu"`,
}

Decoded_Raw_Telemetry :: struct {
	record_type:      u32 `json:"rt"`,
	sequence:         u64 `json:"sq"`,
	gpu_frames:       []Decoded_Raw_GPU `json:"gfd"`,
	gpu_health:       Decoded_GPU_Health `json:"gh"`,
	delivery:         []Decoded_Delivery `json:"fd"`,
	delivery_dropped: u64 `json:"fdd"`,
}

@(private = "file")
Decoded_Telemetry :: struct {
	frame:                u64 `json:"i"`,
	frame_last:           f64 `json:"fl"`,
	frame_mean:           f64 `json:"fm"`,
	frame_peak:           f64 `json:"fp"`,
	frame_p50:            f64 `json:"f50"`,
	frame_p95:            f64 `json:"f95"`,
	frame_p99:            f64 `json:"f99"`,
	gpu_valid:            bool `json:"gv"`,
	gpu_last_ms:          f64 `json:"gl"`,
	gpu_mean_ms:          f64 `json:"gm"`,
	gpu_peak_ms:          f64 `json:"gp"`,
	gpu_groups:           []Decoded_GPU_Group `json:"gg"`,
	delivery:             []Decoded_Delivery `json:"fd"`,
	delivery_dropped:     u64 `json:"fdd"`,
	draws:                u64 `json:"d"`,
	passes:               u64 `json:"rp"`,
	scene_bind_creations: u32 `json:"sbc"`,
	window_width:         i32 `json:"ww"`,
	window_height:        i32 `json:"wh"`,
	target_width:         i32 `json:"tw"`,
	target_height:        i32 `json:"th"`,
	refresh:              i32 `json:"hz"`,
	budget_ms:            f32 `json:"bt"`,
	render_scale:         f32 `json:"rs"`,
	misses:               u64 `json:"mc"`,
	miss_ratio:           f32 `json:"mr"`,
	pressure:             f32 `json:"pr"`,
	pacing_mode:          int `json:"pm"`,
	surface_mode:         int `json:"sm"`,
	phases:               []Decoded_Phase `json:"p"`,
	ticks:                u64 `json:"tc"`,
	tick_last:            f64 `json:"tl"`,
	tick_peak:            f64 `json:"tk"`,
	prepared_commits:     u64 `json:"pc"`,
	prepared_fallbacks:   u64 `json:"pf"`,
	prepared_peak:        f64 `json:"pk"`,
	acquire_ms:           f64 `json:"aq"`,
	encode_ms:            f64 `json:"en"`,
	submit_ms:            f64 `json:"sb"`,
	present_ms:           f64 `json:"ps"`,
	frame_cpu_ms:         f64 `json:"fc"`,
	clipmap_anchors:      u64 `json:"ca"`,
	clipmap_started:      u64 `json:"cg"`,
	clipmap_published:    u64 `json:"cp"`,
	clipmap_rings:        u64 `json:"cr"`,
	clipmap_rows:         u64 `json:"cw"`,
	clipmap_vertices:     u64 `json:"cv"`,
	clipmap_uploads:      u64 `json:"cu"`,
	stages:               []Decoded_Stage `json:"s"`,
}

// filled_profiler fakes a completed window so the writer has something to
// summarise without running a frame.
@(private = "file")
filled_profiler :: proc() -> Profiler {
	profiler: Profiler
	profiler.filled = 2
	profiler.frame = 1
	profiler.totals[0] = 16
	profiler.totals[1] = 18
	profiler.samples[.Draw_World][0] = 3
	profiler.samples[.Draw_World][1] = 5
	profiler.samples[.Sim][0] = 1
	profiler.samples[.Sim][1] = 1
	timing: shared.Sim_Tick_Timing
	timing.tick = 7
	timing.total_ms = 9
	timing.stage_ms[.Climate] = 6
	profile_tick_record(&profiler, &timing)
	timing.total_ms = 3
	timing.stage_ms[.Climate] = 0
	timing.stage_ms[.Ocean] = 2
	profile_tick_record(&profiler, &timing)
	profile_tick_prepared(&profiler, 5, 1, 4.5)
	profile_clipmap_record(&profiler, 7, 2, 1, 3, 129, 16_641, 1)
	return profiler
}

@(private = "file")
sidecar_path :: proc() -> string {
	tmp, error := os.temp_dir(context.temp_allocator)
	if error != nil do tmp = "/tmp"
	return fmt.tprintf("%s/terraforger-telemetry-%d.tel", tmp, time.tick_now()._nsec)
}

@(test)
telemetry_writes_one_json_line_per_interval :: proc(t: ^testing.T) {
	when !PROFILE_ENABLED do return
	path := sidecar_path()
	defer _ = os.remove(path)
	os.set_env(TELEMETRY_ENV, path)
	defer os.unset_env(TELEMETRY_ENV)
	telemetry: Telemetry
	telemetry_init(&telemetry)
	testing.expect(t, telemetry.open, "sidecar should open when the env var is set")
	defer telemetry_shutdown(&telemetry)
	profiler := filled_profiler()
	performance := performance_init(120)

	telemetry_publish(&telemetry, &profiler, &performance, 100)
	// Still inside the interval: a second call must not write.
	telemetry_publish(&telemetry, &profiler, &performance, 100.5)
	telemetry_publish(&telemetry, &profiler, &performance, 100 + TELEMETRY_INTERVAL)

	data, read_error := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, read_error == nil, "sidecar should be readable")
	text := string(data)
	testing.expect_value(t, strings.count(text, "\n"), 2)
	testing.expect(t, strings.has_suffix(text, "\n"), "every record is newline terminated")
}

@(test)
telemetry_line_decodes_into_the_shape_aesir_expects :: proc(t: ^testing.T) {
	when !PROFILE_ENABLED do return
	path := sidecar_path()
	defer _ = os.remove(path)
	os.set_env(TELEMETRY_ENV, path)
	defer os.unset_env(TELEMETRY_ENV)
	telemetry: Telemetry
	telemetry_init(&telemetry)
	testing.expect(t, telemetry.open)
	defer telemetry_shutdown(&telemetry)
	profiler := filled_profiler()
	performance := performance_init(120)
	_ = performance_frame_record(&performance, performance.target_seconds * 2)
	telemetry.delivery[0] = {
		epoch                  = 3,
		presentation_supported = true,
		frame_index            = 9,
		renderer_cpu_seconds   = 0.004,
		host_cpu_seconds       = 0.005,
		gpu_complete_seconds   = 0.006,
		presented_timestamp    = 10,
		presentation_seconds   = 1.0 / 120.0,
		cpu_valid              = true,
		gpu_complete_valid     = true,
		presented_valid        = true,
	}
	telemetry.delivery_count = 1
	telemetry_publish(&telemetry, &profiler, &performance, 1)

	data, read_error := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, read_error == nil)
	lines := strings.split(string(data), "\n", context.temp_allocator)
	testing.expect_value(t, len(lines), 3)
	raw: Decoded_Raw_Telemetry
	testing.expect(
		t,
		json.unmarshal(transmute([]u8)lines[0], &raw, allocator = context.temp_allocator) == nil,
		"raw sidecar line must be valid JSON",
	)
	testing.expect_value(t, raw.record_type, u32(1))
	testing.expect_value(t, raw.sequence, u64(1))
	testing.expect_value(t, len(raw.delivery), 1)
	testing.expect_value(t, raw.delivery[0].epoch, u64(3))
	testing.expect(t, raw.delivery[0].presentation_supported)
	decoded: Decoded_Telemetry
	testing.expect(
		t,
		json.unmarshal(transmute([]u8)lines[1], &decoded, allocator = context.temp_allocator) ==
		nil,
		"summary sidecar line must be valid JSON",
	)
	testing.expect_value(t, decoded.frame, u64(1))
	// totals[frame=1] is 18, mean of {16,18} is 17, peak is 18.
	testing.expect_value(t, decoded.frame_last, f64(18))
	testing.expect_value(t, decoded.frame_mean, f64(17))
	testing.expect_value(t, decoded.frame_peak, f64(18))
	testing.expect_value(t, decoded.frame_p50, f64(16))
	testing.expect_value(t, decoded.frame_p95, f64(18))
	testing.expect_value(t, decoded.frame_p99, f64(18))
	testing.expect(t, !decoded.gpu_valid)
	testing.expect_value(t, decoded.gpu_last_ms, f64(0))
	testing.expect_value(t, decoded.window_width, decoded.target_width)
	testing.expect_value(t, decoded.window_height, decoded.target_height)
	testing.expect_value(t, decoded.refresh, i32(120))
	testing.expect(t, abs(decoded.budget_ms - f32(1000.0 / 120.0)) < 0.001)
	testing.expect_value(t, decoded.render_scale, performance.render_scale)
	testing.expect_value(t, decoded.misses, u64(1))
	testing.expect_value(t, decoded.miss_ratio, f32(1))
	testing.expect(t, decoded.pressure > 0)
	testing.expect_value(t, decoded.pacing_mode, 0)
	testing.expect_value(t, decoded.surface_mode, int(rl.Surface_Present_Mode.Other))
	testing.expect_value(t, len(decoded.delivery), 0)
	testing.expect_value(t, raw.delivery[0].frame, u64(9))
	testing.expect_value(t, raw.delivery[0].renderer_cpu, f64(4))
	testing.expect_value(t, raw.delivery[0].host_cpu, f64(5))
	testing.expect_value(t, raw.delivery[0].valid, u8(7))
	testing.expect(t, abs(raw.delivery[0].interval - f64(1000.0 / 120.0)) < 0.001)
	// Every phase but .None is emitted, including the ones that never ran: a
	// zero row means "skipped", and a stable key set keeps runs comparable.
	testing.expect_value(t, len(decoded.phases), len(Profile_Phase) - 1)
	found := false
	for phase in decoded.phases {
		if phase.name != "draw.world" do continue
		found = true
		testing.expect_value(t, phase.last, f64(5))
		testing.expect_value(t, phase.peak, f64(5))
	}
	testing.expect(t, found, "draw.world row missing")
	// The tick breakdown carries the last tick and the peak since the
	// previous line, then resets the peaks so the next line stands alone.
	testing.expect_value(t, decoded.ticks, u64(2))
	testing.expect_value(t, decoded.tick_last, f64(3))
	testing.expect_value(t, decoded.tick_peak, f64(9))
	testing.expect_value(t, decoded.prepared_commits, u64(5))
	testing.expect_value(t, decoded.prepared_fallbacks, u64(1))
	testing.expect_value(t, decoded.prepared_peak, f64(4.5))
	testing.expect(
		t,
		decoded.acquire_ms >= 0 && decoded.present_ms >= 0,
		"presentation times decode",
	)
	testing.expect_value(t, decoded.clipmap_anchors, u64(7))
	testing.expect_value(t, decoded.clipmap_started, u64(2))
	testing.expect_value(t, decoded.clipmap_published, u64(1))
	testing.expect_value(t, decoded.clipmap_rings, u64(3))
	testing.expect_value(t, decoded.clipmap_rows, u64(129))
	testing.expect_value(t, decoded.clipmap_vertices, u64(16_641))
	testing.expect_value(t, decoded.clipmap_uploads, u64(1))
	testing.expect_value(t, len(decoded.stages), len(shared.Sim_Stage))
	climate_found := false
	for stage in decoded.stages {
		if stage.name != "climate" do continue
		climate_found = true
		testing.expect_value(t, stage.last, f64(0))
		testing.expect_value(t, stage.peak, f64(6))
	}
	testing.expect(t, climate_found, "climate stage row missing")
	testing.expect_value(t, profiler.tick.peak_total, f64(0))
	testing.expect_value(t, profiler.tick.peak_stage[.Climate], f64(0))
	testing.expect_value(t, profiler.clipmap, Profile_Clipmap{})
}

@(test)
telemetry_invalid_timestamp_identity_decodes :: proc(t: ^testing.T) {
	when !PROFILE_ENABLED do return
	path := sidecar_path()
	defer _ = os.remove(path)
	os.set_env(TELEMETRY_ENV, path)
	defer os.unset_env(TELEMETRY_ENV)
	telemetry: Telemetry
	telemetry_init(&telemetry)
	testing.expect(t, telemetry.open)
	defer telemetry_shutdown(&telemetry)
	telemetry.gpu_health.invalid_timestamps = 1
	telemetry.gpu_health.first_invalid_pair = {
		valid       = true,
		epoch       = 23,
		frame_index = 45,
		pair_index  = 1,
		begin_tick  = 9_007_199_254_740_993,
		end_tick    = 9_007_199_254_740_991,
		slot_index  = 7,
		query_begin = 2,
		query_end   = 3,
		generation  = 103,
		submission  = 97,
	}
	testing.expect(t, telemetry_records_write(&telemetry))
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, read_error == nil)
	raw: Decoded_Raw_Telemetry
	testing.expect(t, json.unmarshal(data, &raw, allocator = context.temp_allocator) == nil)
	health := raw.gpu_health
	testing.expect_value(t, health.invalid_timestamps, u64(1))
	testing.expect(t, health.invalid_valid)
	testing.expect_value(t, health.invalid_epoch, u64(23))
	testing.expect_value(t, health.invalid_frame, u64(45))
	testing.expect_value(t, health.invalid_pair, u32(1))
	testing.expect_value(t, health.invalid_begin_tick, u64(9_007_199_254_740_993))
	testing.expect_value(t, health.invalid_end_tick, u64(9_007_199_254_740_991))
	testing.expect_value(t, health.invalid_slot, u32(7))
	testing.expect_value(t, health.invalid_query_begin, u32(2))
	testing.expect_value(t, health.invalid_query_end, u32(3))
	testing.expect_value(t, health.invalid_generation, u64(103))
	testing.expect_value(t, health.invalid_submission, u64(97))
	testing.expect_value(t, telemetry.gpu_health, rl.Gpu_Timing_Health{})
}

@(test)
telemetry_gpu_samples_aggregate_once :: proc(t: ^testing.T) {
	value: Telemetry
	telemetry_gpu_record(&value, {epoch = 1, frame_index = 7, seconds = 0.004, valid = true})
	telemetry_gpu_record(&value, {epoch = 1, frame_index = 7, seconds = 0.008, valid = true})
	telemetry_gpu_record(&value, {epoch = 2, frame_index = 7, seconds = 0.006, valid = true})
	testing.expect_value(t, value.gpu_epoch, u64(2))
	testing.expect_value(t, value.gpu_frame, u64(7))
	testing.expect_value(t, value.gpu_count, u32(2))
	testing.expect_value(t, value.gpu_last_ms, f64(6))
	testing.expect_value(t, value.gpu_sum_ms, f64(10))
	testing.expect_value(t, value.gpu_peak_ms, f64(6))
}

@(test)
telemetry_gpu_detail_aggregates_once_per_frame :: proc(t: ^testing.T) {
	value: Telemetry
	label: rl.Gpu_Timing_Label
	copy(label.bytes[:5], []u8{'w', 'o', 'r', 'l', 'd'})
	label.length = 5
	detail := rl.Gpu_Frame_Timing_Detail {
		epoch       = 1,
		frame_index = 7,
		group_count = 1,
		valid       = true,
	}
	detail.groups[0] = {
		label   = label,
		seconds = 0.004,
		count   = 1,
	}
	telemetry_gpu_detail_record(&value, detail)
	telemetry_gpu_detail_record(&value, detail)
	detail.epoch = 2
	detail.groups[0].seconds = 0.006
	telemetry_gpu_detail_record(&value, detail)
	testing.expect_value(t, value.gpu_group_count, u32(1))
	testing.expect_value(t, value.gpu_groups[0].count, u32(2))
	testing.expect_value(t, value.gpu_groups[0].last_ms, f64(6))
	testing.expect_value(t, value.gpu_groups[0].sum_ms, f64(10))
}

@(test)
telemetry_stays_silent_without_the_env_var :: proc(t: ^testing.T) {
	when !PROFILE_ENABLED do return
	// A plain run must not create files or pay for formatting.
	os.unset_env(TELEMETRY_ENV)
	telemetry: Telemetry
	telemetry_init(&telemetry)
	defer telemetry_shutdown(&telemetry)
	testing.expect(t, !telemetry.open, "no sidecar without AESIR_TELEMETRY")
	profiler := filled_profiler()
	performance := performance_init(60)
	telemetry_publish(&telemetry, &profiler, &performance, 1)
	testing.expect_value(t, telemetry.frame, u64(0))
}

@(test)
telemetry_ignores_an_unfilled_window :: proc(t: ^testing.T) {
	when !PROFILE_ENABLED do return
	path := sidecar_path()
	defer _ = os.remove(path)
	os.set_env(TELEMETRY_ENV, path)
	defer os.unset_env(TELEMETRY_ENV)
	telemetry: Telemetry
	telemetry_init(&telemetry)
	defer telemetry_shutdown(&telemetry)
	// A session that never reached a gameplay frame has nothing to summarise.
	profiler: Profiler
	performance := performance_init(60)
	telemetry.gpu_frames[0] = {
		epoch       = 1,
		frame_index = 1,
		seconds     = 0.004,
		valid       = true,
	}
	telemetry.gpu_frame_count = 1
	telemetry_publish(&telemetry, &profiler, &performance, 1)
	testing.expect_value(t, telemetry.frame, u64(0))
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, read_error == nil)
	lines := strings.split(string(data), "\n", context.temp_allocator)
	testing.expect_value(t, len(lines), 2)
	raw: Decoded_Raw_Telemetry
	testing.expect(
		t,
		json.unmarshal(transmute([]u8)lines[0], &raw, allocator = context.temp_allocator) == nil,
	)
	testing.expect_value(t, len(raw.gpu_frames), 1)
	testing.expect_value(t, raw.gpu_frames[0].epoch, u64(1))
}
