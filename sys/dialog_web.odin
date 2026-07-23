#+build js
// File dialogs (web): browsers cannot open synchronous native file dialogs,
// and file access is user-gesture-gated — ok = false always. The web path
// for getting file contents into an ingot app is drag-and-drop onto the
// canvas (gfx IsFileDropped / GetDroppedFileData), which works today.
package sys

// open_file_dialog on web reports "no dialog available". Use canvas
// drag-and-drop instead (see gfx.GetDroppedFileData).
open_file_dialog :: proc(
	title: string,
	allocator := context.allocator,
) -> (
	path: string,
	ok: bool,
) {
	assert(len(title) < 256, "open_file_dialog: unreasonable title length")
	assert(allocator.procedure != nil, "open_file_dialog: nil allocator")
	return "", false
}

// save_file_dialog on web reports "no dialog available". Offer a download
// link via the host page instead; browsers do not expose save paths.
save_file_dialog :: proc(
	title: string,
	default_name: string,
	allocator := context.allocator,
) -> (
	path: string,
	ok: bool,
) {
	assert(len(title) < 256, "save_file_dialog: unreasonable title length")
	assert(len(default_name) < 256, "save_file_dialog: unreasonable name length")
	return "", false
}
