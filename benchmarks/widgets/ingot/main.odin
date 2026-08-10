package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import ui "ingot:ui"

WARMUP_DEFAULT :: 300
FRAMES_DEFAULT :: 2000
MAX_SCALE :: 16384
STABLE_LABEL_LEN :: 15 // len("Widget 00000000")
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
}

Options :: struct {
	workload:   Workload,
	scale:      int,
	warmup:     int,
	frames:     int,
	repetition: int,
}

Harness :: struct {
	runtime:          ui.Ui_Runtime,
	frame:            ui.Ui_Frame,
	input:            ui.Ui_Input,
	output:           ui.Ui_Output,
	checked:          [MAX_SCALE]bool,
	values:           [MAX_SCALE]f32,
	stable_labels:    [MAX_SCALE][32]u8,
	changing_labels:  [MAX_SCALE][32]u8,
	dashboard_inputs: [DASHBOARD_MAX_GROUPS]ui.Input_Box,
	layout_checksum:  u64,
}

font_for_size :: proc(data: rawptr, size: i32) -> ui.Font_Id {
	assert(data != nil && size > 0, "font_for_size: invalid argument")
	return ui.Font_Id(size)
}

measure_text :: proc(data: rawptr, font: ui.Font_Id, text: string, size, spacing: f32) -> ui.Vec2 {
	assert(data != nil && font != 0, "measure_text: invalid argument")
	assert(size > 0 && spacing >= 0, "measure_text: invalid dimensions")
	return {f32(len(text)) * size * 0.5 + f32(max(len(text) - 1, 0)) * spacing, size}
}

harness_make :: proc(semantics: bool) -> ^Harness {
	h := new(Harness)
	ui.ui_runtime_init(&h.runtime)
	ui.ui_runtime_set_text_backend(
		&h.runtime,
		{data = h, font_for_size = font_for_size, measure = measure_text},
	)
	ui.sem_enable(&h.runtime, semantics)
	h.frame.output = &h.output
	h.input.screen_size = {1280, 720}
	h.input.dpi_scale = 1
	h.input.window_focused = true
	h.input.cursor_on_screen = true
	for index in 0 ..< MAX_SCALE {
		_ = fmt.bprintf(h.stable_labels[index][:], "Widget %08d", index)
	}
	return h
}

harness_destroy :: proc(h: ^Harness) {
	assert(h != nil && !h.frame.open, "harness_destroy: invalid harness")
	for index in 0 ..< DASHBOARD_MAX_GROUPS {
		ui.input_box_destroy(&h.dashboard_inputs[index])
	}
	ui.ui_frame_destroy(&h.frame)
	ui.ui_runtime_destroy(&h.runtime)
	free(h)
}

label_for :: proc(h: ^Harness, index: int, unique: bool) -> string {
	assert(h != nil && index >= 0, "label_for: invalid argument")
	if !unique do return "Widget"
	// Precomputed at harness init: the timed region must measure widget
	// submission, not core:fmt. Indexing is pinned by spec/dataset.json
	// label_index_modulus.
	return string(h.stable_labels[index % MAX_SCALE][:STABLE_LABEL_LEN])
}

stable_label_for :: proc(h: ^Harness, index: int) -> string {
	assert(h != nil && index >= 0 && index < MAX_SCALE, "stable_label_for: invalid argument")
	return string(h.stable_labels[index][:STABLE_LABEL_LEN])
}

changing_label_for :: proc(h: ^Harness, index, frame_index: int) -> string {
	assert(h != nil && index >= 0 && index < MAX_SCALE, "changing_label_for: invalid argument")
	return fmt.bprintf(h.changing_labels[index][:], "Widget %08d %08d", index, frame_index)
}

hash_u64 :: proc(hash, value: u64) -> u64 {
	result := hash
	for shift: u64 = 0; shift < 64; shift += 8 {
		result ~= (value >> shift) & 0xff
		result *= FNV_PRIME
	}
	return result
}

