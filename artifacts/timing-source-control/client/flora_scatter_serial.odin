#+build js
package main

// JS fallback: no threads on wasm, so entering tiles advance one per poll and
// commit through the same bounded state machine as the native path.

import shared "../shared"

Flora_Scatter_Load :: struct {
	state:            Flora_Scatter_State,
	scatter_index:    int,
	commit_index:     int,
	terrain:          ^Terrain,
	world:            ^shared.World,
	ruins:            ^Ruins,
	center_tile:      Flora_Tile_Id,
	enter_tiles:      [FLORA_MAX_ENTER_TILES]Flora_Tile_Span,
	enter_instances:  [FLORA_MAX_ENTER_TILES][FLORA_TILE_CAPACITY]Flora_Instance,
	enter_tile_count: int,
	exit_slots:       [FLORA_STREAM_TILE_COUNT]i32,
	exit_count:       int,
}

flora_scatter_load_active :: proc(load: ^Flora_Scatter_Load) -> bool {
	return load != nil && load.state != .Idle
}

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
}

flora_scatter_load_poll :: proc(load: ^Flora_Scatter_Load) -> (finished: bool) {
	assert(load != nil, "flora_scatter_load_poll: nil load")
	if load.state == .Ready || load.state == .Committing do return true
	if load.state != .Scattering do return false
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

flora_scatter_load_finish :: proc(load: ^Flora_Scatter_Load) {
	if load == nil do return
	load.state = .Idle
	load.scatter_index = 0
	load.commit_index = 0
}
