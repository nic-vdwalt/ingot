#+build !js
// ingot:gfx - native accessibility seam over the AccessKit C API.
package gfx

import "base:runtime"
import "core:sync"
import ak "ingot:accesskit"

A11Y_ENABLED :: ak.ENABLED
MAX_A11Y_ACTIONS :: 64

A11y_Action :: struct {
	action: ak.Action,
	node:   ak.Node_Id,
}

when A11Y_ENABLED {
	when ODIN_OS == .Darwin {
		A11y_State :: struct {
			initialized: bool,
			factory:     ak.Tree_Update_Factory,
			userdata:    rawptr,
			actions:     [MAX_A11Y_ACTIONS]A11y_Action,
			action_len:  int,
			action_mu:   sync.Mutex,
			adapter:     ak.Macos_Subclassing_Adapter,
		}
	} else when ODIN_OS == .Windows {
		A11y_State :: struct {
			initialized: bool,
			factory:     ak.Tree_Update_Factory,
			userdata:    rawptr,
			actions:     [MAX_A11Y_ACTIONS]A11y_Action,
			action_len:  int,
			action_mu:   sync.Mutex,
			adapter:     ak.Windows_Subclassing_Adapter,
		}
	} else {
		A11y_State :: struct {
			initialized: bool,
			factory:     ak.Tree_Update_Factory,
			userdata:    rawptr,
			actions:     [MAX_A11Y_ACTIONS]A11y_Action,
			action_len:  int,
			action_mu:   sync.Mutex,
			adapter:     ak.Unix_Adapter,
		}
	}
} else {
	A11y_State :: struct {
		initialized: bool,
		factory:     ak.Tree_Update_Factory,
		userdata:    rawptr,
		actions:     [MAX_A11Y_ACTIONS]A11y_Action,
		action_len:  int,
		action_mu:   sync.Mutex,
	}
}

@(private)
_a11y_stage :: proc(state: ^A11y_State, action: ak.Action, node: ak.Node_Id) {
	assert(state != nil, "_a11y_stage: nil state")
	sync.mutex_lock(&state.action_mu)
	if state.action_len < MAX_A11Y_ACTIONS {
		state.actions[state.action_len] = {action, node}
		state.action_len += 1
	}
	sync.mutex_unlock(&state.action_mu)
}

@(private)
_a11y_poll :: proc(state: ^A11y_State) -> (action: A11y_Action, ok: bool) {
	if state == nil do return {}, false
	sync.mutex_lock(&state.action_mu)
	defer sync.mutex_unlock(&state.action_mu)
	if state.action_len == 0 do return {}, false
	action = state.actions[0]
	state.action_len -= 1
	copy(state.actions[:state.action_len], state.actions[1:state.action_len + 1])
	return action, true
}

@(private = "file")
_a11y_on_action :: proc "c" (request: ^ak.Action_Request, userdata: rawptr) {
	context = runtime.default_context()
	when A11Y_ENABLED {
		if request == nil do return
		ctx := cast(^Context)userdata
		if ctx != nil && ctx.a11y.initialized {
			_a11y_stage(&ctx.a11y, request.action, request.target_node)
		}
		ak.action_request_free(request)
	}
}

context_init_accessibility :: proc(
	ctx: ^Context,
	factory: ak.Tree_Update_Factory,
	userdata: rawptr,
) -> bool {
	assert(ctx != nil, "context_init_accessibility: nil context")
	assert(factory != nil, "context_init_accessibility: nil factory")
	assert(!ctx.a11y.initialized, "context_init_accessibility: already initialized")
	when A11Y_ENABLED {
		when ODIN_OS == .Darwin {
			win := context_get_window_handle(ctx)
			if win == nil do return false
			ctx.a11y.adapter = ak.macos_subclassing_adapter_for_window(
				win,
				factory,
				userdata,
				_a11y_on_action,
				ctx,
			)
		} else when ODIN_OS == .Windows {
			hwnd := context_get_window_handle(ctx)
			if hwnd == nil do return false
			ctx.a11y.adapter = ak.windows_subclassing_adapter_new(
				hwnd,
				factory,
				userdata,
				_a11y_on_action,
				ctx,
			)
		} else {
			ctx.a11y.adapter = ak.unix_adapter_new(
				factory,
				userdata,
				_a11y_on_action,
				ctx,
				_a11y_on_deactivate,
				ctx,
			)
		}
		if ctx.a11y.adapter == nil do return false
		ctx.a11y.factory = factory
		ctx.a11y.userdata = userdata
		ctx.a11y.initialized = true
		return true
	} else {
		return false
	}
}

InitAccessibility :: proc(factory: ak.Tree_Update_Factory, userdata: rawptr) -> bool {
	return context_init_accessibility(default_context(), factory, userdata)
}

when A11Y_ENABLED && ODIN_OS != .Darwin && ODIN_OS != .Windows {
	@(private = "file")
	_a11y_on_deactivate :: proc "c" (userdata: rawptr) {}
}

context_push_accessibility_update :: proc(ctx: ^Context) {
	if ctx == nil do return
	when A11Y_ENABLED {
		if !ctx.a11y.initialized do return
		assert(ctx.a11y.factory != nil, "context_push_accessibility_update: nil factory")
		when ODIN_OS == .Darwin {
			events := ak.macos_subclassing_adapter_update_if_active(
				ctx.a11y.adapter,
				ctx.a11y.factory,
				ctx.a11y.userdata,
			)
			if events != nil do ak.macos_queued_events_raise(events)
		} else when ODIN_OS == .Windows {
			events := ak.windows_subclassing_adapter_update_if_active(
				ctx.a11y.adapter,
				ctx.a11y.factory,
				ctx.a11y.userdata,
			)
			if events != nil do ak.windows_queued_events_raise(events)
		} else {
			ak.unix_adapter_update_if_active(ctx.a11y.adapter, ctx.a11y.factory, ctx.a11y.userdata)
		}
	}
}

PushAccessibilityUpdate :: proc() {
	context_push_accessibility_update(default_context())
}

context_poll_accessibility_action :: proc(ctx: ^Context) -> (action: A11y_Action, ok: bool) {
	when A11Y_ENABLED {
		if ctx == nil do return {}, false
		return _a11y_poll(&ctx.a11y)
	} else {
		return {}, false
	}
}

PollAccessibilityAction :: proc() -> (action: A11y_Action, ok: bool) {
	return context_poll_accessibility_action(default_context())
}

context_close_accessibility :: proc(ctx: ^Context) {
	if ctx == nil do return
	when A11Y_ENABLED {
		if !ctx.a11y.initialized do return
		when ODIN_OS == .Darwin {
			ak.macos_subclassing_adapter_free(ctx.a11y.adapter)
		} else when ODIN_OS == .Windows {
			ak.windows_subclassing_adapter_free(ctx.a11y.adapter)
		} else {
			ak.unix_adapter_free(ctx.a11y.adapter)
		}
		ctx.a11y = {}
	}
}

CloseAccessibility :: proc() {
	context_close_accessibility(default_context())
}
