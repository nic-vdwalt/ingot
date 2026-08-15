// Text input: rendering - spellcheck integration, caret-aware line
// rendering, caret/selection drawing, and box chrome.
package ui

import "core:math"
import "core:strings"

// ti_spell scans the composer for misspelled words (memoized) and opens the
// suggestions menu on right-click over one. Only the chat composer qualifies
// (caret-aware, with pills + undo).
@(private = "file")
ti_spell :: proc(ctx: ^TI_Ctx, text: string, v: ^TI_View) -> []Spell_Range {
	assert(ctx.pills != nil && ctx.undo != nil, "ti_spell: pills and undo required")
	assert(v.caret_render, "ti_spell: caret renderer required")
	squiggles := spellcheck_ranges_with(
		ui_frame_spell(ctx.frame),
		ctx.spell_memo,
		text,
		ctx.cursor^,
		ctx.pills,
	)
	if is_mouse_button_pressed(ctx.frame, .RIGHT) {
		mouse := get_mouse_position(ctx.frame)
		occluded := route_occluded(ctx.frame, mouse)
		mouse = frame_to_local(ctx.frame, mouse)
		if !occluded && point_in_rect(mouse, ctx.rect) {
			off := input_mouse_to_byte(
				ctx.frame,
				v.vlines,
				text,
				mouse,
				ctx.inner_x,
				ctx.y,
				v.vis_start,
				v.vis_end,
			)
			ws, we, misspelled := spellcheck_word_at_with(
				ui_frame_spell(ctx.frame),
				text,
				off,
				ctx.pills,
			)
			if misspelled {
				_, word_x := input_caret_visual_frame(
					ctx.frame,
					v.vlines,
					text,
					ws,
					int(ui_frame_metrics(ctx.frame).FONT_SIZE_BODY),
				)
				spell_menu_open(
					ctx.spell_menu,
					ui_frame_spell(ctx.frame),
					ctx.sb,
					ctx.cursor,
					ctx.pills,
					ctx.undo,
					ws,
					we,
					ctx.inner_x + word_x,
					ctx.y,
				)
			} else if spell_menu_active(ctx.spell_menu, ctx.sb) {
				spell_menu_close(ctx.spell_menu)
			}
		}
	}
	return squiggles
}

// TI_Span_Px is one byte-range's resolved geometry on a visual line.
@(private = "file")
TI_Span_Px :: struct {
	seg: cstring,
	x:   i32,
	w:   i32,
}

// ti_line_span_px measures the overlap of [lo,hi) with visual line `vl`
// once, so the chip background, accent text, and squiggle passes reuse one
// geometry instead of re-measuring the same prefixes per pass.
@(private = "file")
ti_line_span_px :: proc(
	ctx: ^TI_Ctx,
	text: string,
	vl: Wrap_Line,
	lo, hi: int,
	font_size: i32,
) -> (
	span: TI_Span_Px,
	ok: bool,
) {
	assert(ctx != nil, "ti_line_span_px: nil ctx")
	assert(vl.start <= vl.end && vl.end <= len(text), "ti_line_span_px: bad line")
	assert(lo <= hi, "ti_line_span_px: inverted span")
	s := max(lo, vl.start)
	e := min(hi, vl.end)
	if s >= e do return {}, false
	pre_c := strings.clone_to_cstring(text[vl.start:s], context.temp_allocator)
	span.seg = strings.clone_to_cstring(text[s:e], context.temp_allocator)
	span.x = ctx.inner_x + measure_text_frame(ctx.frame, pre_c, font_size)
	span.w = measure_text_frame(ctx.frame, span.seg, font_size)
	return span, true
}