paint_label :: proc(frame: ^ui.Ui_Frame, label: string, x, y, w: i32) {
	assert(frame != nil && frame.open, "paint_label: invalid frame")
	assert(w > 0, "paint_label: invalid width")
	ui.draw_rectangle(frame, x, y, w, 18, ui.Color{35, 38, 45, 255})
	ui.draw_text_string_frame(frame, label, x + 2, y + 2, 14, ui.Color{230, 230, 230, 255})
}

run_labels :: proc(h: ^Harness, count: int, unique: bool) -> int {
	assert(h != nil && count > 0 && count <= MAX_SCALE, "run_labels: invalid argument")
	for index in 0 ..< count {
		x := i32(index % 10) * 126
		y := i32(index / 10) * 18
		paint_label(&h.frame, label_for(h, index, unique), x, y, 124)
	}
	return count
}

run_isolated_labels :: proc(h: ^Harness, count, frame_index: int, changing: bool) -> int {
	assert(h != nil && count > 0 && count <= MAX_SCALE, "run_isolated_labels: invalid argument")
	for index in 0 ..< count {
		label :=
			changing_label_for(h, index, frame_index) if changing else stable_label_for(h, index)
		x := i32(index % 10) * 126
		y := i32(index / 10) * 18
		paint_label(&h.frame, label, x, y, 124)
	}
	return count
}

run_inputs :: proc(h: ^Harness, count: int, active: bool) -> int {
	assert(h != nil && count > 0 && count <= DASHBOARD_MAX_GROUPS, "run_inputs: invalid argument")
	for index in 0 ..< count {
		_ = ui.text_input_at(
			&h.frame,
			{0, i32(index) * 26, 180, 24},
			&h.dashboard_inputs[index],
			"Filter",
			active,
		)
	}
	return count
}

run_checkboxes :: proc(h: ^Harness, count: int) -> int {
	assert(h != nil && count > 0 && count <= MAX_SCALE, "run_checkboxes: invalid argument")
	for index in 0 ..< count {
		x := i32(index % 10) * 100
		y := i32(index / 10) * 26
		_ = ui.checkbox_at(&h.frame, {x, y, 96, 24}, "Check", &h.checked[index])
	}
	return count
}

run_sliders :: proc(h: ^Harness, count: int) -> int {
	assert(h != nil && count > 0 && count <= MAX_SCALE, "run_sliders: invalid argument")
	for index in 0 ..< count {
		x := i32(index % 8) * 150
		y := i32(index / 8) * 26
		_ = ui.slider_at(
			&h.frame,
			{x, y, 144, 24},
			&h.values[index],
			0,
			1,
			0.01,
			a11y_label = "Value",
		)
	}
	return count
}

run_buttons :: proc(h: ^Harness, count: int, semantics: bool) -> int {
	assert(h != nil && count > 0 && count <= MAX_SCALE, "run_buttons: invalid argument")
	for index in 0 ..< count {
		x := i32(index % 10) * 100
		y := i32(index / 10) * 26
		id := ui.Widget_Id(index + 1)
		focus := ui.Focus_Opt{}
		if semantics && index < ui.MAX_FOCUSABLES {
			focus = {
				focus = nil,
				id    = index + 1,
			}
		}
		_ = ui.button_at(&h.frame, {x, y, 96, 24}, "Button", focus = focus, widget = id)
	}
	return count
}

run_mixed :: proc(h: ^Harness, groups: int) -> int {
	assert(h != nil && groups > 0 && groups <= MAX_SCALE / 5, "run_mixed: invalid argument")
	for index in 0 ..< groups {
		y := i32(index) * 30
		paint_label(&h.frame, "Label", 0, y, 100)
		_ = ui.checkbox_at(&h.frame, {105, y, 120, 24}, "Check", &h.checked[index])
		_ = ui.slider_at(
			&h.frame,
			{230, y, 140, 24},
			&h.values[index],
			0,
			1,
			0.01,
			a11y_label = "Value",
		)
		paint_label(&h.frame, "Input", 375, y, 160)
		_ = ui.button_at(&h.frame, {540, y, 96, 24}, "Submit", widget = ui.Widget_Id(index + 1))
	}
	return groups * 5
}

