package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import fit "ingot:fit"
import ui "ingot:ui"

WARMUP_DEFAULT :: 300
FRAMES_DEFAULT :: 2000
MAX_SCALE :: 16384
FIT_NODE_CAPACITY :: fit.STORAGE_NODE_HARD_MAX
STABLE_LABEL_LEN :: 15
VIRTUAL_ROWS :: 40
VIRTUAL_OVERSCAN :: 2
DASHBOARD_WIDGETS_PER_GROUP :: 10
DASHBOARD_MAX_GROUPS :: 250
FNV_BASIS :: u64(1469598103934665603)
FNV_PRIME :: u64(1099511628211)

Workload :: enum {
	Labels_Repeated,
	Labels_Unique,
	Labels_Stable_Unique,
	Labels_Changing_Unique,
	Input_Inactive,
	Input_Active,
	Checkbox_Only,
	Slider_Only,
	Button_Only,
	Button_Semantics_Disabled,
	Button_Semantics_Enabled,
	Button_Grid,
	Mixed_Form,
	Complex_Dashboard,
	Layout_Flow,
	List_Full,
	List_Virtual,
	Table_Repeated,
	Table_Unique,
	Dynamic_Churn,
	Accessibility,
	Capacity,
	Prepared_Flat_Fixed,
	Prepared_Flat_Intrinsic,
	Prepared_Rows_Fixed,
	Prepared_Rows_Intrinsic,
	Prepared_Deep_Fixed,
	Prepared_Deep_Intrinsic,
	Prepared_Wrapped,
	Prepared_Mixed_Tracks,
	Prepared_Effects,
}

Ingot_Layer :: enum {
	Fit,
	Ui,
}

Frame_Timing :: struct {
	build_ns:          i64,
	measure_ns:        i64,
	layout_render_ns:  i64,
	frame_finalize_ns: i64,
	finalize_ns:       i64,
	frame_ns:          i64,
}

Options :: struct {
	layer:         Ingot_Layer,
	workload:      Workload,
	scale:         int,
	warmup:        int,
	frames:        int,
	repetition:    int,
	measure_cache: bool,
}

Harness :: struct {
	driver:             fit.Test_Driver,
	input:              fit.Test_Input,
	nodes:              [FIT_NODE_CAPACITY]fit.Storage_Node,
	outputs:            [FIT_NODE_CAPACITY]^bool,
	checked:            [MAX_SCALE]bool,
	values:             [MAX_SCALE]f32,
	stable_labels:      [MAX_SCALE][32]u8,
	changing_labels:    [MAX_SCALE][32]u8,
	dashboard_inputs:   [DASHBOARD_MAX_GROUPS]fit.Input_Box,
	ui_runtime:         ui.Ui_Runtime,
	ui_frame:           ^ui.Ui_Frame,
	ui_output:          ^ui.Ui_Output,
	ui_input:           ui.Ui_Input,
	ui_inputs:          [DASHBOARD_MAX_GROUPS]ui.Input_Box,
	ui_telemetry:       ui.Ui_Frame_Telemetry,
	ui_diagnostics:     ui.Ui_Frame_Diagnostics,
	ui_active_input:    int,
	workload:           Workload,
	scale:              int,
	frame_index:        int,
	submitted:          int,
	layout_checksum:    u64,
	active_input_stage: i32,
	telemetry:          fit.Frame_Telemetry,
}

harness_make :: proc(layer: Ingot_Layer, semantics, measure_cache: bool) -> ^Harness {
	h := new(Harness)
	if layer == .Fit {
		fit.Test_Driver_Init(&h.driver)
		fit.Test_Driver_Set_Storage(&h.driver, {nodes = h.nodes[:], outputs = h.outputs[:]})
		fit.Test_Driver_Set_Semantics(&h.driver, semantics)
		fit.Test_Driver_Set_Backend_Measure_Cache(&h.driver, measure_cache)
	} else {
		h.ui_frame = new(ui.Ui_Frame)
		h.ui_output = new(ui.Ui_Output)
		h.ui_frame.output = h.ui_output
		ui.ui_runtime_init(&h.ui_runtime)
		ui.ui_runtime_set_text_backend(
			&h.ui_runtime,
			{data = h, font_for_size = benchmark_font, measure = benchmark_measure},
		)
		ui.ui_runtime_set_backend_measure_cache_enabled(&h.ui_runtime, measure_cache)
		ui.sem_enable(&h.ui_runtime, semantics)
		h.ui_input.screen_size = {1280, 720}
		h.ui_input.dpi_scale = 1
	}
	h.input.screen_size = {1280, 720}
	h.input.dpi_scale = 1
	for index in 0 ..< MAX_SCALE {
		_ = fmt.bprintf(h.stable_labels[index][:], "Widget %08d", index)
	}
	return h
}

harness_destroy :: proc(h: ^Harness, layer: Ingot_Layer) {
	assert(h != nil, "harness_destroy: nil harness")
	if layer == .Fit {
		for index in 0 ..< DASHBOARD_MAX_GROUPS {
			fit.Input_Box_Destroy(&h.dashboard_inputs[index])
		}
		fit.Test_Driver_Destroy(&h.driver)
	} else {
		for index in 0 ..< DASHBOARD_MAX_GROUPS {
			ui.input_box_destroy(&h.ui_inputs[index])
		}
		ui.ui_frame_destroy(h.ui_frame)
		ui.ui_runtime_destroy(&h.ui_runtime)
		free(h.ui_output)
		free(h.ui_frame)
	}
	free(h)
}

benchmark_font :: proc(data: rawptr, size: i32) -> ui.Font_Id {
	assert(data != nil && size > 0, "benchmark_font: invalid argument")
	return ui.Font_Id(size)
}

benchmark_measure :: proc(
	data: rawptr,
	font: ui.Font_Id,
	text: string,
	size, spacing: f32,
) -> ui.Vec2 {
	assert(data != nil && font != 0, "benchmark_measure: invalid argument")
	assert(size >= 0 && spacing >= 0, "benchmark_measure: invalid geometry")
	return {f32(len(text)) * max(size * 0.5, 1), size}
}

label_for :: proc(h: ^Harness, index: int, unique: bool) -> string {
	assert(h != nil && index >= 0, "label_for: invalid argument")
	if !unique do return "Widget"
	return string(h.stable_labels[index % MAX_SCALE][:STABLE_LABEL_LEN])
}

changing_label_for :: proc(h: ^Harness, index: int) -> string {
	assert(h != nil && index >= 0 && index < MAX_SCALE, "changing_label_for: invalid argument")
	return fmt.bprintf(h.changing_labels[index][:], "Widget %08d %08d", index, h.frame_index)
}

hash_u64 :: proc(hash, value: u64) -> u64 {
	result := hash
	for shift: u64 = 0; shift < 64; shift += 8 {
		result ~= (value >> shift) & 0xff
		result *= FNV_PRIME
	}
	return result
}

