// LIB-CANDIDATE: imports only core:*.
// Generic UI-scale settings modal. The caller owns all state: whether the
// panel is open, the highlighted row index, and the currently stored scale.
// Ported from Alloy's settings_panel.odin with the app coupling removed.
package ui

import "core:fmt"


// A selectable UI-scale preset. A value of 0 means "auto" (follow the OS DPI).
Settings_Scale_Preset :: struct {
	label: string,
	value: f32,
}

// Available UI-scale presets shown in the settings panel. Auto is first so it
// is the default selection when no override is stored.
SETTINGS_SCALE_PRESETS :: [?]Settings_Scale_Preset {
	{"Auto (system)", 0.0},
	{"75%", 0.75},
	{"90%", 0.90},
	{"100%", 1.00},
	{"110%", 1.10},
	{"125%", 1.25},
	{"150%", 1.50},
	{"175%", 1.75},
	{"200%", 2.00},
}

// Result from the settings panel modal.
Settings_Panel_Result :: struct {
	applied:   bool, // true if a scale preset was chosen this frame
	ui_scale:  f32, // chosen scale (0 = auto), valid when applied == true
	dismissed: bool, // true if Escape / outside click closed the panel
}

// settings_auto_scale returns the scale the "Auto" preset resolves to on this
// platform: 1.0 on macOS (the compositor handles HiDPI) or the OS DPI factor
// on Windows/Linux.
settings_auto_scale :: proc(input: ^Ui_Input = nil) -> f32 {
	return auto_scale(input)
}

// settings_scale_preset_index returns the preset row index that matches the
// given stored ui_scale value (0 = auto). Falls back to 0 (Auto) when no
// preset matches exactly.
settings_scale_preset_index :: proc(ui_scale: f32) -> int {
	presets := SETTINGS_SCALE_PRESETS
	for p, i in presets {
		if abs(p.value - ui_scale) < 0.001 {
			return i
		}
	}
	return 0
}

// draw_scale_settings_panel draws the settings modal overlay and returns the
// result of user interaction this frame. `selected` is the caller-owned
// highlighted row; `current_scale` is the stored preference (0 = auto).
// Applying a preset, pressing Escape, or clicking outside dismisses the panel.
// Chrome, input claiming, and dismissal ride on the generic modal widget
// (popups.odin); this proc owns only the preset rows.
draw_scale_settings_panel :: proc(
	frame: ^Ui_Frame,
	selected: ^int,
	current_scale: f32,
	screen_width, screen_height: i32,
) -> Settings_Panel_Result {
	assert(selected != nil, "draw_scale_settings_panel: nil selected")
	assert(screen_width > 0 && screen_height > 0, "draw_scale_settings_panel: empty screen")
	presets := SETTINGS_SCALE_PRESETS
	n := len(presets)

	// Modal dimensions.
	metrics := ui_frame_metrics(frame)
	item_h := ui_frame_sc(frame, 28)
	section_h := ui_frame_sc(frame, 26)
	footer_h := ui_frame_sc(frame, 24)
	modal_padding := metrics.PADDING
	modal_w := min(ui_frame_sc(frame, 440), screen_width - metrics.PADDING * 4)
	modal_h := ui_frame_sc(frame, 40) + section_h + i32(n) * item_h + footer_h + modal_padding * 2

	st := Modal_State {
		open = true,
	}
	body := modal_begin(
		frame,
		&st,
		"Settings",
		{
			size    = {modal_w, modal_h},
			screen  = {0, 0, screen_width, screen_height},
			dismiss = {.Escape, .Outside_Click},
		},
	)
	modal_x := st.rect.x
	modal_y := st.rect.y

	// Keyboard navigation with wraparound.
	if is_key_pressed(frame, .UP) {
		selected^ -= 1
		if selected^ < 0 do selected^ = n - 1
	}
	if is_key_pressed(frame, .DOWN) {
		selected^ += 1
		if selected^ >= n do selected^ = 0
	}
	if selected^ < 0 do selected^ = 0
	if selected^ >= n do selected^ = n - 1
	enter_pressed := is_key_pressed(frame, .ENTER)

	// Section header.
	text(frame, "UI SCALE", modal_x + modal_padding, body.y + 4, .Label, .Label)

	pending_result, have_result := settings_scale_rows(
		frame,
		selected,
		current_scale,
		modal_x,
		body.y + section_h,
		st.rect.w,
		item_h,
	)

	// Footer hint.
	footer_y := modal_y + modal_h - modal_padding - footer_h + 4
	text(
		frame,
		"Enter apply  \u00b7  Esc close",
		modal_x + modal_padding,
		footer_y,
		.Label,
		.Secondary,
	)

	modal_end(&st)
	modal_rect := Rectangle{f32(st.rect.x), f32(st.rect.y), f32(st.rect.w), f32(st.rect.h)}
	outside_pressed :=
		is_mouse_button_pressed(frame, .LEFT) && !point_in_rect(get_mouse_position(frame), modal_rect)
	if st.dismissed || outside_pressed {
		return Settings_Panel_Result{dismissed = true}
	}
	if have_result {
		return pending_result
	}
	// Enter - apply the highlighted preset.
	if enter_pressed {
		return Settings_Panel_Result {
			applied   = true,
			ui_scale  = presets[selected^].value,
			dismissed = true,
		}
	}
	return {}
}

