package ui

Theme_Basis :: enum u8 {
	Dark,
	Light,
}

Theme_Palette :: struct {
	basis:                Theme_Basis,
	ground:               Color,
	surface:              Color,
	surface_raised:       Color,
	control:              Color,
	control_hover:        Color,
	control_pressed:      Color,
	foreground:           Color,
	foreground_muted:     Color,
	accent:               Color,
	foreground_on_accent: Color,
	danger:               Color,
	foreground_on_danger: Color,
	success:              Color,
	border:               Color,
	focus:                Color,
}

Theme_Role :: enum u8 {
	Background_App,
	Background_Chat,
	Background_Panel,
	Background_App_Windowed,
	Background_Chat_Windowed,
	Background_Panel_Windowed,
	Background_App_Fullscreen,
	Background_Chat_Fullscreen,
	Background_Panel_Fullscreen,
	Background,
	Background_Secondary,
	Background_Active,
	Background_Hover,
	Background_Input,
	Background_Code,
	Foreground_Primary,
	Foreground_Secondary,
	Foreground_Accent,
	Foreground_User,
	Foreground_Assistant,
	Foreground_Error,
	Foreground_Success,
	Foreground_Tool,
	Foreground_Diff_Remove,
	Foreground_Diff_Add,
	Background_Diff_Remove,
	Background_Diff_Add,
	Foreground_Diff_Gutter,
	Border,
	Border_Subtle,
	Badge,
	Merge_Link,
	Button_Background,
	Button_Hover,
	Button_Text,
	Background_Popup,
	Foreground_Disabled,
	Background_Plan_Bar,
	Foreground_Plan,
	Foreground_Planning,
	Background_Selection,
	Background_Plan_Title,
	Background_Tool_Card,
	Background_Tool_Card_Hover,
	Foreground_Heading,
	Foreground_Bullet,
	Foreground_Bold,
	Foreground_Code_Inline,
	Background_Table_Header,
	Wave_A,
	Wave_B,
	Drop_Zone_Background,
	Drop_Zone_Border,
	Foreground_Debug,
	Background_Debug_Title,
	Foreground_Debug_Changed,
	Foreground_Debug_Annotation,
	Background_Chip,
	Background_Chip_Hover,
	Background_User_Card,
	Border_User_Card,
	Background_Band_Error,
	Foreground_Label,
	Button_Danger_Background,
	Button_Danger_Hover,
	Button_Danger_Foreground,
	Button_Disabled_Background,
	Button_Pressed,
	Surface_Pressed,
	Foreground_Accent_Light,
	Foreground_Muted,
	Modal_Dim,
	Focus_Ring,
	Shadow,
	Button_Gradient_Top,
	Button_Gradient_Bottom,
	Paper_Rule,
	Paper_Tooth,
	Graphite,
	Chalk,
	Highlighter,
	Tape,
	Ink_Faded,
	Foreground_On_Accent,
	Caption_Hover,
	Caption_Pressed,
	Caption_Close_Hover,
	Caption_Close_Pressed,
	Spell_Error,
}

Theme_Validation_Code :: enum u8 {
	Valid,
	Transparent_Foreground,
	Transparent_Background,
	Primary_Contrast,
	Button_Contrast,
	Reading_Contrast,
}

Theme_Validation :: struct {
	code:           Theme_Validation_Code,
	role:           Theme_Role,
	contrast_ratio: f64,
	required_ratio: f64,
}

Theme_Color_Entry :: struct {
	role:  Theme_Role,
	color: Color,
}

THEME_REQUIRED_FOREGROUNDS :: [?]Theme_Role {
	.Foreground_Primary,
	.Foreground_Secondary,
	.Foreground_Code_Inline,
	.Foreground_Heading,
	.Button_Text,
	.Button_Danger_Foreground,
	.Foreground_Disabled,
}

THEME_REQUIRED_BACKGROUNDS :: [?]Theme_Role {
	.Background_App_Windowed,
	.Background_App_Fullscreen,
	.Background_Panel_Windowed,
	.Background_Panel_Fullscreen,
	.Background_Tool_Card,
	.Background_Popup,
	.Background_Input,
	.Background_Chip,
	.Background_Code,
	.Background_Table_Header,
	.Button_Background,
	.Background_Active,
	.Button_Danger_Background,
	.Background,
	.Button_Hover,
	.Button_Danger_Hover,
	.Background_Chip_Hover,
	.Background_Tool_Card_Hover,
	.Background_Hover,
	.Button_Pressed,
	.Surface_Pressed,
	.Button_Disabled_Background,
}

