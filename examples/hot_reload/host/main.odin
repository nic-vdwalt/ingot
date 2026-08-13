package main

import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:time"
import ui "ingot:fit"
import ui_gfx "ingot:fit"
import rl "ingot:gfx"

when ODIN_OS == .Windows {
	LIBRARY_EXTENSION :: ".dll"
} else when ODIN_OS == .Darwin {
	LIBRARY_EXTENSION :: ".dylib"
} else {
	LIBRARY_EXTENSION :: ".so"
}

GAME_LIBRARY_DIRECTORY :: "build/"
GAME_LIBRARY_PATH :: GAME_LIBRARY_DIRECTORY + "game" + LIBRARY_EXTENSION
GAME_LIBRARY_MAX :: 64

Game_API :: struct {
	lib:           dynlib.Library,
	init:          proc() -> bool,
	draw:          proc(frame: ^ui.Ui_Frame),
	shutdown:      proc(),
	memory:        proc() -> rawptr,
	memory_size:   proc() -> u64,
	memory_schema: proc() -> u64,
	hot_reloaded:  proc(memory: rawptr),
	modified:      time.Time,
	version:       int,
}

Host :: struct {
	session:   ui_gfx.Host_Session,
	api:       Game_API,
	old:       [GAME_LIBRARY_MAX]Game_API,
	old_count: int,
	next:      int,
}

host: Host

library_copy_path :: proc(version: int) -> string {
	assert(version >= 0, "library_copy_path: negative version")
	return fmt.tprintf(GAME_LIBRARY_DIRECTORY + "game_%d" + LIBRARY_EXTENSION, version)
}

load_game_api :: proc(version: int) -> (api: Game_API, ok: bool) {
	assert(version >= 0 && version < GAME_LIBRARY_MAX, "load_game_api: invalid version")
	modified, modified_error := os.last_write_time_by_name(GAME_LIBRARY_PATH)
	if modified_error != os.ERROR_NONE do return
	copy_path := library_copy_path(version)
	if os.copy_file(copy_path, GAME_LIBRARY_PATH) != nil do return
	_, initialized := dynlib.initialize_symbols(&api, copy_path, "game_", "lib")
	if !initialized {
		fmt.eprintfln("hot_reload: cannot load game API: %s", dynlib.last_error())
		_ = os.remove(copy_path)
		return
	}
	api.modified = modified
	api.version = version
	assert(api.lib != nil, "load_game_api: missing library")
	assert(api.memory_size() > 0 && api.memory_schema() > 0, "load_game_api: invalid state ABI")
	return api, true
}

unload_game_api :: proc(api: ^Game_API) {
	assert(api != nil, "unload_game_api: nil API")
	if api.lib != nil && !dynlib.unload_library(api.lib) {
		fmt.eprintfln("hot_reload: cannot unload game API: %s", dynlib.last_error())
	}
	if api.version >= 0 do _ = os.remove(library_copy_path(api.version))
	api^ = {}
	assert(api.lib == nil)
}

unload_old_apis :: proc(state: ^Host) {
	assert(state != nil, "unload_old_apis: nil host")
	assert(state.old_count >= 0 && state.old_count <= GAME_LIBRARY_MAX)
	for index in 0 ..< state.old_count do unload_game_api(&state.old[index])
	state.old_count = 0
	assert(state.old_count == 0)
}

restart_game :: proc(state: ^Host, next: Game_API) -> bool {
	assert(state != nil && next.lib != nil, "restart_game: invalid arguments")
	state.api.shutdown()
	unload_old_apis(state)
	unload_game_api(&state.api)
	state.api = next
	if !state.api.init() {
		unload_game_api(&state.api)
		return false
	}
	assert(state.api.memory() != nil, "restart_game: initialization produced no state")
	return true
}

reload_game :: proc(state: ^Host) {
	assert(state != nil && state.api.lib != nil, "reload_game: invalid host")
	if state.next >= GAME_LIBRARY_MAX do return
	next, loaded := load_game_api(state.next)
	if !loaded do return
	state.next += 1
	compatible := state.api.memory_size() == next.memory_size()
	compatible &&= state.api.memory_schema() == next.memory_schema()
	if !compatible {
		if !restart_game(state, next) do panic("hot_reload: game restart failed")
		return
	}
	if state.old_count >= GAME_LIBRARY_MAX {
		unload_game_api(&next)
		return
	}
	memory := state.api.memory()
	state.old[state.old_count] = state.api
	state.old_count += 1
	state.api = next
	state.api.hot_reloaded(memory)
	assert(state.api.memory() == memory, "reload_game: state was not rebound")
}

reload_if_changed :: proc(state: ^Host) {
	assert(state != nil && state.api.lib != nil, "reload_if_changed: invalid host")
	modified, err := os.last_write_time_by_name(GAME_LIBRARY_PATH)
	if err != os.ERROR_NONE || modified == state.api.modified do return
	reload_game(state)
}

frame :: proc() {
	reload_if_changed(&host)
	current, acquired := ui_gfx.session_acquire_frame(&host.session)
	if !acquired do return
	rl.ClearBackground(rl.Color{22, 24, 32, 255})
	host.api.draw(current.ui)
	ui_gfx.session_present_frame(&current)
}

main :: proc() {
	executable_directory := filepath.dir(string(os.args[0]))
	if os.set_working_directory(executable_directory) != nil {
		fmt.eprintln("hot_reload: cannot use the example directory")
		return
	}
	api, loaded := load_game_api(0)
	if !loaded {
		fmt.eprintln("hot_reload: build the game library before starting the host")
		return
	}
	host.api = api
	host.next = 1
	if !host.api.init() {
		unload_game_api(&host.api)
		return
	}
	flags: rl.ConfigFlags = {.WINDOW_RESIZABLE, .VSYNC_HINT}
	when ODIN_OS == .Darwin do flags += {.WINDOW_HIGHDPI}
	rl.SetConfigFlags(flags)
	rl.InitWindow(720, 360, "Ingot hot reload")
	ui_gfx.session_init(&host.session, {semantics_enabled = true})
	rl.run(frame)
	ui_gfx.session_destroy(&host.session)
	rl.CloseWindow()
	host.api.shutdown()
	unload_old_apis(&host)
	unload_game_api(&host.api)
}

@(export)
NvOptimusEnablement: u32 = 1

@(export)
AmdPowerXpressRequestHighPerformance: i32 = 1
