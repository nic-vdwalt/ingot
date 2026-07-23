// File dialogs (macOS): AppleScript `choose file` / `choose file name` via
// osascript. Zero-dependency (argv spawn, no shell) and returns the selected
// POSIX path on stdout. A dismissed dialog exits non-zero — an operating
// condition, reported as ok = false.
package sys

import "core:os"
import "core:strings"

// open_file_dialog shows the OS open-file dialog; blocks until dismissed.
// ok = false when the user cancels or the dialog cannot be shown.
open_file_dialog :: proc(title: string, allocator := context.allocator) -> (path: string, ok: bool) {
	assert(len(title) < 256, "open_file_dialog: unreasonable title length")
	script := strings.concatenate(
		{"POSIX path of (choose file with prompt \"", _dialog_escape(title), "\")"},
		context.temp_allocator,
	)
	return _dialog_exec(script, allocator)
}

// save_file_dialog shows the OS save-file dialog with a suggested file name.
save_file_dialog :: proc(
	title: string,
	default_name: string,
	allocator := context.allocator,
) -> (path: string, ok: bool) {
	assert(len(title) < 256, "save_file_dialog: unreasonable title length")
	assert(len(default_name) < 256, "save_file_dialog: unreasonable name length")
	script := strings.concatenate(
		{
			"POSIX path of (choose file name with prompt \"", _dialog_escape(title),
			"\" default name \"", _dialog_escape(default_name), "\")",
		},
		context.temp_allocator,
	)
	return _dialog_exec(script, allocator)
}

// _dialog_escape neutralizes quotes/backslashes so titles cannot break out of
// the AppleScript string literal (paired with the argv spawn: no shell).
@(private)
_dialog_escape :: proc(s: string, allocator := context.temp_allocator) -> string {
	assert(len(s) < 1024, "_dialog_escape: unreasonable input length")
	escaped, _ := strings.replace_all(s, "\\", "\\\\", allocator)
	escaped, _ = strings.replace_all(escaped, "\"", "\\\"", allocator)
	return escaped
}

@(private)
_dialog_exec :: proc(script: string, allocator := context.allocator) -> (path: string, ok: bool) {
	assert(len(script) > 0, "_dialog_exec: empty script")
	state, stdout, stderr, err := os.process_exec(
		{command = {"osascript", "-e", script}},
		context.temp_allocator,
	)
	_ = stderr
	if err != nil || !state.exited || state.exit_code != 0 do return "", false
	trimmed := strings.trim_space(string(stdout))
	if len(trimmed) == 0 do return "", false
	assert(trimmed[0] == '/', "_dialog_exec: expected absolute POSIX path")
	return strings.clone(trimmed, allocator), true
}
