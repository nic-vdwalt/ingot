package fit

import "ingot:ui"

Markdown_Context :: struct {
	inner:       ui.Markdown_Context,
	cull_top:    i32,
	cull_bottom: i32,
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

Markdown_Context_Create :: proc(
	surface: ^Surface,
	workspace_files: []string = nil,
) -> Markdown_Context {
	u := surface_ui(surface)
	inner := ui.markdown_context(u.frame, workspace_files)
	return {inner = inner, cull_top = inner.cull_top, cull_bottom = inner.cull_bottom}
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
	inner := ui.parse_inline_spans_with(text, allocator)
	result := make([]Text_Span, len(inner), allocator)
	for span, index in inner {
		result[index] = {
			text      = span.text,
			raw_start = span.raw_start,
			raw_end   = span.raw_end,
			bold      = span.bold,
			pill      = span.pill,
			code      = span.code,
			link      = span.link,
			href      = span.href,
		}
	}
	return result
}

Workspace_Reference_Path :: proc(reference: string) -> string {
	return ui.workspace_reference_path(reference)
}

Workspace_Has_Path :: proc(workspace_files: []string, reference: string) -> bool {
	return ui.workspace_has_path_with(workspace_files, reference)
}

Diff_Row_Kind :: enum u8 {
	Context,
	Add,
	Del,
	Hunk,
	Metadata,
}

Diff_Row :: struct {
	kind:   Diff_Row_Kind,
	old_no: int,
	new_no: int,
	text:   string,
}

Diff_Parse_Result :: struct {
	rows:      []Diff_Row,
	truncated: bool,
	malformed: bool,
}

Diff_Layout :: enum u8 {
	Auto,
	Unified,
	Split,
}

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
	result_rows := make([]Diff_Row, len(rows), context.temp_allocator)
	for row, index in rows {
		result_rows[index] = {Diff_Row_Kind(row.kind), row.old_no, row.new_no, row.text}
	}
	return {result_rows, parsed.truncated, parsed.malformed}
}

Surface_Diff_View :: proc(
	surface: ^Surface,
	x, y, width: i32,
	rows: []Diff_Row,
	options: Diff_View_Options = {},
) -> Diff_View_Result {
	u := surface_ui(surface)
	inner_rows := make([]ui.Diff_Row, len(rows), context.temp_allocator)
	for row, index in rows {
		inner_rows[index] = {ui.Diff_Row_Kind(row.kind), row.old_no, row.new_no, row.text}
	}
	result := ui.diff_view(
		u.frame,
		x,
		y,
		width,
		inner_rows,
		{
			layout = ui.Diff_Layout(options.layout),
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
