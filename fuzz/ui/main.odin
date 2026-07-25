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
import "core:unicode/utf8"
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

exercise_spans :: proc(c: ^fuzzx.Ctx, p: ^Prng, frame: ^ui.Ui_Frame, line: string) {
	spans := ui.frame_view_items(frame, ui.parse_inline_spans(frame, line))
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

exercise_table :: proc(c: ^fuzzx.Ctx, p: ^Prng, frame: ^ui.Ui_Frame, line: string) {
	_ = ui.is_code_fence(line)
	_ = ui.is_table_separator(line)
	line_end := fuzzx.int_range(p, 0, len(line) + 1)
	line_start := fuzzx.int_range(p, 0, line_end + 1)
	cells_view, starts_view := ui.split_table_row_offsets(frame, line, line_start, line_end)
	cells := ui.frame_view_items(frame, cells_view)
	starts := ui.frame_view_items(frame, starts_view)
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
exercise_document :: proc(c: ^fuzzx.Ctx, p: ^Prng, frame: ^ui.Ui_Frame) {
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
		exercise_spans(c, p, frame, line)
		exercise_table(c, p, frame, line)
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

// exercise_eased property-fuzzes the animation easing primitive: band
// containment, monotone convergence, hostile dt/speed, and the one-sided
// frame-partition property (sub-steps never get closer than one big step).
exercise_eased :: proc(c: ^fuzzx.Ctx, p: ^Prng) {
	// Magnitudes stay under 4096 so one f32 ulp is well below the 0.001
	// snap threshold; a wider range would make band checks flaky by ulps.
	current0 := f32(fuzzx.int_range(p, -64_000, 64_000)) / 16.0
	target := f32(fuzzx.int_range(p, -64_000, 64_000)) / 16.0
	dt := f32(fuzzx.int_range(p, 0, 4_000)) / 1000.0 // 0..4 s
	speed := f32(fuzzx.int_range(p, 0, 64_000)) / 1000.0 // 0..64 units/s
	lo, hi := min(current0, target), max(current0, target)

	// Single step: never escapes [current, target], never moves away.
	single := current0
	ui.eased(&single, target, dt, speed)
	fuzzx.check(c, single >= lo && single <= hi, "eased escaped [current, target]")
	fuzzx.check(c, abs(target - single) <= abs(target - current0), "eased moved away from target")

	// Hostile inputs: negative and NaN dt/speed must hold position
	// (the terminal snap may still fire when already within 0.001).
	nan := transmute(f32)u32(0x7FC0_0000)
	hostile := [4][2]f32{{-dt, speed}, {dt, -speed}, {nan, speed}, {dt, nan}}
	for hd in hostile {
		v := current0
		ui.eased(&v, target, hd[0], hd[1])
		fuzzx.check(c, v == current0 || v == target, "eased moved on hostile dt/speed")
	}

	// Convergence: any meaningful per-frame factor must settle exactly.
	if speed * dt >= 0.01 {
		v := current0
		settled := false
		for _ in 0 ..< 5_000 {
			if ui.eased(&v, target, dt, speed) == target {
				settled = true
				break
			}
		}
		fuzzx.check(c, settled, "eased failed to converge to target")
	}

	// Partition: m sub-steps stay in band and end no closer than one step —
	// unless a sub-step hit the f32-stall terminal snap (split == target).
	steps := fuzzx.int_range(p, 2, 9)
	split := current0
	for _ in 0 ..< steps do ui.eased(&split, target, dt / f32(steps), speed)
	fuzzx.check(c, split >= lo && split <= hi, "split eased escaped [current, target]")
	tolerance := 0.002 + abs(target - current0) * 1e-5
	fuzzx.check(
		c,
		split == target || abs(target - split) + tolerance >= abs(target - single),
		"split steps overtook the single step",
	)
}

// exercise_semantics storms the accessibility semantic buffer: random roles,
// labels straddling truncation boundaries (multi-byte runes at SEM_LABEL_MAX),
// saturation past MAX_SEM_NODES, frame churn, and focus-registry
// interleaving — then validates the pure AccessKit node build.
exercise_semantics :: proc(c: ^fuzzx.Ctx, p: ^Prng) {
	runtime: ui.Ui_Runtime
	ui.ui_runtime_init(&runtime)
	defer ui.ui_runtime_destroy(&runtime)
	ui.sem_enable(&runtime, true)
	frame: ui.Ui_Frame
	ui.ui_frame_begin(&frame, &runtime)
	defer ui.ui_frame_end(&frame)

	roles := [?]ui.Sem_Role {
		.Button,
		.Checkbox,
		.Radio,
		.Slider,
		.Dropdown,
		.Menu_Item,
		.Label,
		.Pane,
		.Modal,
	}
	slots: [4]int
	// (slot, id) pairs must be unique per frame the way real widget code is
	// unique — the same pair IS the same widget and legitimately shares a
	// node id, so the fuzzer allocates ids sequentially per slot.
	next_focus_id: [4]int

	frames := fuzzx.int_range(p, 1, 4)
	for _ in 0 ..< frames {
		ui.sem_begin_frame(&frame)
		for i in 0 ..< len(next_focus_id) do next_focus_id[i] = 1
		pushes := fuzzx.int_range(p, 0, ui.MAX_SEM_NODES + 40) // past saturation sometimes
		for _ in 0 ..< pushes {
			role := roles[fuzzx.int_range(p, 0, len(roles))]
			// Label biased to straddle the truncation cap with multi-byte runes.
			label_bytes := fuzzx.random_bytes(p, ui.SEM_LABEL_MAX + 8)
			if fuzzx.int_range(p, 0, 2) == 0 && len(label_bytes) >= 4 {
				copy(label_bytes[len(label_bytes) - 4:], "€") // 3-byte rune near the end
			}
			focus := ui.Focus_Opt{}
			if fuzzx.int_range(p, 0, 3) == 0 {
				slot := fuzzx.int_range(p, 0, len(slots))
				focus = {&slots[slot], next_focus_id[slot]}
				next_focus_id[slot] += 1
			}
			ui.semantic_push(
				&frame,
				role,
				{
					i32(fuzzx.int_range(p, -50, 2000)),
					i32(fuzzx.int_range(p, -50, 2000)),
					i32(fuzzx.int_range(p, 1, 500)),
					i32(fuzzx.int_range(p, 1, 200)),
				},
				string(label_bytes),
				{},
				focus,
				value = f32(fuzzx.int_range(p, 0, 100)),
				lo = 0,
				hi = 100,
			)
		}

		semantics := ui.sem_frame(&frame)
		fuzzx.check(
			c,
			semantics.count >= 0 && semantics.count <= ui.MAX_SEM_NODES,
			"sem buffer overflow",
		)
		for i in 0 ..< semantics.count {
			label := ui.sem_node_label(&semantics.nodes[i])
			fuzzx.check(c, len(label) <= ui.SEM_LABEL_MAX, "sem label exceeds cap")
			fuzzx.check(c, utf8.valid_string(label), "sem label not valid UTF-8 after truncation")
		}
		fuzzx.check(
			c,
			ui.sem_focus_list(&frame).count <= ui.MAX_SEM_FOCUS,
			"focus registry overflow",
		)
		fuzzx.check(
			c,
			frame.semantics.action_targets.count <= ui.MAX_SEM_FOCUS,
			"action target registry overflow",
		)

		// Pure AccessKit node build: ids unique, non-reserved; every desc
		// mirrors its source node.
		nodes, focus_id := ui.a11y_build_nodes(semantics, context.temp_allocator)
		fuzzx.check(c, len(nodes) == semantics.count, "a11y node count mismatch")
		fuzzx.check(c, focus_id != 0, "a11y focus id zero")
		for i in 0 ..< len(nodes) {
			fuzzx.check(c, nodes[i].id > 1, "a11y node id reserved")
			fuzzx.check(c, len(nodes[i].label) <= ui.SEM_LABEL_MAX, "a11y label exceeds cap")
			for j in i + 1 ..< len(nodes) {
				if nodes[i].id == nodes[j].id {
					_, actionable := ui.sem_action_target(&frame, nodes[i].id)
					fuzzx.check(c, !actionable, "a11y duplicate interactive node id")
				}
			}
		}
	}
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
		c := fuzzx.Ctx {
			name = "fuzz_ui",
			seed = round_seed,
		}
		for i in 0 ..< iterations {
			c.iteration = i
			runtime: ui.Ui_Runtime
			ui.ui_runtime_init(&runtime)
			frame: ui.Ui_Frame
			ui.ui_frame_begin(&frame, &runtime)
			line := make_line(&p)
			c.input = transmute([]u8)line
			exercise_spans(&c, &p, &frame, line)
			exercise_table(&c, &p, &frame, line)
			if i % 8 == 0 do exercise_document(&c, &p, &frame)
			ui.ui_frame_end(&frame)
			ui.ui_frame_destroy(&frame)
			ui.ui_runtime_destroy(&runtime)
			if i % 16 == 0 do exercise_semantics(&c, &p)
			exercise_widget_math(&c, &p)
			exercise_eased(&c, &p)
			free_all(context.temp_allocator)
		}
	}

	fuzzx.report(&track, "fuzz_ui", seed)
	fmt.printfln("fuzz_ui ok")
}
