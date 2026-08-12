// LIB-CANDIDATE: imports only core:*.
// Date picker: a dropdown-style field showing an ISO date plus a calendar
// popup for choosing one. Calendar math lives in pure procs so tests cover
// leap years and week alignment without a frame.
package ui

import "core:fmt"
import "core:strconv"
import "core:strings"

// Calendar_Date is a plain caller-owned date. day == 0 means "unset".
Calendar_Date :: struct {
	year:  i32,
	month: i32, // 1..12
	day:   i32, // 1..31, 0 = unset
}

// Date_Picker_State is the caller-owned lifecycle of one picker.
Date_Picker_State :: struct {
	open:        bool,
	just_opened: bool,
	view_year:   i32,
	view_month:  i32,
}

CALENDAR_MONTH_NAMES := [12]string {
	"January",
	"February",
	"March",
	"April",
	"May",
	"June",
	"July",
	"August",
	"September",
	"October",
	"November",
	"December",
}

// calendar_days_in_month returns the day count, honoring leap years.
calendar_days_in_month :: proc(year, month: i32) -> i32 {
	lengths := [12]i32{31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
	assert(month >= 1 && int(month) <= len(lengths), "calendar_days_in_month: bad month")
	if month == 2 {
		leap := (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
		return 29 if leap else 28
	}
	return lengths[month - 1]
}

// calendar_weekday returns 0=Sunday..6=Saturday via Zeller's congruence.
calendar_weekday :: proc(year, month, day: i32) -> i32 {
	assert(month >= 1 && month <= 12, "calendar_weekday: month out of range")
	assert(day >= 1 && day <= 31, "calendar_weekday: day out of range")
	y := year
	m := month
	if m < 3 {
		m += 12
		y -= 1
	}
	k := y % 100
	j := y / 100
	h := (day + 13 * (m + 1) / 5 + k + k / 4 + j / 4 + 5 * j) % 7
	return (h + 6) % 7 // Zeller: 0=Saturday; rotate to 0=Sunday
}

calendar_date_valid :: proc(date: Calendar_Date) -> bool {
	if date.month < 1 || date.month > 12 do return false
	if date.day < 1 do return false
	return date.day <= calendar_days_in_month(date.year, date.month)
}

// calendar_format renders "YYYY-MM-DD" into the temp allocator.
calendar_format :: proc(date: Calendar_Date) -> string {
	assert(calendar_date_valid(date), "calendar_format: invalid date")
	return fmt.tprintf("%04d-%02d-%02d", date.year, date.month, date.day)
}

// calendar_parse reads "YYYY-MM-DD"; ok is false for malformed input.
calendar_parse :: proc(value: string) -> (date: Calendar_Date, ok: bool) {
	parts := strings.split(value, "-", context.temp_allocator)
	if len(parts) != 3 do return {}, false
	year, year_ok := strconv.parse_int(parts[0])
	month, month_ok := strconv.parse_int(parts[1])
	day, day_ok := strconv.parse_int(parts[2])
	if !year_ok || !month_ok || !day_ok do return {}, false
	date = Calendar_Date{i32(year), i32(month), i32(day)}
	if !calendar_date_valid(date) do return {}, false
	return date, true
}

// date_picker carves a full-width slot. See date_picker_at.
date_picker :: proc(
	u: ^Ui,
	key: string,
	st: ^Date_Picker_State,
	value: ^Calendar_Date,
	placeholder: string,
	a11y_label: string,
) -> (
	changed: bool,
) {
	assert(u != nil && u.open, "date_picker: frame not open")
	assert(st != nil && value != nil, "date_picker: nil state")
	assert(a11y_label != "", "date_picker: empty accessible label")
	metrics := ui_frame_metrics(u.frame)
	widget := id(u, key)
	r := slot_next_px(u, remaining(&u.layout).w, metrics.ROW_H_MD + metrics.CONTROL_GAP)
	fo := focus(u, widget) if slot_visible(r) else Focus_Opt{}
	return date_picker_at(
		u.frame,
		r,
		st,
		value,
		placeholder,
		u.screen_w,
		u.screen_h,
		fo,
		a11y_label,
		widget,
	)
}

// date_picker_at draws the field at an explicit rect and drives the calendar
// popup. Returns true on the frame the value changed.
date_picker_at :: proc(
	frame: ^Ui_Frame,
	rect: Rect_I32,
	st: ^Date_Picker_State,
	value: ^Calendar_Date,
	placeholder: string,
	screen_w, screen_h: i32,
	focus: Focus_Opt = {},
	a11y_label: string = "",
	widget: Widget_Id = WIDGET_ID_NONE,
) -> (
	changed: bool,
) {
	assert(frame != nil, "date_picker_at: nil frame")
	assert(st != nil && value != nil, "date_picker_at: nil state")
	if ui_frame_drop_degenerate(frame, rect.w <= 0 || rect.h <= 0) do return false

	rrect := rect_f32(rect)
	it := interact(frame, rrect)
	focus_opt_click(frame, focus, rect.x, rect.y, rect.w, rect.h)
	if it.hovered do request_cursor(frame, .POINTING_HAND)

	metrics := ui_frame_metrics(frame)
	style := ui_frame_theme(frame)
	bg := style.bg_input if st.open || it.hovered else style.bg_secondary
	border :=
		style.fg_accent if st.open || it.hovered || focus_opt_focused(focus) else style.border_color
	draw_rectangle_rec(frame, rrect, bg)
	draw_rectangle_lines_ex(frame, rrect, border_pixels(frame, .Hairline), border)
	label := placeholder
	label_color := Ink.Secondary
	if calendar_date_valid(value^) {
		label = calendar_format(value^)
		label_color = .Primary
	}
	text(
		frame,
		label,
		rect.x + metrics.PADDING,
		rect.y + (rect.h - text_role_size(frame, .Body)) / 2,
		.Body,
		label_color,
	)
	chev :: "\u25BE"
	chev_w := text_width(frame, chev, .Label)
	text(
		frame,
		chev,
		rect.x + rect.w - chev_w - ui_frame_sc(frame, 8),
		rect.y + (rect.h - text_role_size(frame, .Label)) / 2,
		.Label,
		.Secondary,
	)
	if focus_opt_focused(focus) do draw_focus_ring(frame, rect.x, rect.y, rect.w, rect.h)

	activated :=
		it.clicked ||
		(focus_opt_focused(focus) &&
				(is_key_pressed(frame, .ENTER) || is_key_pressed(frame, .SPACE)))
	if !st.open && activated {
		st.open = true
		st.just_opened = true
		seed := value^ if calendar_date_valid(value^) else Calendar_Date{2026, 1, 1}
		st.view_year = seed.year
		st.view_month = seed.month
	}
	sem: Sem_State
	if st.open do sem += {.Expanded}
	sem_label := a11y_label if a11y_label != "" else label
	semantic_push(frame, .Dropdown, rect, sem_label, sem, focus, widget = widget)
	if !st.open do return false
	if is_key_pressed(frame, .ESCAPE) {
		st.open = false
		return false
	}
	return date_picker_popup(frame, st, value, rect, screen_w, screen_h)
}

Date_Picker_Popup_Layout :: struct {
	local:    Rectangle,
	screen:   Rectangle,
	cell:     i32,
	pad:      i32,
	header_h: i32,
	// Screen-space y of the day grid: popup drawing happens inside a layer,
	// where the pane origin is zero and all coordinates are screen space.
	grid_y:   f32,
}

@(private = "file")
date_picker_popup_layout :: proc(
	frame: ^Ui_Frame,
	rect: Rect_I32,
	screen_w, screen_h: i32,
) -> Date_Picker_Popup_Layout {
	assert(frame != nil, "date_picker_popup_layout: nil frame")
	assert(screen_w >= 0 && screen_h >= 0, "date_picker_popup_layout: negative screen")
	metrics := ui_frame_metrics(frame)
	cell := ui_frame_sc(frame, 30)
	header_h := ui_frame_sc(frame, 30)
	menu_w := cell * 7 + metrics.PADDING * 2
	menu_h := header_h + cell * 7 + metrics.PADDING * 2
	assert(menu_w >= 0 && menu_h >= 0, "date_picker_popup_layout: negative menu")
	anchor := frame_to_screen(frame, {f32(rect.x), f32(rect.y)})
	sx := clamp(i32(anchor.x), 0, max(screen_w - menu_w, 0))
	sy := i32(anchor.y) + rect.h + 2
	if sy + menu_h > screen_h do sy = max(i32(anchor.y) - menu_h - 2, 0)
	screen := Rectangle{f32(sx), f32(sy), f32(menu_w), f32(menu_h)}
	local := frame_rect_to_local(frame, screen)
	return {
		local,
		screen,
		cell,
		metrics.PADDING,
		header_h,
		screen.y + f32(metrics.PADDING + header_h + cell),
	}
}

@(private = "file")
date_picker_popup_weekdays :: proc(frame: ^Ui_Frame, layout: Date_Picker_Popup_Layout) {
	assert(frame != nil, "date_picker_popup_weekdays: nil frame")
	assert(layout.cell > 0, "date_picker_popup_weekdays: invalid cell")
	metrics := ui_frame_metrics(frame)
	weekdays := [7]string{"Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"}
	row_y := layout.screen.y + f32(layout.pad + layout.header_h)
	for name, column in weekdays {
		name_w := text_width(frame, name, .Label)
		draw_text_string(
			frame,
			name,
			i32(layout.screen.x) +
			layout.pad +
			i32(column) * layout.cell +
			(layout.cell - name_w) / 2,
			i32(row_y) + (layout.cell - metrics.FONT_SIZE_LABEL) / 2,
			metrics.FONT_SIZE_LABEL,
			ui_frame_theme(frame).fg_secondary,
		)
	}
}

// date_picker_popup records the calendar panel on a popup layer: month
// header with prev/next, weekday labels, and the day grid. Returns true when
// a day was chosen (which also closes the popup).
@(private = "file")
date_picker_popup :: proc(
	frame: ^Ui_Frame,
	st: ^Date_Picker_State,
	value: ^Calendar_Date,
	rect: Rect_I32,
	screen_w, screen_h: i32,
) -> (
	changed: bool,
) {
	assert(frame != nil && st != nil, "date_picker_popup: invalid call")
	assert(st.open, "date_picker_popup: popup not open")
	assert(st.view_month >= 1 && st.view_month <= 12, "date_picker_popup: bad view month")
	layout := date_picker_popup_layout(frame, rect, screen_w, screen_h)
	mouse := frame_to_local(frame, get_mouse_position(frame))
	pressed := is_mouse_button_pressed(frame, .LEFT)
	if !st.just_opened && pressed && !point_in_rect(mouse, layout.local) {
		st.open = false
		return false
	}
	st.just_opened = false

	style := ui_frame_theme(frame)
	mouse_screen := get_mouse_position(frame)
	layer_begin(frame, Z_POPUP, claim = layout.screen)
	draw_rectangle_rec(frame, layout.screen, style.bg_popup)
	draw_rectangle_lines_ex(frame, layout.screen, ui_frame_scf(frame, 1), style.border_color)
	date_picker_popup_header(frame, st, layout, mouse_screen, pressed)
	date_picker_popup_weekdays(frame, layout)
	changed = date_picker_days(frame, st, value, layout, mouse_screen, pressed)
	layer_end(frame)
	return changed
}

@(private = "file")
date_picker_popup_header :: proc(
	frame: ^Ui_Frame,
	st: ^Date_Picker_State,
	layout: Date_Picker_Popup_Layout,
	mouse: Vector2,
	pressed: bool,
) {
	assert(frame != nil && st != nil, "date_picker_popup_header: invalid call")
	month_index := int(st.view_month - 1)
	assert(month_index >= 0, "date_picker_popup_header: month below range")
	assert(month_index < len(CALENDAR_MONTH_NAMES), "date_picker_popup_header: month above range")
	metrics := ui_frame_metrics(frame)
	style := ui_frame_theme(frame)
	nav_w := ui_frame_sc(frame, 26)
	prev_rect := Rectangle {
		layout.screen.x + f32(layout.pad),
		layout.screen.y + f32(layout.pad),
		f32(nav_w),
		f32(layout.header_h - ui_frame_sc(frame, 4)),
	}
	next_rect := prev_rect
	next_rect.x = layout.screen.x + layout.screen.width - f32(layout.pad + nav_w)
	if point_in_rect(mouse, prev_rect) {
		request_cursor(frame, .POINTING_HAND)
		if pressed do date_picker_shift_month(st, -1)
	}
	if point_in_rect(mouse, next_rect) {
		request_cursor(frame, .POINTING_HAND)
		if pressed do date_picker_shift_month(st, 1)
	}
	sx, sy := i32(layout.screen.x), i32(layout.screen.y)
	draw_text_string(
		frame,
		"\u2039",
		sx + layout.pad + nav_w / 3,
		sy + layout.pad,
		metrics.FONT_SIZE_TITLE,
		style.fg_primary,
	)
	draw_text_string(
		frame,
		"\u203A",
		sx + i32(layout.screen.width) - layout.pad - nav_w * 2 / 3,
		sy + layout.pad,
		metrics.FONT_SIZE_TITLE,
		style.fg_primary,
	)
	title := fmt.tprintf("%s %d", CALENDAR_MONTH_NAMES[month_index], st.view_year)
	title_w := text_width(frame, title, .Body)
	draw_text_string(
		frame,
		title,
		sx + (i32(layout.screen.width) - title_w) / 2,
		sy + layout.pad + ui_frame_sc(frame, 2),
		metrics.FONT_SIZE_BODY,
		style.fg_primary,
	)
}

@(private = "file")
date_picker_days :: proc(
	frame: ^Ui_Frame,
	st: ^Date_Picker_State,
	value: ^Calendar_Date,
	layout: Date_Picker_Popup_Layout,
	mouse: Vector2,
	pressed: bool,
) -> (
	changed: bool,
) {
	assert(frame != nil && st != nil && value != nil, "date_picker_days: invalid call")
	assert(layout.cell > 0, "date_picker_days: invalid cell")
	metrics := ui_frame_metrics(frame)
	style := ui_frame_theme(frame)
	first_weekday := calendar_weekday(st.view_year, st.view_month, 1)
	day_count := calendar_days_in_month(st.view_year, st.view_month)
	assert(day_count >= 28 && day_count <= 31, "date_picker_days: invalid day count")
	for day in 1 ..= day_count {
		slot := first_weekday + day - 1
		screen_cell := Rectangle {
			layout.screen.x + f32(layout.pad + slot % 7 * layout.cell),
			layout.grid_y + f32(slot / 7 * layout.cell),
			f32(layout.cell),
			f32(layout.cell),
		}
		hovered := point_in_rect(mouse, screen_cell)
		is_selected :=
			value.day == day && value.month == st.view_month && value.year == st.view_year
		if is_selected || hovered {
			color := style.fg_accent if is_selected else style.bg_active
			draw_rectangle_rec(frame, screen_cell, color)
		}
		if hovered do request_cursor(frame, .POINTING_HAND)
		day_text := fmt.tprintf("%d", day)
		day_w := text_width(frame, day_text, .Label)
		day_color := style.button_text if is_selected else style.fg_primary
		draw_text_string(
			frame,
			day_text,
			i32(screen_cell.x) + (layout.cell - day_w) / 2,
			i32(screen_cell.y) + (layout.cell - metrics.FONT_SIZE_LABEL) / 2,
			metrics.FONT_SIZE_LABEL,
			day_color,
		)
		if hovered && pressed {
			chosen := Calendar_Date{st.view_year, st.view_month, day}
			assert(calendar_date_valid(chosen), "date_picker_days: produced invalid date")
			changed = value^ != chosen
			value^ = chosen
			st.open = false
		}
	}
	return changed
}

@(private = "package")
date_picker_shift_month :: proc(st: ^Date_Picker_State, delta: i32) {
	assert(st != nil, "date_picker_shift_month: nil state")
	assert(delta == 1 || delta == -1, "date_picker_shift_month: delta must be +/-1")
	st.view_month += delta
	if st.view_month < 1 {
		st.view_month = 12
		st.view_year -= 1
	}
	if st.view_month > 12 {
		st.view_month = 1
		st.view_year += 1
	}
	assert(st.view_month >= 1 && st.view_month <= 12, "date_picker_shift_month: bad month")
}
