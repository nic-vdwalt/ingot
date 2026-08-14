package gfx

MAX_DROPPED_FILES :: 16
MAX_DROPPED_PATH_BYTES :: 64 * 1024
DROP_NAME_MAX :: 256

context_is_file_drag_over :: proc(ctx: ^Context) -> bool {
	return ctx != nil && ctx.drop.hover_frame
}

IsFileDragOver :: proc() -> bool {
	return context_is_file_drag_over(default_context())
}

@(private)
_drop_hover_stage_context :: proc "contextless" (ctx: ^Context, over: bool) {
	if ctx == nil do return
	ctx.drop.hover_staged = over
}

@(private)
_drop_hover_stage :: proc "contextless" (over: bool) {
	_drop_hover_stage_context(default_context(), over)
}

@(private)
_drop_hover_publish :: proc(ctx: ^Context) {
	assert(ctx != nil, "_drop_hover_publish: nil context")
	ctx.drop.hover_frame = ctx.drop.hover_staged
}

@(private)
_drop_complete_context :: proc "contextless" (ctx: ^Context) {
	if ctx == nil do return
	ctx.drop.hover_staged = false
	ctx.drop.hover_frame = false
	ctx.drop.ready = true
}

@(private)
_drop_complete :: proc "contextless" () {
	_drop_complete_context(default_context())
}

@(private)
_drop_state_reset_context :: proc(ctx: ^Context) {
	assert(ctx != nil, "_drop_state_reset_context: nil context")
	ctx.drop.hover_staged = false
	ctx.drop.hover_frame = false
	ctx.drop.ready = false
}

@(private)
_drop_state_reset :: proc() {
	_drop_state_reset_context(default_context())
}
