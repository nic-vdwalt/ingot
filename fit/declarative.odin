package fit

import "ingot:ui"

Section :: proc(builder: ^Builder, title: string, options: Section_Options = {}) {
	assert(builder != nil && builder.bound, "Fit.Section: builder not bound")
	assert(title != "", "Fit.Section: empty title")
	Column(builder, options.container)
	Label(builder, title, options.title)
}

Card :: proc(builder: ^Builder, options: Card_Options = {}) {
	assert(builder != nil && builder.bound, "Fit.Card: builder not bound")
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
	Column(builder, container)
}

Compact :: proc(builder: ^Builder, breakpoint: i32 = 640) -> bool {
	assert(builder != nil && builder.bound, "Fit.Compact: builder not bound")
	assert(breakpoint > 0, "Fit.Compact: non-positive breakpoint")
	return ui.compact(&builder.root, breakpoint)
}

Canvas_Leaf :: proc(
	builder: ^Builder,
	options: Canvas_Options,
	render: Render_Proc,
	userdata: rawptr = nil,
) {
	assert(builder != nil && builder.bound, "Fit.Canvas_Leaf: builder not bound")
	assert(render != nil, "Fit.Canvas_Leaf: nil render callback")
	assert(options.intrinsic.w >= 0 && options.intrinsic.h >= 0, "Fit.Canvas_Leaf: invalid size")
	custom_intrinsic(
		builder,
		{render = render, userdata = userdata, intrinsic = options.intrinsic},
		{track = options.track, size = options.size, activated = options.activated},
	)
}
