package shared

PLANET_EVENT_CAPACITY :: 256

Planetary_Event_Kind :: enum u8 {
	Precipitation,
	Lightning,
	Eruption,
	Ash,
	Lava,
	Quake,
	Vent,
}

Planetary_Event :: struct {
	kind:      Planetary_Event_Kind,
	cell:      u32,
	magnitude: u32,
	duration:  u32,
	sequence:  u64,
}

Planetary_Event_Queue :: struct {
	items:    [PLANET_EVENT_CAPACITY]Planetary_Event,
	count:    u16,
	dropped:  u32,
	sequence: u64,
}

planetary_event_push :: proc(
	queue: ^Planetary_Event_Queue,
	kind: Planetary_Event_Kind,
	cell, magnitude, duration: u32,
) -> bool {
	assert(queue != nil, "planetary_event_push: nil queue")
	assert(cell < PLANET_SIM_CELL_COUNT, "planetary_event_push: invalid cell")
	if int(queue.count) >= PLANET_EVENT_CAPACITY {
		queue.dropped += 1
		return false
	}
	queue.items[queue.count] = {kind, cell, magnitude, duration, queue.sequence}
	queue.count += 1
	queue.sequence += 1
	return true
}

planetary_events_clear :: proc(queue: ^Planetary_Event_Queue) {
	assert(queue != nil, "planetary_events_clear: nil queue")
	queue.count = 0
}
