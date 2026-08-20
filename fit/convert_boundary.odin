package fit

import "ingot:ui"

@(private = "package")
to_key :: proc(value: Key) -> ui.Key {
	switch value {
	case .Null:
		return .KEY_NULL
	case .Space:
		return .SPACE
	case .Apostrophe:
		return .APOSTROPHE
	case .Comma:
		return .COMMA
	case .Minus:
		return .MINUS
	case .Period:
		return .PERIOD
	case .Slash:
		return .SLASH
	case .Zero:
		return .ZERO
	case .One:
		return .ONE
	case .Two:
		return .TWO
	case .Three:
		return .THREE
	case .Four:
		return .FOUR
	case .Five:
		return .FIVE
	case .Six:
		return .SIX
	case .Seven:
		return .SEVEN
	case .Eight:
		return .EIGHT
	case .Nine:
		return .NINE
	case .Semicolon:
		return .SEMICOLON
	case .Equal:
		return .EQUAL
	case .A:
		return .A
	case .B:
		return .B
	case .C:
		return .C
	case .D:
		return .D
	case .E:
		return .E
	case .F:
		return .F
	case .G:
		return .G
	case .H:
		return .H
	case .I:
		return .I
	case .J:
		return .J
	case .K:
		return .K
	case .L:
		return .L
	case .M:
		return .M
	case .N:
		return .N
	case .O:
		return .O
	case .P:
		return .P
	case .Q:
		return .Q
	case .R:
		return .R
	case .S:
		return .S
	case .T:
		return .T
	case .U:
		return .U
	case .V:
		return .V
	case .W:
		return .W
	case .X:
		return .X
	case .Y:
		return .Y
	case .Z:
		return .Z
	case .Left_Bracket:
		return .LEFT_BRACKET
	case .Backslash:
		return .BACKSLASH
	case .Right_Bracket:
		return .RIGHT_BRACKET
	case .Grave:
		return .GRAVE
	case .Escape:
		return .ESCAPE
	case .Enter:
		return .ENTER
	case .Tab:
		return .TAB
	case .Backspace:
		return .BACKSPACE
	case .Insert:
		return .INSERT
	case .Delete:
		return .DELETE
	case .Right:
		return .RIGHT
	case .Left:
		return .LEFT
	case .Down:
		return .DOWN
	case .Up:
		return .UP
	case .Page_Up:
		return .PAGE_UP
	case .Page_Down:
		return .PAGE_DOWN
	case .Home:
		return .HOME
	case .End:
		return .END
	case .F1:
		return .F1
	case .F2:
		return .F2
	case .F3:
		return .F3
	case .F4:
		return .F4
	case .F5:
		return .F5
	case .F6:
		return .F6
	case .F7:
		return .F7
	case .F8:
		return .F8
	case .F9:
		return .F9
	case .F10:
		return .F10
	case .F11:
		return .F11
	case .F12:
		return .F12
	case .Keypad_Enter:
		return .KP_ENTER
	case .Left_Shift:
		return .LEFT_SHIFT
	case .Left_Control:
		return .LEFT_CONTROL
	case .Left_Alt:
		return .LEFT_ALT
	case .Left_Super:
		return .LEFT_SUPER
	case .Right_Shift:
		return .RIGHT_SHIFT
	case .Right_Control:
		return .RIGHT_CONTROL
	case .Right_Alt:
		return .RIGHT_ALT
	case .Right_Super:
		return .RIGHT_SUPER
	}
	unreachable()
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
