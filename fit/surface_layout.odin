package fit

import "ingot:ui"

Fit_Column_Begin :: proc(
	surface: ^Surface,
	state: ^Fit_Column_State,
	x, y, width: i32,
	gap: i32 = 0,
) {
	_ = surface_ui(surface)
	assert(state != nil, "Fit.Fit_Column_Begin: nil state")
	assert(!state.open, "Fit.Fit_Column_Begin: state already open")
	state.surface = surface
	state.open = true
	ui.fit_column_begin(&state.inner, x, y, width, gap)
}

Fit_Column_Next :: proc(state: ^Fit_Column_State, height: i32) -> Rect {
	assert(state != nil && state.open, "Fit.Fit_Column_Next: state not open")
	_ = surface_ui(state.surface)
	return from_rect(ui.fit_column_next(&state.inner, height))
}

Fit_Column_End :: proc(state: ^Fit_Column_State) -> Rect {
	assert(state != nil && state.open, "Fit.Fit_Column_End: state not open")
	_ = surface_ui(state.surface)
	result := from_rect(ui.fit_column_end(&state.inner))
	state.surface = nil
	state.open = false
	return result
}

Surface_Fit_Column_Begin :: proc(
	surface: ^Surface,
	state: ^Fit_Column_State,
	x, y, width: i32,
	gap: i32 = 0,
) {
	Fit_Column_Begin(surface, state, x, y, width, gap)
}

Surface_Fit_Column_Next :: proc(surface: ^Surface, state: ^Fit_Column_State, height: i32) -> Rect {
	assert(state != nil && state.surface == surface, "Fit.Surface_Fit_Column_Next: surface mismatch")
	return Fit_Column_Next(state, height)
}

Surface_Fit_Column_End :: proc(surface: ^Surface, state: ^Fit_Column_State) -> Rect {
	assert(state != nil && state.surface == surface, "Fit.Surface_Fit_Column_End: surface mismatch")
	return Fit_Column_End(state)
}

Flow_Begin :: proc(surface: ^Surface, state: ^Flow_State, rect: Rect, gap_x, gap_y: i32) {
	_ = surface_ui(surface)
	assert(state != nil, "Fit.Flow_Begin: nil state")
	assert(!state.open, "Fit.Flow_Begin: state already open")
	state.surface = surface
	state.open = true
	ui.flow_begin(&state.inner, to_rect(rect), gap_x, gap_y)
}

Flow_Next :: proc(state: ^Flow_State, width, height: i32) -> Rect {
	assert(state != nil && state.open, "Fit.Flow_Next: state not open")
	_ = surface_ui(state.surface)
	return from_rect(ui.flow_next(&state.inner, width, height))
}

Flow_End :: proc(state: ^Flow_State) -> Rect {
	assert(state != nil && state.open, "Fit.Flow_End: state not open")
	_ = surface_ui(state.surface)
	result := from_rect(ui.flow_end(&state.inner))
	state.surface = nil
	state.open = false
	return result
}

Surface_Flow_Begin :: proc(surface: ^Surface, state: ^Flow_State, rect: Rect, gap_x, gap_y: i32) {
	Flow_Begin(surface, state, rect, gap_x, gap_y)
}

Surface_Flow_Next :: proc(surface: ^Surface, state: ^Flow_State, width, height: i32) -> Rect {
	assert(state != nil && state.surface == surface, "Fit.Surface_Flow_Next: surface mismatch")
	return Flow_Next(state, width, height)
}

Surface_Flow_End :: proc(surface: ^Surface, state: ^Flow_State) -> Rect {
	assert(state != nil && state.surface == surface, "Fit.Surface_Flow_End: surface mismatch")
	return Flow_End(state)
}

Layout_Begin :: proc(surface: ^Surface, state: ^Layout_State, rect: Rect, gap: i32 = 0) {
	_ = surface_ui(surface)
	assert(state != nil, "Fit.Layout_Begin: nil state")
	assert(!state.open, "Fit.Layout_Begin: state already open")
	state.surface = surface
	state.open = true
	ui.layout_begin(&state.inner, rect.x, rect.y, rect.w, rect.h, gap)
}

Layout_End :: proc(state: ^Layout_State) {
	assert(state != nil && state.open, "Fit.Layout_End: state not open")
	_ = surface_ui(state.surface)
	ui.layout_end(&state.inner)
	state.surface = nil
	state.open = false
}

Layout_Row :: proc(
	state: ^Layout_State,
	height: i32,
	gap: i32 = 0,
	align: Cross_Align = .Stretch,
) {
	assert(state != nil && state.open, "Fit.Layout_Row: state not open")
	_ = surface_ui(state.surface)
	ui.push_row(&state.inner, height, gap, ui.Cross_Align(align))
}

Layout_Pop :: proc(state: ^Layout_State) {
	assert(state != nil && state.open, "Fit.Layout_Pop: state not open")
	_ = surface_ui(state.surface)
	ui.layout_pop(&state.inner)
}

Layout_Weights :: proc(state: ^Layout_State, weights: []i32) {
	assert(state != nil && state.open, "Fit.Layout_Weights: state not open")
	_ = surface_ui(state.surface)
	ui.row_weights(&state.inner, weights)
}

