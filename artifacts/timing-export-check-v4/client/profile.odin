package main

import "core:slice"
import "core:time"
import shared "../shared"

// Fixed-capacity per-frame CPU phase profiler. game_frame is a flat sequence
// of subsystem calls, so a phase timeline (each marker closes the previous
// phase and opens the next) is sufficient and cannot be unbalanced the way a
// nested zone stack can. Storage is inline and bounded: no allocation, so the
// profiler is safe to embed in Client_State and to reset across a hot reload.

// Compile-time kill switch; the timing calls vanish when false.
PROFILE_ENABLED :: #config(FORGE_PROFILE, true)
// Rolling window: 120 frames is about two seconds at 60 Hz, enough to keep a
// pan or sculpt hitch visible in the peak column after it happens.
PROFILE_HISTORY :: 120

// Profile_Phase names one segment of game_frame. The declaration order
// matches the call order in game_frame so the raw sample arrays read as a
// timeline; the overlay sorts by cost separately.
Profile_Phase :: enum u8 {
	None,
	Console,
	Camera,
	Entity_Queries,
	Hover,
	Input,
	Terraform,
	Sim,
	Terrain_Update,
	Ocean_Update,
	Wind_Update,
	Spectral_Prepare,
	Ruins_Stream,
	Flora_Stream,
	Flora_Update,
	Cosmetics,
	Sockets,
	Highlight,
	Cursor,
	Draw_World,
	Portrait,
	Draw_Screen,
}

PROFILE_PHASE_NAMES :: [Profile_Phase]string {
	.None             = "none",
	.Console          = "console",
	.Camera           = "camera",
	.Entity_Queries   = "queries",
	.Hover            = "hover",
	.Input            = "input",
	.Terraform        = "terraform",
	.Sim              = "sim",
	.Terrain_Update   = "terrain",
	.Ocean_Update     = "ocean",
	.Wind_Update      = "wind",
	.Spectral_Prepare = "ocean.spectral",
	.Ruins_Stream     = "ruins",
	.Flora_Stream     = "flora.stream",
	.Flora_Update     = "flora.update",
	.Cosmetics        = "cosmetics",
	.Sockets          = "sockets",
	.Highlight        = "highlight",
	.Cursor           = "cursor",
	.Draw_World       = "draw.world",
	.Portrait         = "draw.portrait",
	.Draw_Screen      = "draw.screen",
}

// Profiler holds a fixed ring of per-phase millisecond samples: 21 phases *
// 120 frames * 8 B is about 20 KB of inline storage.
Profiler :: struct {
	visible:  bool,
	frame:    int,
	filled:   int,
	current:  Profile_Phase,
	started:  time.Tick,
	frame_at: time.Tick,
	samples:  [Profile_Phase][PROFILE_HISTORY]f64,
	pending:  [Profile_Phase]f64,
	totals:   [PROFILE_HISTORY]f64,
	tick:     Profile_Tick,
	clipmap:  Profile_Clipmap,
}

Profile_Clipmap :: struct {
	anchor_changes:        u64,
	generations_started:   u64,
	generations_published: u64,
	rings_filled:          u64,
	rows_filled:           u64,
	vertices_filled:       u64,
	gpu_uploads:           u64,
}

// Profile_Tick keeps the most recent authoritative tick's stage breakdown
// and the per-stage peak since the peaks were last reset (telemetry resets
// them once per published line). Ticks run at 4 Hz, so a frame ring would
// mostly hold zeros; the peak-since-publish form answers "which stage made
// the last spike" directly.
Profile_Tick :: struct {
	last:       shared.Sim_Tick_Timing,
	peak_total: f64,
	peak_stage: [shared.Sim_Stage]f64,
	count:      u64,
	// Asynchronous planetary preparation, published by the game each frame:
	// how many ticks committed a prepared stage, how many fell back to a
	// synchronous tick, and the worker's peak preparation time.
	prepared_commits:   u64,
	prepared_fallbacks: u64,
	prepared_peak:      f64,
}

Profile_Summary :: struct {
	last: f64,
	mean: f64,
	peak: f64,
	p50:  f64,
	p95:  f64,
	p99:  f64,
}

// profile_frame_begin closes any stale phase and starts a new frame slot.
profile_frame_begin :: proc(value: ^Profiler) {
	assert(value != nil, "profile_frame_begin: nil profiler")
	when PROFILE_ENABLED {
		value.frame = (value.frame + 1) % PROFILE_HISTORY
		for phase in Profile_Phase {
			value.samples[phase][value.frame] = value.pending[phase]
			value.pending[phase] = 0
		}
		value.totals[value.frame] = 0
		value.current = .None
		value.frame_at = time.tick_now()
		value.started = value.frame_at
	}
}

// profile_phase closes the open phase and opens the named one. Phases
// accumulate within a frame, so a phase entered twice (an early-return path
// that re-enters) sums rather than overwrites.
profile_phase :: proc(value: ^Profiler, phase: Profile_Phase) {
	assert(value != nil, "profile_phase: nil profiler")
	when PROFILE_ENABLED {
		now := time.tick_now()
		if value.current != .None {
			elapsed := time.duration_milliseconds(time.tick_diff(value.started, now))
			value.samples[value.current][value.frame] += elapsed
		}
		value.current = phase
		value.started = now
	}
}

