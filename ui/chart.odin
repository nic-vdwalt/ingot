// LIB-CANDIDATE: imports only core:*.
// Immediate-mode chart widgets: line, bar, and sparkline. Widgets take plain
// data and return events; callers own all state (Chart_State holds only the
// enter animation and last hover index so redraws can be event-driven).
package ui

import "core:fmt"
import "core:math"
import "core:strings"

// Every string a chart draws — axis ticks, legend entries, tooltip rows — is
// chrome around the plot, never reading text. Naming the role once here stops
// the axis and the legend drifting apart the way they can when each call site
// reaches for its own metric.
@(private = "file")
CHART_TEXT :: Text_Role.Label

@(private = "file")
chart_text_size :: proc(frame: ^Ui_Frame) -> i32 {
	return text_role_size(frame, CHART_TEXT)
}


// Chart_State is caller-owned per-chart state. The zero value is valid; reset
// enter_anim to 0 to replay the enter animation.
Chart_State :: struct {
	enter_anim: f32, // 0→1 eased on first show
	hover_idx:  int, // last hovered point index (for redraw-on-change)
}

// Chart_Series is one plotted data set. A zero color resolves to the theme
// palette by series index at draw time (defaults must be compile-time
// constants; the theme is runtime).
Chart_Series :: struct {
	name:   string,
	values: []f32,
	color:  Color,
}

// Chart_Opts configures axes, range, and decoration. The zero value draws a
// bare plot (no grid/axes/legend) with an auto-computed nice range.
Chart_Opts :: struct {
	labels:      []string, // x-axis category labels (optional)
	y_min:       f32, // ignored unless y_fixed
	y_max:       f32,
	y_fixed:     bool, // false → auto-range with nice-number padding
	show_grid:   bool,
	show_axes:   bool,
	show_legend: bool,
	fill:        bool, // line chart: translucent area fill under curve
	format:      proc(v: f32, buf: []u8) -> string, // nil → default
}

// --- pure internals (package-visible for tests) -----------------------------

// nice_ticks expands [min_v, max_v] to a "nice" range whose step is
// 1/2/5 × 10ⁿ, aiming for ~target intervals. Handles reversed and degenerate
// (min == max) inputs; step is always > 0.
@(private)
nice_ticks :: proc(min_v, max_v: f32, target: int) -> (lo, hi, step: f32) {
	mn, mx := min_v, max_v
	if mx < mn do mn, mx = mx, mn
	if mx - mn < 1e-6 {
		// Degenerate span: pad around the value so a range exists.
		pad := abs(mn) * 0.1
		if pad < 1e-6 do pad = 1
		mn -= pad
		mx += pad
	}
	raw := (mx - mn) / f32(max(target, 1))
	mag := math.pow(f32(10), math.floor(math.ln(raw) / math.ln(f32(10))))
	norm := raw / mag
	nice: f32
	switch {
	case norm <= 1:
		nice = 1
	case norm <= 2:
		nice = 2
	case norm <= 5:
		nice = 5
	case:
		nice = 10
	}
	step = nice * mag
	lo = math.floor(mn / step) * step
	hi = math.ceil(mx / step) * step
	return
}

// map_y maps a value to a pixel y within the plot rect (lo → bottom edge,
// hi → top edge). Values outside [lo, hi] clamp to the plot edges.
@(private)
map_y :: proc(v, lo, hi: f32, plot: Rectangle) -> f32 {
	if hi - lo < 1e-9 do return plot.y + plot.height
	t := clamp((v - lo) / (hi - lo), 0, 1)
	return plot.y + plot.height * (1 - t)
}

// line_hover_index returns the point index nearest the mouse x, or -1 when
// the mouse is outside the plot (or there are no points). Points sit at
// evenly spaced x positions spanning the plot width.
@(private)
line_hover_index :: proc(mouse: Vector2, plot: Rectangle, n: int) -> int {
	if n <= 0 || !point_in_rect(mouse, plot) do return -1
	if n == 1 do return 0
	slot := plot.width / f32(n - 1)
	idx := int((mouse.x - plot.x) / slot + 0.5)
	return clamp(idx, 0, n - 1)
}

