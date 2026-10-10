package fit

import "ingot:ui"

fit_column_begin :: proc(
	surface: ^Surface,
	state: ^Fit_Column_State,
	x, y, width: i32,
	gap: i32 = 0,
) {
	_ = surface_ui(surface)
	assert(state != nil, "fit.fit_column_begin: nil state")
	assert(!state.open, "fit.fit_column_begin: state already open")
	state.surface = surface
	state.open = true
	ui.fit_column_begin(&state.inner, x, y, width, gap)
}

fit_column_next :: proc(state: ^Fit_Column_State, height: i32) -> Rect {
	assert(state != nil && state.open, "fit.fit_column_next: state not open")
	_ = surface_ui(state.surface)
	return ui.fit_column_next(&state.inner, height)
}

fit_column_end :: proc(state: ^Fit_Column_State) -> Rect {
	assert(state != nil && state.open, "fit.fit_column_end: state not open")
	_ = surface_ui(state.surface)
	result := ui.fit_column_end(&state.inner)
	state.surface = nil
	state.open = false
	return result
}

surface_fit_column_begin :: proc(
	surface: ^Surface,
	state: ^Fit_Column_State,
	x, y, width: i32,
	gap: i32 = 0,
) {
	fit_column_begin(surface, state, x, y, width, gap)
}

surface_fit_column_next :: proc(surface: ^Surface, state: ^Fit_Column_State, height: i32) -> Rect {
	assert(
		state != nil && state.surface == surface,
		"fit.surface_fit_column_next: surface mismatch",
	)
	return fit_column_next(state, height)
}

surface_fit_column_end :: proc(surface: ^Surface, state: ^Fit_Column_State) -> Rect {
	assert(
		state != nil && state.surface == surface,
		"fit.surface_fit_column_end: surface mismatch",
	)
	return fit_column_end(state)
}

flow_begin :: proc(surface: ^Surface, state: ^Flow_State, rect: Rect, gap_x, gap_y: i32) {
	_ = surface_ui(surface)
	assert(state != nil, "fit.flow_begin: nil state")
	assert(!state.open, "fit.flow_begin: state already open")
	state.surface = surface
	state.open = true
	ui.flow_begin(&state.inner, rect, gap_x, gap_y)
}

flow_next :: proc(state: ^Flow_State, width, height: i32) -> Rect {
	assert(state != nil && state.open, "fit.flow_next: state not open")
	_ = surface_ui(state.surface)
	return ui.flow_next(&state.inner, width, height)
}

flow_end :: proc(state: ^Flow_State) -> Rect {
	assert(state != nil && state.open, "fit.flow_end: state not open")
	_ = surface_ui(state.surface)
	result := ui.flow_end(&state.inner)
	state.surface = nil
	state.open = false
	return result
}

surface_flow_begin :: proc(surface: ^Surface, state: ^Flow_State, rect: Rect, gap_x, gap_y: i32) {
	flow_begin(surface, state, rect, gap_x, gap_y)
}

surface_flow_next :: proc(surface: ^Surface, state: ^Flow_State, width, height: i32) -> Rect {
	assert(state != nil && state.surface == surface, "fit.surface_flow_next: surface mismatch")
	return flow_next(state, width, height)
}

surface_flow_end :: proc(surface: ^Surface, state: ^Flow_State) -> Rect {
	assert(state != nil && state.surface == surface, "fit.surface_flow_end: surface mismatch")
	return flow_end(state)
}

layout_begin :: proc(surface: ^Surface, state: ^Layout_State, rect: Rect, gap: i32 = 0) {
	_ = surface_ui(surface)
	assert(state != nil, "fit.layout_begin: nil state")
	assert(!state.open, "fit.layout_begin: state already open")
	state.surface = surface
	state.open = true
	ui.layout_begin(&state.inner, rect.x, rect.y, rect.w, rect.h, gap)
}

layout_end :: proc(state: ^Layout_State) {
	assert(state != nil && state.open, "fit.layout_end: state not open")
	_ = surface_ui(state.surface)
	ui.layout_end(&state.inner)
	state.surface = nil
	state.open = false
}

layout_row :: proc(
	state: ^Layout_State,
	height: i32,
	gap: i32 = 0,
	align: Cross_Align = .Stretch,
) {
	assert(state != nil && state.open, "fit.layout_row: state not open")
	_ = surface_ui(state.surface)
	ui.push_row(&state.inner, height, gap, align)
}

layout_pop :: proc(state: ^Layout_State) {
	assert(state != nil && state.open, "fit.layout_pop: state not open")
	_ = surface_ui(state.surface)
	ui.layout_pop(&state.inner)
}

layout_weights :: proc(state: ^Layout_State, weights: []i32) {
	assert(state != nil && state.open, "fit.layout_weights: state not open")
	_ = surface_ui(state.surface)
	ui.row_weights(&state.inner, weights)
}