label_options :: proc(width, height: i32) -> fit.Label_Options {
	return {size = {width = fit.Fixed(width), height = fit.Fixed(height)}}
}

control_options :: proc(width, height: i32) -> fit.Control_Options {
	return {size = {width = fit.Fixed(width), height = fit.Fixed(height)}}
}

button_options :: proc(width, height: i32) -> fit.Button_Options {
	return {size = {width = fit.Fixed(width), height = fit.Fixed(height)}}
}

run_labels :: proc(builder: ^fit.Builder, h: ^Harness, count: int, unique: bool) -> int {
	assert(builder != nil && h != nil && count > 0, "run_labels: invalid argument")
	grid := fit.Grid(builder, {columns = 10, row_height = 18})
	for index in 0 ..< count {
		fit.Label(grid, label_for(h, index, unique), label_options(124, 18))
	}
	return count
}

run_isolated_labels :: proc(
	builder: ^fit.Builder,
	h: ^Harness,
	count: int,
	changing: bool,
) -> int {
	assert(builder != nil && h != nil && count > 0, "run_isolated_labels: invalid argument")
	grid := fit.Grid(builder, {columns = 10, row_height = 18})
	for index in 0 ..< count {
		label := changing_label_for(h, index) if changing else label_for(h, index, true)
		fit.Label(grid, label, label_options(124, 18))
	}
	return count
}

run_inputs :: proc(builder: ^fit.Builder, h: ^Harness, count: int) -> int {
	assert(builder != nil && h != nil && count > 0, "run_inputs: invalid argument")
	assert(count <= DASHBOARD_MAX_GROUPS, "run_inputs: too many inputs")
	grid := fit.Grid(builder, {columns = 1, row_height = 24})
	for index in 0 ..< count {
		fit.Text_Input(
			grid,
			u64(index + 1),
			&h.dashboard_inputs[index],
			"Filter",
			{
				semantics = {name = "Filter"},
				size = {width = fit.Fixed(180), height = fit.Fixed(24)},
			},
		)
	}
	return count
}

run_checkboxes :: proc(builder: ^fit.Builder, h: ^Harness, count: int) -> int {
	assert(builder != nil && h != nil && count > 0, "run_checkboxes: invalid argument")
	grid := fit.Grid(builder, {columns = 10, row_height = 24})
	for index in 0 ..< count {
		fit.Checkbox(grid, u64(index + 1), "Check", &h.checked[index], control_options(96, 24))
	}
	return count
}

run_sliders :: proc(builder: ^fit.Builder, h: ^Harness, count: int) -> int {
	assert(builder != nil && h != nil && count > 0, "run_sliders: invalid argument")
	grid := fit.Grid(builder, {columns = 8, row_height = 24})
	for index in 0 ..< count {
		fit.Slider(
			grid,
			u64(index + 1),
			&h.values[index],
			0,
			1,
			0.01,
			"Value",
			control_options(144, 24),
		)
	}
	return count
}

run_buttons :: proc(builder: ^fit.Builder, count: int) -> int {
	assert(builder != nil && count > 0, "run_buttons: invalid argument")
	grid := fit.Grid(builder, {columns = 10, row_height = 24})
	for index in 0 ..< count {
		fit.Button(grid, u64(index + 1), "Button", button_options(96, 24))
	}
	return count
}

run_mixed :: proc(builder: ^fit.Builder, h: ^Harness, groups: int) -> int {
	assert(builder != nil && h != nil && groups > 0, "run_mixed: invalid argument")
	grid := fit.Grid(builder, {columns = 1, row_height = 30})
	for index in 0 ..< groups {
		row_parent := fit.Row(grid, {size = {height = fit.Fixed(30)}})
		fit.Label(row_parent, "Label", label_options(100, 24))
		fit.Checkbox(
			row_parent,
			u64(index * 4 + 1),
			"Check",
			&h.checked[index],
			control_options(120, 24),
		)
		fit.Slider(
			row_parent,
			u64(index * 4 + 2),
			&h.values[index],
			0,
			1,
			0.01,
			"Value",
			control_options(140, 24),
		)
		fit.Label(row_parent, "Input", label_options(160, 24))
		fit.Button(row_parent, u64(index * 4 + 3), "Submit", button_options(96, 24))
	}
	return groups * 5
}

run_dashboard :: proc(builder: ^fit.Builder, h: ^Harness, groups: int) -> int {
	assert(builder != nil && h != nil && groups > 0, "run_dashboard: invalid argument")
	assert(groups <= DASHBOARD_MAX_GROUPS, "run_dashboard: too many groups")
	grid := fit.Grid(builder, {columns = 1, row_height = 30})
	for index in 0 ..< groups {
		row_parent := fit.Row(grid, {size = {height = fit.Fixed(30)}})
		fit.Label(row_parent, label_for(h, index, true), label_options(124, 24))
		fit.Label(row_parent, "Healthy", label_options(76, 24))
		fit.Checkbox(
			row_parent,
			u64(index * 4 + 1),
			"Live",
			&h.checked[index],
			control_options(88, 24),
		)
		fit.Slider(
			row_parent,
			u64(index * 4 + 2),
			&h.values[index],
			0,
			1,
			0.01,
			"Value",
			control_options(130, 24),
		)
		fit.Text_Input(
			row_parent,
			u64(index * 4 + 3),
			&h.dashboard_inputs[index],
			"Filter",
			{
				semantics = {name = "Filter"},
				size = {width = fit.Fixed(150), height = fit.Fixed(24)},
			},
		)
		fit.Button(row_parent, u64(index * 4 + 4), "Open", button_options(72, 24))
		for _ in 0 ..< 4 do fit.Label(row_parent, "Data", label_options(82, 24))
	}
	return groups * DASHBOARD_WIDGETS_PER_GROUP
}

layout_render :: proc(surface: ^fit.Surface, rect: fit.Rect, userdata: rawptr) -> bool {
	assert(surface != nil && userdata != nil, "layout_render: invalid argument")
	h := cast(^Harness)userdata
	flow: fit.Flow_State
	fit.Flow_Begin(surface, &flow, rect, 6, 4)
	checksum := FNV_BASIS
	for index in 0 ..< h.scale {
		item := fit.Flow_Next(&flow, i32(24 + index % 17 * 7), i32(18 + index % 3 * 4))
		checksum = hash_u64(checksum, u64(item.x))
		checksum = hash_u64(checksum, u64(item.y))
		checksum = hash_u64(checksum, u64(item.w))
		checksum = hash_u64(checksum, u64(item.h))
	}
	bounds := fit.Flow_End(&flow)
	h.layout_checksum = hash_u64(checksum, u64(bounds.h))
	return false
}

run_layout_flow :: proc(builder: ^fit.Builder, h: ^Harness) -> int {
	assert(builder != nil && h != nil && h.scale > 0, "run_layout_flow: invalid argument")
	fit.Canvas(builder, layout_render, h)
	return h.scale
}

