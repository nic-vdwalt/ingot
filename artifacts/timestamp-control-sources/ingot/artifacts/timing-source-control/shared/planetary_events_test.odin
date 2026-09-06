package shared

import "core:testing"

@(test)
planetary_events_are_bounded_and_ordered :: proc(t: ^testing.T) {
	queue: Planetary_Event_Queue
	for index in 0 ..< PLANET_EVENT_CAPACITY {
		testing.expect(t, planetary_event_push(&queue, .Precipitation, u32(index), 1, 1))
	}
	testing.expect(t, !planetary_event_push(&queue, .Quake, 0, 1, 1))
	testing.expect_value(t, queue.count, u16(PLANET_EVENT_CAPACITY))
	testing.expect_value(t, queue.dropped, u32(1))
	testing.expect_value(
		t,
		queue.items[PLANET_EVENT_CAPACITY - 1].sequence,
		u64(PLANET_EVENT_CAPACITY - 1),
	)
}
