package fit

import "ingot:ui"

Markdown_Context :: struct {
	inner:       ui.Markdown_Context,
	cull_top:    i32,
	cull_bottom: i32,
}

Markdown_Prepare_Status :: ui.Markdown_Prepare_Status

Markdown_Prepared :: struct {
	inner: ui.Markdown_Prepared,
}

Text_Span :: struct {
	text:      string,
	raw_start: int,
	raw_end:   int,
	bold:      bool,
	pill:      bool,
	code:      bool,
	link:      bool,
	href:      string,
}
#assert(size_of(Text_Span) == size_of(ui.Text_Span))
#assert(align_of(Text_Span) == align_of(ui.Text_Span))
#assert(offset_of(Text_Span, text) == offset_of(ui.Text_Span, text))
#assert(offset_of(Text_Span, raw_start) == offset_of(ui.Text_Span, raw_start))
#assert(offset_of(Text_Span, raw_end) == offset_of(ui.Text_Span, raw_end))
#assert(offset_of(Text_Span, bold) == offset_of(ui.Text_Span, bold))
#assert(offset_of(Text_Span, pill) == offset_of(ui.Text_Span, pill))
#assert(offset_of(Text_Span, code) == offset_of(ui.Text_Span, code))
#assert(offset_of(Text_Span, link) == offset_of(ui.Text_Span, link))
#assert(offset_of(Text_Span, href) == offset_of(ui.Text_Span, href))

Markdown_Context_Create :: proc(
	surface: ^Surface,
	workspace_files: []string = nil,
) -> Markdown_Context {
	u := surface_ui(surface)
	inner := ui.markdown_context(u.frame, workspace_files)
	return {inner = inner, cull_top = inner.cull_top, cull_bottom = inner.cull_bottom}
}

Markdown_Prepare :: proc(ctx: ^Markdown_Context, width: i32, text: string) -> Markdown_Prepared {
	assert(ctx != nil, "Fit.Markdown_Prepare: nil context")
	ctx.inner.cull_top = ctx.cull_top
	ctx.inner.cull_bottom = ctx.cull_bottom
	return {inner = ui.markdown_prepare(&ctx.inner, width, text)}
}

Markdown_Prepared_Measure :: proc(
	ctx: ^Markdown_Context,
	prepared: ^Markdown_Prepared,
	out_width: ^i32 = nil,
) -> i32 {
	assert(ctx != nil && prepared != nil, "Fit.Markdown_Prepared_Measure: invalid argument")
	return ui.markdown_prepared_measure(&ctx.inner, &prepared.inner, out_width)
}

Markdown_Prepared_Hit_Test :: proc(
	ctx: ^Markdown_Context,
	prepared: ^Markdown_Prepared,
	x, y, mouse_x, mouse_y: i32,
) -> int {
	assert(ctx != nil && prepared != nil, "Fit.Markdown_Prepared_Hit_Test: invalid argument")
	return ui.markdown_prepared_hit_test(&ctx.inner, &prepared.inner, x, y, mouse_x, mouse_y)
}

Markdown_Prepared_Source_Y :: proc(
	ctx: ^Markdown_Context,
	prepared: ^Markdown_Prepared,
	offset: int,
) -> i32 {
	assert(ctx != nil && prepared != nil, "Fit.Markdown_Prepared_Source_Y: invalid argument")
	return ui.markdown_prepared_source_y(&ctx.inner, &prepared.inner, offset)
}

Markdown_Prepared_Draw :: proc(
	ctx: ^Markdown_Context,
	prepared: ^Markdown_Prepared,
	rect: Rect,
	color: Color,
	selection_start: int = -1,
	selection_end: int = -1,
	out_width: ^i32 = nil,
) -> i32 {
	assert(ctx != nil && prepared != nil, "Fit.Markdown_Prepared_Draw: invalid argument")
	ctx.inner.cull_top = ctx.cull_top
	ctx.inner.cull_bottom = ctx.cull_bottom
	return ui.markdown_prepared_draw(
		&ctx.inner,
		&prepared.inner,
		to_rect(rect),
		ui.Color(color),
		selection_start,
		selection_end,
		out_width,
	)
}

Markdown_Measure :: proc(
	ctx: ^Markdown_Context,
	width: i32,
	text: string,
	out_width: ^i32,
) -> i32 {
	assert(ctx != nil, "Fit.Markdown_Measure: nil context")
	ctx.inner.cull_top = ctx.cull_top
	ctx.inner.cull_bottom = ctx.cull_bottom
	return ui.measure_markdown(&ctx.inner, width, text, out_width)
}

