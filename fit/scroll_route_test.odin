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
	root := column(builder)
	panel := attachment(
		root,
		{
			target_kind = .Viewport,
			target_point = .Top_Left,
			self_point = .Top_Left,
			z = Z_PANEL,
			claim = true,
		},
	)
	body := column(panel, {size = {width = fixed(200), height = fixed(100)}})
	scroll_parent := scroll(
		body,
		"scroll-route",
		&fixture.scroll,
		{axis = fixture.axis, size = {width = fixed(200), height = fixed(100)}},
	)
	if fixture.axis == .Horizontal {
		content := row(scroll_parent, {size = {width = fixed(600), height = fixed(80)}})
		spacer(content, .XL, {size = {width = fixed(600), height = fixed(80)}})
	} else {
		content := column(scroll_parent)
		spacer(content, .XL, {size = {height = fixed(300)}})
	}
	if !fixture.cover do return
	modal := attachment(
		root,
		{
			target_kind = .Viewport,
			target_point = .Top_Left,
			self_point = .Top_Left,
			z = Z_POPUP,
			claim = true,
		},
	)
	cover := column(modal, {size = {width = fixed(300), height = fixed(300)}})
	spacer(cover, .XL, {size = {width = fixed(300), height = fixed(300)}})
}

@(private = "file")
scroll_route_offset_after_wheel :: proc(fixture: ^Scroll_Route_Fixture, wheel: Point) -> f32 {
	assert(fixture != nil, "scroll_route_offset_after_wheel: nil fixture")
	driver: Test_Driver
	test_driver_init(&driver)
	defer test_driver_destroy(&driver)
	idle := Test_Input {
		screen_size    = {800, 600},
		dpi_scale      = 1,
		mouse_position = {100, 50},
	}
	for _ in 0 ..< 2 {
		if !test_driver_frame(&driver, idle, scroll_route_draw, fixture) do return -1
	}
	scrolled := idle
	scrolled.mouse_wheel = wheel
	if !test_driver_frame(&driver, scrolled, scroll_route_draw, fixture) do return -1
	return scroll_offset(&fixture.scroll)
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