layout_weighted :: proc(state: ^Layout_State, weight: i32) -> Rect {
	assert(state != nil && state.open, "fit.layout_weighted: state not open")
	_ = surface_ui(state.surface)
	return ui.next_weighted(&state.inner, weight)
}

layout_next :: proc(state: ^Layout_State, size: i32) -> Rect {
	assert(state != nil && state.open, "fit.layout_next: state not open")
	_ = surface_ui(state.surface)
	return ui.next(&state.inner, size)
}

layout_sized :: proc(state: ^Layout_State, main_size, cross_size: i32) -> Rect {
	assert(state != nil && state.open, "fit.layout_sized: state not open")
	_ = surface_ui(state.surface)
	return ui.next_sized(&state.inner, main_size, cross_size)
}

layout_remaining :: proc(state: ^Layout_State) -> Rect {
	assert(state != nil && state.open, "fit.layout_remaining: state not open")
	_ = surface_ui(state.surface)
	return ui.remaining(&state.inner)
}

layout_flex :: proc(state: ^Layout_State, tracks: []Track, justify: Main_Align = .Start) {
	assert(state != nil && state.open, "fit.layout_flex: state not open")
	_ = surface_ui(state.surface)
	assert(len(tracks) <= ui.MAX_LAYOUT_FLEX, "fit.layout_flex: too many tracks")
	inner: [ui.MAX_LAYOUT_FLEX]ui.Track
	for track, index in tracks do inner[index] = track
	ui.flex_begin(&state.inner, inner[:len(tracks)], justify)
}

layout_flex_next :: proc(state: ^Layout_State) -> Rect {
	assert(state != nil && state.open, "fit.layout_flex_next: state not open")
	_ = surface_ui(state.surface)
	return ui.flex_next(&state.inner)
}

surface_layout_begin :: proc(
	surface: ^Surface,
	state: ^Layout_State,
	x, y, width, height: i32,
	gap: i32 = 0,
) {
	layout_begin(surface, state, {x, y, width, height}, gap)
}

surface_layout_end :: proc(surface: ^Surface, state: ^Layout_State) {
	assert(state != nil && state.surface == surface, "fit.surface_layout_end: surface mismatch")
	layout_end(state)
}

surface_layout_push_row :: proc(
	surface: ^Surface,
	state: ^Layout_State,
	height: i32,
	gap: i32 = 0,
	align: Cross_Align = .Stretch,
) {
	assert(
		state != nil && state.surface == surface,
		"fit.surface_layout_push_row: surface mismatch",
	)
	layout_row(state, height, gap, align)
}

surface_layout_pop :: proc(surface: ^Surface, state: ^Layout_State) {
	assert(state != nil && state.surface == surface, "fit.surface_layout_pop: surface mismatch")
	layout_pop(state)
}

surface_layout_row_weights :: proc(surface: ^Surface, state: ^Layout_State, weights: []i32) {
	assert(
		state != nil && state.surface == surface,
		"fit.surface_layout_row_weights: surface mismatch",
	)
	layout_weights(state, weights)
}

surface_layout_next_weighted :: proc(
	surface: ^Surface,
	state: ^Layout_State,
	weight: i32,
) -> Rect {
	assert(
		state != nil && state.surface == surface,
		"fit.surface_layout_next_weighted: surface mismatch",
	)
	return layout_weighted(state, weight)
}

surface_layout_next :: proc(surface: ^Surface, state: ^Layout_State, size: i32) -> Rect {
	assert(state != nil && state.surface == surface, "fit.surface_layout_next: surface mismatch")
	return layout_next(state, size)
}

surface_layout_next_sized :: proc(
	surface: ^Surface,
	state: ^Layout_State,
	main_size, cross_size: i32,
) -> Rect {
	assert(
		state != nil && state.surface == surface,
		"fit.surface_layout_next_sized: surface mismatch",
	)
	return layout_sized(state, main_size, cross_size)
}

surface_layout_remaining :: proc(surface: ^Surface, state: ^Layout_State) -> Rect {
	assert(
		state != nil && state.surface == surface,
		"fit.surface_layout_remaining: surface mismatch",
	)
	return layout_remaining(state)
}

surface_layout_flex_begin :: proc(
	surface: ^Surface,
	state: ^Layout_State,
	tracks: []Track,
	justify: Main_Align = .Start,
) {
	assert(
		state != nil && state.surface == surface,
		"fit.surface_layout_flex_begin: surface mismatch",
	)
	layout_flex(state, tracks, justify)
}

surface_layout_flex_next :: proc(surface: ^Surface, state: ^Layout_State) -> Rect {
	assert(
		state != nil && state.surface == surface,
		"fit.surface_layout_flex_next: surface mismatch",
	)
	return layout_flex_next(state)
}
