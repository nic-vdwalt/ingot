#+build !darwin
#+build !windows
#+build !linux
#+build !js
package gfx

@(private)
platform_dragdrop_init :: proc() {}

@(private)
platform_dragdrop_tick :: proc() {}

@(private)
platform_dragdrop_shutdown :: proc() {
	_drop_hover_stage(false)
}
