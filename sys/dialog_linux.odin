// File dialogs (Linux): try zenity, then kdialog. Neither installed (or the
// user cancelled) is an operating condition - ok = false, never an assert.
// argv spawn, no shell, so titles cannot inject commands.
package sys

import "core:os"
import "core:strings"

// open_file_dialog shows an open-file dialog; blocks until dismissed.
open_file_dialog :: proc(
	title: string,
	allocator := context.allocator,
) -> (
	path: string,
	ok: bool,
) {
	if len(title) >= 256 do return "", false
	if p, zok := _dialog_exec({"zenity", "--file-selection", "--title", title}, allocator); zok {
		return p, true
	}
	return _dialog_exec({"kdialog", "--getopenfilename", ".", "--title", title}, allocator)
}

// save_file_dialog shows a save-file dialog with a suggested file name.
save_file_dialog :: proc(
	title: string,
	default_name: string,
	allocator := context.allocator,
) -> (
	path: string,
	ok: bool,
) {
	if len(title) >= 256 || len(default_name) >= 256 do return "", false
	if p, zok := _dialog_exec(
		{"zenity", "--file-selection", "--save", "--title", title, "--filename", default_name},
		allocator,
	); zok {
		return p, true
	}
	return _dialog_exec(
		{"kdialog", "--getsavefilename", default_name, "--title", title},
		allocator,
	)
}

@(private)
_dialog_exec :: proc(
	command: []string,
	allocator := context.allocator,
) -> (
	path: string,
	ok: bool,
) {
	if len(command) < 2 do return "", false
	state, stdout, stderr, err := os.process_exec({command = command}, context.temp_allocator)
	_ = stderr
	if err != nil || !state.exited || state.exit_code != 0 do return "", false
	trimmed := strings.trim_right(string(stdout), "\r\n")
	if len(trimmed) == 0 || len(trimmed) >= 4096 do return "", false
	return strings.clone(trimmed, allocator), true
}
