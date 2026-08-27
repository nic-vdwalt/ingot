package main

import "core:fmt"
import fit "ingot:fit"

Command :: enum u8 {
	Continue,
	Reset,
}

State :: struct {
	clicks:   u64,
	commands: fit.Typed_Commands(Command, 16),
}

app: fit.App
state: State

main :: proc() {
	_ = fit.Run(&app, {width = 640, height = 400, title = "Ingot typed commands"}, Draw)
}

Draw :: proc(builder: ^fit.Builder, _: rawptr) {
	fit.Typed_Commands_Begin(&state.commands)
	command: Command
	for _ in 0 ..< 16 {
		if !fit.Typed_Commands_Take(&state.commands, &command) do break
		switch command {
		case .Continue:
			state.clicks += 1
		case .Reset:
			state.clicks = 0
		}
	}
	fit.Typed_Commands_End(&state.commands)

	root := fit.Center(builder, {gap = .SM, padding = .LG})
	fit.Label(root, "Caller-owned typed commands")
	fit.Label(root, fmt.tprintf("Button clicks: %d", state.clicks))
	_ = fit.Button_Command(root, "continue", "Continue", &state.commands, Command.Continue)
	_ = fit.Button_Command(root, "reset", "Reset", &state.commands, Command.Reset)
}
