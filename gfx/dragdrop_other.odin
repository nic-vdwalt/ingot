#+build !darwin
#+build !windows
#+build !linux
#+build !js
package gfx

@(private)
platform_dragdrop_init :: proc(owner: ^Context) {}

@(private)
platform_dragdrop_tick :: proc() {}

@(private)
platform_dragdrop_shutdown :: proc(owner: ^Context) {
	_drop_hover_stage_context(owner, false)
}
