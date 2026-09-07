package main

import "core:testing"
import "core:time"

@(test)
profile_summary_reports_last_mean_and_peak :: proc(t: ^testing.T) {
	samples: [PROFILE_HISTORY]f64
	samples[0] = 1
	samples[1] = 5
	samples[2] = 3
	summary := profile_summary(samples[:], 3, 2)
	testing.expect_value(t, summary.last, f64(3))
	testing.expect_value(t, summary.mean, f64(3))
	testing.expect_value(t, summary.peak, f64(5))
	testing.expect_value(t, summary.p50, f64(3))
	testing.expect_value(t, summary.p95, f64(5))
	testing.expect_value(t, summary.p99, f64(5))
}

@(test)
profile_summary_reports_nearest_rank_percentiles :: proc(t: ^testing.T) {
	samples: [PROFILE_HISTORY]f64
	for &sample, index in samples do sample = f64(index + 1)
	summary := profile_summary(samples[:], PROFILE_HISTORY, PROFILE_HISTORY - 1)
	testing.expect_value(t, summary.p50, f64(60))
	testing.expect_value(t, summary.p95, f64(114))
	testing.expect_value(t, summary.p99, f64(119))
}

// The first frame is recorded in slot 1, not slot 0: a partially filled
// window must be read backwards from `frame`, not as an array prefix.
@(test)
profile_summary_reads_the_ring_ending_at_frame :: proc(t: ^testing.T) {
	samples: [PROFILE_HISTORY]f64
	samples[0] = 99
	samples[1] = 4
	single := profile_summary(samples[:], 1, 1)
	testing.expect_value(t, single.last, f64(4))
	testing.expect_value(t, single.mean, f64(4))
	testing.expect_value(t, single.peak, f64(4))
	testing.expect_value(t, single.p99, f64(4))
	// A window that wraps the ring end: slots 118, 119, 0 hold the frames.
	wrapped: [PROFILE_HISTORY]f64
	wrapped[PROFILE_HISTORY - 2] = 2
	wrapped[PROFILE_HISTORY - 1] = 8
	wrapped[0] = 5
	wrapped[1] = 100
	summary := profile_summary(wrapped[:], 3, 0)
	testing.expect_value(t, summary.last, f64(5))
	testing.expect_value(t, summary.mean, f64(5))
	testing.expect_value(t, summary.peak, f64(8))
	testing.expect_value(t, summary.p50, f64(5))
}

@(test)
profile_summary_on_empty_window_is_zero :: proc(t: ^testing.T) {
	samples: [PROFILE_HISTORY]f64
	summary := profile_summary(samples[:], 0, 0)
	testing.expect_value(t, summary.last, f64(0))
	testing.expect_value(t, summary.mean, f64(0))
	testing.expect_value(t, summary.peak, f64(0))
}

@(test)
profile_external_time_enters_the_next_frame :: proc(t: ^testing.T) {
	when !PROFILE_ENABLED do return
	profiler := new(Profiler)
	defer free(profiler)
	profile_external(profiler, .Spectral_Prepare, time.Millisecond)
	profile_frame_begin(profiler)
	testing.expect_value(t, profiler.samples[.Spectral_Prepare][profiler.frame], f64(1))
	testing.expect_value(t, profiler.pending[.Spectral_Prepare], f64(0))
}

// A phase entered twice in one frame must accumulate, because early-return
// paths in game_frame can re-enter a phase before the frame closes.
@(test)
profile_phase_accumulates_within_a_frame :: proc(t: ^testing.T) {
	when !PROFILE_ENABLED do return
	profiler := new(Profiler)
	defer free(profiler)
	profile_frame_begin(profiler)
	profile_phase(profiler, .Sim)
	profile_phase(profiler, .Draw_World)
	profile_phase(profiler, .Sim)
	profile_frame_end(profiler)
	testing.expect_value(t, profiler.filled, 1)
	testing.expect(t, profiler.samples[.Sim][profiler.frame] >= 0, "sim phase recorded")
	testing.expect(t, profiler.totals[profiler.frame] >= 0, "frame total recorded")
	testing.expect_value(t, profiler.current, Profile_Phase.None)
}

// The ring must wrap without growing: filled saturates at the window size.
@(test)
profile_ring_wraps_and_saturates :: proc(t: ^testing.T) {
	when !PROFILE_ENABLED do return
	profiler := new(Profiler)
	defer free(profiler)
	for _ in 0 ..< PROFILE_HISTORY + 10 {
		profile_frame_begin(profiler)
		profile_phase(profiler, .Sim)
		profile_frame_end(profiler)
	}
	testing.expect_value(t, profiler.filled, PROFILE_HISTORY)
	testing.expect(t, profiler.frame < PROFILE_HISTORY, "frame index stays in range")
}
