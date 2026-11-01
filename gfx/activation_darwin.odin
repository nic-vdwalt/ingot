#+build darwin
package gfx

import "base:intrinsics"
@(require) import "core:fmt"
import NS "core:sys/darwin/Foundation"

foreign import libproc "system:System"

@(default_calling_convention = "c")
@(private = "file")
foreign libproc {
	proc_listallpids :: proc(buffer: rawptr, buffer_size: i32) -> i32 ---
	proc_name :: proc(pid: i32, buffer: rawptr, buffer_size: u32) -> i32 ---
}

@(objc_class = "NSRunningApplication")
@(private = "file")
Focus_NS_Running_Application :: struct {
	using _: intrinsics.objc_object,
}

@(private = "file")
SCREENSHOT_UI_BUNDLE :: "com.apple.screencaptureui"
// The /usr/sbin/screencapture CLI that drives an interactive selection.
@(private = "file")
SCREENSHOT_SELECTION_PROCESS :: "screencapture"
@(private = "file")
SCREENSHOT_PIDS_MAX :: 4
@(private = "file")
PROCESS_PIDS_MAX :: 8192
@(private = "file")
PROCESS_NAME_MAX :: 64

INGOT_FOCUS_TRACE :: #config(INGOT_FOCUS_TRACE, false)

@(objc_class = "NSWindow")
@(private = "file")
Focus_NS_Window :: struct {
	using _: intrinsics.objc_object,
}

@(objc_class = "NSEvent")
@(private = "file")
Focus_NS_Event :: struct {
	using _: intrinsics.objc_object,
}

@(private = "file")
NS_MODIFIER_SHIFT :: uint(1 << 17)
@(private = "file")
NS_MODIFIER_CONTROL :: uint(1 << 18)
@(private = "file")
NS_MODIFIER_OPTION :: uint(1 << 19)
@(private = "file")
NS_MODIFIER_COMMAND :: uint(1 << 20)

// +[NSEvent modifierFlags] reports the current hardware modifier state,
// independent of which app or window received the key events.
@(private)
_platform_held_modifiers :: proc() -> (held: Modifier_Families, known: bool) {
	flags := intrinsics.objc_send(uint, Focus_NS_Event, "modifierFlags")
	if flags & NS_MODIFIER_SHIFT != 0 do held += {.Shift}
	if flags & NS_MODIFIER_CONTROL != 0 do held += {.Control}
	if flags & NS_MODIFIER_OPTION != 0 do held += {.Alt}
	if flags & NS_MODIFIER_COMMAND != 0 do held += {.Super}
	return held, true
}

@(private)
_platform_modifier_reconcile :: proc(ctx: ^Context) {
	assert(ctx != nil, "_platform_modifier_reconcile: nil context")
	if ctx.win == nil do return
	held, known := _platform_held_modifiers()
	if !known do return
	released := _input_release_stale_modifiers(&ctx.inp, held)
	if released == 0 do return
	_idle_note_activity(&ctx.idle)
	when INGOT_FOCUS_TRACE {
		fmt.eprintfln("[ingot focus] released %d stale modifier key(s) held=%v", released, held)
	}
}

@(private = "file")
_darwin_activate_application :: proc(application: ^NS.Application) {
	assert(application != nil, "_darwin_activate_application: nil application")
	// macOS 14+ ignores activateIgnoringOtherApps:; activate is the cooperative
	// replacement and is honoured when the system grants activation.
	if bool(NS.respondsToSelector(cast(^NS.Object)application, NS.sel_registerName("activate"))) {
		NS.Application_activate(application)
	} else {
		NS.Application_activateIgnoringOtherApps(application, true)
	}
}

// A key window whose first responder is the window itself routes keystrokes to
// -[NSWindow noResponderFor:], which beeps. setStyleMask: and content-view
// swaps can leave it there, so hand input back to the backend's view.
@(private = "file")
_darwin_repair_first_responder :: proc(ctx: ^Context, window: ^Focus_NS_Window) {
	assert(ctx != nil, "_darwin_repair_first_responder: nil context")
	if window == nil || ctx.activation_view == nil do return
	responder := intrinsics.objc_send(rawptr, window, "firstResponder")
	if responder != nil && responder != rawptr(window) do return
	repaired := intrinsics.objc_send(NS.BOOL, window, "makeFirstResponder:", ctx.activation_view)
	when INGOT_FOCUS_TRACE {
		fmt.eprintfln("[ingot focus] first responder repaired=%v", bool(repaired))
	} else {
		_ = repaired
	}
}

