package main

import "core:fmt"
import fit "ingot:fit"

FIXTURE_FRAME_LIMIT :: 120

Fixture_State :: struct {
	label: string,
}

fixture_draw :: proc(builder: ^fit.Builder, userdata: rawptr) {
	state := cast(^Fixture_State)userdata
	fit.Center(builder, {gap = .SM, padding = .LG})
	fit.Label(builder, "Multi-App fixture", {role = .Title})
	fit.Label(builder, state.label)
	fit.Label(builder, "Each App owns an isolated Fit lifecycle.", {ink = .Success})
	fit.End(builder)
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
	primary_ok := fit.Init(
		primary,
		{width = 640, height = 360, title = "Ingot primary App", flags = flags},
		{draw = fixture_draw},
		&primary_state,
	)
	secondary_ok := fit.Init(
		secondary,
		{width = 480, height = 300, title = "Ingot secondary App", flags = flags},
		{draw = fixture_draw},
		&secondary_state,
	)
	if !primary_ok || !secondary_ok {
		fmt.eprintln("multi_app_fixture: initialization failed")
		if primary_ok do fit.Destroy(primary)
		if secondary_ok do fit.Destroy(secondary)
		return
	}
	defer {
		if fit.Get_State(primary) == .Running do _ = fit.Stop(primary)
		if fit.Get_State(primary) != .Empty do fit.Destroy(primary)
		if fit.Get_State(secondary) == .Running do _ = fit.Stop(secondary)
		if fit.Get_State(secondary) != .Empty do fit.Destroy(secondary)
	}
	if !fit.Start(primary) || !fit.Start(secondary) {
		fmt.eprintln("multi_app_fixture: start failed")
		return
	}
	for frame_index in 0 ..< FIXTURE_FRAME_LIMIT {
		if !fit.Tick(primary) || !fit.Tick(secondary) do break
		if frame_index == FIXTURE_FRAME_LIMIT / 2 {
			_ = fit.Stop(primary)
			fit.Destroy(primary)
			for _ in frame_index ..< FIXTURE_FRAME_LIMIT {
				if !fit.Tick(secondary) do break
			}
			break
		}
	}
}
