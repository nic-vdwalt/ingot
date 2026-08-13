#+build !js
package fit

import "core:log"
import "core:testing"
import "core:time"
import fuzzx "ingot:fuzz/fuzzx"
import "ingot:ui"

FIT_FUZZ_ITER :: #config(INGOT_FUZZ_ITER, 128)
FIT_FUZZ_SEED :: #config(INGOT_FUZZ_SEED, 0)
FIT_FUZZ_NODE_LIMIT :: 24
FIT_FUZZ_STORAGE_CAPACITY :: STORAGE_NODE_DEFAULT + 64

Fit_Fuzz_Counts :: struct {
	customs: i32,
	measure: i32,
	render:  i32,
}

@(private = "file")
fit_fuzz_font_for_size :: proc(data: rawptr, size: i32) -> ui.Font_Id {
	assert(data != nil && size >= 0, "fit fuzz font: invalid argument")
	return ui.Font_Id(size)
}

@(private = "file")
fit_fuzz_text_measure :: proc(
	data: rawptr,
	font: ui.Font_Id,
	text: string,
	size, spacing: f32,
) -> ui.Vec2 {
	assert(data != nil && font != 0, "fit fuzz text: invalid backend")
	assert(size >= 0 && spacing >= 0, "fit fuzz text: invalid geometry")
	return {f32(len(text)) * max(size * 0.5, 1), size}
}

@(private = "file")
fit_fuzz_custom_measure :: proc(constraints: Constraints, userdata: rawptr) -> Size {
	assert(userdata != nil, "fit fuzz measure: invalid argument")
	assert(constraints.max_w >= 0 && constraints.max_h >= 0, "fit fuzz measure: invalid bounds")
	counts := cast(^Fit_Fuzz_Counts)userdata
	counts.measure += 1
	return {32, 18, false}
}

@(private = "file")
fit_fuzz_custom_render :: proc(surface: ^Surface, rect: Rect, userdata: rawptr) -> bool {
	assert(surface != nil && userdata != nil, "fit fuzz render: invalid argument")
	assert(rect.w >= 0 && rect.h >= 0, "fit fuzz render: invalid rect")
	counts := cast(^Fit_Fuzz_Counts)userdata
	counts.render += 1
	return false
}

@(private = "file")
fit_fuzz_track :: proc(p: ^fuzzx.Prng) -> Track {
	if fuzzx.int_range(p, 0, 2) == 0 do return Fixed(i32(fuzzx.int_range(p, 0, 65)))
	return Fit(i32(fuzzx.int_range(p, 0, 65)))
}

@(private = "file")
fit_fuzz_container :: proc(builder: ^Builder, p: ^fuzzx.Prng) {
	assert(builder != nil && p != nil, "fit fuzz container: invalid argument")
	switch fuzzx.int_range(p, 0, 4) {
	case 0:
		Row(builder, {gap = .XS, padding = .XS, track = fit_fuzz_track(p)})
	case 1:
		Column(builder, {gap = .SM, padding = .XS, track = fit_fuzz_track(p)})
	case 2:
		Flow(builder, {gap_x = .XS, gap_y = .SM, padding = .XS, track = fit_fuzz_track(p)})
	case 3:
		Grid(
			builder,
			{
				columns = i32(fuzzx.int_range(p, 1, 5)),
				row_height = i32(fuzzx.int_range(p, 0, 49)),
				gap_x = .XS,
				gap_y = .SM,
				padding = .XS,
				track = fit_fuzz_track(p),
			},
		)
	}
}

@(private = "file")
fit_fuzz_leaf :: proc(
	builder: ^Builder,
	p: ^fuzzx.Prng,
	counts: ^Fit_Fuzz_Counts,
	activations: ^[FIT_FUZZ_NODE_LIMIT]bool,
	selections: ^[FIT_FUZZ_NODE_LIMIT]i32,
	values: ^[FIT_FUZZ_NODE_LIMIT]f32,
	key: u64,
) {
	assert(
		builder != nil && p != nil && counts != nil && activations != nil,
		"fit fuzz leaf: nil argument",
	)
	assert(selections != nil && values != nil, "fit fuzz leaf: nil control state")
	index := int(key % FIT_FUZZ_NODE_LIMIT)
	switch fuzzx.int_range(p, 0, 6) {
	case 0:
		Label(
			builder,
			"fuzz label alpha beta",
			{role = .Body, wrap = fuzzx.int_range(p, 0, 2) == 0, track = fit_fuzz_track(p)},
		)
	case 1:
		Button(builder, key + 1, "Fuzz button", &activations[index])
	case 2:
		counts.customs += 1
		Custom(
			builder,
			{
				measure = fit_fuzz_custom_measure,
				render = fit_fuzz_custom_render,
				userdata = counts,
			},
			{track = fit_fuzz_track(p), activated = &activations[index]},
		)
	case 3:
		Checkbox(builder, key + 1, "Fuzz checkbox", &activations[index])
	case 4:
		Radio(builder, key + 1, "Fuzz radio", &selections[index], i32(index))
	case 5:
		Slider(builder, key + 1, &values[index], 0, f32(FIT_FUZZ_NODE_LIMIT), 1, "Fuzz slider")
	}
}

