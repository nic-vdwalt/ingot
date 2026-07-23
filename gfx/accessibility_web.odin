#+build js
// ingot:gfx — web accessibility stubs. The browser target mirrors semantic
// nodes into real DOM controls (SyncWebControl / web/ingot_web.js) instead
// of AccessKit, so the native adapter API is a no-op here; apps can call it
// unconditionally.
package gfx

import ak "ingot:accesskit"

A11Y_ENABLED :: false

MAX_A11Y_ACTIONS :: 64

A11y_Action :: struct {
	action: ak.Action,
	node:   ak.Node_Id,
}

InitAccessibility :: proc(factory: ak.Tree_Update_Factory, userdata: rawptr) -> bool {
	return false
}

PushAccessibilityUpdate :: proc() {
}

PollAccessibilityAction :: proc() -> (action: A11y_Action, ok: bool) {
	return {}, false
}

CloseAccessibility :: proc() {
}
