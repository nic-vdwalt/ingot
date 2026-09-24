#+build !js
package fit

import "core:testing"

@(private = "file")
Scroll_Route_Fixture :: struct {
	scroll: Scroll_State,
	axis:   Scroll_Axis,
	cover:  bool,
}

@(private = "file")
scroll_route_draw :: proc(builder: ^Builder, user_data: rawptr) {
	assert(builder != nil && user_data != nil, "scroll_route_draw: invalid argument")
	fixture := cast(^Scroll_Route_Fixture)user_data
	root := Column(builder)
	panel := Attachment(
		root,
		{
			target_kind = .Viewport,
			target_point = .Top_Left,
			self_point = .Top_Left,
			z = Z_PANEL,
			claim = true,
		},
	)
	body := Column(panel, {size = {width = Fixed(200), height = Fixed(100)}})
	scroll := Scroll(
		body,
		"scroll-route",
		&fixture.scroll,
		{axis = fixture.axis, size = {width = Fixed(200), height = Fixed(100)}},
	)
	if fixture.axis == .Horizontal {
		content := Row(scroll, {size = {width = Fixed(600), height = Fixed(80)}})
		Spacer(content, .XL, {size = {width = Fixed(600), height = Fixed(80)}})
	} else {
		content := Column(scroll)
		Spacer(content, .XL, {size = {height = Fixed(300)}})
	}
	if !fixture.cover do return
	modal := Attachment(
		root,
		{
			target_kind = .Viewport,
			target_point = .Top_Left,
			self_point = .Top_Left,
			z = Z_POPUP,
			claim = true,
		},
	)
	Spacer(modal, .XL, {size = {width = Fixed(300), height = Fixed(300)}})
}

@(private = "file")
scroll_route_offset_after_wheel :: proc(fixture: ^Scroll_Route_Fixture, wheel: Point) -> f32 {
	assert(fixture != nil, "scroll_route_offset_after_wheel: nil fixture")
	driver: Test_Driver
	Test_Driver_Init(&driver)
	defer Test_Driver_Destroy(&driver)
	idle := Test_Input {
		screen_size    = {800, 600},
		dpi_scale      = 1,
		mouse_position = {100, 50},
	}
	for _ in 0 ..< 2 {
		if !Test_Driver_Frame(&driver, idle, scroll_route_draw, fixture) do return -1
	}
	scrolled := idle
	scrolled.mouse_wheel = wheel
	if !Test_Driver_Frame(&driver, scrolled, scroll_route_draw, fixture) do return -1
	return Scroll_Offset(&fixture.scroll)
}

@(test)
scroll_inside_claimed_attachment_takes_the_wheel :: proc(t: ^testing.T) {
	fixture: Scroll_Route_Fixture
	offset := scroll_route_offset_after_wheel(&fixture, {0, -1})
	testing.expect_value(t, fixture.scroll.inner.content_h, i32(300))
	testing.expect(t, offset > 0, "a panel must not occlude its own scroll")
}

@(test)
horizontal_scroll_inside_claimed_attachment_takes_the_wheel :: proc(t: ^testing.T) {
	fixture := Scroll_Route_Fixture {
		axis = .Horizontal,
	}
	offset := scroll_route_offset_after_wheel(&fixture, {-1, 0})
	testing.expect(t, offset > 0, "a panel must not occlude its own horizontal scroll")
}

@(test)
scroll_under_a_higher_claim_ignores_the_wheel :: proc(t: ^testing.T) {
	fixture := Scroll_Route_Fixture {
		cover = true,
	}
	offset := scroll_route_offset_after_wheel(&fixture, {0, -1})
	testing.expect_value(t, offset, f32(0))
}
