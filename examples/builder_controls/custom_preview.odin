package main

import fit "ingot:fit"

preview_render :: proc(surface: ^fit.Surface, rect: fit.Rect, _: rawptr) -> bool {
	assert(surface != nil, "preview render: nil surface")
	assert(rect.w >= 0 && rect.h >= 0, "preview render: negative bounds")
	fit.surface_clip_begin(surface, rect)
	defer fit.surface_clip_end(surface)
	theme := fit.get_theme_tokens(surface)
	fit.fill_rect(surface, rect, theme.background_panel)
	inset := min(fit.px(surface, 8), min(rect.w, rect.h) / 2)
	inner := fit.Rect{rect.x + inset, rect.y + inset, rect.w - 2 * inset, rect.h - 2 * inset}
	fit.fill_rect(surface, inner, theme.background_active)
	return false
}
