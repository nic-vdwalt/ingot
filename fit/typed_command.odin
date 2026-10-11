package fit

TYPED_COMMAND_CAPACITY_MAX :: 256

Typed_Command_Result :: enum u8 {
	Accepted,
	Full,
	Invalid,
}

Typed_Command_Mode :: enum u8 {
	Unset,
	Legacy,
	Owned,
}

Typed_Command_Activation :: struct($T: typeid) {
	widget:    Widget_Id,
	value:     T,
	activated: bool,
}

Typed_Commands :: struct($T: typeid, $Capacity: int) {
	ready:               [Capacity]T,
	activations:         [Capacity]Typed_Command_Activation(T),
	ready_count:         int,
	ready_index:         int,
	drain_limit:         int,
	activation_count:    int,
	dropped_ready:       u64,
	dropped_activation:  u64,
	collect_pending:     bool,
	mode:                Typed_Command_Mode,
	binding:             Debug_Frame_Access,
	unavailable_results: u64,
	result_owner:        ^Builder,
	result_epoch:        u64,
	result_generation:   u64,
}

typed_commands_append :: proc(
	queue: ^Typed_Commands($T, $Capacity),
	value: T,
) -> Typed_Command_Result where Capacity >
	0,
	Capacity <=
	TYPED_COMMAND_CAPACITY_MAX {
	assert(queue != nil, "fit.typed_commands_append: nil queue")
	assert(
		queue.ready_count >= 0 && queue.ready_count <= Capacity,
		"fit typed commands: invalid count",
	)
	if queue.ready_count >= Capacity {
		queue.dropped_ready += 1
		return .Full
	}
	queue.ready[queue.ready_count] = value
	queue.ready_count += 1
	return .Accepted
}

typed_commands_begin_legacy :: proc(queue: ^Typed_Commands($T, $Capacity)) where Capacity > 0,
	Capacity <= TYPED_COMMAND_CAPACITY_MAX {
	assert(queue != nil, "fit.typed_commands_begin: nil queue")
	assert(!queue.collect_pending, "fit.typed_commands_begin: build already open")
	assert(queue.mode != .Owned, "fit typed commands: reset before changing mode")
	queue.mode = .Legacy
	assert(queue.activation_count >= 0 && queue.activation_count <= Capacity)
	for index in 0 ..< queue.activation_count {
		activation := &queue.activations[index]
		if activation.activated {
			_ = typed_commands_append(queue, activation.value)
			activation.activated = false
		}
	}
	queue.activation_count = 0
	queue.drain_limit = queue.ready_count
	queue.collect_pending = true
}

typed_commands_begin_owned :: proc(
	queue: ^Typed_Commands($T, $Capacity),
	builder: ^Builder,
) where Capacity >
	0,
	Capacity <=
	TYPED_COMMAND_CAPACITY_MAX {
	assert(queue != nil && !queue.collect_pending)
	assert(queue.mode != .Legacy, "fit typed commands: reset before changing mode")
	queue.binding = debug_frame_access_get(builder)
	queue.mode = .Owned
	assert(queue.activation_count >= 0 && queue.activation_count <= Capacity)
	for index in 0 ..< queue.activation_count {
		activation := queue.activations[index]
		result: Button_Result
		if queue.result_owner == builder &&
		   queue.result_epoch == builder.owner.epoch &&
		   queue.result_generation < max(u64) &&
		   queue.result_generation + 1 == builder.generation {
			result = builder_button_result(builder, activation.widget)
		}
		if result.status == .Unavailable {
			queue.unavailable_results += 1
		} else if result.activated {
			_ = typed_commands_append(queue, activation.value)
		}
	}
	queue.activation_count = 0
	queue.drain_limit = queue.ready_count
	queue.collect_pending = true
}

typed_commands_begin :: proc {
	typed_commands_begin_legacy,
	typed_commands_begin_owned,
}

typed_commands_unavailable :: proc(queue: ^Typed_Commands($T, $Capacity)) -> u64 {
	assert(queue != nil)
	return queue.unavailable_results
}

typed_commands_take :: proc(
	queue: ^Typed_Commands($T, $Capacity),
	value: ^T,
) -> bool where Capacity >
	0,
	Capacity <=
	TYPED_COMMAND_CAPACITY_MAX {
	assert(queue != nil && value != nil, "fit.typed_commands_take: invalid argument")
	assert(queue.collect_pending, "fit.typed_commands_take: build not open")
	assert(queue.ready_index >= 0 && queue.ready_index <= queue.drain_limit)
	assert(queue.drain_limit >= 0 && queue.drain_limit <= queue.ready_count)
	if queue.ready_index >= queue.drain_limit do return false
	value^ = queue.ready[queue.ready_index]
	queue.ready_index += 1
	return true
}

typed_commands_end :: proc(queue: ^Typed_Commands($T, $Capacity)) where Capacity > 0,
	Capacity <= TYPED_COMMAND_CAPACITY_MAX {
	assert(queue != nil, "fit.typed_commands_end: nil queue")
	assert(queue.collect_pending, "fit.typed_commands_end: build not open")
	remaining := queue.ready_count - queue.drain_limit
	assert(remaining >= 0 && remaining <= Capacity)
	for index in 0 ..< remaining {
		queue.ready[index] = queue.ready[queue.drain_limit + index]
	}
	queue.ready_count = remaining
	queue.ready_index = 0
	queue.drain_limit = 0
	queue.collect_pending = false
	queue.binding = {}
}

typed_commands_reset :: proc(queue: ^Typed_Commands($T, $Capacity)) where Capacity > 0,
	Capacity <= TYPED_COMMAND_CAPACITY_MAX {
	assert(queue != nil, "fit.typed_commands_reset: nil queue")
	queue.ready_count = 0
	queue.ready_index = 0
	queue.drain_limit = 0
	queue.activation_count = 0
	queue.collect_pending = false
	queue.binding = {}
	queue.mode = .Unset
	queue.result_owner = nil
	queue.result_epoch = 0
	queue.result_generation = 0
}

typed_commands_dropped :: proc(
	queue: ^Typed_Commands($T, $Capacity),
) -> (
	ready, activation: u64,
) where Capacity >
	0,
	Capacity <=
	TYPED_COMMAND_CAPACITY_MAX {
	assert(queue != nil, "fit.typed_commands_dropped: nil queue")
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
	assert(queue != nil, "fit typed command reserve: nil queue")
	assert(queue.collect_pending, "fit typed command reserve: build not open")
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

button_command :: proc(
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
	assert(queue != nil && queue.collect_pending)
	assert(options.activated == nil)
	assert(options.action.procedure == nil && options.action.tagged_procedure == nil)
	if queue.mode == .Owned {
		builder := parent_validate(parent)
		assert(debug_frame_access_valid(queue.binding))
		assert(builder == queue.binding.builder)
		if queue.activation_count >= Capacity {
			queue.dropped_activation += 1
			return .Full
		}
		queue.result_owner = builder
		queue.result_epoch = builder.owner.epoch
		queue.result_generation = builder.generation
		queue.activations[queue.activation_count] = {
			widget = result_identity(parent, key),
			value  = value,
		}
		queue.activation_count += 1
		button(parent, key, label, options)
		return .Accepted
	}
	activated, result := typed_command_reserve(queue, value)
	if result != .Accepted do return result
	resolved := options
	resolved.activated = activated
	button(parent, key, label, resolved)
	return .Accepted
}
