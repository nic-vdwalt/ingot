#+build !js
package fit

import "core:testing"
import "ingot:ui"

@(private = "file")
Contract_Control :: struct {
	variant: int,
	checked: bool,
}

@(private = "file")
contract_checkbox_draw :: proc(builder: ^Builder, userdata: rawptr) {
	state := cast(^Contract_Control)userdata
	root := Center(builder)
	options := Control_Options {
		size = {width = Fixed(100), height = Fixed(40)},
	}
	switch state.variant {
	case 0:
		Checkbox(root, "check", "Check", &state.checked, options)
	case 1:
		Checkbox(root, u64(42), "Check", &state.checked, options)
	case 2:
		Checkbox(root, Id(root, "check"), "Check", &state.checked, options)
	}
}

@(test)
fit_checkbox_overloads_activate_once :: proc(t: ^testing.T) {
	for variant in 0 ..< 3 {
		driver: Test_Driver
		Test_Driver_Init(&driver)
		state := Contract_Control {
			variant = variant,
		}
		base := Test_Input {
			screen_size    = {320, 240},
			mouse_position = {160, 120},
			dpi_scale      = 1,
		}
		testing.expect(t, Test_Driver_Frame(&driver, base, contract_checkbox_draw, &state))
		pressed := base
		pressed.mouse_pressed[0] = true
		pressed.mouse_down[0] = true
		testing.expect(t, Test_Driver_Frame(&driver, pressed, contract_checkbox_draw, &state))
		released := base
		released.mouse_released[0] = true
		testing.expect(t, Test_Driver_Frame(&driver, released, contract_checkbox_draw, &state))
		testing.expect(t, state.checked)
		testing.expect(t, Test_Driver_Frame(&driver, base, contract_checkbox_draw, &state))
		testing.expect(t, state.checked)
		Test_Driver_Destroy(&driver)
	}
}

@(test)
fit_checkbox_overloads_forward_size :: proc(t: ^testing.T) {
	driver: Test_Driver
	Test_Driver_Init(&driver)
	defer Test_Driver_Destroy(&driver)
	impl := cast(^Test_Driver_Impl)driver.inner
	frame: ui.Ui_Frame
	output := new(ui.Ui_Output)
	defer free(output)
	frame.output = output
	ui.ui_frame_begin(&frame, &impl.runtime)
	defer ui.ui_frame_end(&frame)
	builder: Builder
	builder_open(&builder, &frame, {0, 0, 320, 240})
	root := Column(&builder)
	checked: [3]bool
	Checkbox(
		root,
		"string",
		"String",
		&checked[0],
		{size = {width = Fixed(40), height = Fixed(16)}},
	)
	Checkbox(
		root,
		u64(7),
		"Integer",
		&checked[1],
		{size = {width = Fixed(50), height = Fixed(18)}},
	)
	Checkbox(
		root,
		Id(root, "widget"),
		"Widget",
		&checked[2],
		{size = {width = Fixed(60), height = Fixed(20)}},
	)
	size := Measure(&builder)
	Render_At(&builder, {0, 0, size.w, size.h})
	builder_close(&builder)
	testing.expect_value(t, size.w, i32(60))
	testing.expect_value(t, size.h, i32(54))
}
