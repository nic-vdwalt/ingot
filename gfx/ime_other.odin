#+build !darwin
#+build !windows
#+build !js
// ingot:gfx - IME seam stubs for platforms without a candidate-rect
// implementation yet (Linux/X11/Wayland input-method positioning would go
// through XIM/text-input-v3; not implemented).
package gfx

@(private)
_ime_set_rect :: proc(x, y, w, h: i32) {
}

@(private)
_ime_deactivate :: proc() {
}
