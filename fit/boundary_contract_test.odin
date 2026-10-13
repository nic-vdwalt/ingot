#+build !js
package fit

import "core:reflect"
import "core:testing"
import "ingot:gfx"
import "ingot:ui"

@(private = "file")
metrics_contract_fields :: [][2]string {
	{"font_title", "FONT_SIZE_TITLE"},
	{"font_body", "FONT_SIZE_BODY"},
	{"font_label", "FONT_SIZE_LABEL"},
	{"font_note", "FONT_SIZE_NOTE"},
	{"line_height", "LINE_HEIGHT"},
	{"tab_bar_height", "TAB_BAR_HEIGHT"},
	{"caption_button_w", "CAPTION_BTN_W"},
	{"padding", "PADDING"},
	{"row_small", "ROW_H_SM"},
	{"row_medium", "ROW_H_MD"},
	{"panel_header_h", "PANEL_HEADER_H"},
	{"card_radius", "CARD_RADIUS_PX"},
	{"control_box", "CONTROL_BOX"},
	{"control_gap", "CONTROL_GAP"},
	{"slider_track_h", "SLIDER_TRACK_H"},
	{"slider_knob_radius", "SLIDER_KNOB_R"},
	{"menu_item_h", "MENU_ITEM_H"},
	{"menu_padding", "MENU_PAD"},
	{"menu_min_w", "MENU_MIN_W"},
	{"tooltip_padding", "TOOLTIP_PAD"},
	{"code_block_padding", "CODE_BLOCK_PAD"},
	{"bullet_indent", "BULLET_INDENT"},
	{"table_cell_padding", "TABLE_CELL_PAD"},
	{"split_divider_w", "SPLIT_DIVIDER_W"},
}

@(test)
fit_metrics_projection_complete :: proc(t: ^testing.T) {
	runtime: ui.Ui_Runtime
	ui.ui_runtime_init(&runtime)
	defer ui.ui_runtime_destroy(&runtime)
	frame: ui.Ui_Frame
	output := new(ui.Ui_Output)
	defer free(output)
	frame.output = output
	ui.ui_frame_begin(&frame, &runtime)
	defer ui.ui_frame_end(&frame)
	root: ui.Ui
	ui.begin(&root, &frame, {0, 0, 320, 240})
	defer ui.end(&root)
	surface := Surface {
		inner = &root,
	}
	metrics := ui.ui_frame_metrics(&frame)
	for names, index in metrics_contract_fields {
		field := reflect.struct_field_value_by_name(
			any{metrics, typeid_of(type_of(metrics^))},
			names[1],
		)
		testing.expect_value(t, field.id, typeid_of(i32))
		if field.id != typeid_of(i32) do continue
		(cast(^i32)field.data)^ = i32(index + 11)
	}
	for square in ([2]bool{false, true}) {
		ui.ui_frame_theme(&frame).square_corners = square
		projected := surface_metrics(&surface)
		for names, index in metrics_contract_fields {
			field := reflect.struct_field_value_by_name(projected, names[0])
			testing.expect_value(t, field.id, typeid_of(i32))
			if field.id != typeid_of(i32) do continue
			expected := i32(index + 11)
			if square && names[0] == "card_radius" do expected = 0
			testing.expect_value(t, (cast(^i32)field.data)^, expected)
		}
	}
	for name in reflect.struct_field_names(Metrics) {
		matches := 0
		for names in metrics_contract_fields {
			if names[0] == name do matches += 1
		}
		testing.expect_value(t, matches, 1)
	}
	testing.expect_value(t, reflect.struct_field_count(Metrics), len(metrics_contract_fields))
}

@(private = "file")
Contract_Key_Pair :: struct {
	source: Key,
	target: ui.Key,
}

