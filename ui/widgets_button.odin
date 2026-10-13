package ui


// Button visual style variants.
Btn_Style :: enum {
	Primary, // Accent-colored bg, white text.
	Secondary, // Muted bg, brightens on hover, accent border on hover.
	Danger, // Red-tinted bg, light-red text.
	Ghost, // Nearly transparent, text-driven, accent color on hover.
}

// color_mix linearly blends a toward b by t (0..1) per channel, alpha
// included, so widgets can fade between two theme states over time.
color_mix :: proc(a, b: Color, t: f32) -> Color {
	assert(t >= 0 && t <= 1, "color_mix: t out of range")
	mix_u8 :: proc(x, y: u8, t: f32) -> u8 {
		return u8(clamp(f32(x) + (f32(y) - f32(x)) * t, 0, 255))
	}
	return Color {
		mix_u8(a.r, b.r, t),
		mix_u8(a.g, b.g, t),
		mix_u8(a.b, b.b, t),
		mix_u8(a.a, b.a, t),
	}
}

Button_State :: struct {
	hover: f32,
}

hover_anim_step :: proc(state: ^f32, hovered: bool, dt: f32) -> f32 {
	assert(state != nil, "hover_anim_step: nil state")
	target: f32 = 1 if hovered else 0
	eased(state, target, dt, 14.0)
	state^ = clamp(state^, 0, 1)
	return state^
}

hover_anim_frac :: proc(frame: ^Ui_Frame, state: ^Button_State, hovered: bool) -> f32 {
	assert(state != nil, "hover_anim_frac: nil state")
	if ui_frame_theme(frame).reduced_motion {
		state.hover = 1 if hovered else 0
		return state.hover
	}
	t := hover_anim_step(&state.hover, hovered, frame_input(frame).frame_time)
	target: f32 = 1 if hovered else 0
	if t != target do request_redraw(frame)
	assert(t >= 0 && t <= 1, "hover_anim_frac: fraction out of range")
	return t
}

// btn_palette returns the (rest, hovered) bg/fg/border colors for a style so
// btn can blend between them with the eased hover fraction.
@(private = "package")
btn_palette :: proc(theme: ^Theme, style: Btn_Style) -> (bg0, bg1, fg0, fg1, bd0, bd1: Color) {
	assert(theme != nil, "btn_palette: nil theme")
	switch style {
	case .Primary:
		return theme.button_bg,
			theme.button_hover,
			theme.button_text,
			theme.button_text,
			theme.border_color,
			theme.fg_accent
	case .Secondary:
		return theme.bg_active,
			theme.bg_hover,
			theme.fg_secondary,
			theme.fg_primary,
			theme.border_color,
			theme.fg_accent
	case .Danger:
		return theme.button_danger_bg,
			theme.button_danger_hover,
			theme.button_danger_fg,
			theme.button_danger_fg,
			Color{},
			theme.fg_error
	case .Ghost:
		return Color{}, theme.bg_hover, theme.fg_secondary, theme.fg_accent, Color{}, Color{}
	}
	return
}

// btn_gloss overlays a subtle top-half sheen on a button. The gradient quad
// is inset past the corner radius because scissor modes don't nest in gfx and
// a raw full-width quad would spill outside the rounded corners.
@(private = "file")
btn_gloss :: proc(frame: ^Ui_Frame, theme: ^Theme, rect: Rectangle) {
	assert(frame != nil && theme != nil, "btn_gloss: invalid argument")
	top := theme.button_primary_grad_top
	if top.a == 0 do return
	radius := radius_pixels(frame, .MD, min(rect.width, rect.height))
	inset := i32(radius) + 1
	gw := i32(rect.width) - inset * 2
	if gw <= 0 do return
	draw_rectangle_gradient_v(
		frame,
		i32(rect.x) + inset,
		i32(rect.y) + 1,
		gw,
		i32(rect.height / 2),
		top,
		theme.button_primary_grad_bottom,
	)
}

Button_Options :: struct {
	style:       Btn_Style,
	disabled:    bool,
	web_form_id: string,
	motion:      ^Control_Motion_State,
}

Button_Spec :: struct {
	id:      Widget_Id,
	label:   string,
	options: Button_Options,
}

