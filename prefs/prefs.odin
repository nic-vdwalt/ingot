#+build !js
// LIB-CANDIDATE: imports only core:*.
// Per-app preference-file persistence (native): resolves the platform data
// directory, creates it on demand, and reads/writes small settings files.
// Callers own the file format (usually hand-rolled JSON). Ported from Alloy's
// persist.odin. The web target uses prefs_web.odin (localStorage), same
// read/write signatures so callers stay target-agnostic.
package prefs

import "core:fmt"
import "core:os"
import "core:strings"

// user_home returns the current user's home directory across platforms.
// HOME is set on macOS/Linux; Windows uses USERPROFILE.
user_home :: proc(allocator := context.temp_allocator) -> string {
	if h := os.get_env("HOME", allocator); len(h) > 0 do return h
	if h := os.get_env("USERPROFILE", allocator); len(h) > 0 do return h
	return ""
}

// data_dir returns the per-app prefs directory (without creating it):
//   unix:    ~/.local/share/<app>
//   windows: %APPDATA%\<app>  (falls back to ~/.local/share/<app>)
data_dir :: proc(app: string, allocator := context.temp_allocator) -> (dir: string, ok: bool) {
	when ODIN_OS == .Windows {
		if ad := os.get_env("APPDATA", allocator); len(ad) > 0 {
			return fmt.aprintf("%s/%s", ad, app, allocator = allocator), true
		}
	}
	home := user_home(allocator)
	if len(home) == 0 do return "", false
	return fmt.aprintf("%s/.local/share/%s", home, app, allocator = allocator), true
}

// path returns data_dir(app)/file.
path :: proc(app, file: string, allocator := context.temp_allocator) -> (p: string, ok: bool) {
	dir := data_dir(app, allocator) or_return
	return fmt.aprintf("%s/%s", dir, file, allocator = allocator), true
}

// write creates the app data directory (with parents) and writes data to
// path(app, file). Returns false when the location cannot be resolved or the
// write fails.
write :: proc(app, file: string, data: []u8) -> bool {
	dir := data_dir(app) or_return
	make_dirs_all(dir)
	p := fmt.tprintf("%s/%s", dir, file)
	return os.write_entire_file(p, data) == nil
}

// read loads path(app, file); ok = false when missing or unreadable.
read :: proc(app, file: string, allocator := context.temp_allocator) -> (data: []u8, ok: bool) {
	p := path(app, file) or_return
	d, err := os.read_entire_file(p, allocator)
	if err != nil do return nil, false
	return d, true
}

// make_dirs_all creates a directory and any missing parents.
make_dirs_all :: proc(path: string) {
	if len(path) == 0 do return
	parts := strings.split(path, "/", context.temp_allocator)
	acc := strings.builder_make(context.temp_allocator)
	for p, i in parts {
		if i == 0 && len(p) == 0 {
			strings.write_string(&acc, "/")
			continue
		}
		if len(p) == 0 do continue
		strings.write_string(&acc, p)
		os.make_directory(strings.to_string(acc))
		strings.write_string(&acc, "/")
	}
}
