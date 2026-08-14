#+build !js
package prefs

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// prefs reads the process-global HOME (USERPROFILE on Windows). Because that
// state is shared across threads, all HOME-dependent assertions run inside one
// sequential test to avoid a race between concurrent test procedures.
@(test)
prefs_paths_and_roundtrip :: proc(t: ^testing.T) {
	restore := os.get_env("HOME", context.temp_allocator)
	restore_appdata := os.get_env("APPDATA", context.temp_allocator)
	defer os.set_env("HOME", restore)
	defer os.set_env("APPDATA", restore_appdata)

	// --- data_dir / path resolution ---
	os.set_env("HOME", "/tmp/ingot_home")
	os.set_env("APPDATA", "")
	dir, ok := data_dir("myapp", context.temp_allocator)
	testing.expect(t, ok, "data_dir resolves with HOME set")
	when ODIN_OS != .Windows {
		testing.expect_value(t, dir, "/tmp/ingot_home/.local/share/myapp")
	}

	p, pok := path("myapp", "settings.json", context.temp_allocator)
	testing.expect(t, pok, "path resolves")
	testing.expect(t, strings.has_suffix(p, "myapp/settings.json"), "path ends with app/file")
	_, empty_app_ok := data_dir("", context.temp_allocator)
	_, empty_file_ok := path("myapp", "", context.temp_allocator)
	testing.expect(t, !empty_app_ok, "empty app is rejected")
	testing.expect(t, !empty_file_ok, "empty file is rejected")

	// --- user_home prefers HOME ---
	testing.expect_value(t, user_home(context.temp_allocator), "/tmp/ingot_home")

	// --- write -> read round-trip (exercises make_dirs_all) ---
	base := fmt.tprintf("/tmp/ingot_prefs_test_%d", os.get_pid())
	os.set_env("HOME", base)
	defer os.remove_all(base)

	payload := transmute([]u8)string("hello=world")
	wok := write("roundtrip", "cfg.txt", payload)
	testing.expect(t, wok, "write succeeds and creates dirs")

	got, rok := read("roundtrip", "cfg.txt", context.temp_allocator)
	testing.expect(t, rok, "read succeeds")
	testing.expect_value(t, string(got), "hello=world")

	replacement := transmute([]u8)string("new=value")
	testing.expect(t, write("roundtrip", "cfg.txt", replacement), "replacement succeeds")
	got, rok = read("roundtrip", "cfg.txt", context.temp_allocator)
	testing.expect(t, rok, "replacement reads")
	testing.expect_value(t, string(got), "new=value")
	roundtrip_dir := fmt.tprintf("%s/.local/share/roundtrip", base)
	dir_handle, dir_err := os.open(roundtrip_dir)
	testing.expect(t, dir_err == nil, "roundtrip directory opens")
	if dir_err == nil {
		entries, read_err := os.read_dir(dir_handle, -1, context.temp_allocator)
		testing.expect(t, read_err == nil, "roundtrip directory reads")
		testing.expect_value(t, len(entries), 1)
		_ = os.close(dir_handle)
	}

	blocked_home := fmt.tprintf("/tmp/ingot_prefs_blocked_%d", os.get_pid())
	os.remove_all(blocked_home)
	defer os.remove_all(blocked_home)
	testing.expect(t, os.make_directory_all(blocked_home) == nil, "create blocked HOME")
	blocker := fmt.tprintf("%s/.local", blocked_home)
	testing.expect(t, os.write_entire_file(blocker, payload) == nil, "create blocker")
	os.set_env("HOME", blocked_home)
	testing.expect(t, !write("blocked", "cfg.txt", payload), "propagate mkdir failure")
	testing.expect(t, !write("", "cfg.txt", payload), "empty app write is rejected")
	testing.expect(t, !write("blocked", "", payload), "empty file write is rejected")
}