@(private = "file")
_darwin_activate_window :: proc(ctx: ^Context) {
	assert(ctx != nil, "_darwin_activate_window: nil context")
	window := cast(^Focus_NS_Window)context_get_window_handle(ctx)
	if window == nil do return
	application := NS.Application_sharedApplication()
	if application == nil do return
	_ = NS.Application_setActivationPolicy(application, .Regular)
	_darwin_activate_application(application)
	intrinsics.objc_send(nil, window, "makeKeyAndOrderFront:", rawptr(nil))
	_darwin_repair_first_responder(ctx, window)
	when INGOT_FOCUS_TRACE {
		fmt.eprintfln(
			"[ingot focus] activate: app_active=%v key_window=%p is_key=%v first_responder=%p pending=%d",
			bool(NS.Application_active(application)),
			NS.Application_keyWindow(application),
			bool(intrinsics.objc_send(NS.BOOL, window, "isKeyWindow")),
			intrinsics.objc_send(rawptr, window, "firstResponder"),
			ctx.activation_retries_pending,
		)
	}
}

@(private)
_platform_activate_window :: proc(ctx: ^Context) {
	assert(ctx != nil, "_platform_activate_window: nil context")
	window := cast(^Focus_NS_Window)context_get_window_handle(ctx)
	// The first call happens at window-ready time, before applications may wrap
	// the content view, so this captures the backend's input view.
	if ctx.activation_view == nil && window != nil {
		ctx.activation_view = intrinsics.objc_send(rawptr, window, "contentView")
	}
	ctx.activation_retries_pending = ACTIVATION_RETRY_LIMIT
	ctx.activation_next_at = 0
	_platform_activation_poll(ctx)
	assert(ctx.activation_retries_pending <= ACTIVATION_RETRY_LIMIT)
}

@(private)
_platform_activation_poll :: proc(ctx: ^Context) {
	assert(ctx != nil, "_platform_activation_poll: nil context")
	now := platform_now()
	focused, known := _platform_native_window_focus(ctx)
	visible := !_platform_native_window_hidden(ctx) && !_platform_native_window_minimized(ctx)
	application := NS.Application_sharedApplication()
	app_active := application != nil && bool(NS.Application_active(application))
	app_has_key_window := application != nil && NS.Application_keyWindow(application) != nil
	rearm := _activation_should_rearm(
		app_active,
		ctx.application_was_active,
		focused,
		known,
		_window_should_activate(ctx.config_flags),
		app_has_key_window,
		visible,
		now,
		ctx.activation_next_at,
	)
	ctx.application_was_active = app_active
	if ctx.activation_retries_pending == 0 && rearm {
		ctx.activation_retries_pending = ACTIVATION_RETRY_LIMIT
		ctx.activation_next_at = now
	}
	next, next_at, retry := _activation_retry_advance(
		ctx.activation_retries_pending,
		ctx.activation_next_at,
		now,
		known && focused,
	)
	ctx.activation_retries_pending = next
	ctx.activation_next_at = next_at
	if retry {
		_darwin_activate_window(ctx)
	} else if known && focused {
		_darwin_repair_first_responder(ctx, cast(^Focus_NS_Window)context_get_window_handle(ctx))
	}
	assert(ctx.activation_retries_pending <= ACTIVATION_RETRY_LIMIT)
	assert(!(known && focused) || ctx.activation_retries_pending == 0)
}

// _platform_activation_wait_timeout shortens an idle wait so a scheduled
// activation retry runs on time even when no native event arrives.
@(private)
_platform_activation_wait_timeout :: proc(ctx: ^Context, timeout: f64) -> f64 {
	assert(ctx != nil, "_platform_activation_wait_timeout: nil context")
	if ctx.activation_retries_pending == 0 do return timeout
	return clamp(ctx.activation_next_at - platform_now(), 0, timeout)
}

@(private)
_platform_native_window_focus :: proc(ctx: ^Context) -> (focused, known: bool) {
	if ctx == nil || ctx.win == nil do return false, false
	window := cast(^Focus_NS_Window)context_get_window_handle(ctx)
	if window == nil do return false, false
	is_key := intrinsics.objc_send(NS.BOOL, window, "isKeyWindow")
	return bool(is_key), true
}

