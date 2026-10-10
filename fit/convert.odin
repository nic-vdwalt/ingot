package fit

import "ingot:gfx"
import "ingot:ui"
import "ingot:ui_gfx"

@(private = "package")
to_app_config :: proc(config: Config) -> ui_gfx.App_Config {
	assert(config.width >= 0 && config.height >= 0, "fit: negative app extent")
	assert(config.target_fps >= 0, "fit: negative target FPS")
	assert(config.session.user_scale >= 0, "fit: negative user scale")
	return {
		width = config.width,
		height = config.height,
		title = config.title,
		flags = to_window_flags(config.flags),
		frame_pacing = config.frame_pacing,
		target_fps = config.target_fps,
		event_waiting = config.event_waiting,
		session = config.session,
	}
}

@(private = "package")
to_window_flags :: proc(value: Window_Flags) -> gfx.ConfigFlags {
	// Why transmute: both bit sets are i32-backed and every Window_Flag bit
	// position equals the gfx.ConfigFlag it names; the #assert beside the
	// declaration and fit_window_bits_contract_complete pin that equality.
	return transmute(gfx.ConfigFlags)value
}

@(private = "package")
to_storage :: proc(value: Storage) -> ui.Fit_Storage {
	assert(value.nodes != nil, "fit.Storage: nil nodes")
	assert(value.outputs != nil, "fit.Storage: nil outputs")
	assert(len(value.nodes) == len(value.outputs), "fit.Storage: capacity mismatch")
	assert(len(value.nodes) <= STORAGE_NODE_HARD_MAX, "fit.Storage: capacity too large")
	return {nodes = transmute([]ui.Prepared_Node)value.nodes, outputs = value.outputs}
}

@(private = "package")
from_point :: proc(value: ui.Vector2) -> Point {
	return {value.x, value.y}
}

@(private = "package")
to_mouse_button :: proc(value: Mouse_Button) -> ui.Mouse_Button {
	// Why transmute: both enums are i32 with the same implicit ordinals; the
	// #assert beside the declaration and fit_pointer_contract_complete pin it.
	return transmute(ui.Mouse_Button)value
}

@(private = "package")
to_cursor :: proc(value: Cursor) -> ui.Cursor {
	// Why transmute: both enums are i32 with the same implicit ordinals; the
	// #assert beside the declaration and fit_pointer_contract_complete pin it.
	return transmute(ui.Cursor)value
}

@(private = "package")
effects_validate :: proc(value: Container_Effects) {
	if value.surface.enabled {
		assert(value.background.a == 0, "fit container: mixed surface and background")
		assert(value.border == .None, "fit container: mixed surface and border")
	}
}

@(private = "package")
grid_options_validate :: proc(value: Grid_Options) {
	assert(
		(value.columns > 0) != (len(value.column_tracks) > 0),
		"fit.grid: choose columns or tracks",
	)
	assert(value.row_height >= 0, "fit.grid: negative row height")
	assert(len(value.column_tracks) <= GRID_TRACK_MAX, "fit.grid: too many columns")
	assert(len(value.row_tracks) <= GRID_TRACK_MAX, "fit.grid: too many rows")
	effects_validate(value.effects)
}

@(private = "package")
to_grid_cell_options :: proc(value: Grid_Cell_Options) -> ui.Prepared_Grid_Cell_Options {
	assert(value.column >= -1 && value.row >= -1, "fit.grid_cell: invalid placement")
	assert(value.column_span >= 0 && value.row_span >= 0, "fit.grid_cell: invalid span")
	return {
		placement = {
			column = value.column,
			row = value.row,
			column_span = value.column_span,
			row_span = value.row_span,
		},
		align_x = value.align_x,
		align_y = value.align_y,
	}
}

@(private = "package")
to_scroll_options :: proc(
	widget: Widget_Id,
	state: ^Scroll_State,
	value: Scroll_Options,
) -> ui.Prepared_Scroll_Options {
	assert(widget != Widget_Id(0) && state != nil, "fit.scroll: invalid state")
	return {
		state = &state.inner,
		id = widget,
		padding = value.padding,
		keyboard = value.keyboard,
		bar = value.bar,
		axis = value.axis,
		track = value.track,
		size = value.size,
	}
}

@(private = "package")
to_text_semantics :: proc(value: Text_Input_Semantics) -> ui.Text_Input_Semantics {
	return {name = value.name}
}

@(private = "package")
to_chart_options :: proc(value: Chart_Options) -> ui.Chart_Opts {
	return {
		labels = value.labels,
		y_min = value.y_min,
		y_max = value.y_max,
		y_fixed = value.y_fixed,
		show_grid = value.show_grid,
		show_axes = value.show_axes,
		show_legend = value.show_legend,
		fill = value.fill,
	}
}