Theme_Get_Color :: proc(theme: Theme, role: Theme_Role) -> Color {
	if role <= .Foreground_Diff_Add do return theme_get_color_core(theme, role)
	if role <= .Drop_Zone_Border do return theme_get_color_controls(theme, role)
	if role <= .Button_Gradient_Bottom do return theme_get_color_states(theme, role)
	return theme_get_color_materials(theme, role)
}

Theme_Set_Color :: proc(theme: ^Theme, role: Theme_Role, color: Color) {
	assert(theme != nil, "Theme_Set_Color: nil theme")
	if role <= .Foreground_Diff_Add do return theme_set_color_core(theme, role, color)
	if role <= .Drop_Zone_Border do return theme_set_color_controls(theme, role, color)
	if role <= .Button_Gradient_Bottom do return theme_set_color_states(theme, role, color)
	theme_set_color_materials(theme, role, color)
}

Theme_From_Palette :: proc(palette: Theme_Palette) -> Theme {
	assert(theme_palette_colors_present(palette), "Theme_From_Palette: transparent required swatch")
	result := theme_dark() if palette.basis == .Dark else theme_light()
	theme_palette_apply_surfaces(&result, palette)
	theme_palette_apply_inks(&result, palette)
	theme_palette_apply_controls(&result, palette)
	theme_palette_apply_semantics(&result, palette)
	return result
}

Theme_Validate :: proc(theme: Theme) -> Theme_Validation {
	for role in THEME_REQUIRED_FOREGROUNDS {
		if Theme_Get_Color(theme, role).a == 0 {
			return {code = .Transparent_Foreground, role = role}
		}
	}
	for role in THEME_REQUIRED_BACKGROUNDS {
		if Theme_Get_Color(theme, role).a == 0 {
			return {code = .Transparent_Background, role = role}
		}
	}
	ratio := contrast_ratio(theme.fg_primary, theme.bg_color)
	if ratio < MIN_TEXT_CONTRAST {
		return {
			code = .Primary_Contrast,
			role = .Foreground_Primary,
			contrast_ratio = ratio,
			required_ratio = MIN_TEXT_CONTRAST,
		}
	}
	ratio = contrast_ratio(theme.button_text, theme.button_bg)
	if ratio < MIN_TEXT_CONTRAST {
		return {
			code = .Button_Contrast,
			role = .Button_Text,
			contrast_ratio = ratio,
			required_ratio = MIN_TEXT_CONTRAST,
		}
	}
	return theme_validate_reading(theme)
}

Theme_Is_Valid :: proc(theme: Theme) -> bool {
	return Theme_Validate(theme).code == .Valid
}

Theme_Set_Pigment :: proc(theme: ^Theme, pigment: Pigment, color: Color) {
	assert(theme != nil, "Theme_Set_Pigment: nil theme")
	theme.pigments[pigment] = color
}

Theme_Set_Substrate :: proc(theme: ^Theme, substrate: Substrate) {
	assert(theme != nil, "Theme_Set_Substrate: nil theme")
	theme.substrate = substrate
}

@(private = "file")
theme_palette_colors_present :: proc(palette: Theme_Palette) -> bool {
	colors := [?]Color {
		palette.ground,
		palette.surface,
		palette.surface_raised,
		palette.control,
		palette.control_hover,
		palette.control_pressed,
		palette.foreground,
		palette.foreground_muted,
		palette.accent,
		palette.foreground_on_accent,
		palette.danger,
		palette.foreground_on_danger,
		palette.success,
		palette.border,
		palette.focus,
	}
	for color in colors {
		if color.a == 0 do return false
	}
	return true
}

