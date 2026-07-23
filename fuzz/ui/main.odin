package fuzz_ui

// Memory-safety fuzzer for the pure text-parsing surface of ingot:ui —
// markdown inline spans, raw/display offset maps, and GFM table splitting.
// These parsers consume untrusted strings (chat/LLM output), so they are
// hammered with biased random bytes AND realistic markdown templates run
// through a structure-aware mutation engine (fuzz/fuzzx): splicing,
// insert/delete/duplicate, boundary bytes. Multi-line documents exercise
// caller-side code-fence/table state across lines, and a rare large class
// (~1 in 200) pushes lines to 64 KiB. Every allocation is tracked; run under
// -sanitize:address for OOB/UAF detection on top.
//
// The seed is printed FIRST so any crash reproduces exactly:
//   fuzz_ui -seed:12345 -iterations:100000 [-rounds:N]

import "core:fmt"
import "core:mem"
import fuzzx "ingot:fuzz/fuzzx"
import "ingot:ui"

ITERATIONS_DEFAULT :: 100_000
MAXIMUM_LINE_BYTES :: 1024
MAXIMUM_LINE_BYTES_LARGE :: 64 * 1024 // rare large class (~1 in 200)

Prng :: fuzzx.Prng

// Realistic markdown lines whose mutations reach deep into span matching,
// table structure, fence detection, links, and pill sentinels.
UI_TEMPLATES := [?]string {
	"| alpha | beta | gamma |",
	"|---|:--:|--:|",
	"| a `code` | **b** | [c](https://example.com) |",
	"```odin",
	"```",
	"**bold** with *italic* and `inline code` mixed",
	"[link text](https://example.com/path?q=1&r=2#frag) trailing",
	"prefix \x01pill-target\x02 suffix with **markers",
	"- list item with `unclosed code and *stray markers",
	"https://bare.example.com/url followed by | pipe",
}

// Random line biased towards markdown metacharacters so the span parser's
// marker matching, unmatched-marker recovery, and pill sentinels are all hit.
random_line :: proc(p: ^Prng) -> string {
	maximum := MAXIMUM_LINE_BYTES
	if fuzzx.int_range(p, 0, 200) == 0 do maximum = MAXIMUM_LINE_BYTES_LARGE
	n := fuzzx.int_range(p, 0, maximum)
	b := make([]u8, n, context.temp_allocator)
	meta := [?]u8{'*', '`', '|', '-', ':', 'h', 't', 'p', '/', '.', ' ', '\t', 0x01, 0x02, 0xFF}
	for i in 0 ..< n {
		if fuzzx.int_range(p, 0, 3) == 0 {
			b[i] = meta[fuzzx.int_range(p, 0, len(meta))]
		} else {
			b[i] = u8(fuzzx.next_u64(p) & 0xFF)
		}
	}
	return string(b)
}

// template_line mutates a realistic markdown template and sometimes splices
// in a slice of another template (e.g. table pipes into a fenced-code line).
template_line :: proc(p: ^Prng) -> string {
	base := transmute([]u8)UI_TEMPLATES[fuzzx.int_range(p, 0, len(UI_TEMPLATES))]
	buf := fuzzx.mutate(p, base)
	if fuzzx.int_range(p, 0, 3) == 0 {
		other := transmute([]u8)UI_TEMPLATES[fuzzx.int_range(p, 0, len(UI_TEMPLATES))]
		buf = fuzzx.splice(p, buf, other)
	}
	cut := fuzzx.int_range(p, 0, len(buf) + 1)
	return string(buf[:cut])
}

make_line :: proc(p: ^Prng) -> string {
	if fuzzx.int_range(p, 0, 2) == 0 do return template_line(p)
	return random_line(p)
}

exercise_spans :: proc(c: ^fuzzx.Ctx, p: ^Prng, line: string) {
	spans := ui.parse_inline_spans(line)
	display_len := ui.spans_display_len(spans)
	fuzzx.check(c, display_len >= 0, "display length must be non-negative")
	fuzzx.check(c, display_len <= len(line), "display text can never be longer than raw text")
	for span in spans {
		fuzzx.check(c, span.raw_start >= 0, "span start in range")
		fuzzx.check(c, span.raw_end <= len(line), "span end in range")
		fuzzx.check(c, span.raw_start <= span.raw_end, "span start <= end")
	}
	// Offset maps must stay in range for ANY offset, valid or hostile.
	raw_probe := fuzzx.int_range(p, 0, len(line) + 2)
	display_position := ui.raw_to_display(spans, raw_probe)
	fuzzx.check(c, display_position >= 0, "raw_to_display in range")
	fuzzx.check(c, display_position <= display_len, "raw_to_display in range")
	display_probe := fuzzx.int_range(p, 0, display_len + 2)
	raw_position := ui.display_to_raw(spans, display_probe)
	fuzzx.check(c, raw_position >= 0, "display_to_raw in range")
	fuzzx.check(c, raw_position <= len(line), "display_to_raw in range")
}

