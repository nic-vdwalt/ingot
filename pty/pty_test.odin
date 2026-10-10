#+build !js
package pty

import "core:testing"

@(test)
spawn_rejects_invalid_arguments :: proc(t: ^testing.T) {
	_, nil_shell := spawn(nil, 80, 24)
	testing.expect_value(t, nil_shell, Spawn_Error.Invalid_Args)
	_, zero_cols := spawn("/bin/sh", 0, 24)
	testing.expect_value(t, zero_cols, Spawn_Error.Invalid_Args)
	_, oversized := spawn("/bin/sh", PTY_DIMENSION_MAX + 1, 24)
	testing.expect_value(t, oversized, Spawn_Error.Invalid_Args)
}

@(test)
spawn_argv_rejects_invalid_arguments :: proc(t: ^testing.T) {
	_, empty := spawn_argv(nil, 80, 24)
	testing.expect_value(t, empty, Spawn_Error.Invalid_Args)
	nil_head := [?]cstring{nil}
	_, nil_arg := spawn_argv(nil_head[:], 80, 24)
	testing.expect_value(t, nil_arg, Spawn_Error.Invalid_Args)
	argv := [?]cstring{"/bin/sh"}
	_, zero_rows := spawn_argv(argv[:], 80, 0)
	testing.expect_value(t, zero_rows, Spawn_Error.Invalid_Args)
}

@(test)
spawn_error_none_is_zero :: proc(t: ^testing.T) {
	err: Spawn_Error
	testing.expect_value(t, err, Spawn_Error.None)
	testing.expect_value(t, int(Spawn_Error.None), 0)
}
