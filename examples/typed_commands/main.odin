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
	if !fit.run(&app, {width = 640, height = 400, title = "Ingot typed commands"}, Draw, &state) {
		fmt.eprintln("Unable to run typed commands example")
	}
}

Draw :: proc(builder: ^fit.Builder, user_data: rawptr) {
	assert(builder != nil && user_data != nil, "typed commands draw: invalid argument")
	data := cast(^State)user_data
	fit.typed_commands_begin(&data.commands, builder)
	defer fit.typed_commands_end(&data.commands)
	command: Command
	for _ in 0 ..< COMMAND_CAPACITY {
		if !fit.typed_commands_take(&data.commands, &command) do break
		switch command {
		case .Continue:
			data.clicks += 1
		case .Reset:
			data.clicks = 0
		}
	}

	root := fit.center(builder, {gap = .SM, padding = .LG})
	fit.label(root, "Caller-owned typed commands")
	fit.label(root, fmt.tprintf("Button clicks: %d", data.clicks))
	ready_dropped, activation_dropped := fit.typed_commands_dropped(&data.commands)
	if data.declaration_failed || ready_dropped > 0 || activation_dropped > 0 {
		fit.label(
			root,
			fmt.tprintf("Queue full: ready=%d, controls=%d", ready_dropped, activation_dropped),
		)
	}
	data.declaration_failed = false
	continued := fit.button_command(root, "continue", "Continue", &data.commands, Command.Continue)
	reset := fit.button_command(root, "reset", "Reset", &data.commands, Command.Reset)
	data.declaration_failed = continued != .Accepted || reset != .Accepted
	polling := fit.scope(root, "polling")
	result := fit.button_result(polling, "inspect")
	if result.status == .Available && result.activated {
		fit.label(polling, "Polling activation from the previous build")
	}
	fit.button(polling, "inspect", "Inspect result")
	unavailable := fit.typed_commands_unavailable(&data.commands)
	if unavailable > 0 {
		fit.label(root, fmt.tprintf("Unavailable interaction results: %d", unavailable))
	}
}
