package game

import "core:fmt"
import fit "ingot:fit"

GAME_STATE_SCHEMA :: u64(1)

Game_State :: struct {
	click_count:       u64,
	reload_generation: u64,
}

g: ^Game_State

@(export)
game_init :: proc() -> bool {
	assert(g == nil, "game_init: state already initialized")
	g = new(Game_State)
	if g == nil do return false
	g.reload_generation = 1
	assert(g.reload_generation > 0)
	return true
}

@(export)
game_draw :: proc(builder: ^fit.Builder) {
	assert(builder != nil, "game_draw: nil builder")
	assert(g != nil, "game_draw: missing state")
	clicked := false
	fit.Column(builder, {gap = .SM, padding = .LG})
	fit.Label(builder, "Ingot hot reload", {role = .Title})
	fit.Label(builder, "The host keeps the window, GPU, and session alive.", {ink = .Secondary})
	fit.Label(builder, fmt.tprintf("Reload generation: %d", g.reload_generation), {role = .Label})
	fit.Label(builder, fmt.tprintf("Persistent clicks: %d", g.click_count), {role = .Label})
	fit.Button(builder, "count", "Count persistent click", &clicked)
	fit.Label(
		builder,
		"Edit game/game.odin, then run the build script again.",
		{role = .Note, ink = .Muted},
	)
	fit.End(builder)
	if clicked do g.click_count += 1
}

@(export)
game_shutdown :: proc() {
	assert(g != nil, "game_shutdown: missing state")
	free(g)
	g = nil
	assert(g == nil)
}

@(export)
game_memory :: proc() -> rawptr {
	assert(g != nil, "game_memory: missing state")
	return g
}

@(export)
game_memory_size :: proc() -> u64 {
	return u64(size_of(Game_State))
}

@(export)
game_memory_schema :: proc() -> u64 {
	return GAME_STATE_SCHEMA
}

@(export)
game_hot_reloaded :: proc(memory: rawptr) {
	assert(memory != nil, "game_hot_reloaded: nil state")
	g = cast(^Game_State)memory
	g.reload_generation += 1
	assert(g.reload_generation > 1)
}
