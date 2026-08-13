package fit

import "ingot:ui"
import "ingot:ui_gfx"

@(private = "package")
to_session_config :: proc(config: Session_Config) -> ui_gfx.Session_Config {
	assert(config.user_scale >= 0, "Fit: negative user scale")
	return {user_scale = config.user_scale, semantics_enabled = config.semantics_enabled}
}

@(private = "package")
to_app_config :: proc(config: Config) -> ui_gfx.App_Config {
	assert(config.width >= 0 && config.height >= 0, "Fit: negative app extent")
	assert(config.target_fps >= 0, "Fit: negative target FPS")
	return {
		width = config.width,
		height = config.height,
		title = config.title,
		flags = config.flags,
		frame_pacing = ui_gfx.App_Frame_Pacing(config.frame_pacing),
		target_fps = config.target_fps,
		event_waiting = config.event_waiting,
		session = to_session_config(config.session),
	}
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
to_track :: proc(value: Track) -> ui.Track {
	return {
		kind = ui.Track_Kind(value.kind),
		basis = value.basis,
		weight = value.weight,
		percent = value.percent,
		min_size = value.min_size,
		max_size = value.max_size,
	}
}

@(private = "package")
to_transition :: proc(value: Transition) -> ui.Prepared_Transition {
	state := cast(^ui.Transition_Rect_State)value.state
	return {state = state, options = {speed = value.options.speed}}
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
	return {
		clip = value.clip,
		background = ui.Color(value.background),
		radius = ui.Radius(value.radius),
		border = ui.Border(value.border),
		border_color = ui.Color(value.border_color),
	}
}

@(private = "package")
to_container_options :: proc(value: Container_Options) -> ui.Prepared_Container_Options {
	return {
		gap = ui.Space(value.gap),
		padding = ui.Space(value.padding),
		align = ui.Cross_Align(value.align),
		justify = ui.Main_Align(value.justify),
		track = to_track(value.track),
		size = to_size(value.size),
		effects = to_effects(value.effects),
	}
}

@(private = "package")
to_flow_options :: proc(value: Flow_Options) -> ui.Prepared_Flow_Options {
	return {
		gap_x = ui.Space(value.gap_x),
		gap_y = ui.Space(value.gap_y),
		padding = ui.Space(value.padding),
		track = to_track(value.track),
		size = to_size(value.size),
		effects = to_effects(value.effects),
	}
}

@(private = "package")
to_grid_options :: proc(value: Grid_Options) -> ui.Prepared_Grid_Options {
	assert(value.columns > 0, "Fit.Grid: invalid columns")
	assert(value.row_height >= 0, "Fit.Grid: negative row height")
	return {
		columns = value.columns,
		row_height = value.row_height,
		gap_x = ui.Space(value.gap_x),
		gap_y = ui.Space(value.gap_y),
		padding = ui.Space(value.padding),
		track = to_track(value.track),
		size = to_size(value.size),
		effects = to_effects(value.effects),
	}
}

@(private = "package")
to_attachment_options :: proc(value: Attachment_Options) -> ui.Prepared_Attachment_Options {
	return {
		target_kind = ui.Attachment_Target_Kind(value.target_kind),
		target = ui.Prepared_Handle(value.target),
		target_screen = to_rect(value.target_screen),
		target_point = ui.Attachment_Point(value.target_point),
		self_point = ui.Attachment_Point(value.self_point),
		offset_x = value.offset_x,
		offset_y = value.offset_y,
		z = ui.Z_Order(value.z),
		claim = value.claim,
		clamp_to_viewport = value.clamp_to_viewport,
		transition = to_transition(value.transition),
	}
}

@(private = "package")
to_label_options :: proc(value: Label_Options) -> ui.Fit_Label_Options {
	return {
		role = ui.Text_Role(value.role),
		ink = ui.Ink(value.ink),
		wrap = value.wrap,
		track = to_track(value.track),
		size = to_size(value.size),
	}
}

@(private = "package")
to_button_options :: proc(value: Button_Options) -> ui.Fit_Button_Options {
	return {
		style = ui.Btn_Style(value.style),
		disabled = value.disabled,
		web_form_id = value.web_form_id,
		track = to_track(value.track),
		size = to_size(value.size),
		activated = value.activated,
	}
}

@(private = "package")
to_control_options :: proc(value: Control_Options) -> ui.Fit_Control_Options {
	return {track = to_track(value.track), size = to_size(value.size), changed = value.changed}
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