// bar_hover_index returns the slot index containing the mouse x, or -1 when
// the mouse is outside the plot. Slots partition the plot width into n bins.
@(private)
bar_hover_index :: proc(mouse: Vector2, plot: Rectangle, n: int) -> int {
	if n <= 0 || !point_in_rect(mouse, plot) do return -1
	slot := plot.width / f32(n)
	idx := int((mouse.x - plot.x) / slot)
	return clamp(idx, 0, n - 1)
}

// chart_data_range scans all series for the value range and the longest
// series length. ok is false when no series has any points.
@(private)
chart_data_range :: proc(series: []Chart_Series) -> (mn, mx: f32, n: int, ok: bool) {
	mn = max(f32)
	mx = -max(f32)
	for s in series {
		n = max(n, len(s.values))
		for v in s.values {
			mn = min(mn, v)
			mx = max(mx, v)
		}
	}
	ok = n > 0
	if !ok {
		mn = 0
		mx = 0
	}
	return
}

// chart_series_color cycles the theme palette by series index.
@(private)
chart_series_color :: proc(frame: ^Ui_Frame, i: int) -> Color {
	assert(frame != nil, "chart_series_color: nil frame")
	style := ui_frame_theme(frame)
	switch i %% 6 {
	case 0:
		return style.fg_accent
	case 1:
		return style.fg_success
	case 2:
		return style.fg_tool
	case 3:
		return style.fg_error
	case 4:
		return style.fg_debug
	case:
		return style.fg_accent_light
	}
}

// --- shared drawing internals ------------------------------------------------

@(private = "file")
Chart_Layout :: struct {
	chart:        Rectangle, // full widget bounds
	plot:         Rectangle, // inner data area
	lo, hi, step: f32, // nice y range
	n:            int, // point count (max across series)
}

@(private = "file")
chart_format_value :: proc(opts: Chart_Opts, v: f32, buf: []u8) -> string {
	if opts.format != nil do return opts.format(v, buf)
	if v == math.floor(v) && abs(v) < 1e6 {
		return fmt.bprintf(buf, "%.0f", v)
	}
	return fmt.bprintf(buf, "%.1f", v)
}

// chart_layout computes the plot rect (reserving margins for tick labels,
// x labels, and the legend) and the nice y range. ok is false when there is
// no data or no room to draw.
@(private = "file")
chart_layout :: proc(
	frame: ^Ui_Frame,
	x, y, w, h: i32,
	series: []Chart_Series,
	opts: Chart_Opts,
	include_zero: bool,
) -> (
	cl: Chart_Layout,
	ok: bool,
) {
	assert(frame != nil, "chart_layout: nil frame")
	mn, mx, n, has := chart_data_range(series)
	if !has || w <= 0 || h <= 0 do return
	if opts.y_fixed {
		mn, mx = opts.y_min, opts.y_max
	} else if include_zero {
		mn = min(mn, 0)
		mx = max(mx, 0)
	}

	top := ui_frame_sc(frame, 4)
	right := ui_frame_sc(frame, 4)
	bottom := ui_frame_sc(frame, 4)
	if len(opts.labels) > 0 do bottom += chart_text_size(frame) + ui_frame_sc(frame, 6)
	if opts.show_legend do bottom += chart_text_size(frame) + ui_frame_sc(frame, 10)

	plot_h := h - top - bottom
	if plot_h < ui_frame_sc(frame, 20) do return

	target := max(int(plot_h / ui_frame_sc(frame, 36)), 2)
	cl.lo, cl.hi, cl.step = nice_ticks(mn, mx, target)

	left := ui_frame_sc(frame, 4)
	if opts.show_axes {
		buf: [32]u8
		widest: i32
		for tv := cl.lo; tv <= cl.hi + cl.step * 0.5; tv += cl.step {
			s := chart_format_value(opts, tv, buf[:])
			c := strings.clone_to_cstring(s, context.temp_allocator)
			widest = max(widest, measure_text_frame(frame, c, chart_text_size(frame)))
		}
		left = widest + ui_frame_sc(frame, 8)
	}
	plot_w := w - left - right
	if plot_w < ui_frame_sc(frame, 20) do return

	cl.chart = Rectangle{f32(x), f32(y), f32(w), f32(h)}
	cl.plot = Rectangle{f32(x + left), f32(y + top), f32(plot_w), f32(plot_h)}
	cl.n = n
	ok = true
	return
}