run_dashboard :: proc(h: ^Harness, groups: int) -> int {
	assert(h != nil && groups > 0, "run_dashboard: invalid argument")
	assert(groups <= DASHBOARD_MAX_GROUPS, "run_dashboard: too many groups")
	for index in 0 ..< groups {
		y := i32(index) * 30
		paint_label(&h.frame, label_for(h, index, true), 0, y, 124)
		paint_label(&h.frame, "Healthy", 128, y, 76)
		_ = ui.checkbox_at(&h.frame, {208, y, 88, 24}, "Live", &h.checked[index])
		_ = ui.slider_at(&h.frame, {300, y, 130, 24}, &h.values[index], 0, 1, 0.01)
		_ = ui.text_input_at(
			&h.frame,
			{434, y, 150, 24},
			&h.dashboard_inputs[index],
			"Filter",
			false,
		)
		_ = ui.button_at(&h.frame, {588, y, 72, 24}, "Open", widget = ui.Widget_Id(index + 1))
		for column in 0 ..< 4 {
			paint_label(&h.frame, "Data", 664 + i32(column) * 86, y, 82)
		}
	}
	return groups * DASHBOARD_WIDGETS_PER_GROUP
}

run_layout_flow :: proc(h: ^Harness, count: int) -> int {
	assert(h != nil && count > 0, "run_layout_flow: invalid argument")
	assert(count <= ui.MAX_FLOW_ITEMS, "run_layout_flow: too many items")
	flow: ui.Flow_Layout
	ui.flow_begin(&flow, {0, 0, 1280, max(i32)}, 6, 4)
	checksum := FNV_BASIS
	for index in 0 ..< count {
		width := i32(24 + index % 17 * 7)
		height := i32(18 + index % 3 * 4)
		rect := ui.flow_next(&flow, width, height)
		checksum = hash_u64(checksum, u64(rect.x))
		checksum = hash_u64(checksum, u64(rect.y))
		checksum = hash_u64(checksum, u64(rect.w))
		checksum = hash_u64(checksum, u64(rect.h))
	}
	bounds := ui.flow_end(&flow)
	h.layout_checksum = hash_u64(checksum, u64(bounds.h))
	return count
}

run_virtual_list :: proc(h: ^Harness, logical_count: int) -> int {
	assert(h != nil && logical_count > 0, "run_virtual_list: invalid argument")
	submitted := min(logical_count, VIRTUAL_ROWS + VIRTUAL_OVERSCAN * 2)
	start := clamp(logical_count / 2 - VIRTUAL_OVERSCAN, 0, logical_count - submitted)
	for offset in 0 ..< submitted {
		index := start + offset
		paint_label(&h.frame, label_for(h, index, true), 0, i32(offset) * 18, 320)
	}
	return submitted
}

run_table :: proc(h: ^Harness, rows: int, unique: bool) -> int {
	assert(h != nil && rows > 0 && rows <= MAX_SCALE, "run_table: invalid argument")
	for row in 0 ..< rows {
		for column in 0 ..< 4 {
			label := label_for(h, (row * 4 + column) % MAX_SCALE, unique)
			paint_label(&h.frame, label, i32(column) * 220, i32(row) * 18, 216)
		}
	}
	return rows * 4
}

