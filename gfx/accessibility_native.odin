#+build !js
// ingot:gfx - native accessibility seam over the AccessKit C API.
//
// The widget toolkit records a per-frame semantic buffer (ui/semantics.odin);
// its bridge (ui/a11y_bridge.odin) converts that buffer into AccessKit tree
// updates through the factory registered here. This file owns only the
// platform adapter lifecycle and the AT action queue:
//
//   InitAccessibility  - attach the adapter to the window (NSWindow content
//                        view on macOS, HWND subclass on Windows, AT-SPI on
//                        Linux). Lazy: AccessKit builds nothing until
//                        assistive tech actually requests the tree, so this
//                        is free for non-AT users.
//   PushAccessibilityUpdate - per frame; invokes the factory only while AT
//                        is active (update_if_active), then raises queued
//                        platform events.
//   PollAccessibilityAction - drains AT-initiated actions (Click/Focus/...)
//                        staged by the adapter callback, which may run off
//                        the main thread (bounded ring + mutex).
//
// Disable at compile time with -define:INGOT_ACCESSKIT=false.
package gfx

import "base:runtime"
import "core:sync"
import ak "ingot:accesskit"

A11Y_ENABLED :: ak.ENABLED

// MAX_A11Y_ACTIONS bounds the staged AT action queue (Tiger Style: put a
// limit on everything). Overflow drops the newest action - AT retries.
MAX_A11Y_ACTIONS :: 64

// A11y_Action is one assistive-tech request against a semantic node.
A11y_Action :: struct {
	action: ak.Action,
	node:   ak.Node_Id,
}

@(private = "file")
A11y_State :: struct {
	initialized: bool,
	factory:     ak.Tree_Update_Factory,
	userdata:    rawptr,
	actions:     [MAX_A11Y_ACTIONS]A11y_Action,
	action_len:  int,
	action_mu:   sync.Mutex,
}

@(private = "file")
g_a11y: A11y_State

when A11Y_ENABLED {
	when ODIN_OS == .Darwin {
		@(private = "file")
		g_a11y_adapter: ak.Macos_Subclassing_Adapter
	} else when ODIN_OS == .Windows {
		@(private = "file")
		g_a11y_adapter: ak.Windows_Subclassing_Adapter
	} else {
		@(private = "file")
		g_a11y_adapter: ak.Unix_Adapter
	}
}

// _a11y_stage appends one action to the bounded queue. Package-private (not
// file-private) so the TSan stress test can drive it from a producer thread
// exactly like the adapter callback does.
@(private)
_a11y_stage :: proc(action: ak.Action, node: ak.Node_Id) {
	sync.mutex_lock(&g_a11y.action_mu)
	if g_a11y.action_len < MAX_A11Y_ACTIONS {
		g_a11y.actions[g_a11y.action_len] = {action, node}
		g_a11y.action_len += 1
	}
	sync.mutex_unlock(&g_a11y.action_mu)
}

// _a11y_on_action stages an AT action; AccessKit may invoke it off the main
// thread (documented for unix, permitted on macOS/Windows), hence the mutex.
@(private = "file")
_a11y_on_action :: proc "c" (request: ^ak.Action_Request, userdata: rawptr) {
	context = runtime.default_context()
	when A11Y_ENABLED {
		if request == nil do return
		_a11y_stage(request.action, request.target_node)
		ak.action_request_free(request)
	}
}

// InitAccessibility attaches the AccessKit adapter to the current window and
// registers the tree-update factory (called lazily, only while assistive
// tech is active). Returns false when accessibility is compiled out or no
// window exists. Call once, after InitWindow.
InitAccessibility :: proc(factory: ak.Tree_Update_Factory, userdata: rawptr) -> bool {
	assert(factory != nil, "InitAccessibility: nil factory")
	assert(!g_a11y.initialized, "InitAccessibility: already initialized")
	when A11Y_ENABLED {
		g_a11y.factory = factory
		g_a11y.userdata = userdata
		when ODIN_OS == .Darwin {
			win := GetWindowHandle()
			if win == nil do return false
			g_a11y_adapter = ak.macos_subclassing_adapter_for_window(
				win,
				factory,
				userdata,
				_a11y_on_action,
				nil,
			)
		} else when ODIN_OS == .Windows {
			hwnd := GetWindowHandle()
			if hwnd == nil do return false
			g_a11y_adapter = ak.windows_subclassing_adapter_new(
				hwnd,
				factory,
				userdata,
				_a11y_on_action,
				nil,
			)
		} else {
			g_a11y_adapter = ak.unix_adapter_new(
				factory,
				userdata,
				_a11y_on_action,
				nil,
				_a11y_on_deactivate,
				nil,
			)
		}
		if g_a11y_adapter == nil do return false
		g_a11y.initialized = true
		return true
	} else {
		return false
	}
}

when A11Y_ENABLED && ODIN_OS != .Darwin && ODIN_OS != .Windows {
	@(private = "file")
	_a11y_on_deactivate :: proc "c" (userdata: rawptr) {
	}
}

// PushAccessibilityUpdate offers this frame's tree to the adapter. The
// factory only runs while assistive tech consumes the tree (update_if_active)
// - the per-frame cost without AT is one branch. Call at end of frame, after
// all UI is drawn.
PushAccessibilityUpdate :: proc() {
	when A11Y_ENABLED {
		if !g_a11y.initialized do return
		assert(g_a11y.factory != nil, "PushAccessibilityUpdate: nil factory")
		when ODIN_OS == .Darwin {
			events := ak.macos_subclassing_adapter_update_if_active(
				g_a11y_adapter,
				g_a11y.factory,
				g_a11y.userdata,
			)
			if events != nil do ak.macos_queued_events_raise(events)
		} else when ODIN_OS == .Windows {
			events := ak.windows_subclassing_adapter_update_if_active(
				g_a11y_adapter,
				g_a11y.factory,
				g_a11y.userdata,
			)
			if events != nil do ak.windows_queued_events_raise(events)
		} else {
			ak.unix_adapter_update_if_active(g_a11y_adapter, g_a11y.factory, g_a11y.userdata)
		}
	}
}

// PollAccessibilityAction pops one staged AT action. Drain each frame before
// input handling so Click/Focus requests act on the same frame's widgets.
PollAccessibilityAction :: proc() -> (action: A11y_Action, ok: bool) {
	when A11Y_ENABLED {
		sync.mutex_lock(&g_a11y.action_mu)
		defer sync.mutex_unlock(&g_a11y.action_mu)
		if g_a11y.action_len == 0 do return {}, false
		action = g_a11y.actions[0]
		g_a11y.action_len -= 1
		copy(g_a11y.actions[:g_a11y.action_len], g_a11y.actions[1:g_a11y.action_len + 1])
		return action, true
	} else {
		return {}, false
	}
}

// CloseAccessibility frees the adapter (window teardown).
CloseAccessibility :: proc() {
	when A11Y_ENABLED {
		if !g_a11y.initialized do return
		when ODIN_OS == .Darwin {
			ak.macos_subclassing_adapter_free(g_a11y_adapter)
		} else when ODIN_OS == .Windows {
			ak.windows_subclassing_adapter_free(g_a11y_adapter)
		} else {
			ak.unix_adapter_free(g_a11y_adapter)
		}
		g_a11y_adapter = nil
		g_a11y = {}
	}
}
