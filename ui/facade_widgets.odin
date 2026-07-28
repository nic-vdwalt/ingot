// LIB-CANDIDATE: imports only core:*.
// Facade entry points for widgets whose implementation lives in the explicit
// tier. Each one does exactly three things: carve a bounded slot in logical
// units, register focus only when that slot is visible, and delegate to the
// *_at form. No widget state is retained here — the Ui owns layout and focus
// order, the caller owns everything else.
//
// Interactive widgets take a Widget_Id so identity survives insertion and
// reordering. Presentational widgets take none: they register no focus, so
// there is nothing for an identity to key.
package ui

import "core:strings"

// --- interactive ------------------------------------------------------------

Collapsible_Header_Facade_Options :: struct {
	icon:        rune,
	right_label: string,
	font_size:   i32,
	height:      i32,
	field_id:    string,
}

// collapsible_header carves a full-width row and toggles open^ on click or
// Space/Enter. Numeric options are logical and scale exactly once here.
collapsible_header :: proc(
	u: ^Ui,
	id: Widget_Id,
	label: string,
	open: ^bool,
	options: Collapsible_Header_Facade_Options = {},
) -> bool {
	assert(u != nil && u.open, "collapsible_header: frame not open")
	assert(id != WIDGET_ID_NONE, "collapsible_header: zero stable id")
	assert(open != nil, "collapsible_header: nil open state")
	height := options.height if options.height > 0 else 26
	rect := slot_next_px(u, remaining(&u.layout).w, ui_frame_sc(u.frame, height))
	opts := Collapsible_Header_Options {
		icon        = options.icon,
		right_label = options.right_label,
		font_size   = ui_frame_sc(u.frame, options.font_size) if options.font_size > 0 else 0,
		height      = ui_frame_sc(u.frame, height),
		field_id    = options.field_id,
		widget      = id,
	}
	if slot_visible(rect) do opts.focus = focus(u, id)
	return collapsible_header_at(u.frame, rect, label, open, opts).toggled
}

// icon_btn carves a square slot sized to the current row height.
icon_btn :: proc(u: ^Ui, id: Widget_Id, label: string, enabled: bool = true) -> bool {
	assert(u != nil && u.open, "icon_btn: frame not open")
	assert(id != WIDGET_ID_NONE, "icon_btn: zero stable id")
	assert(label != "", "icon_btn: empty accessible label")
	size := ui_frame_metrics(u.frame).ROW_H_MD
	rect := slot_next_px(u, size, size)
	fo := focus(u, id) if enabled && slot_visible(rect) else Focus_Opt{}
	return icon_btn_at(u.frame, rect, label, enabled, fo, id)
}

// back_btn carves a content-sized slot for the "← label" affordance.
back_btn :: proc(u: ^Ui, id: Widget_Id, label: string) -> bool {
	assert(u != nil && u.open, "back_btn: frame not open")
	assert(id != WIDGET_ID_NONE, "back_btn: zero stable id")
	assert(label != "", "back_btn: empty accessible label")
	width := back_btn_w(u.frame, label)
	rect := slot_next_px(u, width, ui_frame_sc(u.frame, 22))
	fo := focus(u, id) if slot_visible(rect) else Focus_Opt{}
	return back_btn_at(u.frame, rect, label, fo, id)
}

// tooltip attaches hover text to a rect a facade widget already occupies,
// using the screen bounds cached by begin.
tooltip :: proc(u: ^Ui, state: ^Tooltip_State, rect: Rect_I32, text: string) {
	assert(u != nil && u.open, "tooltip: frame not open")
	assert(state != nil, "tooltip: nil state")
	if !slot_visible(rect) do return
	tooltip_at(u.frame, state, rect, text, u.screen_w, u.screen_h)
}

// --- presentational ---------------------------------------------------------

// section_header carves a full-width row and returns the y a caller drawing on
// the explicit tier should continue from.
section_header :: proc(u: ^Ui, label: string) -> i32 {
	assert(u != nil && u.open, "section_header: frame not open")
	assert(label != "", "section_header: empty label")
	metrics := ui_frame_metrics(u.frame)
	height := metrics.FONT_SIZE_LABEL + ui_frame_sc(u.frame, 11)
	rect := slot_next_px(u, remaining(&u.layout).w, height)
	if !slot_visible(rect) do return rect.y
	return section_header_at(u.frame, rect, label)
}

// pill_width_px is the measured width status_pill_at will draw, so the facade
// can reserve exactly the slot the pill occupies.
@(private = "file")
pill_width_px :: proc(frame: ^Ui_Frame, text: string, font_size: i32) -> i32 {
	assert(frame != nil, "pill_width_px: nil frame")
	assert(font_size > 0, "pill_width_px: non-positive font size")
	c := strings.clone_to_cstring(text, context.temp_allocator)
	return measure_text_frame(frame, c, font_size) + 12
}

// status_pill carves a content-sized slot and returns the drawn pill width.
status_pill :: proc(u: ^Ui, text: string, color: Color, font_size: i32 = 0) -> i32 {
	assert(u != nil && u.open, "status_pill: frame not open")
	assert(text != "", "status_pill: empty text")
	metrics := ui_frame_metrics(u.frame)
	fs := ui_frame_sc(u.frame, font_size) if font_size > 0 else metrics.FONT_SIZE_LABEL
	rect := slot_next_px(u, pill_width_px(u.frame, text, fs), metrics.ROW_H_SM)
	if !slot_visible(rect) do return 0
	return status_pill_at(u.frame, rect, text, fs, color)
}

