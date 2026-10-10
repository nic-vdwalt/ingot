package ui

@(private = "file")
markdown_prepared_validate :: proc(ctx: ^Markdown_Context, prepared: ^Markdown_Prepared) {
	assert(ctx != nil && ctx.frame != nil && ctx.frame.open, "markdown prepared: invalid context")
	assert(prepared != nil && prepared.width > 0, "markdown prepared: invalid layout")
	assert(prepared.generation == ctx.frame.scratch.generation, "markdown prepared: stale layout")
	assert(prepared.content_w >= 0 && prepared.content_h >= 0, "markdown prepared: invalid extent")
}

markdown_prepare :: proc(ctx: ^Markdown_Context, width: i32, source: string) -> Markdown_Prepared {
	assert(ctx != nil && ctx.frame != nil && ctx.frame.open, "markdown prepare: invalid context")
	assert(width > 0, "markdown prepare: non-positive width")
	allocator := ui_frame_allocator(ctx.frame)
	layout := new(Markdown_Layout, allocator)
	markdown_layout_init(layout, allocator)
	status := markdown_layout_prepare(ctx, layout, width, source)
	ctx.hovered_link = ""
	ctx.link_pressed = false
	return {
		source = layout.source,
		width = width,
		content_w = layout.content_w,
		content_h = layout.content_h,
		generation = ctx.frame.scratch.generation,
		status = status,
		layout = layout,
	}
}

// measure_markdown returns the pixel height draw_markdown would produce for
// `text` at `width`, without any visible output. It calls draw_markdown inside a
// zero-size scissor so all raylib draws are clipped (cheap, invisible) while the
// identical layout math runs - guaranteeing the scroll predictor matches what is
// actually rendered. draw_markdown performs no input handling, so re-running it
// here is side-effect free.
measure_markdown :: proc(
	ctx: ^Markdown_Context,
	width: i32,
	text: string,
	out_w: ^i32 = nil,
) -> i32 {
	assert(ctx != nil, "measure_markdown: nil ctx")
	assert(out_w != nil, "measure_markdown: nil out_w")
	if len(text) == 0 do return 0
	prepared := markdown_prepare(ctx, width, text)
	return markdown_prepared_measure(ctx, &prepared, out_w)
}

markdown_prepared_measure :: proc(
	ctx: ^Markdown_Context,
	prepared: ^Markdown_Prepared,
	out_w: ^i32 = nil,
) -> i32 {
	markdown_prepared_validate(ctx, prepared)
	if out_w != nil do out_w^ = prepared.content_w
	when UI_TELEMETRY_ENABLED do ctx.frame.markdown_telemetry.measure_queries += 1
	return prepared.content_h
}

markdown_prepared_draw :: proc(
	ctx: ^Markdown_Context,
	prepared: ^Markdown_Prepared,
	bounds: Rect_I32,
	color: Color,
	sel_start: int = -1,
	sel_end: int = -1,
	out_w: ^i32 = nil,
) -> i32 {
	assert(ctx != nil && prepared != nil, "markdown prepared draw: invalid argument")
	markdown_prepared_validate(ctx, prepared)
	assert(bounds.w == prepared.width, "markdown prepared draw: width mismatch")
	when UI_TELEMETRY_ENABLED do ctx.frame.markdown_telemetry.draw_queries += 1
	return markdown_layout_draw(ctx, prepared.layout, bounds, color, sel_start, sel_end, out_w)
}

markdown_prepared_hit_test :: proc(
	ctx: ^Markdown_Context,
	prepared: ^Markdown_Prepared,
	x, y, mouse_x, mouse_y: i32,
) -> int {
	assert(ctx != nil && prepared != nil, "markdown prepared hit test: invalid argument")
	markdown_prepared_validate(ctx, prepared)
	when UI_TELEMETRY_ENABLED do ctx.frame.markdown_telemetry.hit_queries += 1
	return markdown_layout_hit_test(prepared.layout, x, y, mouse_x, mouse_y)
}

markdown_prepared_source_y :: proc(
	ctx: ^Markdown_Context,
	prepared: ^Markdown_Prepared,
	offset: int,
) -> i32 {
	assert(ctx != nil && prepared != nil, "markdown prepared source y: invalid argument")
	markdown_prepared_validate(ctx, prepared)
	assert(
		offset >= 0 && offset <= len(prepared.source),
		"markdown prepared source y: invalid offset",
	)
	when UI_TELEMETRY_ENABLED do ctx.frame.markdown_telemetry.source_y_queries += 1
	return markdown_layout_source_y(prepared.layout, offset)
}
