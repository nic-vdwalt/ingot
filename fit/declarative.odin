package fit

import "ingot:ui"

section :: proc(parent: Parent, title: string, options: Section_Options = {}) -> Parent {
	assert(title != "", "fit.section: empty title")
	section := column(parent, options.container)
	label(section, title, options.title)
	return section
}

card :: proc(parent: Parent, options: Card_Options = {}) -> Parent {
	container := options.container
	kind := options.kind
	if kind == .App do kind = .Card
	radius := options.radius
	if radius == .None do radius = .MD
	border := options.border
	if border == .None do border = .Hairline
	container.effects.surface = {
		enabled   = true,
		kind      = kind,
		state     = options.state,
		radius    = radius,
		border    = border,
		elevation = options.elevation,
	}
	return column(parent, container)
}

compact :: proc(builder: ^Builder, breakpoint: i32 = 640) -> bool {
	assert(builder != nil && builder.bound, "fit.compact: builder not bound")
	assert(breakpoint > 0, "fit.compact: non-positive breakpoint")
	return ui.compact(&builder.root, breakpoint)
}

canvas_leaf :: proc(
	parent: Parent,
	options: Canvas_Options,
	render: Render_Proc,
	user_data: rawptr = nil,
) {
	assert(render != nil, "fit.canvas_leaf: nil render callback")
	assert(options.intrinsic.w >= 0 && options.intrinsic.h >= 0, "fit.canvas_leaf: invalid size")
	custom_intrinsic(
		parent,
		{render = render, user_data = user_data, intrinsic = options.intrinsic},
		{track = options.track, size = options.size, activated = options.activated},
	)
}