run_prepared_flat :: proc(builder: ^fit.Builder, h: ^Harness, fixed: bool) -> int {
	assert(builder != nil && h != nil && h.scale > 0, "prepared flat: invalid argument")
	grid := fit.Grid(builder, {columns = 8, row_height = 18})
	for index in 0 ..< h.scale {
		options := label_options(124, 18) if fixed else fit.Label_Options{}
		fit.Label(grid, label_for(h, index, true), options)
	}
	return h.scale
}

run_prepared_rows :: proc(builder: ^fit.Builder, h: ^Harness, fixed: bool) -> int {
	assert(builder != nil && h != nil && h.scale >= 4, "prepared rows: invalid argument")
	grid := fit.Grid(builder, {columns = 1, row_height = 18})
	rows := h.scale / 4
	for row in 0 ..< rows {
		row_parent := fit.Row(grid, {size = {height = fit.Fixed(18)}})
		for column in 0 ..< 4 {
			index := row * 4 + column
			options := label_options(124, 18) if fixed else fit.Label_Options{}
			fit.Label(row_parent, label_for(h, index, true), options)
		}
	}
	return rows * 4
}

run_prepared_deep :: proc(builder: ^fit.Builder, h: ^Harness, fixed: bool) -> int {
	assert(builder != nil && h != nil && h.scale > 0, "prepared deep: invalid argument")
	depth := min(h.scale, 15)
	parent := fit.Column(builder, {size = {width = fit.Fixed(320)}})
	for _ in 1 ..< depth do parent = fit.Column(parent, {size = {width = fit.Fixed(320)}})
	options := label_options(124, 18) if fixed else fit.Label_Options{}
	fit.Label(parent, "Deep", options)
	return 1
}

run_prepared_wrapped :: proc(builder: ^fit.Builder, h: ^Harness) -> int {
	assert(builder != nil && h != nil && h.scale > 0, "prepared wrapped: invalid argument")
	grid := fit.Grid(builder, {columns = 4, row_height = 36})
	for _ in 0 ..< h.scale {
		fit.Label(grid, "Prepared wrapped label content", {wrap = true})
	}
	return h.scale
}

run_prepared_mixed :: proc(builder: ^fit.Builder, h: ^Harness) -> int {
	assert(builder != nil && h != nil && h.scale > 0, "prepared mixed: invalid argument")
	grid := fit.Grid(builder, {columns = 4, row_height = 24})
	for index in 0 ..< h.scale {
		width := fit.Fixed(100)
		if index % 3 == 1 do width = fit.Grow()
		if index % 3 == 2 do width = fit.Percent(0.25)
		fit.Label(
			grid,
			label_for(h, index, true),
			{size = {width = width, height = fit.Fixed(24)}},
		)
	}
	return h.scale
}

run_virtual_list :: proc(builder: ^fit.Builder, h: ^Harness, logical_count: int) -> int {
	assert(builder != nil && h != nil && logical_count > 0, "run_virtual_list: invalid argument")
	submitted := min(logical_count, VIRTUAL_ROWS + VIRTUAL_OVERSCAN * 2)
	start := clamp(logical_count / 2 - VIRTUAL_OVERSCAN, 0, logical_count - submitted)
	grid := fit.Grid(builder, {columns = 1, row_height = 18})
	for offset in 0 ..< submitted {
		fit.Label(grid, label_for(h, start + offset, true), label_options(320, 18))
	}
	return submitted
}

run_table :: proc(builder: ^fit.Builder, h: ^Harness, rows: int, unique: bool) -> int {
	assert(builder != nil && h != nil && rows > 0, "run_table: invalid argument")
	grid := fit.Grid(builder, {columns = 4, row_height = 18})
	for row in 0 ..< rows {
		for column in 0 ..< 4 {
			label := label_for(h, (row * 4 + column) % MAX_SCALE, unique)
			fit.Label(grid, label, label_options(216, 18))
		}
	}
	return rows * 4
}

run_churn :: proc(builder: ^fit.Builder, h: ^Harness, count: int) -> int {
	assert(builder != nil && h != nil && count > 0, "run_churn: invalid argument")
	grid := fit.Grid(builder, {columns = 1, row_height = 18})
	for position in 0 ..< count {
		churned := (position + h.frame_index) % 10 == 0
		index := (position + h.frame_index) % count if churned else position
		fit.Label(grid, label_for(h, index, true), label_options(320, 18))
	}
	return count
}

ui_label_at :: proc(h: ^Harness, text: string, rect: ui.Rect_I32) {
	assert(h != nil && h.ui_frame != nil && text != "", "ui_label_at: invalid argument")
	style := ui.ui_frame_theme(h.ui_frame)
	ui.draw_text_string_frame(
		h.ui_frame,
		text,
		rect.x,
		rect.y + (rect.h - 16) / 2,
		16,
		style.fg_primary,
	)
	ui.semantic_push(h.ui_frame, .Label, rect, text, {})
}

run_labels_ui :: proc(h: ^Harness, count: int, unique: bool) -> int {
	assert(h != nil && count > 0, "run_labels_ui: invalid argument")
	for index in 0 ..< count {
		rect := ui.Rect_I32{i32(index % 10 * 126), i32(index / 10 * 18), 124, 18}
		ui_label_at(h, label_for(h, index, unique), rect)
	}
	return count
}

run_isolated_labels_ui :: proc(h: ^Harness, count: int, changing: bool) -> int {
	assert(h != nil && count > 0, "run_isolated_labels_ui: invalid argument")
	for index in 0 ..< count {
		label := changing_label_for(h, index) if changing else label_for(h, index, true)
		rect := ui.Rect_I32{i32(index % 10 * 126), i32(index / 10 * 18), 124, 18}
		ui_label_at(h, label, rect)
	}
	return count
}

run_inputs_ui :: proc(h: ^Harness, count: int) -> int {
	assert(
		h != nil && count > 0 && count <= DASHBOARD_MAX_GROUPS,
		"run_inputs_ui: invalid argument",
	)
	for index in 0 ..< count {
		active := h.ui_active_input == index
		_ = ui.text_input_at(
			h.ui_frame,
			{0, i32(index * 24), 180, 24},
			&h.ui_inputs[index],
			"Filter",
			active,
			semantics = {name = "Filter"},
		)
	}
	return count
}

run_checkboxes_ui :: proc(h: ^Harness, count: int) -> int {
	assert(h != nil && count > 0, "run_checkboxes_ui: invalid argument")
	for index in 0 ..< count {
		rect := ui.Rect_I32{i32(index % 10 * 100), i32(index / 10 * 24), 96, 24}
		_ = ui.checkbox_at(
			h.ui_frame,
			rect,
			"Check",
			&h.checked[index],
			widget = ui.widget_id(u64(index + 1)),
		)
	}
	return count
}