// progress_bar carves a full-width bar of the given logical height.
progress_bar :: proc(
	u: ^Ui,
	fraction: f32,
	color: Color,
	height: i32 = 8,
	options: Progress_Bar_Options = {},
) {
	assert(u != nil && u.open, "progress_bar: frame not open")
	assert(height > 0, "progress_bar: non-positive height")
	rect := slot_next_px(u, remaining(&u.layout).w, ui_frame_sc(u.frame, height))
	if !slot_visible(rect) do return
	progress_bar_at(u.frame, rect, fraction, color, options)
}

// progress_bar_animated is progress_bar with caller-owned eased fill state.
progress_bar_animated :: proc(
	u: ^Ui,
	fraction: f32,
	anim: ^f32,
	color: Color,
	height: i32 = 8,
	options: Progress_Bar_Options = {},
) {
	assert(u != nil && u.open, "progress_bar_animated: frame not open")
	assert(anim != nil, "progress_bar_animated: nil anim")
	assert(height > 0, "progress_bar_animated: non-positive height")
	rect := slot_next_px(u, remaining(&u.layout).w, ui_frame_sc(u.frame, height))
	if !slot_visible(rect) do return
	progress_bar_animated_at(u.frame, rect, fraction, anim, color, options)
}

Spinner_Facade_Options :: struct {
	style:              Spinner_Style,
	radius:             f32,
	color:              Color,
	segments:           i32,
	dot_count:          i32,
	dot_radius:         f32,
	speed:              f32,
	animation_interval: f64,
}

// spinner carves a square slot of the given logical diameter. Numeric option
// dimensions are logical and become physical only at this facade boundary.
spinner :: proc(u: ^Ui, diameter: i32 = 24, options: Spinner_Facade_Options = {}) {
	assert(u != nil && u.open, "spinner: frame not open")
	assert(diameter > 0, "spinner: non-positive diameter")
	size := ui_frame_sc(u.frame, diameter)
	rect := slot_next_px(u, size, size)
	if !slot_visible(rect) do return
	resolved := Spinner_Options {
		style              = options.style,
		radius             = ui_frame_scf(u.frame, options.radius) if options.radius > 0 else 0,
		color              = options.color,
		segments           = options.segments,
		dot_count          = options.dot_count,
		dot_radius         = ui_frame_scf(u.frame, options.dot_radius) if options.dot_radius > 0 else 0,
		speed              = options.speed,
		animation_interval = options.animation_interval,
	}
	spinner_at(u.frame, rect, resolved)
}

// sparkline carves a slot of the given logical size.
sparkline :: proc(u: ^Ui, values: []f32, color: Color = {}, width: i32 = 0, height: i32 = 32) {
	assert(u != nil && u.open, "sparkline: frame not open")
	assert(height > 0, "sparkline: non-positive height")
	w := ui_frame_sc(u.frame, width) if width > 0 else remaining(&u.layout).w
	rect := slot_next_px(u, w, ui_frame_sc(u.frame, height))
	if !slot_visible(rect) do return
	sparkline_at(u.frame, rect, values, color)
}

// line_chart carves a full-width plot of the given logical height and returns
// the hovered sample index, or -1.
line_chart :: proc(
	u: ^Ui,
	series: []Chart_Series,
	state: ^Chart_State,
	height: i32,
	opts: Chart_Opts = {},
) -> int {
	assert(u != nil && u.open, "line_chart: frame not open")
	assert(state != nil, "line_chart: nil state")
	assert(height > 0, "line_chart: non-positive height")
	rect := slot_next_px(u, remaining(&u.layout).w, ui_frame_sc(u.frame, height))
	if !slot_visible(rect) do return -1
	return line_chart_at(u.frame, rect, series, state, opts)
}

// bar_chart carves a full-width plot of the given logical height and returns
// the hovered sample index, or -1.
bar_chart :: proc(
	u: ^Ui,
	series: []Chart_Series,
	state: ^Chart_State,
	height: i32,
	opts: Chart_Opts = {},
) -> int {
	assert(u != nil && u.open, "bar_chart: frame not open")
	assert(state != nil, "bar_chart: nil state")
	assert(height > 0, "bar_chart: non-positive height")
	rect := slot_next_px(u, remaining(&u.layout).w, ui_frame_sc(u.frame, height))
	if !slot_visible(rect) do return -1
	return bar_chart_at(u.frame, rect, series, state, opts)
}

// kv_row carves a full-width row with a key left and a right-aligned value.
kv_row :: proc(u: ^Ui, key, value: string, key_col, val_col: Color, font_size: i32 = 0) {
	assert(u != nil && u.open, "kv_row: frame not open")
	metrics := ui_frame_metrics(u.frame)
	fs := ui_frame_sc(u.frame, font_size) if font_size > 0 else metrics.FONT_SIZE_LABEL
	rect := slot_next_px(u, remaining(&u.layout).w, metrics.LINE_HEIGHT)
	if !slot_visible(rect) do return
	kv_row_at(u.frame, rect, key, value, key_col, val_col, fs)
}

// card_bg fills the remaining container area with the card background. It does
// not carve a slot: it paints behind whatever the caller draws next.
card_bg :: proc(u: ^Ui, bg: Color, accent: Color = THEME_COLOR, accent_w: i32 = 0) {
	assert(u != nil && u.open, "card_bg: frame not open")
	rect := remaining(&u.layout)
	if !slot_visible(rect) do return
	card_bg_at(u.frame, rect, bg, accent, accent_w)
}