// chart_anim advances the caller-owned enter animation and keeps frames
// coming (event-driven mode) until the fill settles.
@(private = "file")
chart_anim :: proc(frame: ^Ui_Frame, state: ^Chart_State) -> f32 {
	if state == nil do return 1
	eased(&state.enter_anim, 1, frame_input(frame).frame_time, 6.0)
	if state.enter_anim < 1 do request_redraw(frame)
	return state.enter_anim
}

// chart_note_hover requests a redraw when the hovered index changed so
// event-driven hosts repaint the guide/tooltip.
@(private = "file")
chart_note_hover :: proc(frame: ^Ui_Frame, state: ^Chart_State, hovered: int) {
	if state == nil do return
	if hovered != state.hover_idx {
		state.hover_idx = hovered
		request_redraw(frame)
	}
}

// chart_draw_axes draws gridlines, y tick labels, the baseline, and decimated
// x labels. xs holds the pixel x center of each point/slot.
@(private = "file")
chart_draw_axes :: proc(frame: ^Ui_Frame, cl: Chart_Layout, opts: Chart_Opts, xs: []f32) {
	assert(frame != nil, "chart_draw_axes: nil frame")
	style := ui_frame_theme(frame)
	buf: [32]u8
	if opts.show_grid || opts.show_axes {
		for tv := cl.lo; tv <= cl.hi + cl.step * 0.5; tv += cl.step {
			py := map_y(tv, cl.lo, cl.hi, cl.plot)
			if opts.show_grid {
				draw_line_ex(
					frame,
					{cl.plot.x, py},
					{cl.plot.x + cl.plot.width, py},
					1,
					style.border_subtle,
				)
			}
			if opts.show_axes {
				s := chart_format_value(opts, tv, buf[:])
				c := strings.clone_to_cstring(s, context.temp_allocator)
				tw := measure_text_frame(frame, c, chart_text_size(frame))
				draw_text_frame(
					frame,
					c,
					i32(cl.plot.x) - tw - ui_frame_sc(frame, 6),
					i32(py) - chart_text_size(frame) / 2,
					chart_text_size(frame),
					style.fg_secondary,
				)
			}
		}
	}
	if opts.show_axes {
		by := cl.plot.y + cl.plot.height
		draw_line_ex(
			frame,
			{cl.plot.x, by},
			{cl.plot.x + cl.plot.width, by},
			ui_frame_scf(frame, 1),
			style.border_color,
		)
	}

	if len(opts.labels) > 0 && len(xs) > 0 {
		// Decimate: draw every Nth label so neighbours can't overlap.
		max_w: i32 = 1
		for l in opts.labels {
			c := strings.clone_to_cstring(l, context.temp_allocator)
			max_w = max(max_w, measure_text_frame(frame, c, chart_text_size(frame)))
		}
		count := min(len(opts.labels), len(xs))
		step_n := max(1, int(f32(max_w) * 1.4 * f32(count) / max(cl.plot.width, 1)))
		ly := i32(cl.plot.y + cl.plot.height) + ui_frame_sc(frame, 4)
		for i := 0; i < count; i += step_n {
			c := strings.clone_to_cstring(opts.labels[i], context.temp_allocator)
			tw := measure_text_frame(frame, c, chart_text_size(frame))
			lx := clamp(
				i32(xs[i]) - tw / 2,
				i32(cl.chart.x),
				max(i32(cl.chart.x + cl.chart.width) - tw, i32(cl.chart.x)),
			)
			draw_text_frame(frame, c, lx, ly, chart_text_size(frame), style.fg_secondary)
		}
	}
}