run_sliders_ui :: proc(h: ^Harness, count: int) -> int {
	assert(h != nil && count > 0, "run_sliders_ui: invalid argument")
	for index in 0 ..< count {
		rect := ui.Rect_I32{i32(index % 8 * 148), i32(index / 8 * 24), 144, 24}
		_ = ui.slider_at(
			h.ui_frame,
			rect,
			&h.values[index],
			0,
			1,
			0.01,
			a11y_label = "Value",
			widget = ui.widget_id(u64(index + 1)),
		)
	}
	return count
}

run_buttons_ui :: proc(h: ^Harness, count: int) -> int {
	assert(h != nil && count > 0, "run_buttons_ui: invalid argument")
	for index in 0 ..< count {
		rect := ui.Rect_I32{i32(index % 10 * 100), i32(index / 10 * 26), 96, 24}
		_ = ui.button_at(h.ui_frame, rect, "Button", widget = ui.widget_id(u64(index + 1)))
	}
	return count
}

run_mixed_ui :: proc(h: ^Harness, groups: int) -> int {
	assert(h != nil && groups > 0, "run_mixed_ui: invalid argument")
	for index in 0 ..< groups {
		y := i32(index * 30)
		ui_label_at(h, "Label", {0, y, 100, 24})
		_ = ui.checkbox_at(
			h.ui_frame,
			{105, y, 120, 24},
			"Check",
			&h.checked[index],
			widget = ui.widget_id(u64(index * 4 + 1)),
		)
		_ = ui.slider_at(
			h.ui_frame,
			{230, y, 140, 24},
			&h.values[index],
			0,
			1,
			0.01,
			a11y_label = "Value",
			widget = ui.widget_id(u64(index * 4 + 2)),
		)
		ui_label_at(h, "Input", {375, y, 160, 24})
		_ = ui.button_at(
			h.ui_frame,
			{540, y, 96, 24},
			"Submit",
			widget = ui.widget_id(u64(index * 4 + 3)),
		)
	}
	return groups * 5
}

run_dashboard_ui :: proc(h: ^Harness, groups: int) -> int {
	assert(
		h != nil && groups > 0 && groups <= DASHBOARD_MAX_GROUPS,
		"run_dashboard_ui: invalid argument",
	)
	for index in 0 ..< groups {
		y := i32(index * 30)
		ui_label_at(h, label_for(h, index, true), {0, y, 124, 24})
		ui_label_at(h, "Healthy", {128, y, 76, 24})
		_ = ui.checkbox_at(
			h.ui_frame,
			{208, y, 88, 24},
			"Live",
			&h.checked[index],
			widget = ui.widget_id(u64(index * 4 + 1)),
		)
		_ = ui.slider_at(
			h.ui_frame,
			{300, y, 130, 24},
			&h.values[index],
			0,
			1,
			0.01,
			a11y_label = "Value",
			widget = ui.widget_id(u64(index * 4 + 2)),
		)
		active := h.ui_active_input == index
		_ = ui.text_input_at(
			h.ui_frame,
			{434, y, 150, 24},
			&h.ui_inputs[index],
			"Filter",
			active,
			semantics = {name = "Filter"},
		)
		_ = ui.button_at(
			h.ui_frame,
			{588, y, 72, 24},
			"Open",
			widget = ui.widget_id(u64(index * 4 + 4)),
		)
		for column in 0 ..< 4 {
			ui_label_at(h, "Data", {664 + i32(column * 86), y, 82, 24})
		}
	}
	return groups * DASHBOARD_WIDGETS_PER_GROUP
}

run_virtual_list_ui :: proc(h: ^Harness, logical_count: int) -> int {
	assert(h != nil && logical_count > 0, "run_virtual_list_ui: invalid argument")
	submitted := min(logical_count, VIRTUAL_ROWS + VIRTUAL_OVERSCAN * 2)
	start := clamp(logical_count / 2 - VIRTUAL_OVERSCAN, 0, logical_count - submitted)
	for offset in 0 ..< submitted {
		ui_label_at(h, label_for(h, start + offset, true), {0, i32(offset * 18), 320, 18})
	}
	return submitted
}

run_table_ui :: proc(h: ^Harness, rows: int, unique: bool) -> int {
	assert(h != nil && rows > 0, "run_table_ui: invalid argument")
	for row in 0 ..< rows {
		for column in 0 ..< 4 {
			label := label_for(h, (row * 4 + column) % MAX_SCALE, unique)
			ui_label_at(h, label, {i32(column * 220), i32(row * 18), 216, 18})
		}
	}
	return rows * 4
}

run_churn_ui :: proc(h: ^Harness, count: int) -> int {
	assert(h != nil && count > 0, "run_churn_ui: invalid argument")
	for position in 0 ..< count {
		churned := (position + h.frame_index) % 10 == 0
		index := (position + h.frame_index) % count if churned else position
		ui_label_at(h, label_for(h, index, true), {0, i32(position * 18), 320, 18})
	}
	return count
}

benchmark_draw_ui :: proc(h: ^Harness) {
	assert(h != nil && h.ui_frame != nil, "benchmark_draw_ui: invalid argument")
	switch h.workload {
	case .Labels_Repeated:
		h.submitted = run_labels_ui(h, h.scale, false)
	case .Labels_Unique, .List_Full:
		h.submitted = run_labels_ui(h, h.scale, true)
	case .Labels_Stable_Unique:
		h.submitted = run_isolated_labels_ui(h, h.scale, false)
	case .Labels_Changing_Unique:
		h.submitted = run_isolated_labels_ui(h, h.scale, true)
	case .Input_Inactive, .Input_Active:
		h.submitted = run_inputs_ui(h, h.scale)
	case .Checkbox_Only:
		h.submitted = run_checkboxes_ui(h, h.scale)
	case .Slider_Only:
		h.submitted = run_sliders_ui(h, h.scale)
	case .Button_Only,
	     .Button_Semantics_Disabled,
	     .Button_Semantics_Enabled,
	     .Button_Grid,
	     .Accessibility,
	     .Capacity:
		h.submitted = run_buttons_ui(h, h.scale)
	case .Mixed_Form:
		h.submitted = run_mixed_ui(h, h.scale)
	case .Complex_Dashboard:
		h.submitted = run_dashboard_ui(h, h.scale)
	case .List_Virtual:
		h.submitted = run_virtual_list_ui(h, h.scale)
	case .Table_Repeated:
		h.submitted = run_table_ui(h, h.scale, false)
	case .Table_Unique:
		h.submitted = run_table_ui(h, h.scale, true)
	case .Dynamic_Churn:
		h.submitted = run_churn_ui(h, h.scale)
	case .Layout_Flow,
	     .Prepared_Flat_Fixed,
	     .Prepared_Flat_Intrinsic,
	     .Prepared_Rows_Fixed,
	     .Prepared_Rows_Intrinsic,
	     .Prepared_Deep_Fixed,
	     .Prepared_Deep_Intrinsic,
	     .Prepared_Wrapped,
	     .Prepared_Mixed_Tracks,
	     .Prepared_Effects:
		assert(false, "workload is Fit-only")
	}
}