// _platform_cursor_occluded reports whether another application's window sits
// under the cursor, such as the Cmd+Shift+4 screenshot overlay. GLFW keeps
// reporting the cursor position through such windows, while native AppKit
// views receive no moves there, so input_poll freezes hover while this holds.
@(private)
_platform_cursor_occluded :: proc(ctx: ^Context) -> bool {
	assert(ctx != nil, "_platform_cursor_occluded: nil context")
	if ctx.win == nil do return false
	window := cast(^Focus_NS_Window)context_get_window_handle(ctx)
	if window == nil do return false
	// The screenshot overlay is invisible to windowNumberAtPoint:, which
	// reports the window beneath it, so it is detected separately. Its
	// screencaptureui host lingers after a capture with a full-screen window
	// still listed on screen, so only the selection CLI's lifetime counts.
	if _darwin_screenshot_selection_active() do return true
	own := intrinsics.objc_send(NS.Integer, window, "windowNumber")
	assert(own >= 0, "_platform_cursor_occluded: negative window number")
	location := intrinsics.objc_send(NS.Point, Focus_NS_Event, "mouseLocation")
	top := intrinsics.objc_send(
		NS.Integer,
		Focus_NS_Window,
		"windowNumberAtPoint:belowWindowWithWindowNumber:",
		location,
		NS.Integer(0),
	)
	if top <= 0 || top == own do return false
	// Windows owned by this process (menus, popups, IME panels) are not
	// foreign occluders, so hovering them must not freeze the pointer.
	application := NS.Application_sharedApplication()
	if application == nil do return true
	return intrinsics.objc_send(rawptr, application, "windowWithWindowNumber:", top) == nil
}

// _darwin_screenshot_pids collects the process identifiers of running
// screencaptureui instances. The system launches it only for a capture and
// its floating thumbnail, so an empty result keeps the per-frame cost low.
@(private = "file")
_darwin_screenshot_pids :: proc(pids: ^[SCREENSHOT_PIDS_MAX]i32) -> int {
	assert(pids != nil, "_darwin_screenshot_pids: nil output")
	apps := intrinsics.objc_send(
		^NS.Array,
		Focus_NS_Running_Application,
		"runningApplicationsWithBundleIdentifier:",
		NS.AT(SCREENSHOT_UI_BUNDLE),
	)
	if apps == nil do return 0
	count := min(int(apps->count()), SCREENSHOT_PIDS_MAX)
	for index in 0 ..< count {
		app := apps->object(NS.UInteger(index))
		pids[index] = intrinsics.objc_send(i32, app, "processIdentifier")
	}
	assert(count >= 0 && count <= SCREENSHOT_PIDS_MAX)
	return count
}

@(private = "file")
_darwin_process_pids: [PROCESS_PIDS_MAX]i32

// _darwin_selection_process_alive reports whether the screencapture CLI runs.
// It lives exactly as long as a selection session, crosshair phase included,
// whereas its windows only appear once a drag starts.
@(private = "file")
_darwin_selection_process_alive :: proc() -> bool {
	listed := proc_listallpids(&_darwin_process_pids[0], size_of(_darwin_process_pids))
	if listed <= 0 do return false
	count := min(int(listed), PROCESS_PIDS_MAX)
	assert(count > 0 && count <= PROCESS_PIDS_MAX)
	for index in 0 ..< count {
		name: [PROCESS_NAME_MAX]u8
		length := proc_name(_darwin_process_pids[index], &name[0], PROCESS_NAME_MAX)
		if length <= 0 do continue
		assert(int(length) <= PROCESS_NAME_MAX)
		if string(name[:length]) == SCREENSHOT_SELECTION_PROCESS do return true
	}
	return false
}

@(private = "file")
_darwin_selection_was_active: bool

// _darwin_screenshot_selection_active reports whether a Cmd+Shift+4/5
// selection is in progress. screencaptureui starts with every session, so the
// process table is only scanned while it runs, keeping idle frames cheap.
@(private = "file")
_darwin_screenshot_selection_active :: proc() -> bool {
	pool := NS.scoped_autoreleasepool()
	assert(pool != nil, "_darwin_screenshot_selection_active: no autorelease pool")
	pids: [SCREENSHOT_PIDS_MAX]i32
	count := _darwin_screenshot_pids(&pids)
	assert(count >= 0 && count <= SCREENSHOT_PIDS_MAX)
	active := count > 0 && _darwin_selection_process_alive()
	when INGOT_FOCUS_TRACE {
		if active != _darwin_selection_was_active {
			fmt.eprintfln("[ingot focus] screenshot selection active=%v", active)
		}
	}
	_darwin_selection_was_active = active
	return active
}

@(private)
_platform_native_window_minimized :: proc(ctx: ^Context) -> bool {
	if ctx == nil || ctx.win == nil do return false
	window := cast(^Focus_NS_Window)context_get_window_handle(ctx)
	if window == nil do return false
	return bool(intrinsics.objc_send(NS.BOOL, window, "isMiniaturized"))
}

@(private)
_platform_native_window_hidden :: proc(ctx: ^Context) -> bool {
	if ctx == nil || ctx.win == nil do return false
	window := cast(^Focus_NS_Window)context_get_window_handle(ctx)
	if window == nil do return false
	return !bool(intrinsics.objc_send(NS.BOOL, window, "isVisible"))
}
