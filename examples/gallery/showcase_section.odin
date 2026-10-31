package main

import fit "ingot:fit"

// Showcase section: the landing page. A hero card pairs the live GPU-3D
// planet (showcase.odin) with live stats and caller-owned controls, and an
// explore grid links every other section. Everything here is ordinary
// immediate-mode composition; the only new capability it leans on is the
// texture paint primitive that puts the 3D target inside the card.

SHOWCASE_WIDE_MIN :: 760
// Logical height the info column needs at 1x: title, tagline, two pill rows,
// five stat rows, toggle, slider, tabs, and a button with their gaps. The card
// is drawn before its contents, so its height is decided up front.
SHOWCASE_INFO_H :: 440
SHOWCASE_VIEW_H_MAX :: 440
SHOWCASE_EXPLORE_CELL_W :: 240
SHOWCASE_EXPLORE_CARD_H :: 96
SHOWCASE_PLAY_ID :: fit.Widget_Id(0x5300)
SHOWCASE_CARD_ID_BASE :: 0x5400

SHOWCASE_PILLS_TOP := [?]string{"WebGPU", "Native + WASM", "Immediate mode"}
SHOWCASE_PILLS_BOTTOM := [?]string{"Accessible", "Deterministic tests"}

showcase_info_region: fit.Region

draw_showcase :: proc(surface: ^fit.Surface, x, y0, w: i32) -> i32 {
	assert(surface != nil, "draw_showcase: nil surface")
	assert(w > 0, "draw_showcase: empty width")
	y := draw_showcase_hero(surface, x, y0, w)
	y += fit.px(surface, 20)
	label_h := fit.get_metrics(surface).line_height
	fit.surface_text_truncated(surface, "EXPLORE THE GALLERY", x, y, w, .Label, .Secondary)
	y += label_h + fit.px(surface, 8)
	return draw_showcase_explore(surface, x, y, w) + fit.px(surface, 16)
}

@(private = "file")
draw_showcase_hero :: proc(surface: ^fit.Surface, x, y, w: i32) -> i32 {
	assert(surface != nil && w > 0, "draw_showcase_hero: invalid argument")
	pad := fit.px(surface, 16)
	gap := fit.px(surface, 20)
	wide := w >= fit.px(surface, SHOWCASE_WIDE_MIN)
	inner_w := max(w - pad * 2, 1)
	info_h := fit.px(surface, SHOWCASE_INFO_H)
	view, info: fit.Rect
	card_h: i32
	if wide {
		view_w := (inner_w - gap) * 3 / 5
		view_h := min(view_w, fit.px(surface, SHOWCASE_VIEW_H_MAX))
		card_h = max(view_h, info_h) + pad * 2
		view = {x + pad, y + pad + (card_h - pad * 2 - view_h) / 2, view_w, view_h}
		info = {view.x + view_w + gap, y + pad, inner_w - view_w - gap, info_h}
	} else {
		view_h := min(inner_w, fit.px(surface, 360))
		card_h = view_h + gap + info_h + pad * 2
		view = {x + pad, y + pad, inner_w, view_h}
		info = {x + pad, view.y + view_h + gap, inner_w, info_h}
	}
	card := fit.Float_Rect{f32(x), f32(y), f32(w), f32(card_h)}
	fit.draw_surface(surface, card, .Card, .Rest, .LG, .Hairline, .Lifted)
	draw_showcase_view(surface, view)
	draw_showcase_info(surface, info)
	return y + card_h
}

