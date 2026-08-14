package fit

import "ingot:ui"

Surface_Fit_Column_Begin :: proc(
	surface: ^Surface,
	state: ^Fit_Column_State,
	x, y, width: i32,
	gap: i32 = 0,
) {
	_ = surface_ui(surface)
	assert(state != nil, "Fit.Surface_Fit_Column_Begin: nil state")
	ui.fit_column_begin(&state.inner, x, y, width, gap)
}

Surface_Fit_Column_Next :: proc(surface: ^Surface, state: ^Fit_Column_State, height: i32) -> Rect {
	_ = surface_ui(surface)
	assert(state != nil, "Fit.Surface_Fit_Column_Next: nil state")
	return from_rect(ui.fit_column_next(&state.inner, height))
}

Surface_Fit_Column_End :: proc(surface: ^Surface, state: ^Fit_Column_State) -> Rect {
	_ = surface_ui(surface)
	assert(state != nil, "Fit.Surface_Fit_Column_End: nil state")
	return from_rect(ui.fit_column_end(&state.inner))
}

Surface_Flow_Begin :: proc(surface: ^Surface, state: ^Flow_State, rect: Rect, gap_x, gap_y: i32) {
	_ = surface_ui(surface)
	assert(state != nil, "Fit.Surface_Flow_Begin: nil state")
	ui.flow_begin(&state.inner, to_rect(rect), gap_x, gap_y)
}

Surface_Flow_Next :: proc(surface: ^Surface, state: ^Flow_State, width, height: i32) -> Rect {
	_ = surface_ui(surface)
	assert(state != nil, "Fit.Surface_Flow_Next: nil state")
	return from_rect(ui.flow_next(&state.inner, width, height))
}

Surface_Flow_End :: proc(surface: ^Surface, state: ^Flow_State) -> Rect {
	_ = surface_ui(surface)
	assert(state != nil, "Fit.Surface_Flow_End: nil state")
	return from_rect(ui.flow_end(&state.inner))
}

Surface_Layout_Begin :: proc(
	surface: ^Surface,
	state: ^Layout_State,
	x, y, width, height: i32,
	gap: i32 = 0,
) {
	_ = surface_ui(surface)
	assert(state != nil, "Fit.Surface_Layout_Begin: nil state")
	ui.layout_begin(&state.inner, x, y, width, height, gap)
}

Surface_Layout_End :: proc(surface: ^Surface, state: ^Layout_State) {
	_ = surface_ui(surface)
	assert(state != nil, "Fit.Surface_Layout_End: nil state")
	ui.layout_end(&state.inner)
}

Surface_Layout_Push_Row :: proc(
	surface: ^Surface,
	state: ^Layout_State,
	height: i32,
	gap: i32 = 0,
	align: Cross_Align = .Stretch,
) {
	_ = surface_ui(surface)
	assert(state != nil, "Fit.Surface_Layout_Push_Row: nil state")
	ui.push_row(&state.inner, height, gap, ui.Cross_Align(align))
}

Surface_Layout_Pop :: proc(surface: ^Surface, state: ^Layout_State) {
	_ = surface_ui(surface)
	assert(state != nil, "Fit.Surface_Layout_Pop: nil state")
	ui.layout_pop(&state.inner)
}

Surface_Layout_Row_Weights :: proc(surface: ^Surface, state: ^Layout_State, weights: []i32) {
	_ = surface_ui(surface)
	assert(state != nil, "Fit.Surface_Layout_Row_Weights: nil state")
	ui.row_weights(&state.inner, weights)
}

Surface_Layout_Next_Weighted :: proc(
	surface: ^Surface,
	state: ^Layout_State,
	weight: i32,
) -> Rect {
	_ = surface_ui(surface)
	assert(state != nil, "Fit.Surface_Layout_Next_Weighted: nil state")
	return from_rect(ui.next_weighted(&state.inner, weight))
}

Surface_Layout_Next :: proc(surface: ^Surface, state: ^Layout_State, size: i32) -> Rect {
	_ = surface_ui(surface)
	assert(state != nil, "Fit.Surface_Layout_Next: nil state")
	return from_rect(ui.next(&state.inner, size))
}

Surface_Layout_Next_Sized :: proc(
	surface: ^Surface,
	state: ^Layout_State,
	main_size, cross_size: i32,
) -> Rect {
	_ = surface_ui(surface)
	assert(state != nil, "Fit.Surface_Layout_Next_Sized: nil state")
	return from_rect(ui.next_sized(&state.inner, main_size, cross_size))
}

Surface_Layout_Remaining :: proc(surface: ^Surface, state: ^Layout_State) -> Rect {
	_ = surface_ui(surface)
	assert(state != nil, "Fit.Surface_Layout_Remaining: nil state")
	return from_rect(ui.remaining(&state.inner))
}

Surface_Layout_Flex_Begin :: proc(
	surface: ^Surface,
	state: ^Layout_State,
	tracks: []Track,
	justify: Main_Align = .Start,
) {
	_ = surface_ui(surface)
	assert(state != nil, "Fit.Surface_Layout_Flex_Begin: nil state")
	assert(len(tracks) <= ui.MAX_LAYOUT_FLEX, "Fit.Surface_Layout_Flex_Begin: too many tracks")
	inner: [ui.MAX_LAYOUT_FLEX]ui.Track
	for track, index in tracks do inner[index] = to_track(track)
	ui.flex_begin(&state.inner, inner[:len(tracks)], ui.Main_Align(justify))
}

Surface_Layout_Flex_Next :: proc(surface: ^Surface, state: ^Layout_State) -> Rect {
	_ = surface_ui(surface)
	assert(state != nil, "Fit.Surface_Layout_Flex_Next: nil state")
	return from_rect(ui.flex_next(&state.inner))
}
