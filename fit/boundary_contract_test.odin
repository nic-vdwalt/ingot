#+build !js
package fit

import "core:testing"
import "ingot:gfx"
import "ingot:ui"
import "ingot:ui_gfx"

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

@(test)
fit_semantic_bits_contract_complete :: proc(t: ^testing.T) {
	cases := [?]struct {
		source: Semantic_State,
		target: ui.Sem_State,
	} {
		{{.Checked}, {.Checked}},
		{{.Disabled}, {.Disabled}},
		{{.Focused}, {.Focused}},
		{{.Expanded}, {.Expanded}},
		{{.Selected}, {.Selected}},
		{{.Read_Only}, {.Read_Only}},
		{{.Password}, {.Password}},
		{{.Multiline}, {.Multiline}},
	}
	all: Semantic_State
	expected: ui.Sem_State
	for entry in cases {
		testing.expect(t, all & entry.source == {})
		all += entry.source
		expected += entry.target
		testing.expect_value(t, to_semantic_state(entry.source), entry.target)
	}
	testing.expect_value(t, all, ~Semantic_State{})
	testing.expect_value(t, to_semantic_state({}), ui.Sem_State{})
	testing.expect_value(t, to_semantic_state(all), expected)
}

@(test)
fit_substrate_contract_complete :: proc(t: ^testing.T) {
	cases := [?]struct {
		source: Substrate_Kind,
		target: ui.Substrate_Kind,
	}{{.None, .None}, {.Ruled, .Ruled}, {.Grid, .Grid}, {.Dots, .Dots}, {.Tooth, .Tooth}}
	for value in Substrate_Kind {
		matches := 0
		for entry in cases {
			if entry.source != value do continue
			matches += 1
			testing.expect_value(t, to_substrate(value), entry.target)
			testing.expect_value(t, from_substrate(entry.target), value)
		}
		testing.expect_value(t, matches, 1)
	}
}

@(test)
fit_state_pacing_contract_complete :: proc(t: ^testing.T) {
	states := [?]struct {
		source: State,
		target: ui_gfx.App_State,
	}{{.Empty, .Empty}, {.Ready, .Ready}, {.Running, .Running}, {.Stopped, .Stopped}}
	for value in State {
		matches := 0
		for entry in states {
			if entry.source != value do continue
			matches += 1
			testing.expect_value(t, from_app_state(entry.target), value)
		}
		testing.expect_value(t, matches, 1)
	}
	pacing := [?]struct {
		source: Frame_Pacing,
		target: ui_gfx.App_Frame_Pacing,
	}{{.Fixed, .Fixed}, {.Uncapped, .Uncapped}, {.Monitor_Refresh, .Monitor_Refresh}}
	for value in Frame_Pacing {
		matches := 0
		for entry in pacing {
			if entry.source != value do continue
			matches += 1
			testing.expect_value(t, to_frame_pacing(value), entry.target)
		}
		testing.expect_value(t, matches, 1)
	}
}
