package fit

import "ingot:ui"

@(private = "package")
to_substrate :: proc(value: Substrate_Kind) -> ui.Substrate_Kind {
	switch value {
	case .None:
		return .None
	case .Ruled:
		return .Ruled
	case .Grid:
		return .Grid
	case .Dots:
		return .Dots
	case .Tooth:
		return .Tooth
	}
	unreachable()
}

@(private = "package")
from_substrate :: proc(value: ui.Substrate_Kind) -> Substrate_Kind {
	switch value {
	case .None:
		return .None
	case .Ruled:
		return .Ruled
	case .Grid:
		return .Grid
	case .Dots:
		return .Dots
	case .Tooth:
		return .Tooth
	}
	unreachable()
}

@(private = "package")
to_key :: proc(value: Key) -> ui.Key {
	if result, ok := to_key_text(value); ok do return result
	if result, ok := to_key_letter(value); ok do return result
	if result, ok := to_key_control(value); ok do return result
	unreachable()
}

@(private = "file")
to_key_text :: proc(value: Key) -> (ui.Key, bool) {
	#partial switch value {
	case .Null:
		return .KEY_NULL, true
	case .Space:
		return .SPACE, true
	case .Apostrophe:
		return .APOSTROPHE, true
	case .Comma:
		return .COMMA, true
	case .Minus:
		return .MINUS, true
	case .Period:
		return .PERIOD, true
	case .Slash:
		return .SLASH, true
	case .Zero:
		return .ZERO, true
	case .One:
		return .ONE, true
	case .Two:
		return .TWO, true
	case .Three:
		return .THREE, true
	case .Four:
		return .FOUR, true
	case .Five:
		return .FIVE, true
	case .Six:
		return .SIX, true
	case .Seven:
		return .SEVEN, true
	case .Eight:
		return .EIGHT, true
	case .Nine:
		return .NINE, true
	case .Semicolon:
		return .SEMICOLON, true
	case .Equal:
		return .EQUAL, true
	case .Left_Bracket:
		return .LEFT_BRACKET, true
	case .Backslash:
		return .BACKSLASH, true
	case .Right_Bracket:
		return .RIGHT_BRACKET, true
	case .Grave:
		return .GRAVE, true
	}
	return .KEY_NULL, false
}

@(private = "file")
to_key_letter :: proc(value: Key) -> (ui.Key, bool) {
	#partial switch value {
	case .A:
		return .A, true
	case .B:
		return .B, true
	case .C:
		return .C, true
	case .D:
		return .D, true
	case .E:
		return .E, true
	case .F:
		return .F, true
	case .G:
		return .G, true
	case .H:
		return .H, true
	case .I:
		return .I, true
	case .J:
		return .J, true
	case .K:
		return .K, true
	case .L:
		return .L, true
	case .M:
		return .M, true
	case .N:
		return .N, true
	case .O:
		return .O, true
	case .P:
		return .P, true
	case .Q:
		return .Q, true
	case .R:
		return .R, true
	case .S:
		return .S, true
	case .T:
		return .T, true
	case .U:
		return .U, true
	case .V:
		return .V, true
	case .W:
		return .W, true
	case .X:
		return .X, true
	case .Y:
		return .Y, true
	case .Z:
		return .Z, true
	}
	return .KEY_NULL, false
}

@(private = "file")
to_key_control :: proc(value: Key) -> (ui.Key, bool) {
	#partial switch value {
	case .Escape:
		return .ESCAPE, true
	case .Enter:
		return .ENTER, true
	case .Tab:
		return .TAB, true
	case .Backspace:
		return .BACKSPACE, true
	case .Insert:
		return .INSERT, true
	case .Delete:
		return .DELETE, true
	case .Right:
		return .RIGHT, true
	case .Left:
		return .LEFT, true
	case .Down:
		return .DOWN, true
	case .Up:
		return .UP, true
	case .Page_Up:
		return .PAGE_UP, true
	case .Page_Down:
		return .PAGE_DOWN, true
	case .Home:
		return .HOME, true
	case .End:
		return .END, true
	case .F1:
		return .F1, true
	case .F2:
		return .F2, true
	case .F3:
		return .F3, true
	case .F4:
		return .F4, true
	case .F5:
		return .F5, true
	case .F6:
		return .F6, true
	case .F7:
		return .F7, true
	case .F8:
		return .F8, true
	case .F9:
		return .F9, true
	case .F10:
		return .F10, true
	case .F11:
		return .F11, true
	case .F12:
		return .F12, true
	case .Keypad_Enter:
		return .KP_ENTER, true
	case .Left_Shift:
		return .LEFT_SHIFT, true
	case .Left_Control:
		return .LEFT_CONTROL, true
	case .Left_Alt:
		return .LEFT_ALT, true
	case .Left_Super:
		return .LEFT_SUPER, true
	case .Right_Shift:
		return .RIGHT_SHIFT, true
	case .Right_Control:
		return .RIGHT_CONTROL, true
	case .Right_Alt:
		return .RIGHT_ALT, true
	case .Right_Super:
		return .RIGHT_SUPER, true
	}
	return .KEY_NULL, false
}

@(private = "package")
to_semantic_role :: proc(value: Semantic_Role) -> ui.Sem_Role {
	switch value {
	case .None:
		return .None
	case .Button:
		return .Button
	case .Checkbox:
		return .Checkbox
	case .Radio:
		return .Radio
	case .Slider:
		return .Slider
	case .Text_Input:
		return .Text_Input
	case .Dropdown:
		return .Dropdown
	case .Menu_Item:
		return .Menu_Item
	case .Label:
		return .Label
	case .Pane:
		return .Pane
	case .Modal:
		return .Modal
	case .Tab:
		return .Tab
	case .Tab_Panel:
		return .Tab_Panel
	case .List:
		return .List
	case .List_Item:
		return .List_Item
	case .Option:
		return .Option
	case .Status:
		return .Status
	case .Progress:
		return .Progress
	case .List_Box:
		return .List_Box
	}
	unreachable()
}

@(private = "package")
to_semantic_state :: proc(value: Semantic_State) -> ui.Sem_State {
	result: ui.Sem_State
	if .Checked in value do result += {.Checked}
	if .Disabled in value do result += {.Disabled}
	if .Focused in value do result += {.Focused}
	if .Expanded in value do result += {.Expanded}
	if .Selected in value do result += {.Selected}
	if .Read_Only in value do result += {.Read_Only}
	if .Password in value do result += {.Password}
	if .Multiline in value do result += {.Multiline}
	return result
}