// Spec churn rule (spec/workloads.json dynamic_churn): position p is churned
// when (p + frame) % 10 == 0 and then draws label (p + frame) % scale; other
// positions draw stable label p.
run_churn :: proc(h: ^Harness, count, frame_index: int) -> int {
	assert(h != nil && count > 0 && count <= MAX_SCALE, "run_churn: invalid argument")
	assert(frame_index >= 0, "run_churn: negative frame index")
	for position in 0 ..< count {
		churned := (position + frame_index) % 10 == 0
		index := (position + frame_index) % count if churned else position
		paint_label(&h.frame, label_for(h, index, true), 0, i32(position) * 18, 320)
	}
	return count
}

run_workload :: proc(h: ^Harness, workload: Workload, scale, frame_index: int) -> int {
	assert(h != nil && scale > 0, "run_workload: invalid argument")
	switch workload {
	case .Labels_Repeated:
		return run_labels(h, scale, false)
	case .Labels_Unique:
		return run_labels(h, scale, true)
	case .Labels_Stable_Unique:
		return run_isolated_labels(h, scale, frame_index, false)
	case .Labels_Changing_Unique:
		return run_isolated_labels(h, scale, frame_index, true)
	case .Input_Inactive:
		return run_inputs(h, scale, false)
	case .Input_Active:
		return run_inputs(h, scale, true)
	case .Checkbox_Only:
		return run_checkboxes(h, scale)
	case .Slider_Only:
		return run_sliders(h, scale)
	case .Button_Only, .Button_Semantics_Disabled:
		return run_buttons(h, scale, false)
	case .Button_Semantics_Enabled:
		return run_buttons(h, scale, true)
	case .Button_Grid:
		return run_buttons(h, scale, false)
	case .Mixed_Form:
		return run_mixed(h, scale)
	case .Complex_Dashboard:
		return run_dashboard(h, scale)
	case .Layout_Flow:
		return run_layout_flow(h, scale)
	case .List_Full:
		return run_labels(h, scale, true)
	case .List_Virtual:
		return run_virtual_list(h, scale)
	case .Table_Repeated:
		return run_table(h, scale, false)
	case .Table_Unique:
		return run_table(h, scale, true)
	case .Dynamic_Churn:
		return run_churn(h, scale, frame_index)
	case .Accessibility:
		return run_buttons(h, scale, true)
	case .Capacity:
		return run_buttons(h, scale, false)
	}
	return 0
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
	}
	return {}, false
}

parse_options :: proc() -> (Options, bool) {
	options := Options {
		workload = .Labels_Repeated,
		scale    = 100,
		warmup   = WARMUP_DEFAULT,
		frames   = FRAMES_DEFAULT,
	}
	for argument in os.args[1:] {
		if strings.has_prefix(argument, "--workload=") {
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
		} else do return {}, false
	}
	valid_scale :=
		options.scale > 0 && (options.scale <= MAX_SCALE || options.workload == .List_Virtual)
	valid_run := options.warmup >= 0 && options.frames > 0 && options.repetition >= 0
	return options, valid_scale && valid_run
}

