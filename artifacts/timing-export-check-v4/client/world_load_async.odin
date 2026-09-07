#+build !js
package main

// Native async world build: shared.world_init_seed bakes the 1.6M-cell
// foundation field, which takes multiple seconds. The loading screen runs
// the whole sim-world build on one worker thread and polls for completion
// each frame, so the window keeps animating instead of freezing. The worker
// owns value.world exclusively until poll reports finished; the main thread
// must not touch the world while a load is active.

import "core:sync"
import "core:thread"
import shared "../shared"

World_Load :: struct {
	thread: ^thread.Thread,
	world:  ^shared.World,
	seed:   u64,
	// done is the worker-to-main handshake; ok is only valid once done.
	done:   bool,
	ok:     bool,
}

world_load_active :: proc(load: ^World_Load) -> bool {
	assert(load != nil, "world_load_active: nil load")
	return load.thread != nil
}

// world_load_begin spawns the worker; returns false when thread creation
// fails, in which case the caller should build synchronously instead.
world_load_begin :: proc(load: ^World_Load, world: ^shared.World, seed: u64) -> bool {
	assert(load != nil, "world_load_begin: nil load")
	assert(world != nil, "world_load_begin: nil world")
	assert(load.thread == nil, "world_load_begin: load already active")
	load.world = world
	load.seed = seed
	load.ok = false
	sync.atomic_store(&load.done, false)
	load.thread = thread.create_and_start_with_poly_data(load, _world_load_worker)
	return load.thread != nil
}

@(private = "file")
_world_load_worker :: proc(load: ^World_Load) {
	load.ok = _world_build(load.world, load.seed)
	sync.atomic_store(&load.done, true)
}

// world_load_poll returns finished=false while the worker is still baking;
// once the worker reports done the thread is joined (non-blocking at that
// point) and its result returned. The world result stays untouched here —
// the caller finalizes or deinits it.
world_load_poll :: proc(load: ^World_Load) -> (finished, ok: bool) {
	assert(load != nil, "world_load_poll: nil load")
	assert(load.thread != nil, "world_load_poll: no active load")
	if !sync.atomic_load(&load.done) do return false, false
	thread.join(load.thread)
	thread.destroy(load.thread)
	load.thread = nil
	return true, load.ok
}

// world_load_finish blocks until an in-flight load completes; called on
// shutdown so the worker never outlives the state it writes into.
world_load_finish :: proc(load: ^World_Load) {
	assert(load != nil, "world_load_finish: nil load")
	if load.thread == nil do return
	thread.join(load.thread)
	thread.destroy(load.thread)
	load.thread = nil
}