Markdown_Hit_Test :: proc(
	ctx: ^Markdown_Context,
	x, y, width: i32,
	text: string,
	mouse_x, mouse_y: i32,
) -> int {
	assert(ctx != nil, "Fit.Markdown_Hit_Test: nil context")
	ctx.inner.cull_top = ctx.cull_top
	ctx.inner.cull_bottom = ctx.cull_bottom
	return ui.hit_test_markdown(&ctx.inner, x, y, width, text, mouse_x, mouse_y)
}

Markdown_Source_Y :: proc(ctx: ^Markdown_Context, width: i32, text: string, offset: int) -> i32 {
	assert(ctx != nil, "Fit.Markdown_Source_Y: nil context")
	assert(offset >= 0 && offset <= len(text), "Fit.Markdown_Source_Y: invalid offset")
	return ui.markdown_source_y(&ctx.inner, width, text, offset)
}

Markdown_Draw :: proc(
	ctx: ^Markdown_Context,
	rect: Rect,
	text: string,
	color: Color,
	selection_start: int = -1,
	selection_end: int = -1,
	out_width: ^i32 = nil,
) -> i32 {
	assert(ctx != nil, "Fit.Markdown_Draw: nil context")
	ctx.inner.cull_top = ctx.cull_top
	ctx.inner.cull_bottom = ctx.cull_bottom
	return ui.markdown_draw(
		&ctx.inner,
		to_rect(rect),
		text,
		ui.Color(color),
		selection_start,
		selection_end,
		out_width,
	)
}

Markdown_Parse_Inline :: proc(text: string, allocator := context.temp_allocator) -> []Text_Span {
	return transmute([]Text_Span)ui.parse_inline_spans_with(text, allocator)
}

Workspace_Reference_Path :: proc(reference: string) -> string {
	return ui.workspace_reference_path(reference)
}

Workspace_Has_Path :: proc(workspace_files: []string, reference: string) -> bool {
	return ui.workspace_has_path_with(workspace_files, reference)
}

Diff_Row_Kind :: ui.Diff_Row_Kind

Diff_Row :: struct {
	kind:   Diff_Row_Kind,
	old_no: int,
	new_no: int,
	text:   string,
}
#assert(size_of(Diff_Row) == size_of(ui.Diff_Row))
#assert(align_of(Diff_Row) == align_of(ui.Diff_Row))
#assert(offset_of(Diff_Row, kind) == offset_of(ui.Diff_Row, kind))
#assert(offset_of(Diff_Row, old_no) == offset_of(ui.Diff_Row, old_no))
#assert(offset_of(Diff_Row, new_no) == offset_of(ui.Diff_Row, new_no))
#assert(offset_of(Diff_Row, text) == offset_of(ui.Diff_Row, text))

Diff_Parse_Result :: struct {
	rows:      []Diff_Row,
	truncated: bool,
	malformed: bool,
}

Diff_Layout :: ui.Diff_Layout

Diff_View_Options :: struct {
	layout:          Diff_Layout,
	max_rows:        int,
	selected:        bool,
	semantic_label:  string,
	field_id:        string,
	minimum_columns: i32,
}

Diff_View_Result :: struct {
	next_y:     i32,
	shown:      int,
	hidden:     int,
	used_split: bool,
}

Diff_Parse_Hunk_Header :: proc(line: string) -> (old_start, new_start: int) {
	return ui.parse_hunk_header(line)
}

Surface_Diff_Parse :: proc(surface: ^Surface, text: string) -> Diff_Parse_Result {
	u := surface_ui(surface)
	parsed := ui.parse_unified_diff(u.frame, text)
	rows := ui.frame_view_items(u.frame, parsed.rows)
	return {transmute([]Diff_Row)rows, parsed.truncated, parsed.malformed}
}

Surface_Diff_View :: proc(
	surface: ^Surface,
	x, y, width: i32,
	rows: []Diff_Row,
	options: Diff_View_Options = {},
) -> Diff_View_Result {
	u := surface_ui(surface)
	result := ui.diff_view(
		u.frame,
		x,
		y,
		width,
		transmute([]ui.Diff_Row)rows,
		{
			layout = options.layout,
			max_rows = options.max_rows,
			selected = options.selected,
			semantic_label = options.semantic_label,
			field_id = options.field_id,
			minimum_columns = options.minimum_columns,
		},
	)
	return {result.next_y, result.shown, result.hidden, result.used_split}
}

Frame_View_Items :: proc(surface: ^Surface, items: $T) -> T {
	_ = surface
	return items
}