measure_frame :: proc(
	h: ^Harness,
	options: Options,
	index: int,
) -> (
	build_ns, finalize_ns, frame_ns: i64,
	submitted: int,
) {
	assert(h != nil && options.scale > 0, "measure_frame: invalid argument")
	frame_started := time.tick_now()
	ui.ui_frame_begin(&h.frame, &h.runtime, &h.input)
	build_started := time.tick_now()
	submitted = run_workload(h, options.workload, options.scale, index)
	build_ns = time.duration_nanoseconds(time.tick_since(build_started))
	finalize_started := time.tick_now()
	ui.ui_frame_finalize(&h.frame)
	finalize_ns = time.duration_nanoseconds(time.tick_since(finalize_started))
	frame_ns = time.duration_nanoseconds(time.tick_since(frame_started))
	return
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

print_telemetry :: proc(telemetry: ui.Ui_Frame_Telemetry) {
	fmt.print(
		"\"scratch_allocations\":",
		telemetry.scratch_allocation_count,
		",\"scratch_resizes\":",
		telemetry.scratch_resize_count,
		",\"scratch_allocation_request_bytes\":",
		telemetry.scratch_allocation_request_bytes,
		",\"scratch_resize_request_bytes\":",
		telemetry.scratch_resize_request_bytes,
		",\"main_command_appends\":",
		telemetry.main.command_append_count,
		",\"main_text_appends\":",
		telemetry.main.text_append_count,
		",\"main_text_bytes_copied\":",
		telemetry.main.text_bytes_copied,
		",\"main_command_growths\":",
		telemetry.main.command_growth_count,
		",\"main_text_growths\":",
		telemetry.main.text_growth_count,
		",\"overlay_command_appends\":",
		telemetry.overlay.command_append_count,
		",\"overlay_text_appends\":",
		telemetry.overlay.text_append_count,
		",\"overlay_text_bytes_copied\":",
		telemetry.overlay.text_bytes_copied,
		",\"overlay_command_growths\":",
		telemetry.overlay.command_growth_count,
		",\"overlay_text_growths\":",
		telemetry.overlay.text_growth_count,
		",\"text_input_full_paths\":",
		telemetry.text_input_full_path_count,
		",\"text_input_inactive_candidates\":",
		telemetry.text_input_inactive_candidates,
	)
}

main :: proc() {
	options, valid := parse_options()
	if !valid {
		fmt.eprintln(
			"usage: ingot_widget_bench [--workload=ID] [--scale=N] ",
			"[--warmup=N] [--frames=N] [--repetition=N]",
		)
		os.exit(2)
	}
	semantics :=
		options.workload == .Accessibility || options.workload == .Button_Semantics_Enabled
	h := harness_make(semantics)
	defer harness_destroy(h)
	for index in 0 ..< options.warmup {
		_, _, _, _ = measure_frame(h, options, index)
		ui.ui_frame_release(&h.frame)
	}
	build_samples := make([]i64, options.frames)
	finalize_samples := make([]i64, options.frames)
	frame_samples := make([]i64, options.frames)
	defer delete(build_samples)
	defer delete(finalize_samples)
	defer delete(frame_samples)
	submitted := 0
	state_checksum := FNV_BASIS
	for index in 0 ..< options.frames {
		build_samples[index], finalize_samples[index], frame_samples[index], submitted =
			measure_frame(h, options, index)
		state_checksum = hash_u64(state_checksum, u64(submitted))
		if options.workload == .Layout_Flow {
			state_checksum = hash_u64(state_checksum, h.layout_checksum)
		}
		ui.ui_frame_release(&h.frame)
	}
	ui.ui_frame_begin(&h.frame, &h.runtime, &h.input)
	submitted = run_workload(h, options.workload, options.scale, options.frames)
	ui.ui_frame_finalize(&h.frame)
	stats := ui.ui_frame_output_stats(&h.frame)
	telemetry := ui.ui_frame_telemetry(&h.frame)
	diagnostics := ui.ui_frame_diagnostics(&h.frame)
	valid_output :=
		diagnostics.main_commands_dropped == 0 && diagnostics.main_text_bytes_dropped == 0
	if options.workload == .Capacity do valid_output = true
	fmt.print(
		"{\"schema_version\":1,\"framework\":\"ingot\",\"framework_revision\":\"workspace\"",
		",\"backend\":\"headless\",\"layer\":\"core\",\"workload\":\"",
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
	print_samples("finalize", finalize_samples, false)
	print_samples("frame", frame_samples, false)
	fmt.print(
		"},\"output\":{\"submitted_widgets\":",
		submitted,
		",\"visible_widgets\":",
		min(submitted, VIRTUAL_ROWS),
		",\"paint_commands\":",
		stats.main_command_count,
		",\"text_bytes\":",
		stats.main_text_bytes,
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
	ui.ui_frame_release(&h.frame)
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
	}
	return "unknown"
}