@(private = "file")
theme_palette_apply_surfaces :: proc(theme: ^Theme, palette: Theme_Palette) {
	assert(theme != nil, "theme palette surfaces: nil theme")
	theme.bg_app = palette.ground
	theme.bg_chat = palette.ground
	theme.bg_app_windowed = palette.ground
	theme.bg_chat_windowed = palette.ground
	theme.bg_app_fullscreen = palette.ground
	theme.bg_chat_fullscreen = palette.ground
	theme.bg_color = palette.ground
	theme.bg_panel = palette.surface
	theme.bg_panel_windowed = palette.surface
	theme.bg_panel_fullscreen = palette.surface
	theme.bg_secondary = palette.surface
	theme.bg_input = palette.surface
	theme.bg_code = palette.surface
	theme.bg_popup = palette.surface_raised
	theme.bg_tool_card = palette.surface_raised
	theme.bg_table_header = palette.surface_raised
	theme.bg_user_card = palette.surface_raised
}

@(private = "file")
theme_palette_apply_inks :: proc(theme: ^Theme, palette: Theme_Palette) {
	assert(theme != nil, "theme palette inks: nil theme")
	theme.fg_primary = palette.foreground
	theme.fg_heading = palette.foreground
	theme.fg_bold = palette.foreground
	theme.fg_user = palette.foreground
	theme.fg_secondary = palette.foreground_muted
	theme.fg_muted_dim = palette.foreground_muted
	theme.fg_disabled = palette.foreground_muted
	theme.fg_label = palette.foreground_muted
	theme.fg_assistant = palette.foreground_muted
	theme.fg_diff_gutter = palette.foreground_muted
	theme.fg_debug_annotation = palette.foreground_muted
	theme.ink_faded = palette.foreground_muted
}

@(private = "file")
theme_palette_apply_controls :: proc(theme: ^Theme, palette: Theme_Palette) {
	assert(theme != nil, "theme palette controls: nil theme")
	theme.bg_active = palette.control
	theme.button_bg = palette.control
	theme.bg_chip = palette.control
	theme.button_disabled_bg = palette.control
	theme.bg_hover = palette.control_hover
	theme.button_hover = palette.control_hover
	theme.bg_chip_hover = palette.control_hover
	theme.bg_tool_card_hover = palette.control_hover
	theme.caption_hover = palette.control_hover
	theme.button_pressed = palette.control_pressed
	theme.surface_pressed = palette.control_pressed
	theme.caption_pressed = palette.control_pressed
	theme.border_color = palette.border
	theme.border_subtle = palette.border
	theme.border_user_card = palette.border
	theme.focus_ring = palette.focus
}

@(private = "file")
theme_palette_apply_semantics :: proc(theme: ^Theme, palette: Theme_Palette) {
	assert(theme != nil, "theme palette semantics: nil theme")
	theme.fg_accent = palette.accent
	theme.fg_accent_light = palette.accent
	theme.fg_tool = palette.accent
	theme.fg_plan = palette.accent
	theme.fg_planning = palette.accent
	theme.fg_debug = palette.accent
	theme.fg_debug_changed = palette.accent
	theme.fg_code_inline = palette.accent
	theme.fg_bullet = palette.accent
	theme.fg_error = palette.danger
	theme.fg_diff_remove = palette.danger
	theme.spell_error = palette.danger
	theme.button_danger_fg = palette.foreground_on_danger
	theme.fg_success = palette.success
	theme.fg_diff_add = palette.success
	theme.button_text = palette.foreground_on_accent
	theme.fg_on_accent = palette.foreground_on_accent
	theme.pigments[.Accent] = palette.accent
	theme.pigments[.Danger] = palette.danger
	theme.pigments[.Success] = palette.success
	theme.pigments[.Tool] = palette.accent
}

@(private = "file")
theme_validate_reading :: proc(theme: Theme) -> Theme_Validation {
	surfaces := theme_reading_surfaces(&theme)
	for ink in READING_INKS {
		foreground := theme_ink(&theme, ink)
		for background in surfaces {
			ratio := contrast_ratio(foreground, background)
			if ratio < MIN_TEXT_CONTRAST_LARGE {
				return {
					code = .Reading_Contrast,
					role = theme_role_for_ink(ink),
					contrast_ratio = ratio,
					required_ratio = MIN_TEXT_CONTRAST_LARGE,
				}
			}
		}
	}
	return {}
}

