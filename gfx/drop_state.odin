package gfx

MAX_DROPPED_FILES :: 16
MAX_DROPPED_PATH_BYTES :: 64 * 1024
DROP_NAME_MAX :: 256

IsFileDragOver :: proc() -> bool {
	return g.drop.hover_frame
}

@(private)
_drop_hover_stage_context :: proc "contextless" (ctx: ^Context, over: bool) {
	if ctx == nil do return
	ctx.drop.hover_staged = over
}

@(private)
_drop_hover_stage :: proc "contextless" (over: bool) {
	_drop_hover_stage_context(g, over)
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
	_drop_complete_context(g)
}

@(private)
_drop_state_reset :: proc() {
	g.drop.hover_staged = false
	g.drop.hover_frame = false
	g.drop.ready = false
}
