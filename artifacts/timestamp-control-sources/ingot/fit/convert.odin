package fit

import "ingot:gfx"
import "ingot:ui"
import "ingot:ui_gfx"

@(private = "package")
to_session_config :: proc(config: Session_Config) -> ui_gfx.Session_Config {
	assert(config.user_scale >= 0, "Fit: negative user scale")
	return {
		user_scale = config.user_scale,
		semantics_enabled = config.semantics_enabled,
		scale_metrics = config.scale_metrics,
		scale_invalidate = config.scale_invalidate,
	}
}

@(private = "package")
to_app_config :: proc(config: Config) -> ui_gfx.App_Config {
	assert(config.width >= 0 && config.height >= 0, "Fit: negative app extent")
	assert(config.target_fps >= 0, "Fit: negative target FPS")
	return {
		width = config.width,
		height = config.height,
		title = config.title,
		flags = to_window_flags(config.flags),
		frame_pacing = to_frame_pacing(config.frame_pacing),
		target_fps = config.target_fps,
		event_waiting = config.event_waiting,
		session = to_session_config(config.session),
	}
}

@(private = "package")
to_frame_pacing :: proc(value: Frame_Pacing) -> ui_gfx.App_Frame_Pacing {
	switch value {
	case .Fixed:
		return .Fixed
	case .Uncapped:
		return .Uncapped
	case .Monitor_Refresh:
		return .Monitor_Refresh
	}
	unreachable()
}

@(private = "package")
from_app_state :: proc(value: ui_gfx.App_State) -> State {
	switch value {
	case .Empty:
		return .Empty
	case .Ready:
		return .Ready
	case .Running:
		return .Running
	case .Stopped:
		return .Stopped
	}
	unreachable()
}

@(private = "package")
to_window_flags :: proc(value: Window_Flags) -> gfx.ConfigFlags {
	result: gfx.ConfigFlags
	if .Fullscreen in value do result += {.FULLSCREEN_MODE}
	if .Resizable in value do result += {.WINDOW_RESIZABLE}
	if .Undecorated in value do result += {.WINDOW_UNDECORATED}
	if .Transparent in value do result += {.WINDOW_TRANSPARENT}
	if .Msaa_4x in value do result += {.MSAA_4X_HINT}
	if .Vsync in value do result += {.VSYNC_HINT}
	if .Hidden in value do result += {.WINDOW_HIDDEN}
	if .Always_Run in value do result += {.WINDOW_ALWAYS_RUN}
	if .Minimized in value do result += {.WINDOW_MINIMIZED}
	if .Maximized in value do result += {.WINDOW_MAXIMIZED}
	if .Unfocused in value do result += {.WINDOW_UNFOCUSED}
	if .Topmost in value do result += {.WINDOW_TOPMOST}
	if .High_Dpi in value do result += {.WINDOW_HIGHDPI}
	if .Mouse_Passthrough in value do result += {.WINDOW_MOUSE_PASSTHROUGH}
	if .Borderless_Windowed in value do result += {.BORDERLESS_WINDOWED_MODE}
	if .Interlaced in value do result += {.INTERLACED_HINT}
	return result
}

@(private = "package")
to_storage :: proc(value: Storage) -> ui.Fit_Storage {
	assert(value.nodes != nil, "Fit.Storage: nil nodes")
	assert(value.outputs != nil, "Fit.Storage: nil outputs")
	assert(len(value.nodes) == len(value.outputs), "Fit.Storage: capacity mismatch")
	assert(len(value.nodes) <= STORAGE_NODE_HARD_MAX, "Fit.Storage: capacity too large")
	return {nodes = transmute([]ui.Prepared_Node)value.nodes, outputs = value.outputs}
}

@(private = "package")
to_rect :: proc(value: Rect) -> ui.Rect_I32 {
	return {value.x, value.y, value.w, value.h}
}

@(private = "package")
to_float_rect :: proc(value: Float_Rect) -> ui.Rectangle {
	return {value.x, value.y, value.width, value.height}
}

@(private = "package")
from_point :: proc(value: ui.Vector2) -> Point {
	return {value.x, value.y}
}

