#+build !js
package ui

import "core:strings"
import "core:testing"

@(private = "file")
Prepared_Input_Frame :: struct {
	text:      string,
	submit:    Maybe(Text_Input_Submit),
	height:    i32,
	max_lines: i32,
	enter:     bool,
	shift:     bool,
	width:     i32, // zero uses 300
}

@(private = "file")
Prepared_Input_Result :: struct {
	text:        string,
	submitted:   bool,
	rect_h:      i32,
	line_height: i32,
	pad:         i32,
	min_h:       i32,
}

// prepared_input_frame drives one real frame of a focused declarative text
// input so measure, layout and the keyboard pipeline all run.
@(private = "file")
prepared_input_frame :: proc(config: Prepared_Input_Frame) -> Prepared_Input_Result {
	runtime := new(Ui_Runtime)
	defer free(runtime)
	ui_runtime_init(runtime)
	defer ui_runtime_destroy(runtime)
	text_backend: Test_Text_Backend_State
	ui_runtime_set_text_backend(
		runtime,
		{
			data = &text_backend,
			font_for_size = test_text_font_for_size,
			measure = test_text_measure,
		},
	)
	output := new(Ui_Output)
	defer free(output)
	frame := new(Ui_Frame)
	defer free(frame)
	defer ui_frame_destroy(frame)
	frame.output = output

	input: Ui_Input
	input.screen_size = {800, 600}
	if config.enter do input.keys_pressed[input_key_index(.ENTER)] = true
	if config.shift do input.keys_down[input_key_index(.LEFT_SHIFT)] = true

	box: Input_Box
	defer input_box_destroy(&box)
	strings.write_string(&box.sb, config.text)
	box.st.cursor = len(config.text)

	width := config.width if config.width > 0 else 300
	ui_frame_begin(frame, runtime, &input)
	u := new(Ui)
	defer free(u)
	begin(u, frame, {0, 0, width, 400})
	widget := id(u, "composer")
	u.focus_state.active = focus_widget_id(widget)
	submitted := false
	builder := new(Fit_Builder)
	defer free(builder)
	fit_begin(builder, u)
	fit_builder_row(builder, {size = {width = grow()}})
	fit_builder_text_input(
		builder,
		{
			id = widget,
			box = &box,
			placeholder = "Message",
			height = config.height,
			semantics = {name = "Message"},
			submit = config.submit,
			max_lines = config.max_lines,
		},
		{size = {width = grow()}, changed = &submitted},
	)
	fit_end(builder)
	fit_render(builder)
	rect_h := i32(-1)
	for index in 0 ..< builder.prepared.count {
		node := &prepared_nodes(&builder.prepared)[index]
		if node.kind == .Text_Input do rect_h = node.rect.h
	}
	metrics := ui_frame_metrics(frame)
	result := Prepared_Input_Result {
		text        = strings.clone(strings.to_string(box.sb), context.temp_allocator),
		submitted   = submitted,
		rect_h      = rect_h,
		line_height = metrics.LINE_HEIGHT,
		pad         = ui_frame_sc(frame, TI_PAD_VERT),
		min_h       = metrics.ROW_H_MD + metrics.CONTROL_GAP,
	}
	end(u)
	ui_frame_end(frame)
	return result
}

@(private = "file")
grown_height :: proc(result: Prepared_Input_Result, lines: i32) -> i32 {
	return max(result.min_h, lines * result.line_height + result.pad)
}

@(test)
prepared_text_input_grows_with_lines_and_clamps_at_max_lines :: proc(t: ^testing.T) {
	one := prepared_input_frame({text = "a", max_lines = 3})
	testing.expect_value(t, one.rect_h, grown_height(one, 1))
	two := prepared_input_frame({text = "a\nb", max_lines = 3})
	testing.expect_value(t, two.rect_h, grown_height(two, 2))
	three := prepared_input_frame({text = "a\nb\nc", max_lines = 3})
	testing.expect_value(t, three.rect_h, grown_height(three, 3))
	clamped := prepared_input_frame({text = "a\nb\nc\nd\ne\nf", max_lines = 3})
	testing.expect_value(t, clamped.rect_h, grown_height(clamped, 3))
	testing.expect(t, three.rect_h > two.rect_h && two.rect_h > one.rect_h, "height must grow")
}

@(test)
prepared_text_input_grows_when_a_long_line_wraps :: proc(t: ^testing.T) {
	long := strings.repeat("word ", 40, context.temp_allocator)
	short := prepared_input_frame({text = "word", max_lines = 6, width = 200})
	wrapped := prepared_input_frame({text = long, max_lines = 6, width = 200})
	testing.expect(t, wrapped.rect_h > short.rect_h, "a wrapped line must grow the box")
	testing.expect(t, wrapped.rect_h <= grown_height(wrapped, 6), "growth must clamp")
}

@(test)
prepared_text_input_fixed_height_is_unchanged_without_max_lines :: proc(t: ^testing.T) {
	one := prepared_input_frame({text = "a"})
	many := prepared_input_frame({text = "a\nb\nc\nd"})
	testing.expect_value(t, one.rect_h, one.min_h)
	testing.expect_value(t, many.rect_h, many.min_h)
}

@(test)
prepared_text_input_explicit_enter_submits_a_multi_line_box :: proc(t: ^testing.T) {
	sent := prepared_input_frame({text = "a\nb", submit = .Enter, max_lines = 6, enter = true})
	testing.expect(t, sent.submitted, "explicit .Enter must submit on Enter")
	testing.expect_value(t, sent.text, "a\nb")
	newline := prepared_input_frame(
		{text = "a\nb", submit = .Enter, max_lines = 6, enter = true, shift = true},
	)
	testing.expect(t, !newline.submitted, "Shift+Enter must not submit")
	testing.expect_value(t, newline.text, "a\nb\n")
}

@(test)
prepared_text_input_default_submit_follows_box_height :: proc(t: ^testing.T) {
	area := prepared_input_frame({text = "ab", height = 90, enter = true})
	testing.expect(t, !area.submitted, "a tall default box must not submit on Enter")
	testing.expect_value(t, area.text, "ab\n")
	field := prepared_input_frame({text = "ab", enter = true})
	testing.expect(t, field.submitted, "a one-line default box must submit on Enter")
	testing.expect_value(t, field.text, "ab")
}
