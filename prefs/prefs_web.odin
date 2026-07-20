#+build js
// Per-app preference persistence (web): browser localStorage. There is no
// filesystem in the browser sandbox, so read/write map (app, file) to a
// localStorage key "app/file". Signatures mirror prefs.odin (native) so callers
// stay target-agnostic. Backed by the ingot_store module in web/ingot_app.js.
package prefs

import "core:fmt"

foreign import store "ingot_store"
@(default_calling_convention = "c")
foreign store {
	// ingot_store_get copies the value for `key` into `dst` (max `cap` bytes)
	// and returns its byte length, or -1 if the key is absent. If the value is
	// longer than cap, it returns the full length (caller may retry larger).
	ingot_store_get :: proc(key: [^]byte, key_len: i32, dst: [^]byte, cap: i32) -> i32 ---
	ingot_store_set :: proc(key: [^]byte, key_len: i32, val: [^]byte, val_len: i32) ---
}

// data_dir returns the logical key prefix for an app (parity with native).
data_dir :: proc(app: string, allocator := context.temp_allocator) -> (dir: string, ok: bool) {
	return app, len(app) > 0
}

// path returns the localStorage key "app/file" (parity with native path()).
path :: proc(app, file: string, allocator := context.temp_allocator) -> (p: string, ok: bool) {
	if len(app) == 0 do return "", false
	return fmt.aprintf("%s/%s", app, file, allocator = allocator), true
}

// write stores `data` under key "app/file".
write :: proc(app, file: string, data: []u8) -> bool {
	key, ok := path(app, file)
	if !ok do return false
	kb := transmute([]byte)key
	ingot_store_set(raw_data(kb), i32(len(kb)), raw_data(data), i32(len(data)))
	return true
}

// read loads the value under key "app/file"; ok=false when absent.
read :: proc(app, file: string, allocator := context.temp_allocator) -> (data: []u8, ok: bool) {
	key, key_ok := path(app, file)
	if !key_ok do return nil, false
	kb := transmute([]byte)key
	// Probe length first, then allocate exactly and copy.
	n := ingot_store_get(raw_data(kb), i32(len(kb)), nil, 0)
	if n <= 0 do return nil, false
	buf := make([]byte, int(n), allocator)
	got := ingot_store_get(raw_data(kb), i32(len(kb)), raw_data(buf), i32(len(buf)))
	if got <= 0 {
		delete(buf, allocator)
		return nil, false
	}
	return buf[:int(got)], true
}
