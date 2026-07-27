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

@(private = "file")
store_len :: proc(n: int) -> (length: i32, ok: bool) {
	if n < 0 || n > int(max(i32)) do return 0, false
	length = i32(n)
	ensure(length >= 0, "store_len: validated length became negative")
	ensure(int(length) == n, "store_len: length narrowed")
	return length, true
}

// data_dir returns the logical key prefix for an app (parity with native).
data_dir :: proc(app: string, allocator := context.temp_allocator) -> (dir: string, ok: bool) {
	return app, len(app) > 0
}

// path returns the localStorage key "app/file" (parity with native path()).
path :: proc(app, file: string, allocator := context.temp_allocator) -> (p: string, ok: bool) {
	if len(app) == 0 || len(file) == 0 do return "", false
	p = fmt.aprintf("%s/%s", app, file, allocator = allocator)
	assert(len(p) > len(app))
	return p, true
}

// write stores `data` under key "app/file".
write :: proc(app, file: string, data: []u8) -> bool {
	key, ok := path(app, file)
	if !ok do return false
	kb := transmute([]byte)key
	key_len := store_len(len(kb)) or_return
	data_len := store_len(len(data)) or_return
	ensure(int(key_len) == len(kb), "write: key length mismatch")
	ensure(int(data_len) == len(data), "write: data length mismatch")
	ingot_store_set(raw_data(kb), key_len, raw_data(data), data_len)
	return true
}

// read loads the value under key "app/file"; ok=false when absent.
read :: proc(app, file: string, allocator := context.temp_allocator) -> (data: []u8, ok: bool) {
	key, key_ok := path(app, file)
	if !key_ok do return nil, false
	kb := transmute([]byte)key
	key_len := store_len(len(kb)) or_return
	// Probe length first, then allocate exactly and copy.
	n := ingot_store_get(raw_data(kb), key_len, nil, 0)
	if n < 0 do return nil, false
	if n == 0 do return make([]byte, 0, allocator), true
	ensure(n > 0, "read: validated length must be positive")
	buf := make([]byte, int(n), allocator)
	got := ingot_store_get(raw_data(kb), key_len, raw_data(buf), n)
	if got != n {
		delete(buf, allocator)
		return nil, false
	}
	ensure(len(buf) == int(n), "read: copied length mismatch")
	return buf, true
}
