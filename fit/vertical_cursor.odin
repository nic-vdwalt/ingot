package fit

import "ingot:ui"

vertical_cursor_begin :: proc(
	surface: ^Surface,
	state: ^Vertical_Cursor_State,
	x, y, width: i32,
	gap: i32 = 0,
) {
	_ = surface_ui(surface)
	assert(state != nil, "fit.vertical_cursor_begin: nil state")
	assert(!state.open, "fit.vertical_cursor_begin: state already open")
	state.surface = surface
	state.open = true
	ui.fit_column_begin(&state.inner, x, y, width, gap)
}

vertical_cursor_begin_bounded :: proc(
	surface: ^Surface,
	state: ^Vertical_Cursor_State,
	rect: Rect,
	gap: i32 = 0,
) {
	_ = surface_ui(surface)
	assert(state != nil, "fit.vertical_cursor_begin_bounded: nil state")
	assert(!state.open, "fit.vertical_cursor_begin_bounded: state already open")
	state.surface = surface
	state.open = true
	ui.fit_column_begin_bounded(&state.inner, rect.x, rect.y, rect.w, rect.h, gap)
}

vertical_cursor_next :: proc(state: ^Vertical_Cursor_State, height: i32) -> Rect {
	assert(state != nil && state.open, "fit.vertical_cursor_next: state not open")
	_ = surface_ui(state.surface)
	return ui.fit_column_next(&state.inner, height)
}

vertical_cursor_space :: proc(state: ^Vertical_Cursor_State, height: i32) {
	assert(state != nil && state.open, "fit.vertical_cursor_space: state not open")
	_ = surface_ui(state.surface)
	ui.fit_column_space(&state.inner, height)
}

vertical_cursor_remaining :: proc(state: ^Vertical_Cursor_State) -> i32 {
	assert(state != nil, "fit.vertical_cursor_remaining: nil state")
	return ui.fit_column_remaining(&state.inner)
}

vertical_cursor_overflow :: proc(state: ^Vertical_Cursor_State) -> i32 {
	assert(state != nil, "fit.vertical_cursor_overflow: nil state")
	return ui.fit_column_overflow(&state.inner)
}

vertical_cursor_text :: proc(
	state: ^Vertical_Cursor_State,
	text: string,
	role: Text_Role = .Body,
	ink: Ink = .Primary,
) -> Rect {
	assert(state != nil && state.open, "fit.vertical_cursor_text: state not open")
	height := surface_text_line_height(state.surface, role)
	slot := vertical_cursor_next(state, height)
	if slot.w > 0 && slot.h == height {
		surface_text(state.surface, text, slot.x, slot.y, role, ink)
	}
	return slot
}

vertical_cursor_text_wrapped :: proc(
	state: ^Vertical_Cursor_State,
	text: string,
	role: Text_Role = .Body,
	ink: Ink = .Primary,
) -> Rect {
	assert(state != nil && state.open, "fit.vertical_cursor_text_wrapped: state not open")
	u := surface_ui(state.surface)
	height := ui.text_wrapped(u.frame, text, 0, 0, state.inner.w, role, ink, draw = false)
	slot := vertical_cursor_next(state, height)
	if slot.w > 0 && slot.h == height && height > 0 {
		drawn := ui.text_wrapped(u.frame, text, slot.x, slot.y, slot.w, role, ink)
		assert(drawn == height, "fit.vertical_cursor_text_wrapped: measurement drift")
	}
	return slot
}

vertical_cursor_section_header :: proc(state: ^Vertical_Cursor_State, label: string) -> Rect {
	assert(state != nil && state.open, "fit.vertical_cursor_section_header: state not open")
	height := surface_section_header_height(state.surface)
	slot := vertical_cursor_next(state, height)
	if slot.w > 0 && slot.h == height {
		next_y := surface_section_header(state.surface, slot, label)
		assert(next_y == slot.y + slot.h, "fit.vertical_cursor_section_header: height drift")
	}
	return slot
}

vertical_cursor_end :: proc(state: ^Vertical_Cursor_State) -> Rect {
	assert(state != nil && state.open, "fit.vertical_cursor_end: state not open")
	_ = surface_ui(state.surface)
	result := ui.fit_column_end(&state.inner)
	state.surface = nil
	state.open = false
	return result
}