// ti_render_caret_lines draws the visible window of soft-wrapped lines with
// selection highlight, pill chips, and spell squiggles.
// ti_span_shift maps a committed-text byte offset into display-text space:
// while an IME composition is spliced in at the caret, offsets at or after
// the insertion point shift right by the preedit length.
@(private = "file")
ti_span_shift :: proc(v: ^TI_View, pos: int) -> int {
	assert(v != nil, "ti_span_shift: nil view")
	assert(v.preedit_lo <= v.preedit_hi, "ti_span_shift: inverted preedit range")
	if v.preedit_hi > v.preedit_lo && pos >= v.preedit_lo {
		return pos + v.preedit_hi - v.preedit_lo
	}
	return pos
}

@(private = "file")
ti_render_caret_lines :: proc(ctx: ^TI_Ctx, text: string, v: ^TI_View, squiggles: []Spell_Range) {
	assert(v.caret_render, "ti_render_caret_lines: caret renderer required")
	metrics := ui_frame_metrics(ctx.frame)
	style := ui_frame_theme(ctx.frame)
	font_size := metrics.FONT_SIZE_BODY
	line_height := metrics.LINE_HEIGHT
	assert(
		v.vis_start >= 0 && v.vis_end <= len(v.vlines),
		"ti_render_caret_lines: window out of range",
	)
	sel := ctx.sel
	render_idx: i32 = 0
	for vi := v.vis_start; vi < v.vis_end; vi += 1 {
		vl := v.vlines[vi]
		line_c := strings.clone_to_cstring(text[vl.start:vl.end], context.temp_allocator)
		line_y := ctx.y + ui_frame_sc(ctx.frame, TI_PAD_TOP) + render_idx * line_height
		// Selection highlight: overlap of this visual line with the range.
		if sel.active && sel.sb == ctx.sb {
			lo, hi := sel_range(sel)
			lo, hi = ti_span_shift(v, lo), ti_span_shift(v, hi)
			if hl, hl_ok := ti_line_span_px(ctx, text, vl, lo, hi, font_size); hl_ok {
				draw_rectangle(ctx.frame, hl.x, line_y, hl.w, font_size, style.bg_selection)
			}
		}
		// Pill spans are measured once and reused for the chip background and
		// the accent redraw (previously two identical measure passes).
		pill_spans := make([dynamic]TI_Span_Px, context.temp_allocator)
		if ctx.pills != nil {
			for p in ctx.pills {
				ps, pe := ti_span_shift(v, p.start), ti_span_shift(v, p.end)
				if span, p_ok := ti_line_span_px(ctx, text, vl, ps, pe, font_size); p_ok {
					append(&pill_spans, span)
				}
			}
		}
		for span in pill_spans {
			draw_input_pill_bg_frame(ctx.frame, span.x, line_y, span.w)
		}
		draw_text_frame(ctx.frame, line_c, ctx.inner_x, line_y, font_size, style.fg_primary)
		for span in pill_spans {
			draw_text_frame(ctx.frame, span.seg, span.x, line_y, font_size, style.fg_accent)
		}
		// Red squiggles under misspelled words on this visual line.
		for r in squiggles {
			if span, s_ok := ti_line_span_px(ctx, text, vl, r.start, r.end, font_size); s_ok {
				draw_squiggle(
					ctx.frame,
					span.x,
					line_y + font_size + ui_frame_sc(ctx.frame, 1),
					span.w,
					style.spell_error,
				)
			}
		}
		// Solid underline beneath the in-progress IME composition, at the
		// same offset as the spell squiggle so the two never disagree on
		// baseline position.
		if v.preedit_hi > v.preedit_lo {
			if ul, ul_ok := ti_line_span_px(ctx, text, vl, v.preedit_lo, v.preedit_hi, font_size);
			   ul_ok {
				draw_rectangle(
					ctx.frame,
					ul.x,
					line_y + font_size + ui_frame_sc(ctx.frame, 1),
					ul.w,
					ui_frame_sc(ctx.frame, 1),
					style.fg_secondary,
				)
			}
		}
		render_idx += 1
	}
}