@(private = "package")
from_rect :: proc(value: ui.Rect_I32) -> Rect {
	return {value.x, value.y, value.w, value.h}
}

@(private = "package")
to_size_value :: proc(value: Size) -> ui.Intrinsic_Size {
	return {value.w, value.h, value.overflow}
}

@(private = "package")
from_size_value :: proc(value: ui.Intrinsic_Size) -> Size {
	return {value.w, value.h, value.overflow}
}

@(private = "package")
from_constraints :: proc(value: ui.Intrinsic_Constraints) -> Constraints {
	return {value.min_w, value.min_h, value.max_w, value.max_h}
}

@(private = "package")
to_mouse_button :: proc(value: Mouse_Button) -> ui.Mouse_Button {
	switch value {
	case .Left:
		return .LEFT
	case .Right:
		return .RIGHT
	case .Middle:
		return .MIDDLE
	case .Side:
		return .SIDE
	case .Extra:
		return .EXTRA
	case .Forward:
		return .FORWARD
	case .Back:
		return .BACK
	}
	unreachable()
}

@(private = "package")
to_cursor :: proc(value: Cursor) -> ui.Cursor {
	switch value {
	case .Default:
		return .DEFAULT
	case .Arrow:
		return .ARROW
	case .IBeam:
		return .IBEAM
	case .Crosshair:
		return .CROSSHAIR
	case .Pointing_Hand:
		return .POINTING_HAND
	case .Resize_EW:
		return .RESIZE_EW
	case .Resize_NS:
		return .RESIZE_NS
	case .Resize_NWSE:
		return .RESIZE_NWSE
	case .Resize_NESW:
		return .RESIZE_NESW
	case .Resize_All:
		return .RESIZE_ALL
	case .Not_Allowed:
		return .NOT_ALLOWED
	}
	unreachable()
}

@(private = "package")
to_track :: proc(value: Track) -> ui.Track {
	return value
}

@(private = "package")
to_transition :: proc(value: Transition) -> ui.Prepared_Transition {
	return {state = value.state, options = {speed = value.options.speed}}
}

@(private = "package")
to_size :: proc(value: Size_Options) -> ui.Prepared_Size {
	return {
		width = to_track(value.width),
		height = to_track(value.height),
		aspect = {value.aspect.width, value.aspect.height},
		transition = to_transition(value.transition),
	}
}

@(private = "package")
to_effects :: proc(value: Container_Effects) -> ui.Prepared_Container_Effects {
	if value.surface.enabled {
		assert(value.background.a == 0, "Fit container: mixed surface and background")
		assert(value.border == .None, "Fit container: mixed surface and border")
	}
	return {
		clip = value.clip,
		background = ui.Color(value.background),
		radius = value.radius,
		border = value.border,
		border_color = ui.Color(value.border_color),
		surface = {
			enabled = value.surface.enabled,
			kind = value.surface.kind,
			state = value.surface.state,
			radius = value.surface.radius,
			border = value.surface.border,
			elevation = value.surface.elevation,
		},
	}
}

@(private = "package")
to_container_options :: proc(value: Container_Options) -> ui.Prepared_Container_Options {
	return {
		gap = value.gap,
		padding = value.padding,
		align = value.align,
		justify = value.justify,
		track = to_track(value.track),
		size = to_size(value.size),
		effects = to_effects(value.effects),
	}
}

@(private = "package")
to_flow_options :: proc(value: Flow_Options) -> ui.Prepared_Flow_Options {
	return {
		gap_x = value.gap_x,
		gap_y = value.gap_y,
		padding = value.padding,
		align = value.align,
		justify = value.justify,
		track = to_track(value.track),
		size = to_size(value.size),
		effects = to_effects(value.effects),
	}
}

