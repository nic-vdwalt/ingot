package fit

import "ingot:ui"
import "ingot:ui_gfx"

@(private = "package")
to_session_config :: proc(config: Session_Config) -> ui_gfx.Session_Config {
	assert(config.user_scale >= 0, "Fit: negative user scale")
	return {
		user_scale = config.user_scale,
		semantics_enabled = config.semantics_enabled,
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
		flags = config.flags,
		frame_pacing = ui_gfx.App_Frame_Pacing(config.frame_pacing),
		target_fps = config.target_fps,
		event_waiting = config.event_waiting,
		session = to_session_config(config.session),
	}
}

@(private = "package")
to_transition :: proc(value: Transition) -> ui.Prepared_Transition {
	return {state = value.state, options = value.options}
}

@(private = "package")
to_size :: proc(value: Size_Options) -> ui.Prepared_Size {
	return {
		width = value.width,
		height = value.height,
		aspect = value.aspect,
		transition = to_transition(value.transition),
	}
}

@(private = "package")
to_effects :: proc(value: Container_Effects) -> ui.Prepared_Container_Effects {
	return {
		clip = value.clip,
		background = value.background,
		radius = value.radius,
		border = value.border,
		border_color = value.border_color,
	}
}

@(private = "package")
to_container_options :: proc(value: Container_Options) -> ui.Prepared_Container_Options {
	return {
		gap = value.gap,
		padding = value.padding,
		align = value.align,
		justify = value.justify,
		track = value.track,
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
		track = value.track,
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
		gap_x = value.gap_x,
		gap_y = value.gap_y,
		padding = value.padding,
		track = value.track,
		size = to_size(value.size),
		effects = to_effects(value.effects),
	}
}

@(private = "package")
to_attachment_options :: proc(value: Attachment_Options) -> ui.Prepared_Attachment_Options {
	return {
		target_kind = value.target_kind,
		target = ui.Prepared_Handle(value.target),
		target_screen = value.target_screen,
		target_point = value.target_point,
		self_point = value.self_point,
		offset_x = value.offset_x,
		offset_y = value.offset_y,
		z = value.z,
		claim = value.claim,
		clamp_to_viewport = value.clamp_to_viewport,
		transition = to_transition(value.transition),
	}
}

@(private = "package")
to_label_options :: proc(value: Label_Options) -> ui.Fit_Label_Options {
	return {
		role = value.role,
		ink = value.ink,
		wrap = value.wrap,
		track = value.track,
		size = to_size(value.size),
	}
}

@(private = "package")
to_button_options :: proc(value: Button_Options) -> ui.Fit_Button_Options {
	return {
		style = value.style,
		disabled = value.disabled,
		web_form_id = value.web_form_id,
		track = value.track,
		size = to_size(value.size),
		activated = value.activated,
	}
}

@(private = "package")
to_custom_options :: proc(value: Custom_Options) -> ui.Fit_Custom_Options {
	return {
		track = value.track,
		size = to_size(value.size),
		activated = value.activated,
	}
}