// ti_render_multiline draws newline-split lines showing the bottom of the
// text (legacy non-caret path; cursor is always at the end).
@(private = "file")
ti_render_multiline :: proc(ctx: ^TI_Ctx, text: string, v: ^TI_View, sel_all: bool) {
	assert(ctx != nil, "ti_render_multiline: nil ctx")
	assert(v != nil, "ti_render_multiline: nil v")
	assert(v.has_newlines, "ti_render_multiline: multiline text required")
	assert(v.visible_lines > 0, "ti_render_multiline: no visible lines")
	metrics := ui_frame_metrics(ctx.frame)
	style := ui_frame_theme(ctx.frame)
	font_size := metrics.FONT_SIZE_BODY
	line_height := metrics.LINE_HEIGHT
	lines := strings.split(text, "\n", context.temp_allocator)
	start_line := max(0, i32(len(lines)) - v.visible_lines)
	render_idx: i32 = 0
	for i := start_line; i < i32(len(lines)); i += 1 {
		line := lines[i]
		line_c := strings.clone_to_cstring(line, context.temp_allocator)
		line_y := ctx.y + ui_frame_sc(ctx.frame, TI_PAD_TOP) + render_idx * line_height
		// Only the last line gets horizontal scrolling (cursor is at the end).
		if i == i32(len(lines)) - 1 {
			line_pixel_w := measure_text_frame(ctx.frame, line_c, font_size)
			line_offset: i32 = 0
			if line_pixel_w > ctx.inner_w {
				line_offset = line_pixel_w - ctx.inner_w
			}
			if sel_all {
				hl_w := min(line_pixel_w, ctx.inner_w)
				draw_rectangle(ctx.frame, ctx.inner_x, line_y, hl_w, font_size, style.bg_selection)
			}
			draw_text_frame(
				ctx.frame,
				line_c,
				ctx.inner_x - line_offset,
				line_y,
				font_size,
				style.fg_primary,
			)
		} else {
			if sel_all {
				hl_w := min(measure_text_frame(ctx.frame, line_c, font_size), ctx.inner_w)
				draw_rectangle(ctx.frame, ctx.inner_x, line_y, hl_w, font_size, style.bg_selection)
			}
			draw_text_frame(ctx.frame, line_c, ctx.inner_x, line_y, font_size, style.fg_primary)
		}
		render_idx += 1
	}
}

// ti_render_single draws the single-line (optionally masked) path with
// horizontal end-scroll.
@(private = "file")
ti_render_single :: proc(ctx: ^TI_Ctx, text: string, v: ^TI_View, sel_all: bool) {
	assert(ctx != nil, "ti_render_single: nil ctx")
	assert(len(text) > 0, "ti_render_single: empty text")
	assert(ctx.inner_w >= 0, "ti_render_single: negative inner width")
	metrics := ui_frame_metrics(ctx.frame)
	style := ui_frame_theme(ctx.frame)
	font_size := metrics.FONT_SIZE_BODY
	display_text := v.masked_text if ctx.masked else text
	display_c := strings.clone_to_cstring(display_text, context.temp_allocator)
	text_pixel_w := measure_text_frame(ctx.frame, display_c, font_size)
	text_offset: i32 = 0
	if text_pixel_w > ctx.inner_w {
		text_offset = text_pixel_w - ctx.inner_w
	}
	if sel_all {
		hl_w := min(text_pixel_w, ctx.inner_w)
		draw_rectangle(
			ctx.frame,
			ctx.inner_x,
			ctx.y + (ctx.h - font_size) / 2,
			hl_w,
			font_size,
			style.bg_selection,
		)
	}
	draw_text_frame(
		ctx.frame,
		display_c,
		ctx.inner_x - text_offset,
		ctx.y + (ctx.h - font_size) / 2,
		font_size,
		style.fg_primary,
	)
}