// settings_scale_rows draws the preset rows inside the modal body and reports
// a click-applied result. Hover moves the highlight only while the mouse
// moves so keyboard navigation isn't overridden by a stationary cursor.
@(private = "file")
settings_scale_rows :: proc(
	frame: ^Ui_Frame,
	selected: ^int,
	current_scale: f32,
	modal_x, top, modal_w, item_h: i32,
) -> (
	result: Settings_Panel_Result,
	applied: bool,
) {
	assert(selected != nil, "settings_scale_rows: nil selected")
	assert(item_h > 0, "settings_scale_rows: non-positive row height")
	presets := SETTINGS_SCALE_PRESETS
	auto_scale := settings_auto_scale()
	metrics := ui_frame_metrics(frame)
	style := ui_frame_theme(frame)
	modal_padding := metrics.PADDING
	right_edge := modal_x + modal_w - modal_padding
	list_y := top
	for p, idx in presets {
		item_rect := Rectangle{f32(modal_x + 2), f32(list_y), f32(modal_w - 4), f32(item_h)}
		mouse := get_mouse_position(frame)
		hovered := point_in_rect(mouse, item_rect)
		if hovered && mouse_moved(frame) {
			selected^ = idx
		}
		if idx == selected^ {
			draw_rectangle_rec(frame, item_rect, style.bg_active)
		}
		// Current-value marker.
		text_x := modal_x + modal_padding
		body_h := text_role_size(frame, .Body)
		if abs(p.value - current_scale) < 0.001 {
			text(frame, "*", text_x, list_y + (item_h - body_h) / 2, .Body, .Accent)
		}
		text_x += ui_frame_sc(frame, 16)
		// Label (Auto shows the resolved system scale on the right).
		label := p.label
		if idx == 0 {
			label = fmt.tprintf("Auto (system \u2014 %d%%)", int(auto_scale * 100 + 0.5))
		}
		text(frame, label, text_x, list_y + (item_h - body_h) / 2, .Body, .Primary)
		// Effective pixel percentage on the far right for non-auto rows.
		if idx != 0 {
			pct := fmt.tprintf("%d%%", int(p.value * 100 + 0.5))
			pct_w := text_width(frame, pct, .Label)
			label_h := text_role_size(frame, .Label)
			text(
				frame,
				pct,
				right_edge - pct_w,
				list_y + (item_h - label_h) / 2,
				.Label,
				.Secondary,
			)
		}
		// Mouse click applies this preset.
		if hovered && is_mouse_button_released(frame, .LEFT) {
			result = Settings_Panel_Result {
				applied   = true,
				ui_scale  = p.value,
				dismissed = true,
			}
			applied = true
		}
		list_y += item_h
	}
	return result, applied
}
