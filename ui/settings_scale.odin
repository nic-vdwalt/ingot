// LIB-CANDIDATE: imports only core:* and ingot:gfx.
// Generic UI-scale settings modal. The caller owns all state: whether the
// panel is open, the highlighted row index, and the currently stored scale.
// Ported from Alloy's settings_panel.odin with the app coupling removed.
package ui

import rl "ingot:gfx"
import "core:fmt"
import "core:strings"

// A selectable UI-scale preset. A value of 0 means "auto" (follow the OS DPI).
Settings_Scale_Preset :: struct {
	label: string,
	value: f32,
}

// Available UI-scale presets shown in the settings panel. Auto is first so it
// is the default selection when no override is stored.
SETTINGS_SCALE_PRESETS :: [?]Settings_Scale_Preset{
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
	ui_scale:  f32,  // chosen scale (0 = auto), valid when applied == true
	dismissed: bool, // true if Escape / outside click closed the panel
}

// settings_auto_scale returns the scale the "Auto" preset resolves to on this
// platform: 1.0 on macOS (the compositor handles HiDPI) or the OS DPI factor
// on Windows/Linux.
settings_auto_scale :: proc() -> f32 {
	when ODIN_OS == .Darwin {
		return 1.0
	} else {
		return rl.GetWindowScaleDPI().x
	}
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
// Applying a preset keeps the panel open so the user can preview other
// scales; Escape (or clicking outside) dismisses — the caller closes the
// panel on `dismissed`.
draw_scale_settings_panel :: proc(selected: ^int, current_scale: f32,
	screen_width, screen_height: i32) -> Settings_Panel_Result {
	presets := SETTINGS_SCALE_PRESETS
	n := len(presets)

	// Keyboard navigation with wraparound.
	if rl.IsKeyPressed(.UP) {
		selected^ -= 1
		if selected^ < 0 do selected^ = n - 1
	}
	if rl.IsKeyPressed(.DOWN) {
		selected^ += 1
		if selected^ >= n do selected^ = 0
	}
	if selected^ < 0 do selected^ = 0
	if selected^ >= n do selected^ = n - 1

	// Dim background.
	rl.DrawRectangle(0, 0, screen_width, screen_height, rl.Color{0, 0, 0, 150})

	// Modal dimensions.
	item_h: i32 = sc(28)
	title_h: i32 = sc(40)
	section_h: i32 = sc(26)
	footer_h: i32 = sc(24)
	modal_padding: i32 = PADDING
	modal_w: i32 = min(sc(440), screen_width - PADDING * 4)
	modal_h: i32 = title_h + section_h + i32(n) * item_h + footer_h + modal_padding * 2
	modal_x := (screen_width - modal_w) / 2
	modal_y := (screen_height - modal_h) / 2

	// Draw modal background.
	rl.DrawRectangle(modal_x, modal_y, modal_w, modal_h, BG_SECONDARY)
	rl.DrawRectangleLines(modal_x, modal_y, modal_w, modal_h, BORDER_COLOR)

	// Clip body content to the modal interior.
	rl.BeginScissorMode(modal_x, modal_y, modal_w, modal_h)

	// Title.
	title_c := strings.clone_to_cstring("Settings", context.temp_allocator)
	draw_text(title_c, modal_x + modal_padding, modal_y + modal_padding, FONT_SIZE_LARGE, FG_PRIMARY)

	// Section header.
	section_y := modal_y + title_h
	section_c := strings.clone_to_cstring("UI SCALE", context.temp_allocator)
	draw_text(section_c, modal_x + modal_padding, section_y + 4, FONT_SIZE_SMALL, FG_LABEL)

	auto_scale := settings_auto_scale()

	// Preset rows. Captured during the loop and returned after EndScissorMode
	// so an open scissor rect never leaks into subsequent draws.
	pending_result: Settings_Panel_Result
	have_result := false
	list_y := section_y + section_h
	right_edge := modal_x + modal_w - modal_padding
	for p, idx in presets {
		item_rect := rl.Rectangle{
			f32(modal_x + 2),
			f32(list_y),
			f32(modal_w - 4),
			f32(item_h),
		}

		// Mouse hover only changes the selection when the cursor actually
		// moves, so keyboard navigation isn't overridden by a stationary cursor.
		mouse := rl.GetMousePosition()
		hovered := rl.CheckCollisionPointRec(mouse, item_rect)
		if hovered && mouse_moved() {
			selected^ = idx
		}
		is_selected := idx == selected^
		is_current := abs(p.value - current_scale) < 0.001

		if is_selected {
			rl.DrawRectangleRec(item_rect, BG_ACTIVE)
		}

		// Current-value marker.
		text_x := modal_x + modal_padding
		if is_current {
			marker_c := strings.clone_to_cstring("*", context.temp_allocator)
			draw_text(marker_c, text_x, list_y + (item_h - FONT_SIZE) / 2, FONT_SIZE, FG_ACCENT)
		}
		text_x += sc(16)

		// Label (Auto shows the resolved system scale on the right).
		label := p.label
		if idx == 0 {
			label = fmt.tprintf("Auto (system \u2014 %d%%)", int(auto_scale * 100 + 0.5))
		}
		label_c := strings.clone_to_cstring(label, context.temp_allocator)
		draw_text(label_c, text_x, list_y + (item_h - FONT_SIZE) / 2, FONT_SIZE, FG_PRIMARY)

		// Effective pixel percentage on the far right for non-auto rows.
		if idx != 0 {
			pct := fmt.tprintf("%d%%", int(p.value * 100 + 0.5))
			pct_c := strings.clone_to_cstring(pct, context.temp_allocator)
			pct_w := measure_text(pct_c, FONT_SIZE_SMALL)
			draw_text(pct_c, right_edge - pct_w, list_y + (item_h - FONT_SIZE_SMALL) / 2, FONT_SIZE_SMALL, FG_SECONDARY)
		}

		// Mouse click applies this preset.
		if hovered && rl.IsMouseButtonReleased(.LEFT) {
			pending_result = Settings_Panel_Result{applied = true, ui_scale = p.value}
			have_result = true
		}

		list_y += item_h
	}

	// Footer hint.
	footer_y := modal_y + modal_h - modal_padding - footer_h + 4
	hint_c := strings.clone_to_cstring("Enter apply  \u00b7  Esc close", context.temp_allocator)
	draw_text(hint_c, modal_x + modal_padding, footer_y, FONT_SIZE_SMALL, FG_SECONDARY)

	rl.EndScissorMode()

	if have_result {
		return pending_result
	}

	// Enter — apply the highlighted preset.
	if rl.IsKeyPressed(.ENTER) {
		return Settings_Panel_Result{applied = true, ui_scale = presets[selected^].value}
	}

	// Escape — dismiss.
	if rl.IsKeyPressed(.ESCAPE) {
		return Settings_Panel_Result{dismissed = true}
	}

	// Click outside the modal — dismiss.
	modal_rect := rl.Rectangle{f32(modal_x), f32(modal_y), f32(modal_w), f32(modal_h)}
	if rl.IsMouseButtonReleased(.LEFT) &&
		!rl.CheckCollisionPointRec(rl.GetMousePosition(), modal_rect) {
		return Settings_Panel_Result{dismissed = true}
	}

	return {}
}
