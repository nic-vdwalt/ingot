// File dialogs (Windows): GetOpenFileNameW / GetSaveFileNameW from comdlg32
// via core:sys/windows — no extra linker flags. Cancel is an operating
// condition (ok = false).
package sys

import "core:strings"
import win "core:sys/windows"

// _DIALOG_PATH_CAP bounds the returned path buffer (wide chars).
@(private)
_DIALOG_PATH_CAP :: 1024

// open_file_dialog shows the OS open-file dialog; blocks until dismissed.
open_file_dialog :: proc(
	title: string,
	allocator := context.allocator,
) -> (
	path: string,
	ok: bool,
) {
	assert(len(title) < 256, "open_file_dialog: unreasonable title length")
	buffer: [_DIALOG_PATH_CAP]u16
	ofn := win.OPENFILENAMEW {
		lStructSize = size_of(win.OPENFILENAMEW),
		lpstrFile   = raw_data(buffer[:]),
		nMaxFile    = _DIALOG_PATH_CAP,
		lpstrTitle  = win.utf8_to_wstring(title, context.temp_allocator),
		Flags       = win.OFN_FILEMUSTEXIST | win.OFN_PATHMUSTEXIST | win.OFN_NOCHANGEDIR,
	}
	if win.GetOpenFileNameW(&ofn) == win.FALSE do return "", false
	return _dialog_wide_to_path(buffer[:], allocator)
}

// save_file_dialog shows the OS save-file dialog with a suggested file name.
save_file_dialog :: proc(
	title: string,
	default_name: string,
	allocator := context.allocator,
) -> (
	path: string,
	ok: bool,
) {
	assert(len(title) < 256, "save_file_dialog: unreasonable title length")
	assert(len(default_name) < _DIALOG_PATH_CAP, "save_file_dialog: name too long")
	buffer: [_DIALOG_PATH_CAP]u16
	seed := win.utf8_to_utf16(default_name, context.temp_allocator)
	for u, i in seed {
		if i >= _DIALOG_PATH_CAP - 1 do break
		buffer[i] = u
	}
	ofn := win.OPENFILENAMEW {
		lStructSize = size_of(win.OPENFILENAMEW),
		lpstrFile   = raw_data(buffer[:]),
		nMaxFile    = _DIALOG_PATH_CAP,
		lpstrTitle  = win.utf8_to_wstring(title, context.temp_allocator),
		Flags       = win.OFN_OVERWRITEPROMPT | win.OFN_NOCHANGEDIR,
	}
	if win.GetSaveFileNameW(&ofn) == win.FALSE do return "", false
	return _dialog_wide_to_path(buffer[:], allocator)
}

@(private)
_dialog_wide_to_path :: proc(
	buffer: []u16,
	allocator := context.allocator,
) -> (
	path: string,
	ok: bool,
) {
	assert(len(buffer) > 0, "_dialog_wide_to_path: empty buffer")
	length := 0
	for length < len(buffer) && buffer[length] != 0 do length += 1
	if length == 0 do return "", false
	converted, err := win.utf16_to_utf8(buffer[:length], context.temp_allocator)
	if err != nil || len(converted) == 0 do return "", false
	return strings.clone(converted, allocator), true
}
