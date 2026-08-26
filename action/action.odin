package action

COMMAND_NAME_BYTE_MAX :: 96
KEYMAP_BINDING_CAP :: 128

Command_Id :: distinct u64
COMMAND_ID_NONE :: Command_Id(0)
Context_Id :: distinct u64
CONTEXT_ID_NONE :: Context_Id(0)

Modifier :: enum u8 {
	Shift,
	Control,
	Alt,
	Super,
}

Modifiers :: bit_set[Modifier;u8]

Keystroke :: struct {
	key:       i32,
	modifiers: Modifiers,
	repeat:    bool,
}

Binding :: struct {
	command:    Command_Id,
	context_id: Context_Id,
	stroke:     Keystroke,
	priority:   i32,
}

Keymap :: struct {
	bindings: [KEYMAP_BINDING_CAP]Binding,
	count:    int,
}

command_id :: proc(value: u64) -> Command_Id {
	assert(value != 0, "action.command_id: zero is reserved")
	return Command_Id(value)
}

command_id_string :: proc(value: string) -> (Command_Id, bool) {
	hash, ok := name_hash(value)
	return Command_Id(hash), ok
}

context_id :: proc(value: u64) -> Context_Id {
	assert(value != 0, "action.context_id: zero is reserved")
	return Context_Id(value)
}

context_id_string :: proc(value: string) -> (Context_Id, bool) {
	hash, ok := name_hash(value)
	return Context_Id(hash), ok
}

@(private = "file")
name_hash :: proc(value: string) -> (u64, bool) {
	if len(value) == 0 || len(value) > COMMAND_NAME_BYTE_MAX do return 0, false
	hash: u64 = 0xcbf29ce484222325
	for byte in transmute([]u8)value {
		hash ~= u64(byte)
		hash *= 0x00000100000001b3
	}
	if hash == 0 do hash = 1
	return hash, true
}

binding_valid :: proc(binding: Binding) -> bool {
	if binding.command == COMMAND_ID_NONE do return false
	if binding.stroke.key < 0 do return false
	return true
}

keymap_set :: proc(keymap: ^Keymap, bindings: []Binding) -> bool {
	assert(keymap != nil, "action.keymap_set: nil keymap")
	if len(bindings) > KEYMAP_BINDING_CAP do return false
	for binding, index in bindings {
		if !binding_valid(binding) do return false
		for previous in 0 ..< index {
			if binding_same_trigger(binding, bindings[previous]) do return false
		}
	}
	keymap.bindings = {}
	copy(keymap.bindings[:len(bindings)], bindings)
	keymap.count = len(bindings)
	assert(keymap.count >= 0 && keymap.count <= KEYMAP_BINDING_CAP)
	return true
}

keymap_bindings :: proc(keymap: ^Keymap) -> []Binding {
	assert(keymap != nil, "action.keymap_bindings: nil keymap")
	assert(keymap.count >= 0 && keymap.count <= KEYMAP_BINDING_CAP)
	return keymap.bindings[:keymap.count]
}

@(private = "file")
binding_same_trigger :: proc(a, b: Binding) -> bool {
	return a.context_id == b.context_id && a.stroke == b.stroke
}