benchmark_draw :: proc(builder: ^fit.Builder, userdata: rawptr) {
	assert(builder != nil && userdata != nil, "benchmark_draw: invalid argument")
	h := cast(^Harness)userdata
	switch h.workload {
	case .Labels_Repeated:
		h.submitted = run_labels(builder, h, h.scale, false)
	case .Labels_Unique, .List_Full:
		h.submitted = run_labels(builder, h, h.scale, true)
	case .Labels_Stable_Unique:
		h.submitted = run_isolated_labels(builder, h, h.scale, false)
	case .Labels_Changing_Unique:
		h.submitted = run_isolated_labels(builder, h, h.scale, true)
	case .Input_Inactive, .Input_Active:
		h.submitted = run_inputs(builder, h, h.scale)
	case .Checkbox_Only:
		h.submitted = run_checkboxes(builder, h, h.scale)
	case .Slider_Only:
		h.submitted = run_sliders(builder, h, h.scale)
	case .Button_Only,
	     .Button_Semantics_Disabled,
	     .Button_Semantics_Enabled,
	     .Button_Grid,
	     .Accessibility,
	     .Capacity:
		h.submitted = run_buttons(builder, h.scale)
	case .Mixed_Form:
		h.submitted = run_mixed(builder, h, h.scale)
	case .Complex_Dashboard:
		h.submitted = run_dashboard(builder, h, h.scale)
	case .Layout_Flow:
		h.submitted = run_layout_flow(builder, h)
	case .List_Virtual:
		h.submitted = run_virtual_list(builder, h, h.scale)
	case .Table_Repeated:
		h.submitted = run_table(builder, h, h.scale, false)
	case .Table_Unique:
		h.submitted = run_table(builder, h, h.scale, true)
	case .Dynamic_Churn:
		h.submitted = run_churn(builder, h, h.scale)
	case .Prepared_Flat_Fixed:
		h.submitted = run_prepared_flat(builder, h, true)
	case .Prepared_Flat_Intrinsic:
		h.submitted = run_prepared_flat(builder, h, false)
	case .Prepared_Rows_Fixed:
		h.submitted = run_prepared_rows(builder, h, true)
	case .Prepared_Rows_Intrinsic:
		h.submitted = run_prepared_rows(builder, h, false)
	case .Prepared_Deep_Fixed:
		h.submitted = run_prepared_deep(builder, h, true)
	case .Prepared_Deep_Intrinsic:
		h.submitted = run_prepared_deep(builder, h, false)
	case .Prepared_Wrapped:
		h.submitted = run_prepared_wrapped(builder, h)
	case .Prepared_Mixed_Tracks, .Prepared_Effects:
		h.submitted = run_prepared_mixed(builder, h)
	}
}

required_nodes :: proc(workload: Workload, scale: int) -> int {
	switch workload {
	case .Mixed_Form:
		return 2 + scale * 6
	case .Complex_Dashboard:
		return 2 + scale * 11
	case .Table_Repeated, .Table_Unique:
		return 1 + scale * 4
	case .Layout_Flow:
		return 2
	case .List_Virtual:
		return 2 + min(scale, VIRTUAL_ROWS + VIRTUAL_OVERSCAN * 2)
	case .Prepared_Rows_Fixed, .Prepared_Rows_Intrinsic:
		return 1 + scale / 4 * 5
	case .Prepared_Deep_Fixed, .Prepared_Deep_Intrinsic:
		return min(scale, 15) + 1
	case .Labels_Repeated,
	     .Labels_Unique,
	     .Labels_Stable_Unique,
	     .Labels_Changing_Unique,
	     .Input_Inactive,
	     .Input_Active,
	     .Checkbox_Only,
	     .Slider_Only,
	     .Button_Only,
	     .Button_Semantics_Disabled,
	     .Button_Semantics_Enabled,
	     .Button_Grid,
	     .List_Full,
	     .Dynamic_Churn,
	     .Accessibility,
	     .Capacity,
	     .Prepared_Flat_Fixed,
	     .Prepared_Flat_Intrinsic,
	     .Prepared_Wrapped,
	     .Prepared_Mixed_Tracks,
	     .Prepared_Effects:
		return 1 + scale
	}
	return FIT_NODE_CAPACITY + 1
}

parse_workload :: proc(value: string) -> (Workload, bool) {
	switch value {
	case "labels_repeated":
		return .Labels_Repeated, true
	case "labels_unique":
		return .Labels_Unique, true
	case "labels_stable_unique":
		return .Labels_Stable_Unique, true
	case "labels_changing_unique":
		return .Labels_Changing_Unique, true
	case "input_inactive":
		return .Input_Inactive, true
	case "input_active":
		return .Input_Active, true
	case "checkbox_only":
		return .Checkbox_Only, true
	case "slider_only":
		return .Slider_Only, true
	case "button_only":
		return .Button_Only, true
	case "button_semantics_disabled":
		return .Button_Semantics_Disabled, true
	case "button_semantics_enabled":
		return .Button_Semantics_Enabled, true
	case "button_grid":
		return .Button_Grid, true
	case "mixed_form":
		return .Mixed_Form, true
	case "complex_dashboard":
		return .Complex_Dashboard, true
	case "layout_flow":
		return .Layout_Flow, true
	case "list_full":
		return .List_Full, true
	case "list_virtual":
		return .List_Virtual, true
	case "table_repeated":
		return .Table_Repeated, true
	case "table_unique":
		return .Table_Unique, true
	case "dynamic_churn":
		return .Dynamic_Churn, true
	case "accessibility":
		return .Accessibility, true
	case "capacity":
		return .Capacity, true
	case "prepared_flat_fixed":
		return .Prepared_Flat_Fixed, true
	case "prepared_flat_intrinsic":
		return .Prepared_Flat_Intrinsic, true
	case "prepared_rows_fixed":
		return .Prepared_Rows_Fixed, true
	case "prepared_rows_intrinsic":
		return .Prepared_Rows_Intrinsic, true
	case "prepared_deep_fixed":
		return .Prepared_Deep_Fixed, true
	case "prepared_deep_intrinsic":
		return .Prepared_Deep_Intrinsic, true
	case "prepared_wrapped":
		return .Prepared_Wrapped, true
	case "prepared_mixed_tracks":
		return .Prepared_Mixed_Tracks, true
	case "prepared_effects":
		return .Prepared_Effects, true
	}
	return {}, false
}