button_spec :: proc(
	u: ^Ui,
	id: Widget_Id,
	label: string,
	options: Button_Options = {},
) -> Button_Spec {
	assert(u != nil && u.open, "button_spec: frame not open")
	assert(id != WIDGET_ID_NONE && label != "", "button_spec: invalid identity or label")
	return {id, label, options}
}

button_spec_size :: proc(u: ^Ui, spec: Button_Spec) -> Intrinsic_Size {
	assert(u != nil && u.open && u.frame != nil, "button_spec_size: invalid UI")
	assert(spec.id != WIDGET_ID_NONE && spec.label != "", "button_spec_size: invalid spec")
	metrics := ui_frame_metrics(u.frame)
	width := button_fit_width(u.frame, spec.label, metrics.FONT_SIZE_LABEL)
	return intrinsic_leaf(width, metrics.ROW_H_MD)
}

button_spec_at :: proc(u: ^Ui, spec: Button_Spec, rect: Rect_I32) -> bool {
	assert(u != nil && u.open, "button_spec_at: frame not open")
	assert(spec.id != WIDGET_ID_NONE && spec.label != "", "button_spec_at: invalid spec")
	enabled := !spec.options.disabled
	fo := focus(u, spec.id) if enabled && slot_visible(rect) else Focus_Opt{}
	return button_at(
		u.frame,
		rect,
		spec.label,
		spec.options.style,
		enabled = enabled,
		web_form_id = spec.options.web_form_id,
		focus = fo,
		widget = spec.id,
		motion = spec.options.motion,
	)
}

Button_At_Options :: struct {
	style:       Btn_Style,
	font_size:   i32,
	disabled:    bool,
	web_form_id: string,
	focus:       Focus_Opt,
	widget:      Widget_Id,
	motion:      ^Control_Motion_State,
}

// Unified button. Returns true if clicked this frame. Hover eases in/out via
// hover_anim_frac (frame-rate independent); pressed state darkens instantly.
// Pass `focus` to make the button keyboard-operable: clicking acquires the
// slot, the ring draws while focused, and Space/Enter activates.
//
// Widget tiers - see docs/ui-state.md#widget-tiers:
//   button      facade: a ^Ui plus a Widget_Id, carving a bounded slot.
//   button_at   explicit: a ^Ui_Frame plus an application-owned Rect_I32.
@(private = "package")
button_id :: proc(
	u: ^Ui,
	id: Widget_Id,
	label: string,
	style: Btn_Style = .Secondary,
	enabled: bool = true,
	web_form_id: string = "",
) -> bool {
	assert(u != nil && u.open, "button: frame not open")
	assert(id != WIDGET_ID_NONE, "button: zero stable id")
	assert(label != "", "button: empty accessible label")
	return button_id_options(
		u,
		id,
		label,
		{style = style, disabled = !enabled, web_form_id = web_form_id},
	)
}

@(private = "package")
button_string :: proc(
	u: ^Ui,
	key: string,
	label: string,
	style: Btn_Style = .Secondary,
	enabled: bool = true,
) -> bool {
	return button_id(u, id(u, key), label, style, enabled)
}

@(private = "package")
button_u64 :: proc(
	u: ^Ui,
	key: u64,
	label: string,
	style: Btn_Style = .Secondary,
	enabled: bool = true,
) -> bool {
	return button_id(u, id(u, key), label, style, enabled)
}

@(private = "package")
button_id_options :: proc(u: ^Ui, id: Widget_Id, label: string, options: Button_Options) -> bool {
	assert(u != nil && u.open, "button options: invalid UI")
	assert(id != WIDGET_ID_NONE && label != "", "button options: invalid identity")
	spec := button_spec(u, id, label, options)
	size := button_spec_size(u, spec)
	return button_spec_at(u, spec, slot_next_px(u, size.w, size.h))
}

@(private = "package")
button_string_options :: proc(u: ^Ui, key, label: string, options: Button_Options) -> bool {
	return button_id_options(u, id(u, key), label, options)
}

@(private = "package")
button_u64_options :: proc(u: ^Ui, key: u64, label: string, options: Button_Options) -> bool {
	return button_id_options(u, id(u, key), label, options)
}

button :: proc {
	button_id,
	button_string,
	button_u64,
	button_id_options,
	button_string_options,
	button_u64_options,
}

