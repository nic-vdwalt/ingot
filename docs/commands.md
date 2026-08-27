# Commands and contextual shortcuts

`ingot:action` provides bounded named command IDs, keystrokes, bindings, and a
transactionally replaced keymap. `ingot:ui` resolves a keymap against the open
frame, while `ingot:fit` exposes the same operation through a Builder or Surface.
The application owns the keymap, chooses the active context, takes the command,
and changes its own state.

```odin
save, save_ok := fit.Command_Id_String("editor.save")
editor, editor_ok := fit.Command_Context_Id_String("editor")
assert(save_ok && editor_ok)

bindings := [1]fit.Command_Binding {{
	command = save,
	context_id = editor,
	stroke = {
		key = i32(fit.Key.S),
		modifiers = {.Control},
	},
}}
assert(fit.Command_Keymap_Set(&keymap, bindings[:]))

Draw :: proc(builder: ^fit.Builder, user_data: rawptr) {
	if fit.Command_Take(builder, &keymap, editor) == save do save_document()
	root := fit.Column(builder)
	fit.Label(root, "Editor")
}
```

Use `.Super` for an explicit macOS Command binding. Applications that want one
portable “primary” shortcut can construct the platform-appropriate binding when
they construct their keymap. Modifiers are matched exactly, preventing an
unmodified printable key or an additional modifier from activating a shortcut.

## Ownership and timing

- A `Command_Keymap` is an ordinary caller-owned bounded value.
- `Command_Keymap_Set` validates the complete replacement before changing it.
- Duplicate context/keystroke triggers are rejected rather than resolved by load order.
- A context-specific binding wins over a global binding; priority resolves ties.
- Declaration order resolves equal-priority ties deterministically.
- `Command_Take` returns at most one command and consumes its key edge and
  printable character queue so a later text input cannot receive the shortcut.
- An unmatched key changes nothing and remains visible to widgets and text input.
- Existing direct key queries and immediate widget return values remain supported.

The initial API supports one-stroke bindings. Chords and untrusted text-file
parsing are intentionally absent until an Ingot application demonstrates the
need and their timeout, parser, and diagnostic contracts are designed.

## Optional typed command queues

`fit.Typed_Commands(T, Capacity)` is a caller-owned fixed-capacity queue for
applications that want buttons, menus, shortcuts, and integration completions
to converge on one typed vocabulary. It is not an application runtime or
reducer, and ordinary immediate results and `fit.Action` remain the shortest
primary APIs.

```odin
Command :: enum u8 {
	Save,
	Reset,
}

commands: fit.Typed_Commands(Command, 16)

Draw :: proc(builder: ^fit.Builder, _: rawptr) {
	fit.Typed_Commands_Begin(&commands)
	command: Command
	for fit.Typed_Commands_Take(&commands, &command) {
		switch command {
		case .Save:
			save()
		case .Reset:
			reset()
		}
	}
	fit.Typed_Commands_End(&commands)

	root := fit.Column(builder)
	_ = fit.Button_Command(root, "save", "Save", &commands, Command.Save)
}
```

The queue copies values into fixed storage. `Begin` promotes activations from
the preceding rendered declaration and captures the drain limit. Entries
appended while draining wait for the next explicit drain, so dispatch is never
recursive. `Button_Command` reports `.Full` if no activation slot remains;
`Typed_Commands_Append` reports `.Full` when ready storage is saturated. Drop
counts remain inspectable through `Typed_Commands_Dropped`.

Command payloads must own everything they carry. Borrowed strings, slices,
frame pointers, and callback closures are not safe queue payloads. An
integration boundary must copy asynchronous completion data into an
application-owned bounded value before appending it and requesting a redraw.
