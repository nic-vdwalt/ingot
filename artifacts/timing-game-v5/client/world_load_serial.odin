#+build js
package main

// JS fallback: no threads on wasm, so the world builds synchronously inside
// begin and poll reports immediate completion. Same API and outcome as the
// native async path, minus the responsiveness.

import shared "../shared"

World_Load :: struct {
	world:   ^shared.World,
	seed:    u64,
	pending: bool,
	ok:      bool,
}

world_load_active :: proc(load: ^World_Load) -> bool {
	assert(load != nil, "world_load_active: nil load")
	return load.pending
}

world_load_begin :: proc(load: ^World_Load, world: ^shared.World, seed: u64) -> bool {
	assert(load != nil, "world_load_begin: nil load")
	assert(world != nil, "world_load_begin: nil world")
	assert(!load.pending, "world_load_begin: load already active")
	load.world = world
	load.seed = seed
	load.ok = _world_build(world, seed)
	load.pending = true
	return true
}

world_load_poll :: proc(load: ^World_Load) -> (finished, ok: bool) {
	assert(load != nil, "world_load_poll: nil load")
	assert(load.pending, "world_load_poll: no active load")
	load.pending = false
	return true, load.ok
}

world_load_finish :: proc(load: ^World_Load) {
	assert(load != nil, "world_load_finish: nil load")
	load.pending = false
}
