package main

import fit "ingot:fit"

preview_render :: proc(surface: ^fit.Surface, rect: fit.Rect, _: rawptr) -> bool {
	assert(surface != nil, "preview render: nil surface")
	assert(rect.w >= 0 && rect.h >= 0, "preview render: negative bounds")
	fit.Surface_Clip_Begin(surface, rect)
	defer fit.Surface_Clip_End(surface)
	theme := fit.Get_Theme_Tokens(surface)
	fit.Fill_Rect(surface, rect, theme.background_panel)
	inset := min(fit.Px(surface, 8), min(rect.w, rect.h) / 2)
	inner := fit.Rect{rect.x + inset, rect.y + inset, rect.w - 2 * inset, rect.h - 2 * inset}
	fit.Fill_Rect(surface, inner, theme.background_active)
	return false
}