@(private = "file")
button_fit_width :: proc(frame: ^Ui_Frame, label: string, font_size: i32) -> i32 {
	assert(frame != nil && font_size > 0, "button_fit_width: invalid frame or size")
	assert(label != "", "button_fit_width: empty label")
	width :=
		measure_text_string_frame(frame, label, font_size) + ui_frame_metrics(frame).PADDING * 2
	assert(width > 0, "button_fit_width: invalid width")
	return width
}

// button_fit_w_frame returns the pixel width a rect-based button (button_at,
// icon_btn_at) needs to draw `label` without ellipsis truncation: the measured
// text plus the standard horizontal padding on both sides. Size caller-owned
// rects with it instead of hardcoding widths that silently truncate.
button_fit_w_frame :: proc(frame: ^Ui_Frame, label: string, font_size: i32 = 0) -> i32 {
	assert(frame != nil, "button_fit_w_frame: nil frame")
	assert(label != "", "button_fit_w_frame: empty label")
	metrics := ui_frame_metrics(frame)
	fs := font_size if font_size > 0 else metrics.FONT_SIZE_LABEL
	return button_fit_width(frame, label, fs)
}

// Fit a button label to the button box and return the drawn text, its
// measured width for centring, and the size to draw it at. An ellipsis hides
// what the button does, so it is the last resort: first the label may eat into
// the horizontal padding down to a minimal inset, then step down in size (no
// smaller than the note size) before it is truncated.
@(private = "file")
btn_label_fit :: proc(frame: ^Ui_Frame, label: string, w, font_size: i32) -> (string, i32, i32) {
	assert(frame != nil, "btn_label_fit: nil frame")
	assert(font_size > 0, "btn_label_fit: non-positive font size")
	assert(label != "", "btn_label_fit: empty label")
	metrics := ui_frame_metrics(frame)
	pad := metrics.CONTROL_GAP
	avail := max(w - pad * 2, 0)
	width := measure_text_string_frame(frame, label, font_size)
	if width <= avail do return label, width, font_size
	inset := max(pad / 4, 1)
	tight := max(w - inset * 2, 0)
	if width <= tight do return label, width, font_size
	drawn := frame_text_size(frame, font_size)
	min_size := max(min(metrics.FONT_SIZE_NOTE, font_size), 1)
	for size := font_size - 1; size >= min_size; size -= 1 {
		if frame_text_size(frame, size) >= drawn do continue
		smaller := measure_text_string_frame(frame, label, size)
		if smaller <= tight do return label, smaller, size
	}
	fitted := truncate_to_width_frame(frame, label, tight, font_size)
	return fitted, measure_text_string_frame(frame, fitted, font_size), font_size
}

// btn_sync_web_submit mirrors a button into the browser form overlay (web
// builds with an installed backend): the DOM submit button drives the
// browser's save-password and autofill flows. Returns true when the DOM form
// submitted this frame.
@(private = "file")
btn_sync_web_submit :: proc(
	frame: ^Ui_Frame,
	web_form_id, label: string,
	x, y, w, h: i32,
	style: Btn_Style,
	font_size: i32,
	enabled: bool,
) -> bool {
	assert(frame != nil, "btn_sync_web_submit: nil frame")
	if web_form_id == "" do return false
	backend := ui_frame_runtime(frame).web_form
	if backend.sync_submit_button == nil do return false
	return backend.sync_submit_button(
		backend.data,
		web_form_id,
		label,
		x,
		y,
		w,
		h,
		i32(style),
		font_size,
		enabled,
	)
}

