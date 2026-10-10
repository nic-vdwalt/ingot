package main

import "core:fmt"
import fit "ingot:fit"

FIXTURE_FRAME_LIMIT :: 120

Fixture_State :: struct {
	label: string,
}

fixture_draw :: proc(builder: ^fit.Builder, user_data: rawptr) {
	state := cast(^Fixture_State)user_data
	root := fit.center(builder, {gap = .SM, padding = .LG})
	fit.label(root, "Multi-App fixture", {role = .Title})
	fit.label(root, state.label)
	fit.label(root, "Each App owns an isolated Fit lifecycle.", {ink = .Success})
}

main :: proc() {
	primary := new(fit.App)
	secondary := new(fit.App)
	defer free(primary)
	defer free(secondary)
	primary_state := Fixture_State {
		label = "Primary",
	}
	secondary_state := Fixture_State {
		label = "Secondary",
	}
	flags: fit.Window_Flags = {.Resizable}
	primary_ok := fit.init(
		primary,
		{width = 640, height = 360, title = "Ingot primary App", flags = flags},
		{draw = fixture_draw},
		&primary_state,
	)
	secondary_ok := fit.init(
		secondary,
		{width = 480, height = 300, title = "Ingot secondary App", flags = flags},
		{draw = fixture_draw},
		&secondary_state,
	)
	if !primary_ok || !secondary_ok {
		fmt.eprintln("multi_app_fixture: initialization failed")
		if primary_ok do fit.destroy(primary)
		if secondary_ok do fit.destroy(secondary)
		return
	}
	defer {
		if fit.get_state(primary) == .Running do _ = fit.stop(primary)
		if fit.get_state(primary) != .Empty do fit.destroy(primary)
		if fit.get_state(secondary) == .Running do _ = fit.stop(secondary)
		if fit.get_state(secondary) != .Empty do fit.destroy(secondary)
	}
	if !fit.start(primary) || !fit.start(secondary) {
		fmt.eprintln("multi_app_fixture: start failed")
		return
	}
	for frame_index in 0 ..< FIXTURE_FRAME_LIMIT {
		if !fit.tick(primary) || !fit.tick(secondary) do break
		if frame_index == FIXTURE_FRAME_LIMIT / 2 {
			_ = fit.stop(primary)
			fit.destroy(primary)
			for _ in frame_index ..< FIXTURE_FRAME_LIMIT {
				if !fit.tick(secondary) do break
			}
			break
		}
	}
}
