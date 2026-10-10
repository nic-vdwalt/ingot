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
	dir, data_dir_err := data_dir("myapp", context.temp_allocator)
	testing.expect_value(t, data_dir_err, Prefs_Error.None)
	when ODIN_OS == .Windows {
		testing.expect(t, strings.has_suffix(dir, "myapp"), "data_dir ends with app")
	} else {
		testing.expect_value(t, dir, "/tmp/ingot_home/.local/share/myapp")
	}

	p, path_err := path("myapp", "settings.json", context.temp_allocator)
	testing.expect_value(t, path_err, Prefs_Error.None)
	testing.expect(t, strings.has_suffix(p, "myapp/settings.json"), "path ends with app/file")
	_, empty_app_err := data_dir("", context.temp_allocator)
	_, empty_file_err := path("myapp", "", context.temp_allocator)
	testing.expect_value(t, empty_app_err, Prefs_Error.Invalid_Name)
	testing.expect_value(t, empty_file_err, Prefs_Error.Invalid_Name)

	// --- user_home prefers HOME ---
	testing.expect_value(t, user_home(context.temp_allocator), "/tmp/ingot_home")

	// --- write -> read round-trip (exercises make_dirs_all) ---
	base := fmt.tprintf("/tmp/ingot_prefs_test_%d", os.get_pid())
	os.set_env("HOME", base)
	defer os.remove_all(base)

	payload := transmute([]u8)string("hello=world")
	testing.expect_value(t, write("roundtrip", "cfg.txt", payload), Prefs_Error.None)

	got, read_err := read("roundtrip", "cfg.txt", context.temp_allocator)
	testing.expect_value(t, read_err, Prefs_Error.None)
	testing.expect_value(t, string(got), "hello=world")

	replacement := transmute([]u8)string("new=value")
	testing.expect_value(t, write("roundtrip", "cfg.txt", replacement), Prefs_Error.None)
	got, read_err = read("roundtrip", "cfg.txt", context.temp_allocator)
	testing.expect_value(t, read_err, Prefs_Error.None)
	_, missing_err := read("roundtrip", "absent.txt", context.temp_allocator)
	testing.expect_value(t, missing_err, Prefs_Error.Missing)
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
	testing.expect_value(t, write("blocked", "cfg.txt", payload), Prefs_Error.Create_Dir)
	testing.expect_value(t, write("", "cfg.txt", payload), Prefs_Error.Invalid_Name)
	testing.expect_value(t, write("blocked", "", payload), Prefs_Error.Invalid_Name)
}