@(private = "file")
theme_role_for_ink :: proc(ink: Ink) -> Theme_Role {
	switch ink {
	case .Primary: return .Foreground_Primary
	case .Heading: return .Foreground_Heading
	case .Secondary: return .Foreground_Secondary
	case .Muted: return .Foreground_Muted
	case .Accent: return .Foreground_Accent
	case .Danger: return .Foreground_Error
	case .Success: return .Foreground_Success
	case .Inverse: return .Button_Text
	case .Disabled: return .Foreground_Disabled
	case .Label: return .Foreground_Label
	case .Accent_Light: return .Foreground_Accent_Light
	case .Tool: return .Foreground_Tool
	case .Diff_Add: return .Foreground_Diff_Add
	case .Diff_Remove: return .Foreground_Diff_Remove
	case .User: return .Foreground_User
	case .Assistant: return .Foreground_Assistant
	case .Plan: return .Foreground_Plan
	}
	return .Foreground_Primary
}

@(private = "file")
theme_get_color_core :: proc(theme: Theme, role: Theme_Role) -> Color {
	#partial switch role {
	case .Background_App: return theme.bg_app
	case .Background_Chat: return theme.bg_chat
	case .Background_Panel: return theme.bg_panel
	case .Background_App_Windowed: return theme.bg_app_windowed
	case .Background_Chat_Windowed: return theme.bg_chat_windowed
	case .Background_Panel_Windowed: return theme.bg_panel_windowed
	case .Background_App_Fullscreen: return theme.bg_app_fullscreen
	case .Background_Chat_Fullscreen: return theme.bg_chat_fullscreen
	case .Background_Panel_Fullscreen: return theme.bg_panel_fullscreen
	case .Background: return theme.bg_color
	case .Background_Secondary: return theme.bg_secondary
	case .Background_Active: return theme.bg_active
	case .Background_Hover: return theme.bg_hover
	case .Background_Input: return theme.bg_input
	case .Background_Code: return theme.bg_code
	case .Foreground_Primary: return theme.fg_primary
	case .Foreground_Secondary: return theme.fg_secondary
	case .Foreground_Accent: return theme.fg_accent
	case .Foreground_User: return theme.fg_user
	case .Foreground_Assistant: return theme.fg_assistant
	case .Foreground_Error: return theme.fg_error
	case .Foreground_Success: return theme.fg_success
	case .Foreground_Tool: return theme.fg_tool
	case .Foreground_Diff_Remove: return theme.fg_diff_remove
	case .Foreground_Diff_Add: return theme.fg_diff_add
	}
	return {}
}

@(private = "file")
theme_get_color_controls :: proc(theme: Theme, role: Theme_Role) -> Color {
	#partial switch role {
	case .Background_Diff_Remove: return theme.bg_diff_remove
	case .Background_Diff_Add: return theme.bg_diff_add
	case .Foreground_Diff_Gutter: return theme.fg_diff_gutter
	case .Border: return theme.border_color
	case .Border_Subtle: return theme.border_subtle
	case .Badge: return theme.badge_color
	case .Merge_Link: return theme.merge_link_color
	case .Button_Background: return theme.button_bg
	case .Button_Hover: return theme.button_hover
	case .Button_Text: return theme.button_text
	case .Background_Popup: return theme.bg_popup
	case .Foreground_Disabled: return theme.fg_disabled
	case .Background_Plan_Bar: return theme.bg_plan_bar
	case .Foreground_Plan: return theme.fg_plan
	case .Foreground_Planning: return theme.fg_planning
	case .Background_Selection: return theme.bg_selection
	case .Background_Plan_Title: return theme.bg_plan_title
	case .Background_Tool_Card: return theme.bg_tool_card
	case .Background_Tool_Card_Hover: return theme.bg_tool_card_hover
	case .Foreground_Heading: return theme.fg_heading
	case .Foreground_Bullet: return theme.fg_bullet
	case .Foreground_Bold: return theme.fg_bold
	case .Foreground_Code_Inline: return theme.fg_code_inline
	case .Background_Table_Header: return theme.bg_table_header
	case .Wave_A: return theme.wave_color_a
	case .Wave_B: return theme.wave_color_b
	case .Drop_Zone_Background: return theme.drop_zone_bg
	case .Drop_Zone_Border: return theme.drop_zone_border
	}
	return {}
}

