// LIB-CANDIDATE: imports only core:*.
// Inline markdown (bold/code/links/pills), GFM tables, headings. Merged
// from openalloy/alloy (adds file pills via ui.workspace_has_path +
// PILL_OPEN/CLOSE from mention_pills.odin). No app-package imports.
package ui

// Tables beyond these dimensions are neither legible nor safe to process in one frame.
MARKDOWN_TABLE_COLS_MAX :: 64
MARKDOWN_TABLE_ROWS_MAX :: 512

Markdown_Prepare_Status :: enum u8 {
	Complete,
	Truncated,
	Malformed,
}

Markdown_Prepared :: struct {
	source:     string,
	width:      i32,
	content_w:  i32,
	content_h:  i32,
	generation: u64,
	status:     Markdown_Prepare_Status,
	layout:     ^Markdown_Layout,
}

Markdown_Context :: struct {
	frame:                      ^Ui_Frame,
	workspace_files:            []string,
	reference_resolver:         Markdown_Reference_Resolver,
	reference_resolver_context: rawptr,
	reference_cache:            map[string]bool,
	document:                   Widget_Id,
	link_focus:                 ^int,
	cull_top:                   i32,
	cull_bottom:                i32,
	// Link under the pointer this frame, filled in during the draw pass.
	//
	// Recorded while drawing rather than found by a second traversal: the draw
	// already computes each span's exact rect, and a separate hit-test pass
	// would have to reproduce that geometry and could disagree with it.
	//
	// Empty when the pointer is over no link. Borrowed from the text the
	// caller passed to markdown_draw, so it stays valid exactly as long as
	// that text does.
	hovered_link:               string,
	// Whether the pointer was pressed on that link this frame. This package
	// imports only core:*, so it cannot open a URL itself: activation is
	// reported and the application decides what following a link means.
	link_pressed:               bool,
}

markdown_context :: proc(
	frame: ^Ui_Frame,
	workspace_files: []string = nil,
	document: Widget_Id = WIDGET_ID_NONE,
	link_focus: ^int = nil,
	reference_resolver: Markdown_Reference_Resolver = nil,
	reference_resolver_context: rawptr = nil,
) -> Markdown_Context {
	assert(frame != nil && frame.open, "markdown_context: invalid frame")
	assert(len(workspace_files) >= 0, "markdown_context: invalid workspace files")
	assert(
		document != WIDGET_ID_NONE || link_focus == nil,
		"markdown_context: focus requires identity",
	)
	return Markdown_Context {
		frame = frame,
		workspace_files = workspace_files,
		reference_resolver = reference_resolver,
		reference_resolver_context = reference_resolver_context,
		reference_cache = make(map[string]bool, context.temp_allocator),
		document = document,
		link_focus = link_focus,
		cull_top = min(i32),
		cull_bottom = max(i32),
	}
}

markdown_line_culled :: proc(ctx: ^Markdown_Context, y, line_height: i32) -> bool {
	assert(ctx != nil && ctx.frame != nil, "markdown_line_culled: invalid context")
	assert(line_height > 0, "markdown_line_culled: invalid line height")
	return y + line_height < ctx.cull_top || y > ctx.cull_bottom
}

Heading_Match :: struct {
	text:       string,
	level:      int,
	prefix_len: int,
}

Text_Span :: struct {
	text:           string, // Display text without inline markers.
	raw_start:      int, // Complete source span start.
	raw_end:        int, // Complete source span end, exclusive.
	text_raw_start: int, // Source byte represented by text[0].
	text_raw_end:   int, // Source boundary represented by text[len(text)].
	bold:           bool,
	pill:           bool, // PILL_OPEN..PILL_CLOSE file-mention chip
	code:           bool, // `backtick` inline code; rendered as a file pill when it
	// names a real workspace path, else as inline-code text.
	link:           bool, // Rendered accent + underline, and activates on click.
	// Where a link span points. Held separately from `text` because the two
	// differ for [label](target) syntax: the label is what the reader sees,
	// the target is where the click goes. A bare URL sets both to the same
	// string, so a consumer never has to ask which spelling it came from.
	href:           string,
}

markdown_reference_resolves_cached :: proc(ctx: ^Markdown_Context, reference: string) -> bool {
	assert(ctx != nil, "markdown reference cache: nil ctx")
	if resolved, found := ctx.reference_cache[reference]; found do return resolved
	resolved := workspace_reference_resolves_with(
		ctx.workspace_files,
		reference,
		ctx.reference_resolver,
		ctx.reference_resolver_context,
	)
	ctx.reference_cache[reference] = resolved
	return resolved
}

Markdown_Table_Row :: struct {
	cells:  []string,
	starts: []int,
}

Markdown_Table_Widths :: [MARKDOWN_TABLE_COLS_MAX]i32
Markdown_Table_Heights :: [MARKDOWN_TABLE_ROWS_MAX]i32

Markdown_Table_Column_Bounds :: struct {
	max_w: Markdown_Table_Widths,
	min_w: Markdown_Table_Widths,
	floor: i32,
}
