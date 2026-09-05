package fit

import "core:reflect"
import "core:testing"
import "ingot:ui"

@(private = "file")
theme_contract_fields :: [][2]string {
	{"background_app", "bg_app"}, {"background_chat", "bg_chat"},
	{"background_panel", "bg_panel"}, {"background_color", "bg_color"},
	{"background_secondary", "bg_secondary"}, {"background_active", "bg_active"},
	{"background_hover", "bg_hover"}, {"background_input", "bg_input"},
	{"background_code", "bg_code"}, {"background_popup", "bg_popup"},
	{"background_selection", "bg_selection"}, {"background_plan_bar", "bg_plan_bar"},
	{"background_plan_title", "bg_plan_title"}, {"background_tool_card", "bg_tool_card"},
	{"background_tool_card_hover", "bg_tool_card_hover"},
	{"background_diff_add", "bg_diff_add"}, {"background_diff_remove", "bg_diff_remove"},
	{"background_debug_title", "bg_debug_title"}, {"background_chip", "bg_chip"},
	{"background_chip_hover", "bg_chip_hover"}, {"background_user_card", "bg_user_card"},
	{"background_band_error", "bg_band_error"}, {"modal_dim", "modal_dim"},
	{"foreground_primary", "fg_primary"}, {"foreground_secondary", "fg_secondary"},
	{"foreground_accent", "fg_accent"}, {"foreground_user", "fg_user"},
	{"foreground_assistant", "fg_assistant"}, {"foreground_error", "fg_error"},
	{"foreground_success", "fg_success"}, {"foreground_tool", "fg_tool"},
	{"foreground_diff_remove", "fg_diff_remove"}, {"foreground_diff_add", "fg_diff_add"},
	{"foreground_diff_gutter", "fg_diff_gutter"}, {"foreground_disabled", "fg_disabled"},
	{"foreground_plan", "fg_plan"}, {"foreground_planning", "fg_planning"},
	{"foreground_heading", "fg_heading"}, {"foreground_debug", "fg_debug"},
	{"foreground_debug_changed", "fg_debug_changed"},
	{"foreground_debug_annotation", "fg_debug_annotation"}, {"foreground_label", "fg_label"},
	{"border", "border_color"}, {"border_subtle", "border_subtle"},
	{"border_user_card", "border_user_card"}, {"badge", "badge_color"},
	{"merge_link", "merge_link_color"}, {"button_background", "button_bg"},
	{"button_hover", "button_hover"}, {"wave_a", "wave_color_a"}, {"wave_b", "wave_color_b"},
	{"drop_zone_background", "drop_zone_bg"}, {"drop_zone_border", "drop_zone_border"},
	{"paper_rule", "paper_rule"}, {"paper_tooth", "paper_tooth"}, {"graphite", "graphite"},
	{"chalk", "chalk"}, {"highlighter", "highlighter"}, {"tape", "tape_color"},
}

@(test)
fit_theme_snapshot_complete :: proc(t: ^testing.T) {
	theme: ui.Theme
	for names, index in theme_contract_fields {
		field := reflect.struct_field_value_by_name(any{&theme, typeid_of(ui.Theme)}, names[1])
		testing.expect_value(t, field.id, typeid_of(ui.Color))
		if field.id != typeid_of(ui.Color) do continue
		(cast(^ui.Color)field.data)^ = {u8(index + 1), 71, 123, 255}
	}
	for kind in Substrate_Kind {
		for margin in ([2]bool{false, true}) {
			theme.substrate = {to_substrate(kind), margin}
			tokens := theme_tokens(theme)
			testing.expect_value(t, tokens.substrate, kind)
			testing.expect_value(t, tokens.margin_rule, margin)
			for names, index in theme_contract_fields {
				field := reflect.struct_field_value_by_name(tokens, names[0])
				testing.expect_value(t, field.id, typeid_of(Color))
				if field.id != typeid_of(Color) do continue
				expected := Color{u8(index + 1), 71, 123, 255}
				testing.expect_value(t, (cast(^Color)field.data)^, expected)
			}
		}
	}
	for name in reflect.struct_field_names(Theme_Tokens) {
		matches := 0
		if name == "substrate" || name == "margin_rule" do matches += 1
		for names in theme_contract_fields {
			if names[0] == name do matches += 1
		}
		testing.expect_value(t, matches, 1)
	}
	testing.expect_value(t, reflect.struct_field_count(Theme_Tokens), len(theme_contract_fields) + 2)
}