// ti_draw_caret draws the blinking caret and updates the OS text-input rect
// so IME candidate windows track it. Caret position is computed every frame
// (not only blink-on); only the caret line itself blinks.
@(private = "file")
ti_draw_caret :: proc(ctx: ^TI_Ctx, text: string, v: ^TI_View) {
	assert(ctx != nil, "ti_draw_caret: nil ctx")
	assert(v != nil, "ti_draw_caret: nil v")
	assert(ctx.active, "ti_draw_caret: input not active")
	assert(ctx.h > 0, "ti_draw_caret: non-positive height")
	metrics := ui_frame_metrics(ctx.frame)
	style := ui_frame_theme(ctx.frame)
	font_size := metrics.FONT_SIZE_BODY
	line_height := metrics.LINE_HEIGHT
	t := frame_input(ctx.frame).time
	blink_on := true
	if !style.reduced_motion {
		// Blink is time-driven: in event-driven frame mode nothing else
		// forces a repaint while the user pauses typing, so schedule one at
		// the next half-second toggle boundary. Reduced motion keeps the
		// caret steady (no blink, no scheduled repaints).
		request_redraw_in(ctx.frame, 0.5 - math.mod(t, 0.5))
		blink_on = int(t * 2) % 2 == 0
	}
	if v.caret_render {
		// Caret at its true visual (row, x) within the visible window.
		if v.cur_vrow >= v.vis_start && v.cur_vrow < v.vis_end {
			cursor_x := ctx.inner_x + v.cur_caret_x
			cursor_line_y :=
				ctx.y +
				ui_frame_sc(ctx.frame, TI_PAD_TOP) +
				i32(v.cur_vrow - v.vis_start) * line_height
			set_text_input_rect(ctx.frame, cursor_x, cursor_line_y, 1, font_size)
			if blink_on {
				draw_line(
					ctx.frame,
					cursor_x,
					cursor_line_y,
					cursor_x,
					cursor_line_y + font_size,
					style.fg_accent,
				)
			}
		}
		return
	}
	if v.has_newlines {
		// Multiline cursor: position at end of last line.
		lines := strings.split(text, "\n", context.temp_allocator)
		last_line := lines[len(lines) - 1]
		last_line_c := strings.clone_to_cstring(last_line, context.temp_allocator)
		cursor_text_w := measure_text_frame(ctx.frame, last_line_c, font_size)
		cursor_offset: i32 = 0
		if cursor_text_w > ctx.inner_w {
			cursor_offset = cursor_text_w - ctx.inner_w
		}
		cursor_x := ctx.inner_x + cursor_text_w - cursor_offset
		visible_count := min(i32(len(lines)), v.visible_lines)
		cursor_line_y :=
			ctx.y + ui_frame_sc(ctx.frame, TI_PAD_TOP) + (visible_count - 1) * line_height
		set_text_input_rect(ctx.frame, cursor_x, cursor_line_y, 1, font_size)
		if blink_on {
			draw_line(
				ctx.frame,
				cursor_x,
				cursor_line_y,
				cursor_x,
				cursor_line_y + font_size,
				style.fg_accent,
			)
		}
		return
	}
	ti_draw_caret_single(ctx, text, v, blink_on)
}

// ti_draw_caret_single draws the caret for the single-line render path,
// mapping the byte cursor through the (possibly masked) display string.
@(private = "file")
ti_draw_caret_single :: proc(ctx: ^TI_Ctx, text: string, v: ^TI_View, blink_on: bool) {
	assert(ctx != nil, "ti_draw_caret_single: nil ctx")
	assert(ctx.active, "ti_draw_caret_single: input not active")
	assert(ctx.h > 0, "ti_draw_caret_single: non-positive height")
	font_size := ui_frame_metrics(ctx.frame).FONT_SIZE_BODY
	style := ui_frame_theme(ctx.frame)
	display_for_cursor := v.masked_text if ctx.masked else text
	cursor_text_w := measure_text_frame(
		ctx.frame,
		strings.clone_to_cstring(display_for_cursor, context.temp_allocator),
		font_size,
	)
	cursor_offset: i32 = 0
	if cursor_text_w > ctx.inner_w {
		cursor_offset = cursor_text_w - ctx.inner_w
	}
	cursor_prefix := display_for_cursor
	if ctx.caret {
		col := 0
		byte := 0
		for byte < ctx.cursor^ {
			byte = caret_next_rune(text, byte)
			col += 1
		}
		prefix_end := caret_col_to_byte(display_for_cursor, col)
		cursor_prefix = display_for_cursor[:prefix_end]
	}
	cursor_prefix_w := measure_text_frame(
		ctx.frame,
		strings.clone_to_cstring(cursor_prefix, context.temp_allocator),
		font_size,
	)
	cursor_x := ctx.inner_x + cursor_prefix_w - cursor_offset
	// The IME rect and the drawn caret share one scaled inset, or the
	// candidate window drifts from the caret at UI scales other than 1.
	inset := ui_frame_sc(ctx.frame, TI_CARET_INSET)
	set_text_input_rect(ctx.frame, cursor_x, ctx.y + inset, 1, ctx.h - inset * 2)
	if blink_on {
		draw_line(
			ctx.frame,
			cursor_x,
			ctx.y + inset,
			cursor_x,
			ctx.y + ctx.h - inset,
			style.fg_accent,
		)
	}
}

