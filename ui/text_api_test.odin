#+build !js
package ui

// Unit tests for the semantic text API: role/ink resolution against the
// frame's scaled metrics and active theme, and the empty-string fast paths.

import "core:testing"

@(private = "file")
ROLES :: [6]Text_Role{.Body, .Title, .Large, .Small, .Label, .Note}

@(private = "file")
INKS :: [15]Ink {
	.Primary,
	.Secondary,
	.Muted,
	.Accent,
	.Danger,
	.Success,
	.Inverse,
	.Disabled,
	.Label,
	.Tool,
	.Diff_Add,
	.Diff_Remove,
	.User,
	.Assistant,
	.Plan,
}

@(test)
text_roles_resolve_to_metric_sizes :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	defer ui_frame_end(&frame)

	metrics := ui_frame_metrics(&frame)
	testing.expect_value(t, text_role_size(&frame, .Body), metrics.FONT_SIZE_BODY)
	testing.expect_value(t, text_role_size(&frame, .Title), metrics.FONT_SIZE_TITLE)
	testing.expect_value(t, text_role_size(&frame, .Large), metrics.FONT_SIZE_LARGE)
	testing.expect_value(t, text_role_size(&frame, .Small), metrics.FONT_SIZE_SMALL)
	testing.expect_value(t, text_role_size(&frame, .Label), metrics.FONT_SIZE_LABEL)
	testing.expect_value(t, text_role_size(&frame, .Note), metrics.FONT_SIZE_NOTE)
}

@(test)
text_roles_track_ui_scale :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)

	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	base: [6]i32
	for role, index in ROLES do base[index] = text_role_size(&frame, role)
	ui_frame_end(&frame)

	ui_runtime_set_scale(&runtime, 2)
	ui_frame_begin(&frame, &runtime)
	defer ui_frame_end(&frame)
	for role, index in ROLES {
		scaled := text_role_size(&frame, role)
		testing.expect(t, scaled > base[index], "scaling up must grow every text role")
	}
}

@(test)
text_line_height_exceeds_font_size :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)

	for scale in ([3]f32{0.5, 1, 3}) {
		ui_runtime_set_scale(&runtime, scale)
		frame: Ui_Frame
		ui_frame_begin(&frame, &runtime)
		for role in ROLES {
			size := text_role_size(&frame, role)
			height := text_role_line_height(&frame, role)
			testing.expect(t, height > size, "line height must leave leading above the glyph box")
		}
		testing.expect_value(
			t,
			text_role_line_height(&frame, .Body),
			ui_frame_metrics(&frame).LINE_HEIGHT,
		)
		ui_frame_end(&frame)
	}
}

@(test)
text_inks_resolve_opaque_theme_colors :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)

	for palette in ([2]Theme{theme_dark(), theme_light()}) {
		ui_runtime_set_theme(&runtime, palette)
		frame: Ui_Frame
		ui_frame_begin(&frame, &runtime)
		style := ui_frame_theme(&frame)
		testing.expect_value(t, text_ink(&frame, .Primary), style.fg_primary)
		testing.expect_value(t, text_ink(&frame, .Secondary), style.fg_secondary)
		testing.expect_value(t, text_ink(&frame, .Muted), style.fg_muted_dim)
		testing.expect_value(t, text_ink(&frame, .Accent), style.fg_accent)
		testing.expect_value(t, text_ink(&frame, .Danger), style.fg_error)
		testing.expect_value(t, text_ink(&frame, .Success), style.fg_success)
		testing.expect_value(t, text_ink(&frame, .Inverse), style.button_text)
		testing.expect_value(t, text_ink(&frame, .Disabled), style.fg_disabled)
		testing.expect_value(t, text_ink(&frame, .Label), style.fg_label)
		testing.expect_value(t, text_ink(&frame, .Tool), style.fg_tool)
		testing.expect_value(t, text_ink(&frame, .Diff_Add), style.fg_diff_add)
		testing.expect_value(t, text_ink(&frame, .Diff_Remove), style.fg_diff_remove)
		testing.expect_value(t, text_ink(&frame, .User), style.fg_user)
		testing.expect_value(t, text_ink(&frame, .Assistant), style.fg_assistant)
		testing.expect_value(t, text_ink(&frame, .Plan), style.fg_plan)
		for ink in INKS {
			testing.expect(t, text_ink(&frame, ink).a > 0, "ink must resolve to a visible color")
		}
		ui_frame_end(&frame)
	}
}

@(test)
text_empty_string_is_zero_work :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	defer ui_frame_end(&frame)

	testing.expect_value(t, text_width(&frame, "", .Body), i32(0))
	testing.expect_value(t, text_height(&frame, "", 100, .Body), i32(0))
	testing.expect_value(t, text_wrapped(&frame, "", 0, 0, 100), i32(0))
	// Must not assert or emit paint for empty input.
	text(&frame, "", 0, 0)
	text_truncated(&frame, "", 0, 0, 100)
}

@(test)
text_height_matches_wrapped_measure :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	defer ui_frame_end(&frame)

	body := "the quick brown fox jumps over the lazy dog"
	measured := text_height(&frame, body, 120, .Body)
	dry_run := text_wrapped(&frame, body, 0, 0, 120, .Body, .Primary, draw = false)
	testing.expect_value(t, measured, dry_run)
	testing.expect(t, measured > 0, "non-empty text must consume height")
	testing.expect(
		t,
		measured % text_role_line_height(&frame, .Body) == 0,
		"wrapped height must be a whole number of lines",
	)
}