// chart_draw_legend draws a horizontal swatch+name row along the widget's
// bottom edge.
@(private = "file")
chart_draw_legend :: proc(frame: ^Ui_Frame, cl: Chart_Layout, series: []Chart_Series) {
	assert(frame != nil, "chart_draw_legend: nil frame")
	style := ui_frame_theme(frame)
	ly := i32(cl.chart.y + cl.chart.height) - chart_text_size(frame) - ui_frame_sc(frame, 2)
	lx := i32(cl.plot.x)
	sw := ui_frame_sc(frame, 10)
	for s, i in series {
		col := s.color if s.color != {} else chart_series_color(frame, i)
		draw_rectangle_rounded(
			frame,
			{f32(lx), f32(ly + (chart_text_size(frame) - sw) / 2), f32(sw), f32(sw)},
			0.4,
			4,
			col,
		)
		lx += sw + ui_frame_sc(frame, 5)
		name := s.name if len(s.name) > 0 else "series"
		c := strings.clone_to_cstring(name, context.temp_allocator)
		draw_text_frame(frame, c, lx, ly, chart_text_size(frame), style.fg_secondary)
		lx += measure_text_frame(frame, c, chart_text_size(frame)) + ui_frame_sc(frame, 14)
	}
}

// chart_draw_tooltip draws a value readout card near the cursor, clamped to
// the widget bounds: optional x label header plus one swatched row per series.
// Recorded on the overlay layer (passive — no input claim) so the card paints
// above any widgets drawn after the chart; coords are shifted to screen space
// because the overlay replays after pane translation is popped.
@(private = "file")
chart_draw_tooltip :: proc(
	frame: ^Ui_Frame,
	cl: Chart_Layout,
	series: []Chart_Series,
	opts: Chart_Opts,
	idx: int,
	mouse: Vector2,
) {
	assert(frame != nil, "chart_draw_tooltip: nil frame")
	style := ui_frame_theme(frame)
	buf: [32]u8
	pad := ui_frame_sc(frame, 6)
	row_h := chart_text_size(frame) + ui_frame_sc(frame, 4)
	sw := ui_frame_sc(frame, 8)

	// Measure pass.
	rows := 0
	wmax: i32
	has_header := idx >= 0 && idx < len(opts.labels)
	if has_header {
		c := strings.clone_to_cstring(opts.labels[idx], context.temp_allocator)
		wmax = max(wmax, measure_text_frame(frame, c, chart_text_size(frame)))
		rows += 1
	}
	for s, si in series {
		if idx >= len(s.values) do continue
		val := chart_format_value(opts, s.values[idx], buf[:])
		name := s.name if len(s.name) > 0 else fmt.tprintf("series %d", si + 1)
		c := strings.clone_to_cstring(fmt.tprintf("%s: %s", name, val), context.temp_allocator)
		wmax = max(
			wmax,
			measure_text_frame(frame, c, chart_text_size(frame)) + sw + ui_frame_sc(frame, 5),
		)
		rows += 1
	}
	if rows == 0 do return

	tw := wmax + pad * 2
	th := i32(rows) * row_h + pad * 2
	tx := clamp(
		i32(mouse.x) + ui_frame_sc(frame, 14),
		i32(cl.chart.x),
		max(i32(cl.chart.x + cl.chart.width) - tw, i32(cl.chart.x)),
	)
	ty := clamp(
		i32(mouse.y) - th - ui_frame_sc(frame, 6),
		i32(cl.chart.y),
		max(i32(cl.chart.y + cl.chart.height) - th, i32(cl.chart.y)),
	)
	origin := frame_pane_origin(frame)
	ox := i32(origin.x)
	rect := Rectangle{f32(tx + ox), f32(ty), f32(tw), f32(th)}
	overlay_begin(frame, rect, claim_input = false)
	overlay_rounded(frame, rect, 0.2, 4, style.bg_popup)
	overlay_rounded_lines(frame, rect, 0.2, 4, ui_frame_scf(frame, 1), style.border_color)

	// Draw pass.
	ry := ty + pad
	if has_header {
		overlay_text(
			frame,
			opts.labels[idx],
			tx + ox + pad,
			ry,
			chart_text_size(frame),
			style.fg_primary,
		)
		ry += row_h
	}
	for s, si in series {
		if idx >= len(s.values) do continue
		col := s.color if s.color != {} else chart_series_color(frame, si)
		overlay_rounded(
			frame,
			{f32(tx + ox + pad), f32(ry + (chart_text_size(frame) - sw) / 2), f32(sw), f32(sw)},
			0.5,
			4,
			col,
		)
		val := chart_format_value(opts, s.values[idx], buf[:])
		name := s.name if len(s.name) > 0 else fmt.tprintf("series %d", si + 1)
		overlay_text(
			frame,
			fmt.tprintf("%s: %s", name, val),
			tx + ox + pad + sw + ui_frame_sc(frame, 5),
			ry,
			chart_text_size(frame),
			style.fg_secondary,
		)
		ry += row_h
	}
	overlay_end(frame)
}

