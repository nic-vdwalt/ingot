package gfx

MAX_DROPPED_FILES :: 16
MAX_DROPPED_PATH_BYTES :: 64 * 1024
DROP_NAME_MAX :: 256

@(private)
g_drop_hover_staged: bool
@(private)
g_drop_hover_frame: bool
@(private)
g_drop_ready: bool

IsFileDragOver :: proc() -> bool {
	return g_drop_hover_frame
}

@(private)
_drop_hover_stage :: proc "contextless" (over: bool) {
	g_drop_hover_staged = over
}

@(private)
_drop_hover_publish :: proc() {
	g_drop_hover_frame = g_drop_hover_staged
}

@(private)
_drop_complete :: proc "contextless" () {
	g_drop_hover_staged = false
	g_drop_hover_frame = false
	g_drop_ready = true
}

@(private)
_drop_state_reset :: proc() {
	g_drop_hover_staged = false
	g_drop_hover_frame = false
	g_drop_ready = false
}
