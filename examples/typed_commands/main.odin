package main

import "core:fmt"
import fit "ingot:fit"

COMMAND_CAPACITY :: 16

Command :: enum u8 {
	Continue,
	Reset,
}

State :: struct {
	clicks:             u64,
	commands:           fit.Typed_Commands(Command, COMMAND_CAPACITY),
	declaration_failed: bool,
}

app: fit.App
state: State

main :: proc() {
	if !fit.Run(&app, {width = 640, height = 400, title = "Ingot typed commands"}, Draw, &state) {
		fmt.eprintln("Unable to run typed commands example")
	}
}

Draw :: proc(builder: ^fit.Builder, user_data: rawptr) {
	assert(builder != nil && user_data != nil, "typed commands draw: invalid argument")
	data := cast(^State)user_data
	fit.Typed_Commands_Begin(&data.commands)
	defer fit.Typed_Commands_End(&data.commands)
	command: Command
	for _ in 0 ..< COMMAND_CAPACITY {
		if !fit.Typed_Commands_Take(&data.commands, &command) do break
		switch command {
		case .Continue:
			data.clicks += 1
		case .Reset:
			data.clicks = 0
		}
	}

	root := fit.Center(builder, {gap = .SM, padding = .LG})
	fit.Label(root, "Caller-owned typed commands")
	fit.Label(root, fmt.tprintf("Button clicks: %d", data.clicks))
	ready_dropped, activation_dropped := fit.Typed_Commands_Dropped(&data.commands)
	if data.declaration_failed || ready_dropped > 0 || activation_dropped > 0 {
		fit.Label(
			root,
			fmt.tprintf("Queue full: ready=%d, controls=%d", ready_dropped, activation_dropped),
		)
	}
	data.declaration_failed = false
	continued := fit.Button_Command(root, "continue", "Continue", &data.commands, Command.Continue)
	reset := fit.Button_Command(root, "reset", "Reset", &data.commands, Command.Reset)
	data.declaration_failed = continued != .Accepted || reset != .Accepted
}