@(private = "file")
fit_fuzz_description :: proc(
	builder: ^Builder,
	p: ^fuzzx.Prng,
	counts: ^Fit_Fuzz_Counts,
	activations: ^[FIT_FUZZ_NODE_LIMIT]bool,
	selections: ^[FIT_FUZZ_NODE_LIMIT]i32,
	values: ^[FIT_FUZZ_NODE_LIMIT]f32,
) {
	assert(
		builder != nil && p != nil && counts != nil && activations != nil,
		"fit fuzz description: nil argument",
	)
	assert(selections != nil && values != nil, "fit fuzz description: nil control state")
	fit_fuzz_container(builder, p)
	depth := 1
	nodes := 1
	key: u64 = 1
	fit_fuzz_leaf(builder, p, counts, activations, selections, values, key)
	nodes += 1
	key += 1
	target := fuzzx.int_range(p, 8, FIT_FUZZ_NODE_LIMIT + 1)
	for nodes < target {
		action := fuzzx.int_range(p, 0, 5)
		if action == 0 && depth > 1 {
			End(builder)
			depth -= 1
			continue
		}
		if action <= 2 && depth < 8 && nodes + 2 <= target {
			attachment := fuzzx.int_range(p, 0, 5) == 0
			if attachment {
				Attachment(builder, {target_kind = .Viewport, z = Z_Order(200)})
				fit_fuzz_leaf(builder, p, counts, activations, selections, values, key)
				End(builder)
			} else {
				fit_fuzz_container(builder, p)
				fit_fuzz_leaf(builder, p, counts, activations, selections, values, key)
				depth += 1
			}
			nodes += 2
			key += 1
			continue
		}
		fit_fuzz_leaf(builder, p, counts, activations, selections, values, key)
		nodes += 1
		key += 1
	}
	for depth > 0 {
		End(builder)
		depth -= 1
	}
}

@(private = "file")
fit_fuzz_select_storage :: proc(
	t: ^testing.T,
	p: ^fuzzx.Prng,
	builder: ^Builder,
	nodes: []Storage_Node,
	outputs: []^bool,
	seed: u64,
	iteration: int,
) -> bool {
	external := fuzzx.int_range(p, 0, 2) == 0
	if external {
		capacity := fuzzx.int_range(p, FIT_FUZZ_NODE_LIMIT, len(nodes) + 1)
		Set_Storage(builder, {nodes = nodes[:capacity], outputs = outputs[:capacity]})
		testing.expectf(
			t,
			Storage_Capacity(builder) == capacity,
			"seed %d iteration %d: external storage capacity mismatch",
			seed,
			iteration,
		)
	} else {
		testing.expectf(
			t,
			Storage_Capacity(builder) == int(STORAGE_NODE_DEFAULT),
			"seed %d iteration %d: inline storage capacity mismatch",
			seed,
			iteration,
		)
	}
	return external
}

@(private = "file")
fit_fuzz_iteration :: proc(t: ^testing.T, p: ^fuzzx.Prng, seed: u64, iteration: int) {
	runtime: ui.Ui_Runtime
	ui.ui_runtime_init(&runtime)
	text_backend := i32(1)
	ui.ui_runtime_set_text_backend(
		&runtime,
		{
			data = &text_backend,
			font_for_size = fit_fuzz_font_for_size,
			measure = fit_fuzz_text_measure,
		},
	)
	output := new(ui.Ui_Output)
	frame := ui.Ui_Frame {
		output = output,
	}
	ui.ui_frame_begin(&frame, &runtime)
	builder: Builder
	nodes: [FIT_FUZZ_STORAGE_CAPACITY]Storage_Node
	outputs: [FIT_FUZZ_STORAGE_CAPACITY]^bool
	external := fit_fuzz_select_storage(t, p, &builder, nodes[:], outputs[:], seed, iteration)
	width := i32(fuzzx.int_range(p, 64, 1025))
	height := i32(fuzzx.int_range(p, 64, 769))
	builder_open(&builder, &frame, {0, 0, width, height})
	counts: Fit_Fuzz_Counts
	activations: [FIT_FUZZ_NODE_LIMIT]bool
	selections: [FIT_FUZZ_NODE_LIMIT]i32
	values: [FIT_FUZZ_NODE_LIMIT]f32
	fit_fuzz_description(&builder, p, &counts, &activations, &selections, &values)
	size := Measure(&builder)
	testing.expectf(
		t,
		size.w >= 0 && size.h >= 0,
		"seed %d iteration %d: negative measurement",
		seed,
		iteration,
	)
	if iteration % 2 == 0 {
		Render_At(&builder, {0, 0, max(size.w, 1), max(size.h, 1)})
	} else {
		rect := Render(&builder)
		testing.expectf(
			t,
			rect.w >= 0 && rect.h >= 0,
			"seed %d iteration %d: negative render bounds",
			seed,
			iteration,
		)
	}
	testing.expectf(
		t,
		counts.render == counts.customs,
		"seed %d iteration %d: custom render count %d != %d",
		seed,
		iteration,
		counts.render,
		counts.customs,
	)
	testing.expectf(
		t,
		counts.measure >= counts.customs,
		"seed %d iteration %d: custom measure count %d < %d",
		seed,
		iteration,
		counts.measure,
		counts.customs,
	)
	builder_close(&builder)
	if external {
		Reset_Storage(&builder)
		testing.expectf(
			t,
			Storage_Capacity(&builder) == int(STORAGE_NODE_DEFAULT),
			"seed %d iteration %d: storage reset failed",
			seed,
			iteration,
		)
	}
	ui.ui_frame_end(&frame)
	ui.ui_frame_destroy(&frame)
	free(output)
	ui.ui_runtime_destroy(&runtime)
}

@(test)
fit_public_builder_fuzz :: proc(t: ^testing.T) {
	seed := u64(FIT_FUZZ_SEED)
	if seed == 0 do seed = u64(time.now()._nsec)
	log.infof("fit fuzz seed=%d iterations=%d", seed, FIT_FUZZ_ITER)
	p := fuzzx.prng_make(seed)
	for iteration in 0 ..< FIT_FUZZ_ITER do fit_fuzz_iteration(t, &p, seed, iteration)
}
