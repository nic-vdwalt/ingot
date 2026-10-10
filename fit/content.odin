package fit

import "ingot:ui"

Variable_List_Index :: struct {
	inner:   ui.Variable_List_Index,
	heights: []i64,
	total:   i64,
}
Variable_List_Window :: ui.Variable_List_Window
variable_list_init :: proc(index: ^Variable_List_Index) {
	assert(index != nil)
	ui.variable_list_init(&index.inner)
}
variable_list_destroy :: proc(index: ^Variable_List_Index) {
	assert(index != nil)
	ui.variable_list_destroy(&index.inner)
	index^ = {}
}
variable_list_reset :: proc(index: ^Variable_List_Index, heights: []i64) -> bool {
	assert(index != nil)
	if !ui.variable_list_reset(&index.inner, heights) do return false
	index.heights = index.inner.heights[:]
	index.total = index.inner.total
	return true
}
variable_list_append :: proc(index: ^Variable_List_Index, height: i64) -> bool {
	assert(index != nil)
	assert(index.inner.allocator.procedure != nil)
	ok := ui.variable_list_append(&index.inner, height)
	index.heights = index.inner.heights[:]
	index.total = index.inner.total
	return ok
}

variable_list_update :: proc(index: ^Variable_List_Index, offset: int, height: i64) -> bool {
	assert(index != nil)
	if !ui.variable_list_update(&index.inner, offset, height) do return false
	index.total = index.inner.total
	return true
}
variable_list_prefix :: proc(index: ^Variable_List_Index, end: int) -> i64 {
	assert(index != nil)
	return ui.variable_list_prefix(&index.inner, end)
}
variable_list_visible :: proc(
	index: ^Variable_List_Index,
	scroll: f64,
	height: i32,
) -> Variable_List_Window {
	assert(index != nil)
	return ui.variable_list_window(&index.inner, scroll, height)
}

Markdown_Reference_Resolver :: #type proc(
	reference: string,
	workspace_files: []string,
	resolver_context: rawptr,
) -> bool

Markdown_Context :: struct {
	inner:       ui.Markdown_Context,
	cull_top:    i32,
	cull_bottom: i32,
}

Markdown_Prepare_Status :: ui.Markdown_Prepare_Status

Markdown_Layout :: struct {
	inner: ui.Markdown_Layout,
}

markdown_layout_init :: proc(layout: ^Markdown_Layout) {
	assert(layout != nil)
	assert(!layout.inner.initialized)
	ui.markdown_layout_init(&layout.inner)
}

markdown_layout_destroy :: proc(layout: ^Markdown_Layout) {
	assert(layout != nil)
	ui.markdown_layout_destroy(&layout.inner)
}

markdown_layout_prepare :: proc(
	ctx: ^Markdown_Context,
	layout: ^Markdown_Layout,
	width: i32,
	source: string,
) -> Markdown_Prepare_Status {
	assert(ctx != nil && layout != nil)
	assert(width > 0)
	return ui.markdown_layout_prepare(&ctx.inner, &layout.inner, width, source)
}

markdown_layout_measure :: proc(layout: ^Markdown_Layout) -> (width, height: i32) {
	assert(layout != nil)
	return ui.markdown_layout_measure(&layout.inner)
}

markdown_layout_bytes :: proc(layout: ^Markdown_Layout) -> u64 {
	assert(layout != nil)
	return ui.markdown_layout_owned_bytes(&layout.inner)
}

markdown_layout_draw :: proc(
	ctx: ^Markdown_Context,
	layout: ^Markdown_Layout,
	rect: Rect,
	color: Color,
	selection_start: int = -1,
	selection_end: int = -1,
	out_width: ^i32 = nil,
) -> i32 {
	assert(ctx != nil && layout != nil)
	ctx.inner.cull_top = ctx.cull_top
	ctx.inner.cull_bottom = ctx.cull_bottom
	return ui.markdown_layout_draw(
		&ctx.inner,
		&layout.inner,
		rect,
		color,
		selection_start,
		selection_end,
		out_width,
	)
}

markdown_layout_hit_test :: proc(layout: ^Markdown_Layout, x, y, mouse_x, mouse_y: i32) -> int {
	assert(layout != nil)
	return ui.markdown_layout_hit_test(&layout.inner, x, y, mouse_x, mouse_y)
}

markdown_layout_source_y :: proc(layout: ^Markdown_Layout, offset: int) -> i32 {
	assert(layout != nil)
	return ui.markdown_layout_source_y(&layout.inner, offset)
}

Markdown_Prepared :: struct {
	inner: ui.Markdown_Prepared,
}

Text_Span :: ui.Text_Span

markdown_context_create :: proc(
	surface: ^Surface,
	workspace_files: []string = nil,
	reference_resolver: Markdown_Reference_Resolver = nil,
	reference_resolver_context: rawptr = nil,
) -> Markdown_Context {
	u := surface_ui(surface)
	ui_resolver := cast(ui.Markdown_Reference_Resolver)reference_resolver
	inner := ui.markdown_context(
		u.frame,
		workspace_files,
		reference_resolver = ui_resolver,
		reference_resolver_context = reference_resolver_context,
	)
	return {inner = inner, cull_top = inner.cull_top, cull_bottom = inner.cull_bottom}
}

markdown_prepare :: proc(ctx: ^Markdown_Context, width: i32, text: string) -> Markdown_Prepared {
	assert(ctx != nil, "fit.markdown_prepare: nil context")
	ctx.inner.cull_top = ctx.cull_top
	ctx.inner.cull_bottom = ctx.cull_bottom
	return {inner = ui.markdown_prepare(&ctx.inner, width, text)}
}

