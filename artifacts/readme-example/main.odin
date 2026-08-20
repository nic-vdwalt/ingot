package main

import "core:fmt"
import fit "ingot:fit"

app: fit.App
button_clicks: u64

main :: proc() {
	_ = fit.Run(&app, {width = 960, height = 640, title = "Ingot app"}, Draw)
}

Continue :: proc(userdata: rawptr) {
	_ = userdata
	button_clicks += 1
}

Draw :: proc(builder: ^fit.Builder, userdata: rawptr) {
	_ = userdata
	root := fit.Center(builder, {gap = .SM, padding = .LG})
	fit.Label(root, "Hello from Ingot")
	fit.Label(root, fmt.tprintf("Button clicks: %d", button_clicks))
	fit.Button(root, "continue", "Continue", fit.On(Continue))
}
