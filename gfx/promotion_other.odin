#+build !darwin
#+build !js
package gfx

@(private)
platform_promote_refresh :: proc(ctx: ^Context) {
	assert(ctx != nil, "platform_promote_refresh: nil context")
}

@(private)
platform_refresh_shutdown :: proc(ctx: ^Context) {
	assert(ctx != nil, "platform_refresh_shutdown: nil context")
}