parse_options :: proc() -> (Options, bool) {
	options := Options {
		layer         = .Fit,
		workload      = .Labels_Repeated,
		scale         = 100,
		warmup        = WARMUP_DEFAULT,
		frames        = FRAMES_DEFAULT,
		measure_cache = true,
	}
	for argument in os.args[1:] {
		if argument == "--layer=fit" {
			options.layer = .Fit
		} else if argument == "--layer=ui" {
			options.layer = .Ui
		} else if strings.has_prefix(argument, "--workload=") {
			workload, ok := parse_workload(argument[len("--workload="):])
			if !ok do return {}, false
			options.workload = workload
		} else if strings.has_prefix(argument, "--scale=") {
			value, ok := strconv.parse_i64(argument[len("--scale="):])
			if !ok do return {}, false
			options.scale = int(value)
		} else if strings.has_prefix(argument, "--warmup=") {
			value, ok := strconv.parse_i64(argument[len("--warmup="):])
			if !ok do return {}, false
			options.warmup = int(value)
		} else if strings.has_prefix(argument, "--frames=") {
			value, ok := strconv.parse_i64(argument[len("--frames="):])
			if !ok do return {}, false
			options.frames = int(value)
		} else if strings.has_prefix(argument, "--repetition=") {
			value, ok := strconv.parse_i64(argument[len("--repetition="):])
			if !ok do return {}, false
			options.repetition = int(value)
		} else if argument == "--measure-cache=enabled" {
			options.measure_cache = true
		} else if argument == "--measure-cache=bypassed" {
			options.measure_cache = false
		} else do return {}, false
	}
	valid_scale :=
		options.scale > 0 && (options.scale <= MAX_SCALE || options.workload == .List_Virtual)
	valid_nodes :=
		options.layer == .Ui ||
		required_nodes(options.workload, options.scale) <= FIT_NODE_CAPACITY
	valid_layer := options.layer == .Fit || options.workload != .Layout_Flow
	valid_run := options.warmup >= 0 && options.frames > 0 && options.repetition >= 0
	return options, valid_scale && valid_nodes && valid_layer && valid_run
}

measure_frame_fit :: proc(h: ^Harness, options: Options, index: int) -> Frame_Timing {
	assert(h != nil && options.scale > 0, "measure_frame_fit: invalid argument")
	h.workload = options.workload
	h.scale = options.scale
	h.frame_index = index
	left := int(fit.Mouse_Button.Left)
	h.input.mouse_pressed[left] = false
	h.input.mouse_released[left] = false
	h.input.mouse_down[left] = false
	if options.workload == .Input_Active && h.active_input_stage < 2 {
		h.input.mouse_position = {10, 10}
		if h.active_input_stage == 0 {
			h.input.mouse_pressed[left] = true
			h.input.mouse_down[left] = true
		} else {
			h.input.mouse_released[left] = true
		}
		h.active_input_stage += 1
	}
	timing, ok := fit.Test_Driver_Frame_Timed(&h.driver, h.input, benchmark_draw, h)
	assert(ok, "measure_frame_fit: frame failed")
	return {
		timing.build_ns,
		timing.measure_ns,
		timing.layout_render_ns,
		timing.frame_finalize_ns,
		timing.finalize_ns,
		timing.frame_ns,
	}
}

measure_frame_ui :: proc(h: ^Harness, options: Options, index: int) -> Frame_Timing {
	assert(h != nil && options.scale > 0, "measure_frame_ui: invalid argument")
	h.workload = options.workload
	h.scale = options.scale
	h.frame_index = index
	h.ui_active_input = 0 if options.workload == .Input_Active else -1
	frame_started := time.tick_now()
	ui.ui_frame_begin(h.ui_frame, &h.ui_runtime, &h.ui_input)
	build_started := time.tick_now()
	benchmark_draw_ui(h)
	build_ns := time.duration_nanoseconds(time.tick_since(build_started))
	finalize_started := time.tick_now()
	ui.ui_frame_finalize(h.ui_frame)
	finalize_ns := time.duration_nanoseconds(time.tick_since(finalize_started))
	frame_ns := time.duration_nanoseconds(time.tick_since(frame_started))
	h.ui_telemetry = ui.ui_frame_telemetry(h.ui_frame)
	h.ui_diagnostics = ui.ui_frame_diagnostics(h.ui_frame)
	ui.ui_frame_release(h.ui_frame)
	return {
		build_ns = build_ns,
		frame_finalize_ns = finalize_ns,
		finalize_ns = finalize_ns,
		frame_ns = frame_ns,
	}
}

measure_frame :: proc(h: ^Harness, options: Options, index: int) -> Frame_Timing {
	assert(h != nil, "measure_frame: nil harness")
	if options.layer == .Fit do return measure_frame_fit(h, options, index)
	return measure_frame_ui(h, options, index)
}

print_samples :: proc(name: string, samples: []i64, first: bool) {
	assert(len(name) > 0 && len(samples) > 0, "print_samples: invalid argument")
	if !first do fmt.print(",")
	fmt.printf("\"%s\":[", name)
	for value, index in samples {
		if index > 0 do fmt.print(",")
		fmt.print(value)
	}
	fmt.print("]")
}