button_at :: proc(
	frame: ^Ui_Frame,
	rect: Rect_I32,
	label: string,
	style: Btn_Style = .Secondary,
	font_size: i32 = 0,
	enabled: bool = true,
	web_form_id: string = "",
	focus: Focus_Opt = {},
	widget: Widget_Id = WIDGET_ID_NONE,
	motion: ^Control_Motion_State = nil,
	interaction_rect: ^Rect_I32 = nil,
) -> bool {
	assert(frame != nil, "button_at: nil frame")
	// Why assert: a nameless control is invisible to assistive tech.
	assert(label != "", "button_at: empty accessible label")
	x, y, w, h := rect.x, rect.y, rect.w, rect.h
	hit := rect
	if interaction_rect != nil do hit = interaction_rect^
	metrics := ui_frame_metrics(frame)
	fs := font_size if font_size > 0 else metrics.FONT_SIZE_LABEL
	style_theme := ui_frame_theme(frame)
	rrect := rect_f32(rect)
	it := interact(frame, rect_f32(hit))
	hovered := enabled && it.hovered
	clicked := enabled && it.clicked
	if enabled {
		focus_opt_click(frame, focus, hit.x, hit.y, hit.w, hit.h)
		clicked = clicked || focus_opt_activated(frame, focus, .Button, widget)
	}
	clicked =
		clicked || btn_sync_web_submit(frame, web_form_id, label, x, y, w, h, style, fs, enabled)
	if hovered do request_cursor(frame, .POINTING_HAND)

	// Painting is skipped for a button scrolled outside the enclosing pane;
	// interaction, focus, and semantics above and below still run, so a
	// culled button keeps its identity, tab order, and screen-reader record.
	// The scissor would discard this geometry at raster time anyway - the
	// saving is in never building, copying, and uploading it.
	culled := rect_culled_frame(frame, rect)
	hover_channel, press_channel: ^Transition_F32_State
	if motion != nil {
		hover_channel, press_channel = &motion.hover, &motion.press
	}
	t := control_motion_fraction(
		frame,
		hover_channel,
		1 if hovered else 0,
		snap = culled || !enabled,
	)
	pressed := hovered && is_mouse_button_down(frame, .LEFT)
	press := control_motion_fraction(
		frame,
		press_channel,
		1 if pressed else 0,
		snap = culled || !enabled,
	)
	if !culled {
		bg0, bg1, fg0, fg1, bd0, bd1 := btn_palette(style_theme, style)
		bg := color_mix(bg0, bg1, t)
		fg := color_mix(fg0, fg1, t)
		border := color_mix(bd0, bd1, t)
		// Pressed feedback while the mouse button is held over the button.
		if hovered &&
		   is_mouse_button_down(frame, .LEFT) &&
		   (style == .Primary || style == .Secondary) {
			bg = style_theme.button_pressed
		}
		if !enabled {
			bg = style_theme.button_disabled_bg
			// fg_disabled, not fg_muted_dim. Two roles for one concept meant a
			// disabled button and a disabled menu item rendered in different
			// colors in the same frame; fg_muted_dim is now Ink.Muted only.
			fg = style_theme.fg_disabled
			border = {}
		}

		button_surface_paint(frame, rrect, style, enabled, bg, border, press)
		if enabled && focus_opt_focused(focus) {
			draw_focus_ring(frame, x, y, w, h)
		}

		label_s, text_w, label_fs := btn_label_fit(frame, label, w, fs)
		nudge := button_label_nudge(frame, enabled && style != .Ghost, press)
		label_x := x + (w - text_w) / 2 + nudge
		label_y := y + (h - frame_text_size(frame, label_fs)) / 2 + nudge
		draw_text_string_frame(frame, label_s, label_x, label_y, label_fs, fg)
	}

	sem: Sem_State
	if !enabled do sem += {.Disabled}
	semantic_push(frame, .Button, rect, label, sem, focus, widget = widget)
	return clicked && enabled
}

button_surface_paint :: proc(
	frame: ^Ui_Frame,
	rect: Rectangle,
	style: Btn_Style,
	enabled: bool,
	background, border: Color,
	press: f32,
) {
	assert(frame != nil && frame.open, "button surface: invalid frame")
	assert(press >= 0 && press <= 1, "button surface: invalid press")
	if surface_is_pixel(frame) {
		button_surface_paint_pixel(frame, rect, style, enabled, background, border, press)
		return
	}
	draw_surface_colors(frame, rect, {bg = background}, border = .None)
	if style == .Primary && enabled do btn_gloss(frame, ui_frame_theme(frame), rect)
	draw_surface_colors(frame, rect, {border = border})
}

// button_surface_paint_pixel paints a button as a pixel sprite: hard shadow
// while up, notched face, then the notched outline. It has no bevel, which
// would thicken the outline on two sides only, and no gloss; a gradient has
// no place in a fixed palette.
@(private = "file")
button_surface_paint_pixel :: proc(
	frame: ^Ui_Frame,
	rect: Rectangle,
	style: Btn_Style,
	enabled: bool,
	background, border: Color,
	press: f32,
) {
	assert(frame != nil && frame.open, "button surface pixel: invalid frame")
	assert(press >= 0 && press <= 1, "button surface pixel: invalid press")
	if rect.width <= 0 || rect.height <= 0 do return
	solid := enabled && style != .Ghost
	// A pixel press has two frames, up and down; the eased press value only
	// picks which one is showing.
	down := press >= 0.5
	if solid && !down do draw_pixel_shadow(frame, rect, pixel_shadow_offset(frame, .Lifted))
	draw_pixel_fill(frame, rect, background)
	draw_pixel_border(frame, rect, border)
}

