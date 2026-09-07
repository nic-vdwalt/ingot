#+build linux
package gfx

@(require) import "core:sys/posix"
@(require) import x11 "vendor:x11/xlib"

when !INGOT_GFX_SDL3 {

	DD_Get_Display_Proc :: #type proc "c" () -> ^x11.Display
	DD_Get_Window_Proc :: #type proc "c" (window: rawptr) -> x11.Window

	@(private = "file")
	g_dd_resolved: bool
	@(private = "file")
	g_dd_ok: bool
	@(private = "file")
	g_dd_display: ^x11.Display
	@(private = "file")
	g_dd_window: x11.Window
	@(private = "file")
	g_dd_enter: x11.Atom
	@(private = "file")
	g_dd_leave: x11.Atom
	@(private = "file")
	g_dd_position: x11.Atom
	@(private = "file")
	g_dd_drop: x11.Atom
	@(private = "file")
	g_dd_owner: ^Context

	@(private)
	platform_dragdrop_init :: proc(owner: ^Context) {
		if owner == nil || g_dd_resolved do return
		g_dd_resolved = true
		handle := posix.dlopen(nil, {.LAZY})
		if handle == nil do return
		get_display := DD_Get_Display_Proc(posix.dlsym(handle, "glfwGetX11Display"))
		get_window := DD_Get_Window_Proc(posix.dlsym(handle, "glfwGetX11Window"))
		if get_display == nil || get_window == nil do return
		window_handle := rawptr(owner.win)
		if window_handle == nil do return
		g_dd_display = get_display()
		if g_dd_display == nil do return
		g_dd_window = get_window(window_handle)
		g_dd_enter = x11.InternAtom(g_dd_display, "XdndEnter", false)
		g_dd_leave = x11.InternAtom(g_dd_display, "XdndLeave", false)
		g_dd_position = x11.InternAtom(g_dd_display, "XdndPosition", false)
		g_dd_drop = x11.InternAtom(g_dd_display, "XdndDrop", false)
		g_dd_ok = g_dd_window != 0
		if g_dd_ok do g_dd_owner = owner
	}

	@(private)
	platform_dragdrop_tick :: proc() {
		if !g_dd_ok do return
		pending: [16]x11.XEvent
		count := 0
		for count < len(pending) {
			if !x11.CheckTypedWindowEvent(
				g_dd_display,
				g_dd_window,
				.ClientMessage,
				&pending[count],
			) {
				break
			}
			message_type := pending[count].xclient.message_type
			switch message_type {
			case g_dd_enter, g_dd_position:
				_drop_hover_stage_context(g_dd_owner, true)
			case g_dd_leave, g_dd_drop:
				_drop_hover_stage_context(g_dd_owner, false)
			}
			count += 1
		}
		for index := count - 1; index >= 0; index -= 1 do x11.PutBackEvent(g_dd_display, &pending[index])
	}

	@(private)
	platform_dragdrop_shutdown :: proc(owner: ^Context) {
		if owner == nil || owner != g_dd_owner do return
		_drop_hover_stage_context(owner, false)
		g_dd_ok = false
		g_dd_resolved = false
		g_dd_display = nil
		g_dd_window = 0
		g_dd_owner = nil
	}

}