@(private)
ti_draw_chrome :: proc(ctx: ^TI_Ctx) {
	assert(ctx != nil, "ti_draw_chrome: nil context")
	assert(ctx.frame != nil, "ti_draw_chrome: nil frame")
	if !ctx.active && rect_culled_frame(ctx.frame, {ctx.x, ctx.y, ctx.w, ctx.h}) do return
	style := ui_frame_theme(ctx.frame)
	bg := style.bg_input if ctx.active else style.bg_secondary
	draw_rectangle_rec(ctx.frame, ctx.rect, bg)
	draw_rectangle_lines_ex(
		ctx.frame,
		ctx.rect,
		ui_frame_scf(ctx.frame, 1),
		style.border_color if !ctx.active else style.fg_accent,
	)
}

@(private = "file")
ti_selection_is_all :: proc(ctx: ^TI_Ctx, text_length: int) -> bool {
	assert(ctx != nil, "ti_selection_is_all: nil context")
	assert(text_length >= 0, "ti_selection_is_all: negative text length")
	sel := ctx.sel
	return(
		sel.active &&
		sel.sb == ctx.sb &&
		min(sel.anchor, sel.extent) == 0 &&
		max(sel.anchor, sel.extent) == text_length \
	)
}

@(private = "file")
ti_render_content :: proc(
	ctx: ^TI_Ctx,
	text: string,
	view: ^TI_View,
	spell_squiggles: []Spell_Range,
) {
	assert(ctx != nil, "ti_render_content: nil context")
	assert(view != nil, "ti_render_content: nil view")
	font_size := ui_frame_metrics(ctx.frame).FONT_SIZE_BODY
	if len(text) == 0 {
		placeholder := strings.clone_to_cstring(ctx.placeholder, context.temp_allocator)
		draw_text_frame(
			ctx.frame,
			placeholder,
			ctx.inner_x,
			ctx.y + (ctx.h - font_size) / 2,
			font_size,
			ui_frame_theme(ctx.frame).fg_secondary,
		)
	} else if view.caret_render {
		ti_render_caret_lines(ctx, text, view, spell_squiggles)
	} else if view.has_newlines {
		ti_render_multiline(ctx, text, view, ti_selection_is_all(ctx, len(text)))
	} else {
		ti_render_single(ctx, text, view, ti_selection_is_all(ctx, len(text)))
	}
}