@(private = "file")
theme_get_color_states :: proc(theme: Theme, role: Theme_Role) -> Color {
	#partial switch role {
	case .Foreground_Debug: return theme.fg_debug
	case .Background_Debug_Title: return theme.bg_debug_title
	case .Foreground_Debug_Changed: return theme.fg_debug_changed
	case .Foreground_Debug_Annotation: return theme.fg_debug_annotation
	case .Background_Chip: return theme.bg_chip
	case .Background_Chip_Hover: return theme.bg_chip_hover
	case .Background_User_Card: return theme.bg_user_card
	case .Border_User_Card: return theme.border_user_card
	case .Background_Band_Error: return theme.bg_band_error
	case .Foreground_Label: return theme.fg_label
	case .Button_Danger_Background: return theme.button_danger_bg
	case .Button_Danger_Hover: return theme.button_danger_hover
	case .Button_Danger_Foreground: return theme.button_danger_fg
	case .Button_Disabled_Background: return theme.button_disabled_bg
	case .Button_Pressed: return theme.button_pressed
	case .Surface_Pressed: return theme.surface_pressed
	case .Foreground_Accent_Light: return theme.fg_accent_light
	case .Foreground_Muted: return theme.fg_muted_dim
	case .Modal_Dim: return theme.modal_dim
	case .Focus_Ring: return theme.focus_ring
	case .Shadow: return theme.shadow_color
	case .Button_Gradient_Top: return theme.button_primary_grad_top
	case .Button_Gradient_Bottom: return theme.button_primary_grad_bottom
	}
	return {}
}

@(private = "file")
theme_get_color_materials :: proc(theme: Theme, role: Theme_Role) -> Color {
	#partial switch role {
	case .Paper_Rule: return theme.paper_rule
	case .Paper_Tooth: return theme.paper_tooth
	case .Graphite: return theme.graphite
	case .Chalk: return theme.chalk
	case .Highlighter: return theme.highlighter
	case .Tape: return theme.tape_color
	case .Ink_Faded: return theme.ink_faded
	case .Foreground_On_Accent: return theme.fg_on_accent
	case .Caption_Hover: return theme.caption_hover
	case .Caption_Pressed: return theme.caption_pressed
	case .Caption_Close_Hover: return theme.caption_close_hover
	case .Caption_Close_Pressed: return theme.caption_close_pressed
	case .Spell_Error: return theme.spell_error
	}
	return {}
}

@(private = "file")
theme_set_color_core :: proc(theme: ^Theme, role: Theme_Role, color: Color) {
	#partial switch role {
	case .Background_App: theme.bg_app = color
	case .Background_Chat: theme.bg_chat = color
	case .Background_Panel: theme.bg_panel = color
	case .Background_App_Windowed: theme.bg_app_windowed = color
	case .Background_Chat_Windowed: theme.bg_chat_windowed = color
	case .Background_Panel_Windowed: theme.bg_panel_windowed = color
	case .Background_App_Fullscreen: theme.bg_app_fullscreen = color
	case .Background_Chat_Fullscreen: theme.bg_chat_fullscreen = color
	case .Background_Panel_Fullscreen: theme.bg_panel_fullscreen = color
	case .Background: theme.bg_color = color
	case .Background_Secondary: theme.bg_secondary = color
	case .Background_Active: theme.bg_active = color
	case .Background_Hover: theme.bg_hover = color
	case .Background_Input: theme.bg_input = color
	case .Background_Code: theme.bg_code = color
	case .Foreground_Primary: theme.fg_primary = color
	case .Foreground_Secondary: theme.fg_secondary = color
	case .Foreground_Accent: theme.fg_accent = color
	case .Foreground_User: theme.fg_user = color
	case .Foreground_Assistant: theme.fg_assistant = color
	case .Foreground_Error: theme.fg_error = color
	case .Foreground_Success: theme.fg_success = color
	case .Foreground_Tool: theme.fg_tool = color
	case .Foreground_Diff_Remove: theme.fg_diff_remove = color
	case .Foreground_Diff_Add: theme.fg_diff_add = color
	}
}