@(test)
fit_key_contract_complete :: proc(t: ^testing.T) {
	cases := [?]Contract_Key_Pair {
		{.Null, .KEY_NULL},
		{.Space, .SPACE},
		{.Apostrophe, .APOSTROPHE},
		{.Comma, .COMMA},
		{.Minus, .MINUS},
		{.Period, .PERIOD},
		{.Slash, .SLASH},
		{.Zero, .ZERO},
		{.One, .ONE},
		{.Two, .TWO},
		{.Three, .THREE},
		{.Four, .FOUR},
		{.Five, .FIVE},
		{.Six, .SIX},
		{.Seven, .SEVEN},
		{.Eight, .EIGHT},
		{.Nine, .NINE},
		{.Semicolon, .SEMICOLON},
		{.Equal, .EQUAL},
		{.Left_Bracket, .LEFT_BRACKET},
		{.Backslash, .BACKSLASH},
		{.Right_Bracket, .RIGHT_BRACKET},
		{.Grave, .GRAVE},
		{.A, .A},
		{.B, .B},
		{.C, .C},
		{.D, .D},
		{.E, .E},
		{.F, .F},
		{.G, .G},
		{.H, .H},
		{.I, .I},
		{.J, .J},
		{.K, .K},
		{.L, .L},
		{.M, .M},
		{.N, .N},
		{.O, .O},
		{.P, .P},
		{.Q, .Q},
		{.R, .R},
		{.S, .S},
		{.T, .T},
		{.U, .U},
		{.V, .V},
		{.W, .W},
		{.X, .X},
		{.Y, .Y},
		{.Z, .Z},
		{.Escape, .ESCAPE},
		{.Enter, .ENTER},
		{.Tab, .TAB},
		{.Backspace, .BACKSPACE},
		{.Insert, .INSERT},
		{.Delete, .DELETE},
		{.Right, .RIGHT},
		{.Left, .LEFT},
		{.Down, .DOWN},
		{.Up, .UP},
		{.Page_Up, .PAGE_UP},
		{.Page_Down, .PAGE_DOWN},
		{.Home, .HOME},
		{.End, .END},
		{.F1, .F1},
		{.F2, .F2},
		{.F3, .F3},
		{.F4, .F4},
		{.F5, .F5},
		{.F6, .F6},
		{.F7, .F7},
		{.F8, .F8},
		{.F9, .F9},
		{.F10, .F10},
		{.F11, .F11},
		{.F12, .F12},
		{.Keypad_Enter, .KP_ENTER},
		{.Left_Shift, .LEFT_SHIFT},
		{.Left_Control, .LEFT_CONTROL},
		{.Left_Alt, .LEFT_ALT},
		{.Left_Super, .LEFT_SUPER},
		{.Right_Shift, .RIGHT_SHIFT},
		{.Right_Control, .RIGHT_CONTROL},
		{.Right_Alt, .RIGHT_ALT},
		{.Right_Super, .RIGHT_SUPER},
	}
	for value in Key {
		matches := 0
		for entry in cases {
			if entry.source != value do continue
			matches += 1
			testing.expect_value(t, to_key(value), entry.target)
		}
		testing.expect_value(t, matches, 1)
	}
}

@(test)
fit_pointer_contract_complete :: proc(t: ^testing.T) {
	buttons := [?]struct {
		source: Mouse_Button,
		target: ui.Mouse_Button,
	} {
		{.Left, .LEFT},
		{.Right, .RIGHT},
		{.Middle, .MIDDLE},
		{.Side, .SIDE},
		{.Extra, .EXTRA},
		{.Forward, .FORWARD},
		{.Back, .BACK},
	}
	for value in Mouse_Button {
		matches := 0
		for entry in buttons {
			if entry.source != value do continue
			matches += 1
			testing.expect_value(t, to_mouse_button(value), entry.target)
		}
		testing.expect_value(t, matches, 1)
	}
	cursors := [?]struct {
		source: Cursor,
		target: ui.Cursor,
	} {
		{.Default, .DEFAULT},
		{.Arrow, .ARROW},
		{.IBeam, .IBEAM},
		{.Crosshair, .CROSSHAIR},
		{.Pointing_Hand, .POINTING_HAND},
		{.Resize_EW, .RESIZE_EW},
		{.Resize_NS, .RESIZE_NS},
		{.Resize_NWSE, .RESIZE_NWSE},
		{.Resize_NESW, .RESIZE_NESW},
		{.Resize_All, .RESIZE_ALL},
		{.Not_Allowed, .NOT_ALLOWED},
	}
	for value in Cursor {
		matches := 0
		for entry in cursors {
			if entry.source != value do continue
			matches += 1
			testing.expect_value(t, to_cursor(value), entry.target)
		}
		testing.expect_value(t, matches, 1)
	}
}

