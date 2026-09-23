#+build js
// ingot:gfx - web accessibility stubs. The browser target mirrors semantic
// nodes into real DOM controls instead of AccessKit.
package gfx

import ak "ingot:accesskit"

A11Y_ENABLED :: false
MAX_A11Y_ACTIONS :: 64

A11y_Action :: struct {
	action: ak.Action,
	node:   ak.Node_Id,
}

A11y_State :: struct {}

context_init_accessibility :: proc(
	ctx: ^Context,
	factory: ak.Tree_Update_Factory,
	userdata: rawptr,
) -> bool {
	return false
}

init_accessibility :: proc(factory: ak.Tree_Update_Factory, userdata: rawptr) -> bool {
	return context_init_accessibility(default_context(), factory, userdata)
}

@(deprecated = "use init_accessibility")
InitAccessibility :: proc(factory: ak.Tree_Update_Factory, userdata: rawptr) -> bool {
	return init_accessibility(factory, userdata)
}

context_push_accessibility_update :: proc(ctx: ^Context) {}

push_accessibility_update :: proc() {
	context_push_accessibility_update(default_context())
}

@(deprecated = "use push_accessibility_update")
PushAccessibilityUpdate :: proc() {
	push_accessibility_update()
}

context_poll_accessibility_action :: proc(ctx: ^Context) -> (action: A11y_Action, ok: bool) {
	return {}, false
}

poll_accessibility_action :: proc() -> (action: A11y_Action, ok: bool) {
	return context_poll_accessibility_action(default_context())
}

@(deprecated = "use poll_accessibility_action")
PollAccessibilityAction :: proc() -> (action: A11y_Action, ok: bool) {
	return poll_accessibility_action()
}

context_close_accessibility :: proc(ctx: ^Context) {}

close_accessibility :: proc() {
	context_close_accessibility(default_context())
}

@(deprecated = "use close_accessibility")
CloseAccessibility :: proc() {
	close_accessibility()
}