benchmark_evidence :: proc(
	h: ^Harness,
	layer: Ingot_Layer,
) -> (
	fit.Paint_Summary,
	fit.Frame_Telemetry,
	fit.Frame_Diagnostics,
) {
	assert(h != nil, "benchmark_evidence: nil harness")
	if layer == .Fit {
		return fit.Test_Driver_Paint_Summary(
			&h.driver,
		), fit.Test_Driver_Telemetry(&h.driver), fit.Test_Driver_Diagnostics(&h.driver)
	}
	telemetry := fit.Frame_Telemetry {
		scratch_allocations           = h.ui_telemetry.scratch_allocation_count,
		scratch_resizes               = h.ui_telemetry.scratch_resize_count,
		scratch_allocation_bytes      = h.ui_telemetry.scratch_allocation_request_bytes,
		scratch_resize_bytes          = h.ui_telemetry.scratch_resize_request_bytes,
		main                          = {
			h.ui_telemetry.main.command_append_count,
			h.ui_telemetry.main.text_append_count,
			h.ui_telemetry.main.text_bytes_copied,
			h.ui_telemetry.main.command_growth_count,
			h.ui_telemetry.main.text_growth_count,
		},
		overlay                       = {
			h.ui_telemetry.overlay.command_append_count,
			h.ui_telemetry.overlay.text_append_count,
			h.ui_telemetry.overlay.text_bytes_copied,
			h.ui_telemetry.overlay.command_growth_count,
			h.ui_telemetry.overlay.text_growth_count,
		},
		text_input_full_paths         = h.ui_telemetry.text_input_full_path_count,
		text_input_inactive_paths     = h.ui_telemetry.text_input_inactive_candidates,
		natural_leaf_measures         = h.ui_telemetry.prepared.natural_leaf_measures,
		resolved_leaf_measures        = h.ui_telemetry.prepared.resolved_leaf_measures,
		fixed_leaf_measure_skips      = h.ui_telemetry.prepared.fixed_leaf_measure_skips,
		container_measures            = h.ui_telemetry.prepared.container_measures,
		placed_nodes                  = h.ui_telemetry.prepared.placed_nodes,
		rendered_nodes                = h.ui_telemetry.prepared.rendered_nodes,
		activation_outputs            = h.ui_telemetry.prepared.activation_outputs,
		render_relayouts              = h.ui_telemetry.prepared.render_relayouts,
		measure_cache_hits            = h.ui_telemetry.measure_cache_hits,
		measure_cache_misses          = h.ui_telemetry.measure_cache_misses,
		measure_cache_policy_bypasses = h.ui_telemetry.measure_cache_policy_bypasses,
		phases                        = {
			h.ui_telemetry.prepared.phase_ns[.Measure_Natural],
			h.ui_telemetry.prepared.phase_ns[.Resolve_Size],
			h.ui_telemetry.prepared.phase_ns[.Measure_Resolved],
			h.ui_telemetry.prepared.phase_ns[.Place],
			h.ui_telemetry.prepared.phase_ns[.Render_Tree],
			h.ui_telemetry.prepared.phase_ns[.Output_Clear],
			h.ui_telemetry.prepared.phase_ns[.Finalize_Routes],
			h.ui_telemetry.prepared.phase_ns[.Finalize_Semantics],
			h.ui_telemetry.prepared.phase_ns[.Finalize_Lifetimes],
		},
	}
	diagnostics := fit.Frame_Diagnostics {
		input_characters_dropped   = h.ui_diagnostics.input_characters_dropped,
		degenerate_widgets_dropped = h.ui_diagnostics.degenerate_widgets_dropped,
		semantic_nodes_dropped     = h.ui_diagnostics.semantic_nodes_dropped,
		semantic_focus_dropped     = h.ui_diagnostics.semantic_focus_dropped,
		semantic_actions_dropped   = h.ui_diagnostics.semantic_actions_dropped,
		semantic_id_collisions     = h.ui_diagnostics.semantic_id_collisions,
		semantic_text_truncations  = h.ui_diagnostics.semantic_text_truncations,
		main_commands_dropped      = h.ui_diagnostics.main_commands_dropped,
		main_text_bytes_dropped    = h.ui_diagnostics.main_text_bytes_dropped,
		overlay_commands_dropped   = h.ui_diagnostics.overlay_commands_dropped,
		overlay_text_bytes_dropped = h.ui_diagnostics.overlay_text_bytes_dropped,
		platform_controls_dropped  = h.ui_diagnostics.platform_controls_dropped,
	}
	summary := fit.Paint_Summary {
		main_commands      = h.ui_output.main.count,
		main_text_bytes    = h.ui_output.main.text_len,
		overlay_commands   = h.ui_output.overlay.count,
		overlay_text_bytes = h.ui_output.overlay.text_len,
	}
	return summary, telemetry, diagnostics
}

print_telemetry :: proc(value: fit.Frame_Telemetry) {
	print_telemetry_output(value)
	print_telemetry_prepared(value)
}

print_telemetry_output :: proc(value: fit.Frame_Telemetry) {
	fmt.print(
		"\"scratch_allocations\":",
		value.scratch_allocations,
		",\"scratch_resizes\":",
		value.scratch_resizes,
		",\"scratch_allocation_request_bytes\":",
		value.scratch_allocation_bytes,
		",\"scratch_resize_request_bytes\":",
		value.scratch_resize_bytes,
		",\"main_command_appends\":",
		value.main.command_appends,
		",\"main_text_appends\":",
		value.main.text_appends,
		",\"main_text_bytes_copied\":",
		value.main.text_bytes,
		",\"main_command_growths\":",
		value.main.command_growths,
		",\"main_text_growths\":",
		value.main.text_growths,
		",\"overlay_command_appends\":",
		value.overlay.command_appends,
		",\"overlay_text_appends\":",
		value.overlay.text_appends,
		",\"overlay_text_bytes_copied\":",
		value.overlay.text_bytes,
		",\"overlay_command_growths\":",
		value.overlay.command_growths,
		",\"overlay_text_growths\":",
		value.overlay.text_growths,
		",\"text_input_full_paths\":",
		value.text_input_full_paths,
		",\"text_input_inactive_candidates\":",
		value.text_input_inactive_paths,
	)
}

print_telemetry_prepared :: proc(value: fit.Frame_Telemetry) {
	fmt.print(
		",\"phase_measure_natural_ns\":",
		value.phases.measure_natural_ns,
		",\"phase_resolve_size_ns\":",
		value.phases.resolve_size_ns,
		",\"phase_measure_resolved_ns\":",
		value.phases.measure_resolved_ns,
		",\"phase_place_ns\":",
		value.phases.place_ns,
		",\"phase_render_tree_ns\":",
		value.phases.render_tree_ns,
		",\"phase_output_clear_ns\":",
		value.phases.output_clear_ns,
		",\"phase_finalize_routes_ns\":",
		value.phases.finalize_routes_ns,
		",\"phase_finalize_semantics_ns\":",
		value.phases.finalize_semantics_ns,
		",\"phase_finalize_lifetimes_ns\":",
		value.phases.finalize_lifetimes_ns,
		",\"description_nodes\":",
		value.description_nodes,
		",\"leaf_nodes\":",
		value.leaf_nodes,
		",\"container_nodes\":",
		value.container_nodes,
		",\"maximum_depth\":",
		value.maximum_depth,
		",\"fixed_leaf_nodes\":",
		value.fixed_leaf_nodes,
		",\"intrinsic_leaf_nodes\":",
		value.intrinsic_leaf_nodes,
		",\"width_dependent_leaf_nodes\":",
		value.width_dependent_leaf_nodes,
		",\"dependency_node_visits\":",
		value.dependency_node_visits,
		",\"dependency_child_visits\":",
		value.dependency_child_visits,
		",\"natural_node_visits\":",
		value.natural_node_visits,
		",\"resolve_node_visits\":",
		value.resolve_node_visits,
		",\"remeasure_node_visits\":",
		value.remeasure_node_visits,
		",\"width_assignment_visits\":",
		value.width_assignment_visits,
		",\"resolved_measure_visits\":",
		value.resolved_measure_visits,
		",\"placement_node_visits\":",
		value.placement_node_visits,
		",\"render_node_visits\":",
		value.render_node_visits,
		",\"child_run_visits\":",
		value.child_run_visits,
		",\"specialized_nodes\":",
		value.specialized_nodes,
		",\"generic_fallback_nodes\":",
		value.generic_fallback_nodes,
		",\"natural_leaf_measures\":",
		value.natural_leaf_measures,
		",\"resolved_leaf_measures\":",
		value.resolved_leaf_measures,
		",\"fixed_leaf_measure_skips\":",
		value.fixed_leaf_measure_skips,
		",\"container_measures\":",
		value.container_measures,
		",\"width_assignments\":",
		value.width_assignments,
		",\"placed_nodes\":",
		value.placed_nodes,
		",\"rendered_nodes\":",
		value.rendered_nodes,
		",\"activation_outputs\":",
		value.activation_outputs,
		",\"render_relayouts\":",
		value.render_relayouts,
		",\"measure_cache_hits\":",
		value.measure_cache_hits,
		",\"measure_cache_misses\":",
		value.measure_cache_misses,
		",\"measure_cache_policy_bypasses\":",
		value.measure_cache_policy_bypasses,
	)
}

