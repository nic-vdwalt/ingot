#+build !darwin
package gfx

@(private)
platform_frame_delivery_init :: proc(ctx: ^Context) -> bool {
	assert(ctx != nil, "platform_frame_delivery_init: nil context")
	return false
}

@(private)
platform_frame_delivery_shutdown :: proc(ctx: ^Context) {
	assert(ctx != nil, "platform_frame_delivery_shutdown: nil context")
}
