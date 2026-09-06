package fit

import "ingot:ui"

Vertical_Cursor_Begin :: proc(
	surface: ^Surface,
	state: ^Vertical_Cursor_State,
	x, y, width: i32,
	gap: i32 = 0,
) {
	_ = surface_ui(surface)
	assert(state != nil, "Fit.Vertical_Cursor_Begin: nil state")
	assert(!state.open, "Fit.Vertical_Cursor_Begin: state already open")
	state.surface = surface
	state.open = true
	ui.fit_column_begin(&state.inner, x, y, width, gap)
}

Vertical_Cursor_Begin_Bounded :: proc(
	surface: ^Surface,
	state: ^Vertical_Cursor_State,
	rect: Rect,
	gap: i32 = 0,
) {
	_ = surface_ui(surface)
	assert(state != nil, "Fit.Vertical_Cursor_Begin_Bounded: nil state")
	assert(!state.open, "Fit.Vertical_Cursor_Begin_Bounded: state already open")
	state.surface = surface
	state.open = true
	ui.fit_column_begin_bounded(&state.inner, rect.x, rect.y, rect.w, rect.h, gap)
}

Vertical_Cursor_Next :: proc(state: ^Vertical_Cursor_State, height: i32) -> Rect {
	assert(state != nil && state.open, "Fit.Vertical_Cursor_Next: state not open")
	_ = surface_ui(state.surface)
	return from_rect(ui.fit_column_next(&state.inner, height))
}

Vertical_Cursor_Space :: proc(state: ^Vertical_Cursor_State, height: i32) {
	assert(state != nil && state.open, "Fit.Vertical_Cursor_Space: state not open")
	_ = surface_ui(state.surface)
	ui.fit_column_space(&state.inner, height)
}

Vertical_Cursor_Remaining :: proc(state: ^Vertical_Cursor_State) -> i32 {
	assert(state != nil, "Fit.Vertical_Cursor_Remaining: nil state")
	return ui.fit_column_remaining(&state.inner)
}

Vertical_Cursor_Overflow :: proc(state: ^Vertical_Cursor_State) -> i32 {
	assert(state != nil, "Fit.Vertical_Cursor_Overflow: nil state")
	return ui.fit_column_overflow(&state.inner)
}

Vertical_Cursor_Text :: proc(
	state: ^Vertical_Cursor_State,
	text: string,
	role: Text_Role = .Body,
	ink: Ink = .Primary,
) -> Rect {
	assert(state != nil && state.open, "Fit.Vertical_Cursor_Text: state not open")
	height := Surface_Text_Line_Height(state.surface, role)
	slot := Vertical_Cursor_Next(state, height)
	if slot.w > 0 && slot.h == height {
		Surface_Text(state.surface, text, slot.x, slot.y, role, ink)
	}
	return slot
}

Vertical_Cursor_Text_Wrapped :: proc(
	state: ^Vertical_Cursor_State,
	text: string,
	role: Text_Role = .Body,
	ink: Ink = .Primary,
) -> Rect {
	assert(state != nil && state.open, "Fit.Vertical_Cursor_Text_Wrapped: state not open")
	u := surface_ui(state.surface)
	height := ui.text_wrapped(u.frame, text, 0, 0, state.inner.w, role, ink, draw = false)
	slot := Vertical_Cursor_Next(state, height)
	if slot.w > 0 && slot.h == height && height > 0 {
		drawn := ui.text_wrapped(u.frame, text, slot.x, slot.y, slot.w, role, ink)
		assert(drawn == height, "Fit.Vertical_Cursor_Text_Wrapped: measurement drift")
	}
	return slot
}

Vertical_Cursor_Section_Header :: proc(state: ^Vertical_Cursor_State, label: string) -> Rect {
	assert(state != nil && state.open, "Fit.Vertical_Cursor_Section_Header: state not open")
	height := Surface_Section_Header_Height(state.surface)
	slot := Vertical_Cursor_Next(state, height)
	if slot.w > 0 && slot.h == height {
		next_y := Surface_Section_Header(state.surface, slot, label)
		assert(next_y == slot.y + slot.h, "Fit.Vertical_Cursor_Section_Header: height drift")
	}
	return slot
}

Vertical_Cursor_End :: proc(state: ^Vertical_Cursor_State) -> Rect {
	assert(state != nil && state.open, "Fit.Vertical_Cursor_End: state not open")
	_ = surface_ui(state.surface)
	result := from_rect(ui.fit_column_end(&state.inner))
	state.surface = nil
	state.open = false
	return result
}
