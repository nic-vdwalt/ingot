package ui

Modal_Id :: distinct u64

Modal_Close_Reason :: enum u8 {
	None,
	Accepted,
	Canceled,
	Escape,
	Outside_Click,
	Programmatic,
}

Modal_Dismiss_Kind :: enum u8 {
	Escape,
	Outside_Click,
}

Modal_Dismiss_Policy :: bit_set[Modal_Dismiss_Kind;u8]

Modal_Key_Edge :: enum u8 {
	Pressed,
	Repeated,
	Released,
}

Modal_Runtime_Entry :: struct {
	id:              Modal_Id,
	z:               Z_Order,
	seen_generation: u64,
	claim:           Rectangle,
	claim_all:       bool,
}

Modal_Runtime :: struct {
	entries:  [MAX_MODAL_STACK]Modal_Runtime_Entry,
	count:    int,
	overflow: bool,
}

Modal_Frame :: struct {
	owners:            [MAX_MODAL_STACK]Modal_Id,
	owner_count:       int,
	consumed_pressed:  [INPUT_KEY_COUNT]bool,
	consumed_repeat:   [INPUT_KEY_COUNT]bool,
	consumed_released: [INPUT_KEY_COUNT]bool,
}

modal_frame_begin :: proc(frame: ^Ui_Frame) {
	assert(frame != nil && frame.open, "modal frame begin: invalid frame")
	frame.modal = {}
	runtime := &frame.runtime.modals
	assert(runtime.count >= 0 && runtime.count <= MAX_MODAL_STACK)
	write := 0
	for read in 0 ..< runtime.count {
		entry := runtime.entries[read]
		if entry.seen_generation + 1 < frame.runtime.frame_generation do continue
		runtime.entries[write] = entry
		write += 1
	}
	runtime.count = write
	for i in 0 ..< runtime.count {
		entry := &runtime.entries[i]
		entry.z = Z_MODAL + Z_Order(i)
		if entry.claim_all {
			route_claim_all(frame, entry.z)
		} else {
			route_claim(frame, entry.claim, entry.z)
		}
	}
	if runtime.overflow do route_claim_all(frame, Z_TOOLTIP)
}

modal_frame_finalize :: proc(frame: ^Ui_Frame) {
	assert(frame != nil && frame.open, "modal frame finalize: invalid frame")
	assert(frame.modal.owner_count == 0, "modal frame finalize: unbalanced owner scope")
	frame.runtime.modals.overflow = false
}

modal_runtime_find :: proc(runtime: ^Modal_Runtime, id: Modal_Id) -> int {
	assert(runtime != nil, "modal runtime find: nil runtime")
	for i in 0 ..< runtime.count do if runtime.entries[i].id == id do return i
	return -1
}

modal_runtime_remove :: proc(runtime: ^Modal_Runtime, id: Modal_Id) {
	assert(runtime != nil, "modal runtime remove: nil runtime")
	index := modal_runtime_find(runtime, id)
	if index < 0 do return
	for i in index ..< runtime.count - 1 do runtime.entries[i] = runtime.entries[i + 1]
	runtime.count -= 1
}

modal_runtime_register :: proc(
	frame: ^Ui_Frame,
	id: Modal_Id,
	z: Z_Order,
	claim: Rectangle,
	claim_all: bool,
) -> bool {
	assert(frame != nil && frame.open, "modal runtime register: invalid frame")
	assert(id != Modal_Id(0), "modal runtime register: zero id")
	assert(claim_all || (claim.width > 0 && claim.height > 0), "modal runtime register: empty claim")
	runtime := &frame.runtime.modals
	index := modal_runtime_find(runtime, id)
	if index >= 0 {
		entry := runtime.entries[index]
		entry.z = z
		entry.seen_generation = frame.runtime.frame_generation
		entry.claim = claim
		entry.claim_all = claim_all
		for i in index ..< runtime.count - 1 do runtime.entries[i] = runtime.entries[i + 1]
		runtime.entries[runtime.count - 1] = entry
		for i in 0 ..< runtime.count do runtime.entries[i].z = Z_MODAL + Z_Order(i)
		entry = runtime.entries[runtime.count - 1]
		if entry.claim_all do route_claim_all(frame, entry.z)
		else do route_claim(frame, entry.claim, entry.z)
		return true
	}
	if runtime.count >= MAX_MODAL_STACK {
		runtime.overflow = true
		route_claim_all(frame, Z_TOOLTIP)
		return false
	}
	runtime.entries[runtime.count] = {
		id              = id,
		z               = z,
		seen_generation = frame.runtime.frame_generation,
		claim           = claim,
		claim_all       = claim_all,
	}
	runtime.count += 1
	if claim_all do route_claim_all(frame, z)
	else do route_claim(frame, claim, z)
	return true
}

modal_top_id :: proc(frame: ^Ui_Frame) -> Modal_Id {
	assert(frame != nil && frame.runtime != nil, "modal top: invalid frame")
	runtime := &frame.runtime.modals
	if runtime.count == 0 do return Modal_Id(0)
	return runtime.entries[runtime.count - 1].id
}

modal_is_top :: proc(frame: ^Ui_Frame, state: ^Modal_State) -> bool {
	assert(frame != nil && state != nil, "modal top state: invalid argument")
	return state.id != Modal_Id(0) && modal_top_id(frame) == state.id
}

modal_owner_current :: proc(frame: ^Ui_Frame) -> Modal_Id {
	assert(frame != nil, "modal owner current: nil frame")
	if frame.modal.owner_count == 0 do return Modal_Id(0)
	return frame.modal.owners[frame.modal.owner_count - 1]
}

modal_owner_begin :: proc(frame: ^Ui_Frame, state: ^Modal_State) {
	assert(frame != nil && state != nil, "modal owner begin: invalid argument")
	assert(frame.modal.owner_count < MAX_MODAL_STACK, "modal owner begin: stack overflow")
	frame.modal.owners[frame.modal.owner_count] = state.id
	frame.modal.owner_count += 1
}

modal_owner_end :: proc(frame: ^Ui_Frame, state: ^Modal_State) {
	assert(frame != nil && state != nil, "modal owner end: invalid argument")
	assert(frame.modal.owner_count > 0, "modal owner end: empty stack")
	assert(modal_owner_current(frame) == state.id, "modal owner end: mismatched state")
	frame.modal.owner_count -= 1
}

modal_keyboard_visible :: proc(frame: ^Ui_Frame) -> bool {
	assert(frame != nil && frame.open, "modal keyboard visible: invalid frame")
	top := modal_top_id(frame)
	return top == Modal_Id(0) || modal_owner_current(frame) == top
}

modal_key_consumed :: proc(frame: ^Ui_Frame, key: KeyboardKey, edge: Modal_Key_Edge) -> bool {
	assert(frame != nil, "modal key consumed: nil frame")
	index := input_key_index(key)
	if index < 0 do return false
	switch edge {
	case .Pressed:
		return frame.modal.consumed_pressed[index]
	case .Repeated:
		return frame.modal.consumed_repeat[index]
	case .Released:
		return frame.modal.consumed_released[index]
	}
	return false
}

modal_key_consume :: proc(frame: ^Ui_Frame, key: KeyboardKey, edge: Modal_Key_Edge) {
	assert(frame != nil && frame.open, "modal key consume: invalid frame")
	index := input_key_index(key)
	if index < 0 do return
	switch edge {
	case .Pressed:
		frame.modal.consumed_pressed[index] = true
	case .Repeated:
		frame.modal.consumed_repeat[index] = true
	case .Released:
		frame.modal.consumed_released[index] = true
	}
}