@(private = "file")
draw_showcase_view :: proc(surface: ^fit.Surface, view: fit.Rect) {
	assert(surface != nil, "draw_showcase_view: nil surface")
	assert(view.w >= 0 && view.h >= 0, "draw_showcase_view: negative rect")
	if view.w <= 0 || view.h <= 0 do return
	backdrop := fit.Float_Rect{f32(view.x), f32(view.y), f32(view.w), f32(view.h)}
	fit.draw_surface(surface, backdrop, .Code, .Rest, .LG, .Hairline)
	fit.surface_clip_begin(surface, view)
	showcase_viewport(surface, &showcase, view)
	fit.surface_clip_end(surface)
	if !showcase_ready(&showcase) do return
	inset := fit.px(surface, 10)
	side := fit.px(surface, 30)
	play := fit.Rect{view.x + view.w - side - inset, view.y + inset, side, side}
	rotating := showcase.auto_rotate
	icon := fit.Icon.Pause if rotating else .Play
	label := "Pause rotation" if rotating else "Resume rotation"
	if fit.surface_icon_button(surface, SHOWCASE_PLAY_ID, icon, label, play) {
		showcase.auto_rotate = !showcase.auto_rotate
	}
	hint_h := fit.get_metrics(surface).line_height
	hint_y := view.y + view.h - hint_h - inset
	hint := "Drag to orbit \u00b7 Scroll to zoom \u00b7 Double-click to reset"
	fit.surface_text_truncated(
		surface,
		hint,
		view.x + inset,
		hint_y,
		view.w - inset * 2,
		.Note,
		.Muted,
	)
}

@(private = "file")
draw_showcase_info :: proc(surface: ^fit.Surface, info: fit.Rect) {
	assert(surface != nil, "draw_showcase_info: nil surface")
	assert(info.w > 0 && info.h > 0, "draw_showcase_info: empty rect")
	u := fit.region_open(
		surface,
		&showcase_info_region,
		{info.x, info.y, info.w, fit.ROOT_EXTENT_OPEN},
		{gap = .SM, scope = "showcase"},
	)
	fit.region_label(u, "Ingot", .Title, .Heading)
	fit.region_label(u, "One Odin source. Native and web.", .Body, .Secondary)
	fit.region_label(u, "Immediate-mode UI on WebGPU.", .Body, .Secondary)
	fit.region_row_begin(u, 26, gap = .XS, align = .Center)
	for pill in SHOWCASE_PILLS_TOP do _ = fit.region_status_pill(u, pill, .Accent)
	fit.region_row_end(u)
	fit.region_row_begin(u, 26, gap = .XS, align = .Center)
	for pill in SHOWCASE_PILLS_BOTTOM do _ = fit.region_status_pill(u, pill, .Accent)
	fit.region_row_end(u)
	draw_showcase_stats(surface, u)
	draw_showcase_controls(u, info.w)
	_ = fit.region_close(u)
}

@(private = "file")
draw_showcase_stats :: proc(surface: ^fit.Surface, u: ^fit.Region) {
	assert(surface != nil && u != nil, "draw_showcase_stats: nil argument")
	ready := showcase_ready(&showcase)
	fps := fit.surface_fps(surface)
	frame_ms := f64(fit.surface_frame_time(surface)) * 1000
	fit.region_key_value(u, "Frame rate", label_int("", i64(fps), " fps"))
	fit.region_key_value(u, "Frame time", label_float("", frame_ms, 1, " ms"))
	if !ready {
		fit.region_key_value(u, "Model", SHOWCASE_LOAD_ERROR_NAMES[showcase.load_error])
		return
	}
	triangles := i64(showcase.info.index_count / 3)
	fit.region_key_value(u, "Triangles", label_int("", triangles))
	fit.region_key_value(u, "Vertices", label_int("", i64(showcase.info.vertex_count)))
	target := label_join(
		label_int("", i64(showcase.target_w)),
		" x ",
		label_int("", i64(showcase.target_h)),
		" px",
	)
	fit.region_key_value(u, "Render target", target)
}

