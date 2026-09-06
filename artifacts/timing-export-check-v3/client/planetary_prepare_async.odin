#+build !js
package main

// Asynchronous planetary preparation. The planetary simulated stage
// (atmosphere dynamics, climate cadence, ocean, biogeochemistry, waves) is
// a pure function of the Planetary_State and the tick, and it is the bulk of
// an authoritative tick: several milliseconds every 250 ms, landing in one
// render frame. This runs that stage ahead of time on a shadow copy from one
// worker thread, so the tick on the render thread only swaps the prepared
// state in (microseconds) and runs the cheap world stage.
//
// Exactness: the shadow is a full copy of the live state taken after the
// previous tick committed; the worker computes exactly what the synchronous
// tick would. If anything edits the live simulated state between the copy
// and the commit (terraform bathymetry sync, debug weather tools, snapshot
// restore) the live mutation revision moves and the prepared result is
// discarded in favour of a synchronous tick, so the committed state never
// differs from the synchronous sequence. Tests pin this byte for byte.

import "core:os"
import "core:sync"
import "core:thread"
import shared "../shared"

// PLANETFORGER_SYNC_TICK=1 disables the asynchronous preparation so a
// profiling run can compare against fully synchronous ticks.
PLANETARY_SYNC_TICK_ENV :: "PLANETFORGER_SYNC_TICK"

Planetary_Prepare :: struct {
	live:      ^shared.Planetary_State,
	shadow:    ^shared.Planetary_State,
	scratch:   ^shared.Planetary_State,
	worker:    ^thread.Thread,
	dispatch:  sync.Sema,
	complete:  sync.Sema,
	shutdown:  bool,
	// Job description written by the main thread before dispatch and read
	// by the worker; `timing` is written by the worker before completion.
	tick:      u64,
	timing:    shared.Sim_Tick_Timing,
	// Revisions captured at dispatch: the result is valid only if they still
	// match the live state at commit.
	mutation:  u64,
	bathymetry: u64,
	in_flight: bool,
	ready:     bool,
	// Counters for telemetry and tests.
	commits:   u64,
	fallbacks: u64,
	peak_ms:   f64,
}

planetary_prepare_active :: proc(prepare: ^Planetary_Prepare) -> bool {
	assert(prepare != nil, "planetary_prepare_active: nil prepare")
	return prepare.worker != nil
}

// planetary_prepare_init allocates the shadow and starts the worker. On
// failure the client simply keeps ticking synchronously.
planetary_prepare_init :: proc(prepare: ^Planetary_Prepare, world: ^shared.World) -> bool {
	assert(prepare != nil && world != nil, "planetary_prepare_init: nil argument")
	assert(prepare.worker == nil, "planetary_prepare_init: already running")
	prepare^ = {}
	if os.get_env(PLANETARY_SYNC_TICK_ENV, context.temp_allocator) == "1" do return false
	prepare.live = &world.planetary
	prepare.shadow = new(shared.Planetary_State)
	prepare.scratch = new(shared.Planetary_State)
	if prepare.shadow == nil || prepare.scratch == nil {
		planetary_prepare_deinit(prepare)
		return false
	}
	shared.planetary_shadow_init(prepare.shadow, prepare.live)
	prepare.worker = thread.create_and_start_with_poly_data(prepare, _planetary_prepare_loop)
	if prepare.worker == nil {
		planetary_prepare_deinit(prepare)
		return false
	}
	return true
}

planetary_prepare_deinit :: proc(prepare: ^Planetary_Prepare) {
	assert(prepare != nil, "planetary_prepare_deinit: nil prepare")
	if prepare.worker != nil {
		planetary_prepare_wait(prepare)
		sync.atomic_store(&prepare.shutdown, true)
		sync.post(&prepare.dispatch, 1)
		thread.join(prepare.worker)
		thread.destroy(prepare.worker)
		prepare.worker = nil
	}
	if prepare.shadow != nil {
		if prepare.shadow.grid.neighbours != nil do shared.planetary_shadow_deinit(prepare.shadow)
		free(prepare.shadow)
	}
	if prepare.scratch != nil do free(prepare.scratch)
	prepare^ = {}
}

// planetary_prepare_begin dispatches the simulated stage for `tick`. The
// live state must not be ticked again before planetary_prepare_wait.
planetary_prepare_begin :: proc(prepare: ^Planetary_Prepare, tick: u64) {
	assert(prepare != nil, "planetary_prepare_begin: nil prepare")
	if prepare.worker == nil || prepare.in_flight do return
	prepare.ready = false
	prepare.tick = tick
	prepare.mutation = prepare.live.mutation_revision
	prepare.bathymetry = prepare.live.ocean.bathymetry_revision
	prepare.in_flight = true
	sync.post(&prepare.dispatch, 1)
}

// planetary_prepare_wait blocks until the in-flight job (if any) finished.
planetary_prepare_wait :: proc(prepare: ^Planetary_Prepare) {
	assert(prepare != nil, "planetary_prepare_wait: nil prepare")
	if !prepare.in_flight do return
	sync.wait(&prepare.complete)
	prepare.in_flight = false
	prepare.ready = true
	if prepare.timing.total_ms > prepare.peak_ms do prepare.peak_ms = prepare.timing.total_ms
}

// planetary_prepare_take reports whether the prepared state is exactly the
// state a synchronous tick `tick` would produce from the current live
// state, and consumes it either way.
planetary_prepare_take :: proc(prepare: ^Planetary_Prepare, tick: u64) -> bool {
	assert(prepare != nil, "planetary_prepare_take: nil prepare")
	assert(!prepare.in_flight, "planetary_prepare_take: job still in flight")
	if !prepare.ready do return false
	prepare.ready = false
	valid :=
		prepare.tick == tick &&
		prepare.mutation == prepare.live.mutation_revision &&
		prepare.bathymetry == prepare.live.ocean.bathymetry_revision
	if valid do prepare.commits += 1
	else do prepare.fallbacks += 1
	return valid
}

@(private = "file")
_planetary_prepare_loop :: proc(prepare: ^Planetary_Prepare) {
	for {
		sync.wait(&prepare.dispatch)
		if sync.atomic_load(&prepare.shutdown) do return
		shared.sim_timing_begin(&prepare.timing, prepare.tick)
		shared.planetary_shadow_copy(prepare.shadow, prepare.live)
		shared.sim_timing_mark(&prepare.timing, .Planetary_Commit)
		shared.planetary_step_simulated(prepare.shadow, prepare.tick, &prepare.timing)
		shared.sim_timing_end(&prepare.timing)
		sync.post(&prepare.complete, 1)
	}
}
