package fuzz_ui

// Memory-safety fuzzer for the pure text-parsing surface of ingot:ui —
// markdown inline spans, raw/display offset maps, and GFM table splitting.
// These parsers consume untrusted strings (chat/LLM output), so they are
// hammered with random bytes and mutated markdown. Every allocation is
// tracked; run under -sanitize:address for OOB/UAF detection on top.
//
// The seed is printed FIRST so any crash reproduces exactly:
//   fuzz_ui -seed:12345 -iterations:100000

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "ingot:ui"

ITERATIONS_DEFAULT :: 100_000
MAXIMUM_LINE_BYTES :: 1024

Prng :: struct {
	state: u64,
}

prng_make :: proc(seed: u64) -> Prng {
	return Prng{state = seed == 0 ? 0x9E3779B97F4A7C15 : seed}
}

next_u64 :: proc(p: ^Prng) -> u64 {
	x := p.state
	x ~= x >> 12
	x ~= x << 25
	x ~= x >> 27
	p.state = x
	return x * 0x2545F4914F6CDD1D
}

// int_range returns a value in [lo, hi).
int_range :: proc(p: ^Prng, lo, hi: int) -> int {
	if hi <= lo do return lo
	return lo + int(next_u64(p) % u64(hi - lo))
}

parse_options :: proc() -> (seed: u64, iterations: int) {
	seed = u64(time.now()._nsec) // replaced by -seed:N for reproduction runs
	iterations = ITERATIONS_DEFAULT
	for arg in os.args[1:] {
		if strings.has_prefix(arg, "-seed:") {
			if value, ok := strconv.parse_u64(arg[len("-seed:"):]); ok do seed = value
		}
		if strings.has_prefix(arg, "-iterations:") {
			if value, ok := strconv.parse_int(arg[len("-iterations:"):]); ok do iterations = value
		}
	}
	assert(iterations > 0)
	return seed, iterations
}

// Random line biased towards markdown metacharacters so the span parser's
// marker matching, unmatched-marker recovery, and pill sentinels are all hit.
random_line :: proc(p: ^Prng) -> string {
	n := int_range(p, 0, MAXIMUM_LINE_BYTES)
	b := make([]u8, n, context.temp_allocator)
	meta := [?]u8{'*', '`', '|', '-', ':', 'h', 't', 'p', '/', '.', ' ', '\t', 0x01, 0x02, 0xFF}
	for i in 0 ..< n {
		if int_range(p, 0, 3) == 0 {
			b[i] = meta[int_range(p, 0, len(meta))]
		} else {
			b[i] = u8(next_u64(p) & 0xFF)
		}
	}
	return string(b)
}

exercise_spans :: proc(p: ^Prng, line: string) {
	spans := ui.parse_inline_spans(line)
	display_len := ui.spans_display_len(spans)
	ensure(display_len >= 0, "display length must be non-negative")
	ensure(display_len <= len(line), "display text can never be longer than raw text")
	for span in spans {
		ensure(span.raw_start >= 0, "span start in range")
		ensure(span.raw_end <= len(line), "span end in range")
		ensure(span.raw_start <= span.raw_end, "span start <= end")
	}
	// Offset maps must stay in range for ANY offset, valid or hostile.
	raw_probe := int_range(p, 0, len(line) + 2)
	display_position := ui.raw_to_display(spans, raw_probe)
	ensure(display_position >= 0, "raw_to_display in range")
	ensure(display_position <= display_len, "raw_to_display in range")
	display_probe := int_range(p, 0, display_len + 2)
	raw_position := ui.display_to_raw(spans, display_probe)
	ensure(raw_position >= 0, "display_to_raw in range")
	ensure(raw_position <= len(line), "display_to_raw in range")
}

exercise_table :: proc(p: ^Prng, line: string) {
	_ = ui.is_code_fence(line)
	_ = ui.is_table_separator(line)
	line_end := int_range(p, 0, len(line) + 1)
	line_start := int_range(p, 0, line_end + 1)
	cells, starts := ui.split_table_row_offsets(line, line_start, line_end)
	ensure(len(cells) == len(starts), "cells and starts must stay parallel")
	for start in starts {
		ensure(start >= 0, "cell start in range")
		ensure(start <= len(line), "cell start in range")
	}
}

// exercise_widget_math fuzzes the pure widget helpers: menu navigation must
// always land on a selectable row (or stay put) and stay in bounds, and
// slider stepping must never escape [lo, hi] for any ratio/step combination.
exercise_widget_math :: proc(p: ^Prng) {
	// Menu navigation over a random mix of items/separators/disabled rows.
	n := int_range(p, 1, 12)
	items := make([]ui.Menu_Item, n, context.temp_allocator)
	for i in 0 ..< n {
		items[i] = ui.Menu_Item {
			label     = "x",
			disabled  = int_range(p, 0, 4) == 0,
			separator = int_range(p, 0, 4) == 0,
		}
	}
	current := int_range(p, 0, n)
	delta := 1 if next_u64(p) % 2 == 0 else -1
	next := ui.menu_nav_next(items, current, delta)
	ensure(next >= 0 && next < n, "menu_nav_next index in range")
	if next != current {
		ensure(!items[next].separator, "menu_nav_next landed on a separator")
		ensure(!items[next].disabled, "menu_nav_next landed on a disabled row")
	}

	// Slider stepping: any ratio and step must clamp into [lo, hi].
	lo := f32(int_range(p, -1000, 1000))
	hi := lo + f32(int_range(p, 1, 2000))
	step := f32(int_range(p, 0, 50))
	t := f32(next_u64(p) % 1001) / 1000.0
	v := ui.slider_step_value(lo, hi, step, t)
	ensure(v >= lo && v <= hi, "slider_step_value escaped [lo, hi]")
	d := ui.slider_keyboard_delta(lo, hi, step)
	ensure(d > 0, "slider_keyboard_delta must be positive")

	// Wheel accumulation: remainder must stay under one row either way.
	accum := f32(next_u64(p) % 100) / 100.0 - 0.5
	wheel := f32(int_range(p, -300, 300)) / 100.0
	_ = ui.wheel_accum_steps(&accum, wheel)
	ensure(accum > -1 && accum < 1, "wheel remainder out of range")
}

main :: proc() {
	seed, iterations := parse_options()
	fmt.printfln("fuzz_ui seed=%d iterations=%d", seed, iterations)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)

	p := prng_make(seed)
	for _ in 0 ..< iterations {
		line := random_line(&p)
		exercise_spans(&p, line)
		exercise_table(&p, line)
		exercise_widget_math(&p)
		free_all(context.temp_allocator)
	}

	if len(track.allocation_map) > 0 {
		for _, entry in track.allocation_map {
			fmt.eprintfln("LEAK %v bytes @ %v", entry.size, entry.location)
		}
		fmt.eprintfln("fuzz_ui FAILED: %d leaks — reproduce with -seed:%d", len(track.allocation_map), seed)
		os.exit(1)
	}
	if len(track.bad_free_array) > 0 {
		fmt.eprintfln("fuzz_ui FAILED: %d bad frees — reproduce with -seed:%d", len(track.bad_free_array), seed)
		os.exit(1)
	}
	fmt.printfln("fuzz_ui ok")
}
