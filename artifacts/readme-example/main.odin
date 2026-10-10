package main

import "core:fmt"
import fit "ingot:fit"

App_State :: struct {
	button_clicks: u64,
}

app: fit.App
state: App_State

main :: proc() {
	_ = fit.run(&app, {width = 960, height = 640, title = "Ingot app"}, Draw, &state)
}

Continue :: proc(user_data: rawptr) {
	assert(user_data != nil)
	state := cast(^App_State)user_data
	state.button_clicks += 1
}

Draw :: proc(builder: ^fit.Builder, user_data: rawptr) {
	assert(builder != nil && user_data != nil)
	state := cast(^App_State)user_data
	root := fit.center(builder, {gap = .SM, padding = .LG})
	fit.label(root, "Hello from Ingot")
	fit.label(root, fmt.tprintf("Button clicks: %d", state.button_clicks))
	fit.button(root, "continue", "Continue", fit.action(Continue, state))
}