@(test)
fit_roles_contract_complete :: proc(t: ^testing.T) {
	cases := [?]struct {
		source: Semantic_Role,
		target: ui.Sem_Role,
	} {
		{.None, .None},
		{.Button, .Button},
		{.Checkbox, .Checkbox},
		{.Radio, .Radio},
		{.Slider, .Slider},
		{.Text_Input, .Text_Input},
		{.Dropdown, .Dropdown},
		{.Menu_Item, .Menu_Item},
		{.Label, .Label},
		{.Pane, .Pane},
		{.Modal, .Modal},
		{.Tab, .Tab},
		{.Tab_Panel, .Tab_Panel},
		{.List, .List},
		{.List_Item, .List_Item},
		{.Option, .Option},
		{.Status, .Status},
		{.Progress, .Progress},
		{.List_Box, .List_Box},
	}
	for value in Semantic_Role {
		matches := 0
		for entry in cases {
			if entry.source != value do continue
			matches += 1
			testing.expect_value(t, to_semantic_role(value), entry.target)
		}
		testing.expect_value(t, matches, 1)
	}
}

@(test)
fit_window_bits_contract_complete :: proc(t: ^testing.T) {
	cases := [?]struct {
		source: Window_Flags,
		target: gfx.ConfigFlags,
	} {
		{{.Fullscreen}, {.FULLSCREEN_MODE}},
		{{.Resizable}, {.WINDOW_RESIZABLE}},
		{{.Undecorated}, {.WINDOW_UNDECORATED}},
		{{.Transparent}, {.WINDOW_TRANSPARENT}},
		{{.Msaa_4x}, {.MSAA_4X_HINT}},
		{{.Vsync}, {.VSYNC_HINT}},
		{{.Hidden}, {.WINDOW_HIDDEN}},
		{{.Always_Run}, {.WINDOW_ALWAYS_RUN}},
		{{.Minimized}, {.WINDOW_MINIMIZED}},
		{{.Maximized}, {.WINDOW_MAXIMIZED}},
		{{.Unfocused}, {.WINDOW_UNFOCUSED}},
		{{.Topmost}, {.WINDOW_TOPMOST}},
		{{.High_Dpi}, {.WINDOW_HIGHDPI}},
		{{.Mouse_Passthrough}, {.WINDOW_MOUSE_PASSTHROUGH}},
		{{.Borderless_Windowed}, {.BORDERLESS_WINDOWED_MODE}},
		{{.Interlaced}, {.INTERLACED_HINT}},
		{{.No_Focus_On_Hover}, {.WINDOW_NO_FOCUS_ON_HOVER}},
	}
	all: Window_Flags
	expected: gfx.ConfigFlags
	for entry in cases {
		testing.expect(t, all & entry.source == {})
		all += entry.source
		expected += entry.target
		testing.expect_value(t, to_window_flags(entry.source), entry.target)
	}
	testing.expect_value(t, all, ~Window_Flags{})
	testing.expect_value(t, to_window_flags({}), gfx.ConfigFlags{})
	testing.expect_value(t, to_window_flags(all), expected)
}
