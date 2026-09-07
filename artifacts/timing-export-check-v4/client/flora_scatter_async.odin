#+build !js
package main

// Native async flora scatter: when the streaming window crosses a tile
// boundary the entering tiles are scattered on a worker thread while the
// main thread keeps rendering the retained tiles. The worker writes into
// per-tile staging buffers using only thread-safe reads (the analytic
// height grid — the Box3D physics world must never be touched off the main
// thread); the main thread polls for completion each frame and swaps the
// staged tiles into freed slots.

import "core:sync"
import "core:thread"
import shared "../shared"

Flora_Scatter_Load :: struct {
	thread:           ^thread.Thread,
	// done is the worker-to-main handshake.
	done:             bool,
	state:            Flora_Scatter_State,
	scatter_index:    int,
	commit_index:     int,
	// Inputs — set before spawn, read-only on the worker.
	terrain:          ^Terrain,
	world:            ^shared.World,
	ruins:            ^Ruins,
	center_tile:      Flora_Tile_Id,
	// Entering tiles staged by the worker. Spans hold buffer-relative
	// ranges (large at 0, ground from FLORA_TILE_LARGE_CAPACITY) that the
	// swap rebases onto the slot each tile lands in.
	enter_tiles:      [FLORA_MAX_ENTER_TILES]Flora_Tile_Span,
	enter_instances:  [FLORA_MAX_ENTER_TILES][FLORA_TILE_CAPACITY]Flora_Instance,
	enter_tile_count: int,
	// Slots vacated by exiting tiles, computed by the main thread before
	// dispatch and consumed by the swap.
	exit_slots:       [FLORA_STREAM_TILE_COUNT]i32,
	exit_count:       int,
}

flora_scatter_load_active :: proc(load: ^Flora_Scatter_Load) -> bool {
	return load != nil && load.state != .Idle
}

// flora_scatter_load_begin spawns the worker; returns false when thread
// creation fails, in which case the caller should scatter synchronously.
// The caller must fill enter_tiles/enter_tile_count/exit_slots/exit_count
// before calling.
flora_scatter_load_begin :: proc(
	load: ^Flora_Scatter_Load,
	terrain: ^Terrain,
	world: ^shared.World,
	ruins: ^Ruins,
	center_tile: Flora_Tile_Id,
) {
	assert(load != nil, "flora_scatter_load_begin: nil load")
	assert(load.state == .Idle, "flora_scatter_load_begin: already active")
	load.terrain = terrain
	load.world = world
	load.ruins = ruins
	load.center_tile = center_tile
	load.scatter_index = 0
	load.commit_index = 0
	load.state = .Scattering
	sync.atomic_store(&load.done, false)
	if flora_ecology_enabled(world) do return
	load.thread = thread.create_and_start_with_poly_data(load, _flora_scatter_worker)
}

@(private = "file")
_flora_scatter_worker :: proc(load: ^Flora_Scatter_Load) {
	_flora_scatter_incremental_staged(load)
	sync.atomic_store(&load.done, true)
}

flora_scatter_load_poll :: proc(load: ^Flora_Scatter_Load) -> (finished: bool) {
	assert(load != nil, "flora_scatter_load_poll: nil load")
	if load.state == .Ready || load.state == .Committing do return true
	if load.state != .Scattering do return false
	if load.thread != nil {
		if !sync.atomic_load(&load.done) do return false
		thread.join(load.thread)
		thread.destroy(load.thread)
		load.thread = nil
		load.state = .Ready
		return true
	}
	if load.scatter_index < load.enter_tile_count {
		_flora_scatter_incremental_staged_range(load, load.scatter_index, load.scatter_index + 1)
		load.scatter_index += 1
	}
	if load.scatter_index < load.enter_tile_count do return false
	load.state = .Ready
	return true
}

flora_scatter_load_commit_begin :: proc(load: ^Flora_Scatter_Load) {
	assert(load != nil && load.state == .Ready, "flora_scatter_load_commit_begin: invalid state")
	load.commit_index = 0
	load.state = .Committing
}

flora_scatter_load_commit_complete :: proc(load: ^Flora_Scatter_Load) {
	assert(load != nil && load.state == .Committing, "flora_scatter_load_commit_complete: invalid state")
	load.state = .Idle
	load.scatter_index = 0
	load.commit_index = 0
}

// flora_scatter_load_finish blocks until an in-flight scatter completes;
// called on shutdown and before synchronous rescatters so the worker never
// outlives the state it reads.
flora_scatter_load_finish :: proc(load: ^Flora_Scatter_Load) {
	assert(load != nil, "flora_scatter_load_finish: nil load")
	if load.thread != nil {
		thread.join(load.thread)
		thread.destroy(load.thread)
		load.thread = nil
	}
	load.state = .Idle
	load.scatter_index = 0
	load.commit_index = 0
}