main :: proc() {
	options, valid := parse_options()
	if !valid {
		fmt.eprintln(
			"usage: ingot_widget_bench [--layer=fit|ui] [--workload=ID] [--scale=N] ",
			"[--warmup=N] [--frames=N] [--repetition=N]",
		)
		os.exit(2)
	}
	semantics :=
		options.workload == .Accessibility || options.workload == .Button_Semantics_Enabled
	h := harness_make(options.layer, semantics, options.measure_cache)
	defer harness_destroy(h, options.layer)
	for index in 0 ..< options.warmup do _ = measure_frame(h, options, index)
	build_samples := make([]i64, options.frames)
	measure_samples := make([]i64, options.frames)
	layout_render_samples := make([]i64, options.frames)
	frame_finalize_samples := make([]i64, options.frames)
	finalize_samples := make([]i64, options.frames)
	frame_samples := make([]i64, options.frames)
	defer delete(build_samples); defer delete(measure_samples)
	defer delete(layout_render_samples); defer delete(frame_finalize_samples)
	defer delete(finalize_samples); defer delete(frame_samples)
	state_checksum := FNV_BASIS
	for index in 0 ..< options.frames {
		timing := measure_frame(h, options, index)
		build_samples[index] = timing.build_ns
		measure_samples[index] = timing.measure_ns
		layout_render_samples[index] = timing.layout_render_ns
		frame_finalize_samples[index] = timing.frame_finalize_ns
		finalize_samples[index] = timing.finalize_ns
		frame_samples[index] = timing.frame_ns
		_, h.telemetry, _ = benchmark_evidence(h, options.layer)
		state_checksum = hash_u64(state_checksum, u64(h.submitted))
		if options.workload == .Layout_Flow {
			state_checksum = hash_u64(state_checksum, h.layout_checksum)
		}
	}
	_ = measure_frame(h, options, options.frames)
	summary, telemetry, diagnostics := benchmark_evidence(h, options.layer)
	valid_output :=
		diagnostics.main_commands_dropped == 0 && diagnostics.main_text_bytes_dropped == 0
	fmt.print(
		"{\"schema_version\":1,\"framework\":\"ingot\",\"framework_revision\":\"workspace\"",
		",\"backend\":\"headless\",\"layer\":\"",
		"fit" if options.layer == .Fit else "ui",
		"\",\"workload\":\"",
		workload_name(options.workload),
		"\",\"scale\":",
		options.scale,
		",\"repetition\":",
		options.repetition,
		",\"warmup_frames\":",
		options.warmup,
		",\"measured_frames\":",
		options.frames,
		",\"valid\":",
		valid_output,
		",\"invalid_reason\":\"",
		"output_overflow" if !valid_output else "",
		"\",\"state_checksum\":",
		state_checksum,
		",\"samples_ns\":{",
	)
	print_samples("build", build_samples, true)
	print_samples("measure", measure_samples, false)
	print_samples("layout_render", layout_render_samples, false)
	print_samples("frame_finalize", frame_finalize_samples, false)
	print_samples("finalize", finalize_samples, false)
	print_samples("frame", frame_samples, false)
	fmt.print(
		"},\"output\":{\"submitted_widgets\":",
		h.submitted,
		",\"visible_widgets\":",
		min(h.submitted, VIRTUAL_ROWS),
		",\"paint_commands\":",
		summary.main_commands,
		",\"text_bytes\":",
		summary.main_text_bytes,
		",\"dropped_commands\":",
		diagnostics.main_commands_dropped,
		",\"dropped_text_bytes\":",
		diagnostics.main_text_bytes_dropped,
		"},\"telemetry\":{",
	)
	print_telemetry(telemetry)
	fmt.print(
		"},\"diagnostics\":{\"semantic_nodes_dropped\":",
		diagnostics.semantic_nodes_dropped,
		",\"semantic_focus_dropped\":",
		diagnostics.semantic_focus_dropped,
		",\"semantic_id_collisions\":",
		diagnostics.semantic_id_collisions,
		"},\"environment\":{\"os\":\"",
		ODIN_OS,
		"\",\"arch\":\"",
		ODIN_ARCH,
		"\",\"cpu\":\"runner\",\"toolchain\":\"odin dev-2026-08-nightly:902106f\"}}\n",
	)
}

workload_name :: proc(workload: Workload) -> string {
	switch workload {
	case .Labels_Repeated:
		return "labels_repeated"
	case .Labels_Unique:
		return "labels_unique"
	case .Labels_Stable_Unique:
		return "labels_stable_unique"
	case .Labels_Changing_Unique:
		return "labels_changing_unique"
	case .Input_Inactive:
		return "input_inactive"
	case .Input_Active:
		return "input_active"
	case .Checkbox_Only:
		return "checkbox_only"
	case .Slider_Only:
		return "slider_only"
	case .Button_Only:
		return "button_only"
	case .Button_Semantics_Disabled:
		return "button_semantics_disabled"
	case .Button_Semantics_Enabled:
		return "button_semantics_enabled"
	case .Button_Grid:
		return "button_grid"
	case .Mixed_Form:
		return "mixed_form"
	case .Complex_Dashboard:
		return "complex_dashboard"
	case .Layout_Flow:
		return "layout_flow"
	case .List_Full:
		return "list_full"
	case .List_Virtual:
		return "list_virtual"
	case .Table_Repeated:
		return "table_repeated"
	case .Table_Unique:
		return "table_unique"
	case .Dynamic_Churn:
		return "dynamic_churn"
	case .Accessibility:
		return "accessibility"
	case .Capacity:
		return "capacity"
	case .Prepared_Flat_Fixed:
		return "prepared_flat_fixed"
	case .Prepared_Flat_Intrinsic:
		return "prepared_flat_intrinsic"
	case .Prepared_Rows_Fixed:
		return "prepared_rows_fixed"
	case .Prepared_Rows_Intrinsic:
		return "prepared_rows_intrinsic"
	case .Prepared_Deep_Fixed:
		return "prepared_deep_fixed"
	case .Prepared_Deep_Intrinsic:
		return "prepared_deep_intrinsic"
	case .Prepared_Wrapped:
		return "prepared_wrapped"
	case .Prepared_Mixed_Tracks:
		return "prepared_mixed_tracks"
	case .Prepared_Effects:
		return "prepared_effects"
	}
	return "unknown"
}