// chart_point_y maps a value to its animated pixel y: during the enter
// animation points rise from the plot's bottom edge toward their target.
@(private = "file")
chart_point_y :: proc(v: f32, cl: Chart_Layout, anim: f32) -> f32 {
	yb := cl.plot.y + cl.plot.height
	py := map_y(v, cl.lo, cl.hi, cl.plot)
	return yb + (py - yb) * anim
}

// --- widgets -----------------------------------------------------------------

// line_chart draws one polyline per series with optional area fill, grid,
// axes, legend, and a hover tooltip. Returns the hovered point index or -1.
line_chart_at :: proc(
	frame: ^Ui_Frame,
	rect: Rect_I32,
	series: []Chart_Series,
	state: ^Chart_State,
	opts: Chart_Opts = {},
) -> int {
	assert(frame != nil, "line_chart_at: nil frame")
	assert(state != nil, "line_chart_at: nil state")
	x, y, w, h := rect.x, rect.y, rect.w, rect.h
	cl, ok := chart_layout(frame, x, y, w, h, series, opts, false)
	if !ok do return -1
	anim := chart_anim(frame, state)

	xs := make([]f32, cl.n, context.temp_allocator)
	if cl.n == 1 {
		xs[0] = cl.plot.x + cl.plot.width / 2
	} else {
		slot := cl.plot.width / f32(cl.n - 1)
		for i in 0 ..< cl.n do xs[i] = cl.plot.x + slot * f32(i)
	}

	chart_draw_axes(frame, cl, opts, xs)

	mouse := get_mouse_position(frame)
	hovered := line_hover_index(mouse, cl.plot, cl.n)
	chart_note_hover(frame, state, hovered)

	yb := cl.plot.y + cl.plot.height
	for s, si in series {
		col := s.color if s.color != {} else chart_series_color(frame, si)
		nv := min(len(s.values), cl.n)
		if nv == 0 do continue
		if opts.fill && nv >= 2 {
			fill := Color{col.r, col.g, col.b, 40}
			for i in 1 ..< nv {
				p0 := Vector2{xs[i - 1], chart_point_y(s.values[i - 1], cl, anim)}
				p1 := Vector2{xs[i], chart_point_y(s.values[i], cl, anim)}
				draw_triangle(frame, p0, {p0.x, yb}, {p1.x, yb}, fill)
				draw_triangle(frame, p0, {p1.x, yb}, p1, fill)
			}
		}
		thick := ui_frame_scf(frame, 2)
		for i in 1 ..< nv {
			p0 := Vector2{xs[i - 1], chart_point_y(s.values[i - 1], cl, anim)}
			p1 := Vector2{xs[i], chart_point_y(s.values[i], cl, anim)}
			draw_line_ex(frame, p0, p1, thick, col)
		}
		if nv == 1 {
			draw_circle_v(
				frame,
				{xs[0], chart_point_y(s.values[0], cl, anim)},
				ui_frame_scf(frame, 3),
				col,
			)
		}
	}

	if opts.show_legend do chart_draw_legend(frame, cl, series)

	if hovered >= 0 {
		gx := xs[hovered]
		draw_line_ex(
			frame,
			{gx, cl.plot.y},
			{gx, yb},
			ui_frame_scf(frame, 1),
			ui_frame_theme(frame).border_color,
		)
		for s, si in series {
			if hovered >= len(s.values) do continue
			col := s.color if s.color != {} else chart_series_color(frame, si)
			draw_circle_v(
				frame,
				{gx, chart_point_y(s.values[hovered], cl, anim)},
				ui_frame_scf(frame, 4),
				col,
			)
		}
		chart_draw_tooltip(frame, cl, series, opts, hovered, mouse)
	}
	return hovered
}

