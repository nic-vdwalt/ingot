package fit

TYPED_COMMAND_CAPACITY_MAX :: 256

Typed_Command_Result :: enum u8 {
	Accepted,
	Full,
	Invalid,
}

Typed_Command_Activation :: struct($T: typeid) {
	value:     T,
	activated: bool,
}

Typed_Commands :: struct($T: typeid, $Capacity: int) {
	ready:              [Capacity]T,
	activations:        [Capacity]Typed_Command_Activation(T),
	ready_count:        int,
	ready_index:        int,
	drain_limit:        int,
	activation_count:   int,
	dropped_ready:      u64,
	dropped_activation: u64,
	collect_pending:    bool,
}

Typed_Commands_Append :: proc(
	queue: ^Typed_Commands($T, $Capacity),
	value: T,
) -> Typed_Command_Result where Capacity >
	0,
	Capacity <=
	TYPED_COMMAND_CAPACITY_MAX {
	assert(queue != nil, "Fit.Typed_Commands_Append: nil queue")
	assert(
		queue.ready_count >= 0 && queue.ready_count <= Capacity,
		"Fit typed commands: invalid count",
	)
	if queue.ready_count >= Capacity {
		queue.dropped_ready += 1
		return .Full
	}
	queue.ready[queue.ready_count] = value
	queue.ready_count += 1
	return .Accepted
}

Typed_Commands_Begin :: proc(queue: ^Typed_Commands($T, $Capacity)) where Capacity > 0,
	Capacity <= TYPED_COMMAND_CAPACITY_MAX {
	assert(queue != nil, "Fit.Typed_Commands_Begin: nil queue")
	assert(!queue.collect_pending, "Fit.Typed_Commands_Begin: build already open")
	assert(queue.activation_count >= 0 && queue.activation_count <= Capacity)
	for index in 0 ..< queue.activation_count {
		activation := &queue.activations[index]
		if activation.activated {
			_ = Typed_Commands_Append(queue, activation.value)
			activation.activated = false
		}
	}
	queue.activation_count = 0
	queue.drain_limit = queue.ready_count
	queue.collect_pending = true
}

Typed_Commands_Take :: proc(
	queue: ^Typed_Commands($T, $Capacity),
	value: ^T,
) -> bool where Capacity >
	0,
	Capacity <=
	TYPED_COMMAND_CAPACITY_MAX {
	assert(queue != nil && value != nil, "Fit.Typed_Commands_Take: invalid argument")
	assert(queue.collect_pending, "Fit.Typed_Commands_Take: build not open")
	assert(queue.ready_index >= 0 && queue.ready_index <= queue.drain_limit)
	assert(queue.drain_limit >= 0 && queue.drain_limit <= queue.ready_count)
	if queue.ready_index >= queue.drain_limit do return false
	value^ = queue.ready[queue.ready_index]
	queue.ready_index += 1
	return true
}

Typed_Commands_End :: proc(queue: ^Typed_Commands($T, $Capacity)) where Capacity > 0,
	Capacity <= TYPED_COMMAND_CAPACITY_MAX {
	assert(queue != nil, "Fit.Typed_Commands_End: nil queue")
	assert(queue.collect_pending, "Fit.Typed_Commands_End: build not open")
	remaining := queue.ready_count - queue.drain_limit
	assert(remaining >= 0 && remaining <= Capacity)
	for index in 0 ..< remaining {
		queue.ready[index] = queue.ready[queue.drain_limit + index]
	}
	queue.ready_count = remaining
	queue.ready_index = 0
	queue.drain_limit = 0
	queue.collect_pending = false
}

Typed_Commands_Reset :: proc(queue: ^Typed_Commands($T, $Capacity)) where Capacity > 0,
	Capacity <= TYPED_COMMAND_CAPACITY_MAX {
	assert(queue != nil, "Fit.Typed_Commands_Reset: nil queue")
	queue.ready_count = 0
	queue.ready_index = 0
	queue.drain_limit = 0
	queue.activation_count = 0
	queue.collect_pending = false
}

Typed_Commands_Dropped :: proc(
	queue: ^Typed_Commands($T, $Capacity),
) -> (
	ready, activation: u64,
) where Capacity >
	0,
	Capacity <=
	TYPED_COMMAND_CAPACITY_MAX {
	assert(queue != nil, "Fit.Typed_Commands_Dropped: nil queue")
	return queue.dropped_ready, queue.dropped_activation
}

@(private = "file")
typed_command_reserve :: proc(
	queue: ^Typed_Commands($T, $Capacity),
	value: T,
) -> (
	^bool,
	Typed_Command_Result,
) where Capacity >
	0,
	Capacity <=
	TYPED_COMMAND_CAPACITY_MAX {
	assert(queue != nil, "Fit typed command reserve: nil queue")
	assert(queue.collect_pending, "Fit typed command reserve: build not open")
	if queue.activation_count >= Capacity {
		queue.dropped_activation += 1
		return nil, .Full
	}
	activation := &queue.activations[queue.activation_count]
	activation.value = value
	activation.activated = false
	queue.activation_count += 1
	return &activation.activated, .Accepted
}

Button_Command :: proc(
	parent: Parent,
	key: $K,
	label: string,
	queue: ^Typed_Commands($T, $Capacity),
	value: T,
	options: Button_Options = {},
) -> Typed_Command_Result where Capacity >
	0,
	Capacity <=
	TYPED_COMMAND_CAPACITY_MAX {
	activated, result := typed_command_reserve(queue, value)
	if result != .Accepted do return result
	resolved := options
	resolved.activated = activated
	Button(parent, key, label, resolved)
	return .Accepted
}