@(private = "file")
theme_set_color_controls :: proc(theme: ^Theme, role: Theme_Role, color: Color) {
	#partial switch role {
	case .Background_Diff_Remove: theme.bg_diff_remove = color
	case .Background_Diff_Add: theme.bg_diff_add = color
	case .Foreground_Diff_Gutter: theme.fg_diff_gutter = color
	case .Border: theme.border_color = color
	case .Border_Subtle: theme.border_subtle = color
	case .Badge: theme.badge_color = color
	case .Merge_Link: theme.merge_link_color = color
	case .Button_Background: theme.button_bg = color
	case .Button_Hover: theme.button_hover = color
	case .Button_Text: theme.button_text = color
	case .Background_Popup: theme.bg_popup = color
	case .Foreground_Disabled: theme.fg_disabled = color
	case .Background_Plan_Bar: theme.bg_plan_bar = color
	case .Foreground_Plan: theme.fg_plan = color
	case .Foreground_Planning: theme.fg_planning = color
	case .Background_Selection: theme.bg_selection = color
	case .Background_Plan_Title: theme.bg_plan_title = color
	case .Background_Tool_Card: theme.bg_tool_card = color
	case .Background_Tool_Card_Hover: theme.bg_tool_card_hover = color
	case .Foreground_Heading: theme.fg_heading = color
	case .Foreground_Bullet: theme.fg_bullet = color
	case .Foreground_Bold: theme.fg_bold = color
	case .Foreground_Code_Inline: theme.fg_code_inline = color
	case .Background_Table_Header: theme.bg_table_header = color
	case .Wave_A: theme.wave_color_a = color
	case .Wave_B: theme.wave_color_b = color
	case .Drop_Zone_Background: theme.drop_zone_bg = color
	case .Drop_Zone_Border: theme.drop_zone_border = color
	}
}

@(private = "file")
theme_set_color_states :: proc(theme: ^Theme, role: Theme_Role, color: Color) {
	#partial switch role {
	case .Foreground_Debug: theme.fg_debug = color
	case .Background_Debug_Title: theme.bg_debug_title = color
	case .Foreground_Debug_Changed: theme.fg_debug_changed = color
	case .Foreground_Debug_Annotation: theme.fg_debug_annotation = color
	case .Background_Chip: theme.bg_chip = color
	case .Background_Chip_Hover: theme.bg_chip_hover = color
	case .Background_User_Card: theme.bg_user_card = color
	case .Border_User_Card: theme.border_user_card = color
	case .Background_Band_Error: theme.bg_band_error = color
	case .Foreground_Label: theme.fg_label = color
	case .Button_Danger_Background: theme.button_danger_bg = color
	case .Button_Danger_Hover: theme.button_danger_hover = color
	case .Button_Danger_Foreground: theme.button_danger_fg = color
	case .Button_Disabled_Background: theme.button_disabled_bg = color
	case .Button_Pressed: theme.button_pressed = color
	case .Surface_Pressed: theme.surface_pressed = color
	case .Foreground_Accent_Light: theme.fg_accent_light = color
	case .Foreground_Muted: theme.fg_muted_dim = color
	case .Modal_Dim: theme.modal_dim = color
	case .Focus_Ring: theme.focus_ring = color
	case .Shadow: theme.shadow_color = color
	case .Button_Gradient_Top: theme.button_primary_grad_top = color
	case .Button_Gradient_Bottom: theme.button_primary_grad_bottom = color
	}
}

@(private = "file")
theme_set_color_materials :: proc(theme: ^Theme, role: Theme_Role, color: Color) {
	#partial switch role {
	case .Paper_Rule: theme.paper_rule = color
	case .Paper_Tooth: theme.paper_tooth = color
	case .Graphite: theme.graphite = color
	case .Chalk: theme.chalk = color
	case .Highlighter: theme.highlighter = color
	case .Tape: theme.tape_color = color
	case .Ink_Faded: theme.ink_faded = color
	case .Foreground_On_Accent: theme.fg_on_accent = color
	case .Caption_Hover: theme.caption_hover = color
	case .Caption_Pressed: theme.caption_pressed = color
	case .Caption_Close_Hover: theme.caption_close_hover = color
	case .Caption_Close_Pressed: theme.caption_close_pressed = color
	case .Spell_Error: theme.spell_error = color
	}
}