@(private = "file")
draw_showcase_controls :: proc(u: ^fit.Region, width: i32) {
	assert(u != nil, "draw_showcase_controls: nil region")
	assert(width > 0, "draw_showcase_controls: empty width")
	_ = fit.region_toggle(
		u,
		"auto_rotate",
		"Auto-rotate",
		&showcase.auto_rotate,
		&showcase.toggle_motion,
	)
	_ = fit.region_slider(
		u,
		"speed",
		&showcase.speed_slider,
		&showcase.speed,
		0,
		SHOWCASE_SPEED_MAX,
		0.02,
		min(width, 260),
		"Rotation speed",
	)
	_ = fit.region_tab_bar(
		u,
		"look",
		SHOWCASE_LOOK_NAMES,
		&showcase.look,
		&showcase.look_motion,
	)
	_ = fit.region_tab_bar(
		u,
		"lighting",
		LIGHTING_PRESET_NAMES,
		&showcase.lighting,
		&showcase.tabs_motion,
	)
	fit.region_row_begin(u, 32, gap = .SM)
	if fit.region_button(u, "reset_view", "Reset view", .Secondary) do showcase_reset_view(&showcase)
	fit.region_row_end(u)
}

// draw_showcase_explore is package-visible so tests can click a card at a
// known geometry without laying out the hero card first.
draw_showcase_explore :: proc(surface: ^fit.Surface, x, y, w: i32) -> i32 {
	assert(surface != nil && w > 0, "draw_showcase_explore: invalid argument")
	gap := fit.px(surface, 12)
	cell := fit.px(surface, SHOWCASE_EXPLORE_CELL_W)
	columns := clamp((w + gap) / (cell + gap), 1, 4)
	grid: fit.Grid_State
	fit.grid_begin(
		surface,
		&grid,
		{x, y, w, 0},
		columns,
		fit.px(surface, SHOWCASE_EXPLORE_CARD_H),
		gap,
		gap,
	)
	for s in Section {
		if s == .Showcase do continue
		draw_explore_card(surface, s, fit.grid_next(&grid))
	}
	used := fit.grid_end(&grid)
	return used.y + used.h
}

@(private = "file")
draw_explore_card :: proc(surface: ^fit.Surface, s: Section, rect: fit.Rect) {
	assert(surface != nil, "draw_explore_card: nil surface")
	assert(rect.w >= 0 && rect.h >= 0, "draw_explore_card: negative rect")
	if rect.w <= 0 || rect.h <= 0 do return
	area := fit.Float_Rect{f32(rect.x), f32(rect.y), f32(rect.w), f32(rect.h)}
	interaction := fit.interact(surface, area)
	if interaction.clicked do section_pending = s
	state := fit.Visual_State.Hover if interaction.hovered else .Rest
	elevation := fit.Elevation.Lifted if interaction.hovered else .Flat
	fit.draw_surface(surface, area, .Card, state, .MD, .Hairline, elevation)
	pad := fit.px(surface, 12)
	side := fit.px(surface, 20)
	metrics := fit.get_metrics(surface)
	fit.surface_clip_begin(surface, rect)
	icon := fit.Rect{rect.x + pad, rect.y + pad, side, side}
	fit.surface_icon(surface, SECTION_ICONS[s], icon, .Accent)
	title_x := icon.x + side + fit.px(surface, 8)
	title_w := rect.x + rect.w - pad - title_x
	fit.surface_text_truncated(
		surface,
		SECTION_NAMES[s],
		title_x,
		rect.y + pad,
		title_w,
		.Label,
		.Heading,
	)
	body_y := rect.y + pad + side + fit.px(surface, 6)
	note_color := fit.surface_theme_color(surface, .Secondary)
	note_line := metrics.font_note + fit.px(surface, 4)
	fit.surface_text_wrapped(
		surface,
		SECTION_BLURBS[s],
		rect.x + pad,
		body_y,
		rect.w - pad * 2,
		note_color,
		metrics.font_note,
		note_line,
	)
	fit.surface_clip_end(surface)
	fit.surface_semantic(surface, .Button, rect, SECTION_NAMES[s], description = SECTION_BLURBS[s])
}