@(private = "package")
to_grid_options :: proc(value: Grid_Options) -> ui.Prepared_Grid_Options {
	assert(
		(value.columns > 0) != (len(value.column_tracks) > 0),
		"Fit.Grid: choose columns or tracks",
	)
	assert(value.row_height >= 0, "Fit.Grid: negative row height")
	assert(len(value.column_tracks) <= GRID_TRACK_MAX, "Fit.Grid: too many columns")
	assert(len(value.row_tracks) <= GRID_TRACK_MAX, "Fit.Grid: too many rows")
	return {
		columns = value.columns,
		row_height = value.row_height,
		column_tracks = value.column_tracks,
		row_tracks = value.row_tracks,
		auto_flow = ui.Grid_Auto_Flow(value.auto_flow),
		gap_x = value.gap_x,
		gap_y = value.gap_y,
		padding = value.padding,
		track = to_track(value.track),
		size = to_size(value.size),
		effects = to_effects(value.effects),
	}
}

@(private = "package")
to_grid_cell_options :: proc(value: Grid_Cell_Options) -> ui.Prepared_Grid_Cell_Options {
	assert(value.column >= -1 && value.row >= -1, "Fit.Grid_Cell: invalid placement")
	assert(value.column_span >= 0 && value.row_span >= 0, "Fit.Grid_Cell: invalid span")
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
to_attachment_options :: proc(value: Attachment_Options) -> ui.Prepared_Attachment_Options {
	return {
		target_kind = value.target_kind,
		target = ui.Prepared_Handle(value.target),
		target_screen = to_rect(value.target_screen),
		target_point = value.target_point,
		self_point = value.self_point,
		offset_x = value.offset_x,
		offset_y = value.offset_y,
		z = ui.Z_Order(value.z),
		claim = value.claim,
		clamp_to_viewport = value.clamp_to_viewport,
		transition = to_transition(value.transition),
	}
}

@(private = "package")
to_scroll_options :: proc(
	widget: Widget_Id,
	state: ^Scroll_State,
	value: Scroll_Options,
) -> ui.Prepared_Scroll_Options {
	assert(widget != Widget_Id(0) && state != nil, "Fit.Scroll: invalid state")
	return {
		state = &state.inner,
		id = ui.Widget_Id(widget),
		padding = value.padding,
		keyboard = value.keyboard,
		bar = value.bar,
		axis = ui.Scroll_Axis(value.axis),
		track = to_track(value.track),
		size = to_size(value.size),
	}
}

@(private = "package")
to_label_options :: proc(value: Label_Options) -> ui.Fit_Label_Options {
	return {
		role = value.role,
		ink = value.ink,
		wrap = value.wrap,
		track = to_track(value.track),
		size = to_size(value.size),
	}
}

@(private = "package")
to_button_options :: proc(value: Button_Options) -> ui.Fit_Button_Options {
	return {
		style = value.style,
		disabled = value.disabled,
		web_form_id = value.web_form_id,
		track = to_track(value.track),
		size = to_size(value.size),
		activated = value.activated,
		action = {
			procedure = ui.Fit_Action_Proc(value.action.procedure),
			tagged_procedure = ui.Fit_Tagged_Action_Proc(value.action.tagged_procedure),
			userdata = value.action.user_data,
			tag = value.action.tag,
		},
	}
}

@(private = "package")
to_control_options :: proc(value: Control_Options) -> ui.Fit_Control_Options {
	return {track = to_track(value.track), size = to_size(value.size), changed = value.changed}
}

@(private = "package")
to_leaf_options :: proc(value: Leaf_Options) -> ui.Fit_Leaf_Options {
	return {track = to_track(value.track), size = to_size(value.size)}
}

@(private = "package")
to_custom_options :: proc(value: Custom_Options) -> ui.Fit_Custom_Options {
	return {track = to_track(value.track), size = to_size(value.size), activated = value.activated}
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

@(private = "package")
from_listbox_result :: proc(value: ui.Listbox_Result) -> Listbox_Result {
	return {
		selection_changed = value.selection_changed,
		activated = value.activated,
		activated_index = value.activated_index,
		reveal = value.reveal,
		reveal_index = value.reveal_index,
	}
}

@(private = "package")
from_selectable_row_result :: proc(value: ui.Selectable_Row_Result) -> Selectable_Row_Result {
	return {value.hovered, value.pressed, value.held, value.selected, value.activated}
}