Layout_Weighted :: proc(state: ^Layout_State, weight: i32) -> Rect {
	assert(state != nil && state.open, "Fit.Layout_Weighted: state not open")
	_ = surface_ui(state.surface)
	return from_rect(ui.next_weighted(&state.inner, weight))
}

Layout_Next :: proc(state: ^Layout_State, size: i32) -> Rect {
	assert(state != nil && state.open, "Fit.Layout_Next: state not open")
	_ = surface_ui(state.surface)
	return from_rect(ui.next(&state.inner, size))
}

Layout_Sized :: proc(state: ^Layout_State, main_size, cross_size: i32) -> Rect {
	assert(state != nil && state.open, "Fit.Layout_Sized: state not open")
	_ = surface_ui(state.surface)
	return from_rect(ui.next_sized(&state.inner, main_size, cross_size))
}

Layout_Remaining :: proc(state: ^Layout_State) -> Rect {
	assert(state != nil && state.open, "Fit.Layout_Remaining: state not open")
	_ = surface_ui(state.surface)
	return from_rect(ui.remaining(&state.inner))
}

Layout_Flex :: proc(
	state: ^Layout_State,
	tracks: []Track,
	justify: Main_Align = .Start,
) {
	assert(state != nil && state.open, "Fit.Layout_Flex: state not open")
	_ = surface_ui(state.surface)
	assert(len(tracks) <= ui.MAX_LAYOUT_FLEX, "Fit.Layout_Flex: too many tracks")
	inner: [ui.MAX_LAYOUT_FLEX]ui.Track
	for track, index in tracks do inner[index] = to_track(track)
	ui.flex_begin(&state.inner, inner[:len(tracks)], ui.Main_Align(justify))
}

Layout_Flex_Next :: proc(state: ^Layout_State) -> Rect {
	assert(state != nil && state.open, "Fit.Layout_Flex_Next: state not open")
	_ = surface_ui(state.surface)
	return from_rect(ui.flex_next(&state.inner))
}

Surface_Layout_Begin :: proc(
	surface: ^Surface,
	state: ^Layout_State,
	x, y, width, height: i32,
	gap: i32 = 0,
) {
	Layout_Begin(surface, state, {x, y, width, height}, gap)
}

Surface_Layout_End :: proc(surface: ^Surface, state: ^Layout_State) {
	assert(state != nil && state.surface == surface, "Fit.Surface_Layout_End: surface mismatch")
	Layout_End(state)
}

Surface_Layout_Push_Row :: proc(
	surface: ^Surface,
	state: ^Layout_State,
	height: i32,
	gap: i32 = 0,
	align: Cross_Align = .Stretch,
) {
	assert(state != nil && state.surface == surface, "Fit.Surface_Layout_Push_Row: surface mismatch")
	Layout_Row(state, height, gap, align)
}

Surface_Layout_Pop :: proc(surface: ^Surface, state: ^Layout_State) {
	assert(state != nil && state.surface == surface, "Fit.Surface_Layout_Pop: surface mismatch")
	Layout_Pop(state)
}

Surface_Layout_Row_Weights :: proc(surface: ^Surface, state: ^Layout_State, weights: []i32) {
	assert(state != nil && state.surface == surface, "Fit.Surface_Layout_Row_Weights: surface mismatch")
	Layout_Weights(state, weights)
}

Surface_Layout_Next_Weighted :: proc(
	surface: ^Surface,
	state: ^Layout_State,
	weight: i32,
) -> Rect {
	assert(state != nil && state.surface == surface, "Fit.Surface_Layout_Next_Weighted: surface mismatch")
	return Layout_Weighted(state, weight)
}

Surface_Layout_Next :: proc(surface: ^Surface, state: ^Layout_State, size: i32) -> Rect {
	assert(state != nil && state.surface == surface, "Fit.Surface_Layout_Next: surface mismatch")
	return Layout_Next(state, size)
}

Surface_Layout_Next_Sized :: proc(
	surface: ^Surface,
	state: ^Layout_State,
	main_size, cross_size: i32,
) -> Rect {
	assert(state != nil && state.surface == surface, "Fit.Surface_Layout_Next_Sized: surface mismatch")
	return Layout_Sized(state, main_size, cross_size)
}

Surface_Layout_Remaining :: proc(surface: ^Surface, state: ^Layout_State) -> Rect {
	assert(state != nil && state.surface == surface, "Fit.Surface_Layout_Remaining: surface mismatch")
	return Layout_Remaining(state)
}

Surface_Layout_Flex_Begin :: proc(
	surface: ^Surface,
	state: ^Layout_State,
	tracks: []Track,
	justify: Main_Align = .Start,
) {
	assert(state != nil && state.surface == surface, "Fit.Surface_Layout_Flex_Begin: surface mismatch")
	Layout_Flex(state, tracks, justify)
}

Surface_Layout_Flex_Next :: proc(surface: ^Surface, state: ^Layout_State) -> Rect {
	assert(state != nil && state.surface == surface, "Fit.Surface_Layout_Flex_Next: surface mismatch")
	return Layout_Flex_Next(state)
}