// bar_chart draws grouped vertical bars (one group per index, one bar per
// series) with optional grid, axes, legend, and a hover tooltip. The range
// always includes zero so bars grow from a meaningful baseline. Returns the
// hovered slot index or -1.
bar_chart_at :: proc(
	frame: ^Ui_Frame,
	rect: Rect_I32,
	series: []Chart_Series,
	state: ^Chart_State,
	opts: Chart_Opts = {},
) -> int {
	assert(frame != nil, "bar_chart_at: nil frame")
	assert(state != nil, "bar_chart_at: nil state")
	x, y, w, h := rect.x, rect.y, rect.w, rect.h
	cl, ok := chart_layout(frame, x, y, w, h, series, opts, true)
	if !ok do return -1
	anim := chart_anim(frame, state)

	slot := cl.plot.width / f32(cl.n)
	xs := make([]f32, cl.n, context.temp_allocator)
	for i in 0 ..< cl.n do xs[i] = cl.plot.x + slot * (f32(i) + 0.5)

	chart_draw_axes(frame, cl, opts, xs)

	mouse := get_mouse_position(frame)
	hovered := bar_hover_index(mouse, cl.plot, cl.n)
	chart_note_hover(frame, state, hovered)

	if hovered >= 0 {
		hl := ui_frame_theme(frame).fg_accent
		draw_rectangle_rec(
			frame,
			{cl.plot.x + slot * f32(hovered), cl.plot.y, slot, cl.plot.height},
			Color{hl.r, hl.g, hl.b, 18},
		)
	}

	// Baseline at value 0 (clamped into the nice range).
	yb := map_y(clamp(0, cl.lo, cl.hi), cl.lo, cl.hi, cl.plot)
	gap := ui_frame_scf(frame, 2)
	group_w := max(slot - gap * 2, 1)
	bw := group_w / f32(max(len(series), 1))

	for s, si in series {
		col := s.color if s.color != {} else chart_series_color(frame, si)
		for i in 0 ..< min(len(s.values), cl.n) {
			py := map_y(s.values[i], cl.lo, cl.hi, cl.plot)
			py = yb + (py - yb) * anim
			bx := cl.plot.x + slot * f32(i) + gap + bw * f32(si)
			bh := abs(yb - py)
			if bh < 0.5 do continue
			rect := Rectangle{bx, min(py, yb), max(bw - 1, 1), bh}
			if bh >= ui_frame_scf(frame, 6) { 	// avoid degenerate rounding on tiny bars
				draw_rectangle_rounded(frame, rect, 0.25, 4, col)
			} else {
				draw_rectangle_rec(frame, rect, col)
			}
		}
	}

	if opts.show_legend do chart_draw_legend(frame, cl, series)
	if hovered >= 0 do chart_draw_tooltip(frame, cl, series, opts, hovered, mouse)
	return hovered
}

// sparkline draws a minimal inline trend line (no axes, no state, no hover)
// sized to fit inside stat cards. A zero color resolves to the theme accent.
sparkline_at :: proc(frame: ^Ui_Frame, rect: Rect_I32, values: []f32, color: Color = {}) {
	assert(frame != nil, "sparkline_at: nil frame")
	x, y, w, h := rect.x, rect.y, rect.w, rect.h
	if len(values) == 0 || w <= 0 || h <= 0 do return
	color := color
	if color == {} do color = ui_frame_theme(frame).fg_accent_light

	mn, mx := values[0], values[0]
	for v in values {
		mn = min(mn, v)
		mx = max(mx, v)
	}
	span := mx - mn

	n := len(values)
	fx, fy, fw, fh := f32(x), f32(y), f32(w), f32(h)
	prev, last: Vector2
	for v, i in values {
		t := f32(0.5) // all-equal values: flat mid line
		if span > 1e-9 do t = (v - mn) / span
		p := Vector2{fx + fw * (f32(i) / f32(max(n - 1, 1))), fy + fh * (1 - t)}
		if i > 0 do draw_line_ex(frame, prev, p, ui_frame_scf(frame, 1.5), color)
		prev = p
		last = p
	}
	draw_circle_v(frame, last, ui_frame_scf(frame, 2.5), color)
}