markdown_prepared_measure :: proc(
	ctx: ^Markdown_Context,
	prepared: ^Markdown_Prepared,
	out_width: ^i32 = nil,
) -> i32 {
	assert(ctx != nil && prepared != nil, "fit.markdown_prepared_measure: invalid argument")
	return ui.markdown_prepared_measure(&ctx.inner, &prepared.inner, out_width)
}

markdown_prepared_hit_test :: proc(
	ctx: ^Markdown_Context,
	prepared: ^Markdown_Prepared,
	x, y, mouse_x, mouse_y: i32,
) -> int {
	assert(ctx != nil && prepared != nil, "fit.markdown_prepared_hit_test: invalid argument")
	return ui.markdown_prepared_hit_test(&ctx.inner, &prepared.inner, x, y, mouse_x, mouse_y)
}

markdown_prepared_source_y :: proc(
	ctx: ^Markdown_Context,
	prepared: ^Markdown_Prepared,
	offset: int,
) -> i32 {
	assert(ctx != nil && prepared != nil, "fit.markdown_prepared_source_y: invalid argument")
	return ui.markdown_prepared_source_y(&ctx.inner, &prepared.inner, offset)
}

markdown_prepared_draw :: proc(
	ctx: ^Markdown_Context,
	prepared: ^Markdown_Prepared,
	rect: Rect,
	color: Color,
	selection_start: int = -1,
	selection_end: int = -1,
	out_width: ^i32 = nil,
) -> i32 {
	assert(ctx != nil && prepared != nil, "fit.markdown_prepared_draw: invalid argument")
	ctx.inner.cull_top = ctx.cull_top
	ctx.inner.cull_bottom = ctx.cull_bottom
	return ui.markdown_prepared_draw(
		&ctx.inner,
		&prepared.inner,
		rect,
		color,
		selection_start,
		selection_end,
		out_width,
	)
}

markdown_measure :: proc(
	ctx: ^Markdown_Context,
	width: i32,
	text: string,
	out_width: ^i32,
) -> i32 {
	assert(ctx != nil, "fit.markdown_measure: nil context")
	ctx.inner.cull_top = ctx.cull_top
	ctx.inner.cull_bottom = ctx.cull_bottom
	return ui.measure_markdown(&ctx.inner, width, text, out_width)
}

markdown_hit_test :: proc(
	ctx: ^Markdown_Context,
	x, y, width: i32,
	text: string,
	mouse_x, mouse_y: i32,
) -> int {
	assert(ctx != nil, "fit.markdown_hit_test: nil context")
	ctx.inner.cull_top = ctx.cull_top
	ctx.inner.cull_bottom = ctx.cull_bottom
	return ui.hit_test_markdown(&ctx.inner, x, y, width, text, mouse_x, mouse_y)
}

markdown_source_y :: proc(ctx: ^Markdown_Context, width: i32, text: string, offset: int) -> i32 {
	assert(ctx != nil, "fit.markdown_source_y: nil context")
	assert(offset >= 0 && offset <= len(text), "fit.markdown_source_y: invalid offset")
	return ui.markdown_source_y(&ctx.inner, width, text, offset)
}

markdown_draw :: proc(
	ctx: ^Markdown_Context,
	rect: Rect,
	text: string,
	color: Color,
	selection_start: int = -1,
	selection_end: int = -1,
	out_width: ^i32 = nil,
) -> i32 {
	assert(ctx != nil, "fit.markdown_draw: nil context")
	ctx.inner.cull_top = ctx.cull_top
	ctx.inner.cull_bottom = ctx.cull_bottom
	return ui.markdown_draw(
		&ctx.inner,
		rect,
		text,
		color,
		selection_start,
		selection_end,
		out_width,
	)
}

markdown_parse_inline :: proc(text: string, allocator := context.temp_allocator) -> []Text_Span {
	return ui.parse_inline_spans_with(text, allocator)
}

workspace_reference_path :: proc(reference: string) -> string {
	return ui.workspace_reference_path(reference)
}

workspace_has_path :: proc(workspace_files: []string, reference: string) -> bool {
	return ui.workspace_has_path_with(workspace_files, reference)
}

Diff_Row_Kind :: ui.Diff_Row_Kind
Diff_Row :: ui.Diff_Row

Diff_Parse_Result :: struct {
	rows:      []Diff_Row,
	truncated: bool,
	malformed: bool,
}

Diff_Layout :: ui.Diff_Layout
Diff_View_Options :: ui.Diff_View_Options
Diff_View_Result :: ui.Diff_View_Result

diff_parse_hunk_header :: proc(line: string) -> (old_start, new_start: int) {
	return ui.parse_hunk_header(line)
}

surface_diff_parse :: proc(surface: ^Surface, text: string) -> Diff_Parse_Result {
	u := surface_ui(surface)
	parsed := ui.parse_unified_diff(u.frame, text)
	rows := ui.frame_view_items(u.frame, parsed.rows)
	return {rows, parsed.truncated, parsed.malformed}
}

surface_diff_view :: proc(
	surface: ^Surface,
	x, y, width: i32,
	rows: []Diff_Row,
	options: Diff_View_Options = {},
) -> Diff_View_Result {
	u := surface_ui(surface)
	return ui.diff_view(u.frame, x, y, width, rows, options)
}

frame_view_items :: proc(surface: ^Surface, items: $T) -> T {
	_ = surface
	return items
}