// button_label_nudge is how far a held pixel button's label moves down and
// right: one art pixel, so the face appears to sink into the shadow it was
// casting. Smooth buttons express the press through the shadow ease instead.
button_label_nudge :: proc(frame: ^Ui_Frame, enabled: bool, press: f32) -> i32 {
	assert(frame != nil, "button_label_nudge: nil frame")
	assert(press >= 0 && press <= 1, "button_label_nudge: invalid press")
	if !enabled || press < 0.5 || !surface_is_pixel(frame) do return 0
	return i32(art_pixel(frame))
}

button_with_options_at :: proc(
	frame: ^Ui_Frame,
	rect: Rect_I32,
	label: string,
	options: Button_At_Options,
) -> bool {
	assert(frame != nil, "button_at: nil frame")
	return button_at(
		frame,
		rect,
		label,
		options.style,
		options.font_size,
		!options.disabled,
		options.web_form_id,
		options.focus,
		options.widget,
		options.motion,
	)
}

// button_at_state is button_at plus caller-owned hover animation state.
button_at_state :: proc(
	frame: ^Ui_Frame,
	state: ^Button_State,
	rect: Rect_I32,
	label: string,
	style: Btn_Style = .Secondary,
	font_size: i32 = 0,
	enabled: bool = true,
	web_form_id: string = "",
	focus: Focus_Opt = {},
	widget: Widget_Id = WIDGET_ID_NONE,
	motion: ^Control_Motion_State = nil,
) -> bool {
	assert(state != nil, "button_at_state: nil state")
	assert(label != "", "button_at_state: empty accessible label")
	x, y, w, h := rect.x, rect.y, rect.w, rect.h
	metrics := ui_frame_metrics(frame)
	fs := font_size if font_size > 0 else metrics.FONT_SIZE_LABEL
	style_theme := ui_frame_theme(frame)
	rrect := rect_f32(rect)
	it := interact(frame, rrect)
	hovered := enabled && it.hovered
	clicked := enabled && it.clicked
	if enabled {
		focus_opt_click(frame, focus, x, y, w, h)
		clicked = clicked || focus_opt_activated(frame, focus, .Button, widget)
	}
	clicked =
		clicked || btn_sync_web_submit(frame, web_form_id, label, x, y, w, h, style, fs, enabled)
	if hovered do request_cursor(frame, .POINTING_HAND)
	culled := rect_culled_frame(frame, rect)
	if culled || !enabled do state.hover = 1 if hovered else 0
	t: f32
	press: f32 = 1 if hovered && is_mouse_button_down(frame, .LEFT) else 0
	if motion != nil {
		t = control_motion_fraction(
			frame,
			&motion.hover,
			1 if hovered else 0,
			snap = culled || !enabled,
		)
		press = control_motion_fraction(frame, &motion.press, press, snap = culled || !enabled)
		state.hover = t
	} else {
		t = hover_anim_frac(frame, state, hovered) if enabled && !culled else 0
	}
	bg0, bg1, fg0, fg1, bd0, bd1 := btn_palette(style_theme, style)
	bg := color_mix(bg0, bg1, t)
	fg := color_mix(fg0, fg1, t)
	border := color_mix(bd0, bd1, t)
	if hovered &&
	   is_mouse_button_down(frame, .LEFT) &&
	   (style == .Primary || style == .Secondary) {
		bg = style_theme.button_pressed
	}
	if !enabled {
		state.hover = 0
		bg = style_theme.button_disabled_bg
		// See button_at: one disabled ink across every surface.
		fg = style_theme.fg_disabled
		border = {}
	}
	if !culled {
		button_surface_paint(frame, rrect, style, enabled, bg, border, press)
		if enabled && focus_opt_focused(focus) do draw_focus_ring(frame, x, y, w, h)
		label_s, text_w, label_fs := btn_label_fit(frame, label, w, fs)
		nudge := button_label_nudge(frame, enabled && style != .Ghost, press)
		label_x := x + (w - text_w) / 2 + nudge
		label_y := y + (h - frame_text_size(frame, label_fs)) / 2 + nudge
		draw_text_string_frame(frame, label_s, label_x, label_y, label_fs, fg)
	}
	if semantic_will_emit(frame) {
		sem: Sem_State
		if !enabled do sem += {.Disabled}
		semantic_push(frame, .Button, rect, label, sem, focus, widget = widget)
	}
	return clicked && enabled
}


