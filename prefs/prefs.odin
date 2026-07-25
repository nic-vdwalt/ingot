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

// write creates the app data directory (with parents) and atomically replaces
// path(app, file). Writing a unique sibling first preserves the last valid
// snapshot and prevents concurrent writers from sharing staging storage.
write :: proc(app, file: string, data: []u8) -> bool {
	dir := data_dir(app, context.allocator) or_return
	defer delete(dir)
	if !make_dirs_all_checked(dir) do return false
	p := fmt.aprintf("%s/%s", dir, file)
	defer delete(p)
	temp, create_err := os.create_temp_file(dir, ".prefs-*.tmp")
	if create_err != nil do return false
	tmp := fmt.aprintf("%s", os.name(temp))
	defer delete(tmp)
	written, write_err := os.write(temp, data)
	sync_err := os.sync(temp)
	if write_err != nil || written != len(data) || sync_err != nil {
		_ = os.close(temp)
		_ = os.remove(tmp)
		return false
	}
	if os.close(temp) != nil {
		_ = os.remove(tmp)
		return false
	}
	if os.rename(tmp, p) != nil {
		_ = os.remove(tmp)
		return false
	}
	return true
}

// read loads path(app, file); ok = false when missing or unreadable.
read :: proc(app, file: string, allocator := context.temp_allocator) -> (data: []u8, ok: bool) {
	p := path(app, file) or_return
	d, err := os.read_entire_file(p, allocator)
	if err != nil do return nil, false
	return d, true
}

make_dirs_all_checked :: proc(path: string) -> bool {
	if len(path) == 0 do return false
	if os.make_directory_all(path) == nil do return true
	return os.is_directory(path)
}

// make_dirs_all preserves the original package contract for existing callers.
make_dirs_all :: proc(path: string) {
	_ = make_dirs_all_checked(path)
}