profile_external :: proc(value: ^Profiler, phase: Profile_Phase, elapsed: time.Duration) {
	assert(value != nil, "profile_external: nil profiler")
	when PROFILE_ENABLED {
		value.pending[phase] += time.duration_milliseconds(elapsed)
	}
}

// profile_tick_record folds one completed authoritative tick's breakdown
// into the profiler: it becomes the last tick and raises any stage peak.
profile_tick_record :: proc(value: ^Profiler, timing: ^shared.Sim_Tick_Timing) {
	assert(value != nil && timing != nil, "profile_tick_record: nil argument")
	when PROFILE_ENABLED {
		value.tick.last = timing^
		value.tick.count += 1
		if timing.total_ms > value.tick.peak_total do value.tick.peak_total = timing.total_ms
		for stage in shared.Sim_Stage {
			if timing.stage_ms[stage] > value.tick.peak_stage[stage] {
				value.tick.peak_stage[stage] = timing.stage_ms[stage]
			}
		}
	}
}

profile_tick_prepared :: proc(value: ^Profiler, commits, fallbacks: u64, peak_ms: f64) {
	assert(value != nil, "profile_tick_prepared: nil profiler")
	when PROFILE_ENABLED {
		value.tick.prepared_commits = commits
		value.tick.prepared_fallbacks = fallbacks
		value.tick.prepared_peak = peak_ms
	}
}

profile_clipmap_record :: proc(
	value: ^Profiler,
	anchor_changes, generations_started, generations_published: u64,
	rings_filled, rows_filled, vertices_filled, gpu_uploads: u64,
) {
	assert(value != nil, "profile_clipmap_record: nil profiler")
	when PROFILE_ENABLED {
		value.clipmap.anchor_changes += anchor_changes
		value.clipmap.generations_started += generations_started
		value.clipmap.generations_published += generations_published
		value.clipmap.rings_filled += rings_filled
		value.clipmap.rows_filled += rows_filled
		value.clipmap.vertices_filled += vertices_filled
		value.clipmap.gpu_uploads += gpu_uploads
	}
}

profile_clipmap_reset :: proc(value: ^Profiler) {
	assert(value != nil, "profile_clipmap_reset: nil profiler")
	when PROFILE_ENABLED {
		value.clipmap = {}
	}
}

profile_tick_reset_peaks :: proc(value: ^Profiler) {
	assert(value != nil, "profile_tick_reset_peaks: nil profiler")
	when PROFILE_ENABLED {
		value.tick.peak_total = 0
		value.tick.peak_stage = {}
	}
}

// profile_frame_end closes the trailing phase and records the frame total.
// It is safe to call on a frame that returned early: the open phase simply
// absorbs the remainder.
profile_frame_end :: proc(value: ^Profiler) {
	assert(value != nil, "profile_frame_end: nil profiler")
	when PROFILE_ENABLED {
		profile_phase(value, .None)
		value.totals[value.frame] = time.duration_milliseconds(
			time.tick_diff(value.frame_at, time.tick_now()),
		)
		if value.filled < PROFILE_HISTORY do value.filled += 1
	}
}

profile_percentile_index :: proc(filled, percentile: int) -> int {
	assert(filled > 0 && filled <= PROFILE_HISTORY, "profile_percentile_index: bad fill")
	assert(percentile > 0 && percentile <= 100, "profile_percentile_index: bad percentile")
	return clamp((filled * percentile + 99) / 100 - 1, 0, filled - 1)
}

// profile_summary reports last / mean / peak milliseconds over the filled
// window. Peak is the number that exposes hitches; mean is the steady-state
// cost. Reading an unfilled window yields a zero summary rather than noise.
//
// The window is the `filled` ring slots ending at `frame`, walked backwards
// modulo the ring length: the first frame lands in slot 1, so a partially
// filled ring is not a prefix of the array.
profile_summary :: proc(samples: []f64, filled, frame: int) -> Profile_Summary {
	assert(filled >= 0 && filled <= PROFILE_HISTORY, "profile_summary: bad fill")
	assert(len(samples) >= filled, "profile_summary: short sample window")
	if filled == 0 do return {}
	assert(frame >= 0 && frame < len(samples), "profile_summary: frame out of range")
	total, peak := f64(0), f64(0)
	ordered: [PROFILE_HISTORY]f64
	ring := len(samples)
	for offset in 0 ..< filled {
		sample := samples[(frame - offset + ring) % ring]
		ordered[offset] = sample
		total += sample
		if sample > peak do peak = sample
	}
	slice.sort(ordered[:filled])
	return {
		last = samples[frame],
		mean = total / f64(filled),
		peak = peak,
		p50 = ordered[profile_percentile_index(filled, 50)],
		p95 = ordered[profile_percentile_index(filled, 95)],
		p99 = ordered[profile_percentile_index(filled, 99)],
	}
}