// Returns true if clicked this frame.
icon_btn_at :: proc(
	frame: ^Ui_Frame,
	rect: Rect_I32,
	label: string,
	enabled: bool = true,
	focus: Focus_Opt = {},
	widget: Widget_Id = WIDGET_ID_NONE,
) -> bool {
	assert(frame != nil, "icon_btn_at: nil frame")
	return button_at(
		frame,
		rect,
		label,
		.Ghost,
		ui_frame_metrics(frame).FONT_SIZE_LABEL,
		enabled,
		focus = focus,
		widget = widget,
	)
}

icon_button_at :: proc(
	frame: ^Ui_Frame,
	rect: Rect_I32,
	icon: Icon,
	accessible_label: string,
	enabled: bool = true,
	focus: Focus_Opt = {},
	widget: Widget_Id = WIDGET_ID_NONE,
) -> bool {
	assert(frame != nil && frame.open, "icon_button_at: invalid frame")
	assert(accessible_label != "", "icon_button_at: empty accessible label")
	interaction := interact(frame, rect_f32(rect))
	hovered := enabled && interaction.hovered
	clicked := enabled && interaction.clicked
	if enabled {
		focus_opt_click(frame, focus, rect.x, rect.y, rect.w, rect.h)
		clicked = clicked || focus_opt_activated(frame, focus, .Button, widget)
	}
	if hovered do request_cursor(frame, .POINTING_HAND)
	if !rect_culled_frame(frame, rect) {
		theme := ui_frame_theme(frame)
		background := theme.button_hover if hovered else theme.button_bg
		foreground := theme.fg_accent if hovered else theme.fg_primary
		if !enabled {
			background = theme.button_disabled_bg
			foreground = theme.fg_disabled
		}
		draw_rounded_fill(frame, rect_f32(rect), .MD, background)
		if enabled && focus_opt_focused(focus) {
			draw_focus_ring(frame, rect.x, rect.y, rect.w, rect.h)
		}
		draw_icon_frame(frame, icon, rect, foreground)
	}
	semantics: Sem_State
	if !enabled do semantics += {.Disabled}
	semantic_push(frame, .Button, rect, accessible_label, semantics, focus, widget = widget)
	return clicked && enabled
}

// kv_row_at draws a key on the left and a right-aligned value inside rect's
// width. Only the origin and width are used; the row is one text line tall.

// --- standardized back button ----------------------------------------------

// back_btn_w returns the width the standard back button occupies for a label,
// so callers can right-align it before drawing.
back_btn_w :: proc(frame: ^Ui_Frame, label: string) -> i32 {
	assert(frame != nil, "back_btn_w: nil frame")
	label_text: Label_Text
	label_text_string(&label_text, "\u2190 ")
	label_text_string(&label_text, label)
	txt := label_text_ctemp(&label_text)
	metrics := ui_frame_metrics(frame)
	return measure_text_frame(frame, txt, metrics.FONT_SIZE_LABEL) + metrics.CONTROL_GAP * 2
}

// back_btn draws the standard Ghost-style "← label" navigation button.
// Returns true if clicked this frame.
// back_btn_at is content-sized: only rect's origin is used, and the width
// comes from back_btn_w so a caller can reserve the slot before drawing.
back_btn_at :: proc(
	frame: ^Ui_Frame,
	rect: Rect_I32,
	label: string,
	focus: Focus_Opt = {},
	widget: Widget_Id = WIDGET_ID_NONE,
) -> bool {
	assert(frame != nil, "back_btn_at: nil frame")
	label_text: Label_Text
	label_text_string(&label_text, "\u2190 ")
	label_text_string(&label_text, label)
	txt := label_text_temp(&label_text)
	box := Rect_I32{rect.x, rect.y, back_btn_w(frame, label), ui_frame_sc(frame, 22)}
	return button_at(frame, box, txt, .Ghost, focus = focus, widget = widget)
}
