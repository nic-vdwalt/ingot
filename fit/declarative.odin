package fit

import "ingot:ui"

Section :: proc(parent: Parent, title: string, options: Section_Options = {}) -> Parent {
	assert(title != "", "Fit.Section: empty title")
	section := Column(parent, options.container)
	Label(section, title, options.title)
	return section
}

Card :: proc(parent: Parent, options: Card_Options = {}) -> Parent {
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
	return Column(parent, container)
}

Compact :: proc(builder: ^Builder, breakpoint: i32 = 640) -> bool {
	assert(builder != nil && builder.bound, "Fit.Compact: builder not bound")
	assert(breakpoint > 0, "Fit.Compact: non-positive breakpoint")
	return ui.compact(&builder.root, breakpoint)
}

Canvas_Leaf :: proc(
	parent: Parent,
	options: Canvas_Options,
	render: Render_Proc,
	user_data: rawptr = nil,
) {
	assert(render != nil, "Fit.Canvas_Leaf: nil render callback")
	assert(options.intrinsic.w >= 0 && options.intrinsic.h >= 0, "Fit.Canvas_Leaf: invalid size")
	custom_intrinsic(
		parent,
		{render = render, user_data = user_data, intrinsic = options.intrinsic},
		{track = options.track, size = options.size, activated = options.activated},
	)
}
