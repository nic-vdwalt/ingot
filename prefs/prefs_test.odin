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
	defer os.set_env("HOME", restore)

	// --- data_dir / path resolution ---
	os.set_env("HOME", "/tmp/ingot_home")
	dir, ok := data_dir("myapp", context.temp_allocator)
	testing.expect(t, ok, "data_dir resolves with HOME set")
	when ODIN_OS != .Windows {
		testing.expect_value(t, dir, "/tmp/ingot_home/.local/share/myapp")
	}

	p, pok := path("myapp", "settings.json", context.temp_allocator)
	testing.expect(t, pok, "path resolves")
	testing.expect(t, strings.has_suffix(p, "myapp/settings.json"), "path ends with app/file")

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
}
