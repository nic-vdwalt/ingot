#+build linux
package gfx

@(require) import "core:sys/posix"
@(require) import x11 "vendor:x11/xlib"

when !INGOT_GFX_SDL3 {

	DD_Get_Display_Proc :: #type proc "c" () -> ^x11.Display
	DD_Get_Window_Proc :: #type proc "c" (window: rawptr) -> x11.Window

	// Process-wide: one X display per process via GLFW, one dlsym pass, one
	// atom set. Per-window state is derived from the owner on every tick, so
	// nothing here is bound to a single context.
	@(private = "file")
	g_dd_resolved: bool
	@(private = "file")
	g_dd_ok: bool
	@(private = "file")
	g_dd_display: ^x11.Display
	@(private = "file")
	g_dd_get_window: DD_Get_Window_Proc
	@(private = "file")
	g_dd_enter: x11.Atom
	@(private = "file")
	g_dd_leave: x11.Atom
	@(private = "file")
	g_dd_position: x11.Atom
	@(private = "file")
	g_dd_drop: x11.Atom

	@(private = "file")
	_dd_resolve_once :: proc() {
		if g_dd_resolved do return
		g_dd_resolved = true
		handle := posix.dlopen(nil, {.LAZY})
		if handle == nil do return
		get_display := DD_Get_Display_Proc(posix.dlsym(handle, "glfwGetX11Display"))
		get_window := DD_Get_Window_Proc(posix.dlsym(handle, "glfwGetX11Window"))
		if get_display == nil || get_window == nil do return
		display := get_display()
		if display == nil do return
		g_dd_display = display
		g_dd_get_window = get_window
		g_dd_enter = x11.InternAtom(g_dd_display, "XdndEnter", false)
		g_dd_leave = x11.InternAtom(g_dd_display, "XdndLeave", false)
		g_dd_position = x11.InternAtom(g_dd_display, "XdndPosition", false)
		g_dd_drop = x11.InternAtom(g_dd_display, "XdndDrop", false)
		g_dd_ok = true
	}

	@(private)
	platform_dragdrop_init :: proc(owner: ^Context) {
		if owner == nil do return
		_dd_resolve_once()
	}

	@(private)
	platform_dragdrop_tick :: proc(ctx: ^Context) {
		assert(ctx != nil, "platform_dragdrop_tick: nil context")
		if !g_dd_ok || ctx.win == nil do return
		window := g_dd_get_window(rawptr(ctx.win))
		if window == 0 do return
		pending: [16]x11.XEvent
		count := 0
		for count < len(pending) {
			if !x11.CheckTypedWindowEvent(g_dd_display, window, .ClientMessage, &pending[count]) {
				break
			}
			message_type := pending[count].xclient.message_type
			switch message_type {
			case g_dd_enter, g_dd_position:
				_drop_hover_stage_context(ctx, true)
			case g_dd_leave, g_dd_drop:
				_drop_hover_stage_context(ctx, false)
			}
			count += 1
		}
		for index := count - 1; index >= 0; index -= 1 do x11.PutBackEvent(g_dd_display, &pending[index])
	}

	@(private)
	platform_dragdrop_shutdown :: proc(owner: ^Context) {
		if owner == nil do return
		_drop_hover_stage_context(owner, false)
	}

}