@(private)
ti_draw_clipped :: proc(ctx: ^TI_Ctx) {
	assert(ctx.inner_w > 0, "ti_draw_clipped: non-positive inner width")
	assert(ctx.h > 0, "ti_draw_clipped: non-positive height")
	begin_pane_scissor(ctx.frame, ctx.inner_x, ctx.y, ctx.inner_w, ctx.h)
	text := strings.to_string(ctx.sb^)
	// While the OS input method is composing, splice the preedit into the
	// display text at the caret so wrap and rendering treat it as real text.
	// Display-only: the builder, undo, pills, and selection stay untouched;
	// the committed text arrives via the character queue on composition end.
	display := text
	pre_lo, pre_hi := 0, 0
	saved_cursor := 0
	composing := false
	if ctx.active && ctx.caret && !ctx.masked {
		preedit, pre_caret := frame_preedit(ctx.frame)
		if len(preedit) > 0 {
			composing = true
			saved_cursor = ctx.cursor^
			cur := clamp(saved_cursor, 0, len(text))
			display = strings.concatenate(
				{text[:cur], preedit, text[cur:]},
				context.temp_allocator,
			)
			pre_lo, pre_hi = cur, cur + len(preedit)
			// The caret rides the composition caret so scroll-follow and the
			// OS candidate-window rect track it; restored before returning.
			ctx.cursor^ = cur + pre_caret
		}
	}
	view := ti_layout(ctx, display)
	view.preedit_lo, view.preedit_hi = pre_lo, pre_hi
	if ctx.active && view.masked_caret do ti_mouse_masked(ctx, display, &view)
	// The input method owns the pointer inside the box mid-composition, so
	// clicks are ignored until commit (display offsets are transient anyway).
	if ctx.active && view.caret_render && !composing do ti_mouse_caret(ctx, display, &view)
	spell_squiggles: []Spell_Range
	if ctx.active && view.caret_render && !composing && ctx.pills != nil && ctx.undo != nil {
		spell_squiggles = ti_spell(ctx, display, &view)
	}
	ti_render_content(ctx, display, &view, spell_squiggles)
	if ctx.active do ti_draw_caret(ctx, display, &view)
	end_scissor_mode(ctx.frame)
	if composing do ctx.cursor^ = saved_cursor
}

@(private)
ti_draw_spell_popup :: proc(ctx: ^TI_Ctx) {
	assert(ctx != nil, "ti_draw_spell_popup: nil context")
	if spell_menu_active(ctx.spell_menu, ctx.sb) {
		draw_spell_menu(ctx.frame, ctx.spell_menu, ui_frame_spell(ctx.frame), ctx.x, ctx.y, ctx.w)
	}
}

@(private = "package")
ti_inactive_candidate :: proc(ctx: ^TI_Ctx) -> bool {
	assert(ctx != nil && ctx.sb != nil, "ti_inactive_candidate: invalid context")
	assert(ctx.sel != nil && ctx.spell_menu != nil, "ti_inactive_candidate: missing state")
	text := strings.to_string(ctx.sb^)
	return(
		!ctx.active &&
		!ctx.masked &&
		!strings.contains_rune(text, '\n') &&
		!ctx.sel.active &&
		(ctx.pills == nil || len(ctx.pills) == 0) &&
		!spell_menu_active(ctx.spell_menu, ctx.sb) \
	)
}

@(private = "package")
ti_draw_inactive_single_line :: proc(ctx: ^TI_Ctx) {
	assert(ctx != nil && ti_inactive_candidate(ctx), "inactive input: invalid context")
	assert(ctx.inner_w > 0 && ctx.h > 0, "inactive input: invalid geometry")
	if rect_culled_frame(ctx.frame, {ctx.x, ctx.y, ctx.w, ctx.h}) do return
	begin_pane_scissor(ctx.frame, ctx.inner_x, ctx.y, ctx.inner_w, ctx.h)
	text := strings.to_string(ctx.sb^)
	font_size := ui_frame_metrics(ctx.frame).FONT_SIZE_BODY
	if len(text) == 0 {
		draw_text_string_frame(
			ctx.frame,
			ctx.placeholder,
			ctx.inner_x,
			ctx.y + (ctx.h - font_size) / 2,
			font_size,
			ui_frame_theme(ctx.frame).fg_secondary,
		)
	} else {
		draw_text_string_frame(
			ctx.frame,
			text,
			ctx.inner_x,
			ctx.y + (ctx.h - font_size) / 2,
			font_size,
			ui_frame_theme(ctx.frame).fg_label,
		)
	}
	end_scissor_mode(ctx.frame)
}