exercise_table :: proc(c: ^fuzzx.Ctx, p: ^Prng, line: string) {
	_ = ui.is_code_fence(line)
	_ = ui.is_table_separator(line)
	line_end := fuzzx.int_range(p, 0, len(line) + 1)
	line_start := fuzzx.int_range(p, 0, line_end + 1)
	cells, starts := ui.split_table_row_offsets(line, line_start, line_end)
	fuzzx.check(c, len(cells) == len(starts), "cells and starts must stay parallel")
	for start in starts {
		fuzzx.check(c, start >= 0, "cell start in range")
		fuzzx.check(c, start <= len(line), "cell start in range")
	}
}

// exercise_document runs fence/table detection across a multi-line document
// the way a renderer does: toggling in_code on fences and tracking table
// runs. This exercises caller-side cross-line state that single-line
// fuzzing never reaches.
exercise_document :: proc(c: ^fuzzx.Ctx, p: ^Prng) {
	line_count := fuzzx.int_range(p, 1, 33)
	in_code := false
	table_run := 0
	for _ in 0 ..< line_count {
		line: string
		// Bias towards template lines so fences and table rows actually occur.
		if fuzzx.int_range(p, 0, 4) == 0 {
			line = random_line(p)
		} else {
			line = template_line(p)
		}
		c.input = transmute([]u8)line
		if ui.is_code_fence(line) {
			in_code = !in_code
			table_run = 0
			continue
		}
		if in_code do continue
		if ui.is_table_separator(line) {
			table_run += 1
			fuzzx.check(c, table_run <= line_count, "table run exceeded document")
		} else {
			table_run = 0
		}
		exercise_spans(c, p, line)
		exercise_table(c, p, line)
	}
}

// exercise_widget_math fuzzes the pure widget helpers: menu navigation must
// always land on a selectable row (or stay put) and stay in bounds, and
// slider stepping must never escape [lo, hi] for any ratio/step combination.
exercise_widget_math :: proc(c: ^fuzzx.Ctx, p: ^Prng) {
	// Menu navigation over a random mix of items/separators/disabled rows.
	n := fuzzx.int_range(p, 1, 12)
	items := make([]ui.Menu_Item, n, context.temp_allocator)
	for i in 0 ..< n {
		items[i] = ui.Menu_Item {
			label     = "x",
			disabled  = fuzzx.int_range(p, 0, 4) == 0,
			separator = fuzzx.int_range(p, 0, 4) == 0,
		}
	}
	current := fuzzx.int_range(p, 0, n)
	delta := 1 if fuzzx.next_u64(p) % 2 == 0 else -1
	next := ui.menu_nav_next(items, current, delta)
	fuzzx.check(c, next >= 0 && next < n, "menu_nav_next index in range")
	if next != current {
		fuzzx.check(c, !items[next].separator, "menu_nav_next landed on a separator")
		fuzzx.check(c, !items[next].disabled, "menu_nav_next landed on a disabled row")
	}

	// Slider stepping: any ratio and step must clamp into [lo, hi].
	lo := f32(fuzzx.int_range(p, -1000, 1000))
	hi := lo + f32(fuzzx.int_range(p, 1, 2000))
	step := f32(fuzzx.int_range(p, 0, 50))
	t := f32(fuzzx.next_u64(p) % 1001) / 1000.0
	v := ui.slider_step_value(lo, hi, step, t)
	fuzzx.check(c, v >= lo && v <= hi, "slider_step_value escaped [lo, hi]")
	d := ui.slider_keyboard_delta(lo, hi, step)
	fuzzx.check(c, d > 0, "slider_keyboard_delta must be positive")

	// Wheel accumulation: remainder must stay under one row either way.
	accum := f32(fuzzx.next_u64(p) % 100) / 100.0 - 0.5
	wheel := f32(fuzzx.int_range(p, -300, 300)) / 100.0
	_ = ui.wheel_accum_steps(&accum, wheel)
	fuzzx.check(c, accum > -1 && accum < 1, "wheel remainder out of range")
}

main :: proc() {
	seed, iterations, rounds := fuzzx.parse_options(ITERATIONS_DEFAULT)
	fmt.printfln("fuzz_ui seed=%d iterations=%d rounds=%d", seed, iterations, rounds)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)

	for round in 0 ..< rounds {
		round_seed := seed + u64(round)
		if rounds > 1 do fmt.printfln("fuzz_ui round %d seed=%d", round, round_seed)
		p := fuzzx.prng_make(round_seed)
		c := fuzzx.Ctx{name = "fuzz_ui", seed = round_seed}
		for i in 0 ..< iterations {
			c.iteration = i
			line := make_line(&p)
			c.input = transmute([]u8)line
			exercise_spans(&c, &p, line)
			exercise_table(&c, &p, line)
			if i % 8 == 0 do exercise_document(&c, &p)
			exercise_widget_math(&c, &p)
			free_all(context.temp_allocator)
		}
	}

	fuzzx.report(&track, "fuzz_ui", seed)
	fmt.printfln("fuzz_ui ok")
}
