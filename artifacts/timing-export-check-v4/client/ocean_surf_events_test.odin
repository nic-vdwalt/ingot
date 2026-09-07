package main

import "core:testing"

@(test)
ocean_surf_event_queue_is_ordered_and_bounded :: proc(t: ^testing.T) {
	events := new(Ocean_Surf_Events)
	defer free(events)
	testing.expect(t, ocean_surf_event_submit(events, 0, {target_tick = 9, kind = .Source_Stop}))
	testing.expect(t, ocean_surf_event_submit(events, 0, {target_tick = 3, kind = .Control, control = {1, 0}}))
	testing.expect(t, ocean_surf_event_submit(events, 0, {target_tick = 3, kind = .Control, control = {0, 1}}))
	testing.expect_value(t, events.count, 2)
	testing.expect_value(t, events.queue[0].control, [2]f32{0, 1})
	testing.expect(t, ocean_surf_event_submit(events, 0, {target_tick = 3, kind = .Source_Stop}))
	testing.expect(t, ocean_surf_event_submit(events, 0, {target_tick = 3, kind = .Control}))
	testing.expect_value(t, events.count, 4)
	for events.count < len(events.queue) {
		testing.expect(t, ocean_surf_event_submit(events, 0, {target_tick = 10, kind = .Source_Stop}))
	}
	sequence := events.next_sequence
	testing.expect(t, !ocean_surf_event_submit(events, 0, {target_tick = 10, kind = .Source_Stop}))
	testing.expect(t, !ocean_surf_event_submit(events, 3, {target_tick = 3, kind = .Control}))
	testing.expect_value(t, events.next_sequence, sequence)
	for index in 1 ..< events.count {
		previous, current := events.queue[index - 1], events.queue[index]
		testing.expect(t, previous.target_tick < current.target_tick || (previous.target_tick == current.target_tick && previous.sequence < current.sequence))
	}
}

@(test)
ocean_surf_event_journal_reports_overwrite :: proc(t: ^testing.T) {
	events := new(Ocean_Surf_Events)
	defer free(events)
	for index in 0 ..< 520 {
		ocean_surf_event_record(events, {sequence = u64(index + 1)})
	}
	testing.expect_value(t, events.journal_count, 512)
	testing.expect_value(t, events.journal_overwrites, u64(8))
	testing.expect_value(t, events.journal[events.journal_cursor].sequence, u64(9))
	ocean_surf_events_reset(events)
	testing.expect_value(t, events.count, 0)
	testing.expect_value(t, events.next_sequence, u64(0))
	testing.expect_value(t, events.journal_count, 0)
}

@(test)
ocean_surf_controls_wait_for_unstarted_interval :: proc(t: ^testing.T) {
	value := new(Client_State)
	defer free(value)
	renderer := &value.terrain.ocean
	renderer.nearshore.fixture_active = true
	renderer.nearshore.tick_pending = true
	renderer.nearshore.pending_control = {1, 0}
	testing.expect(t, ocean_surf_control_submit(renderer, {0, 1}))
	testing.expect_value(t, renderer.surf_events.queue[0].target_tick, u64(2))
	ocean_surf_events_apply_due(value)
	testing.expect_value(t, renderer.surf_events.count, 1)
	testing.expect_value(t, renderer.nearshore.pending_control, [2]f32{1, 0})
	renderer.nearshore.tick_pending = false
	renderer.macro.step_count = 1
	ocean_surf_events_apply_due(value)
	testing.expect_value(t, value.surfboard.control, [2]f32{0, 1})
	testing.expect_value(t, renderer.surf_events.journal_count, 1)
	ocean_surf_events_apply_due(value)
	testing.expect_value(t, renderer.surf_events.journal_count, 1)
}

@(test)
ocean_surf_board_boundary_preserves_source_queue :: proc(t: ^testing.T) {
	value := new(Client_State)
	defer free(value)
	renderer := &value.terrain.ocean
	renderer.nearshore.fixture_active = true
	renderer.nearshore.tick_pending = true
	renderer.nearshore.time_backlog = 0.01
	renderer.macro.accumulator = 0.25
	testing.expect(t, ocean_surf_event_submit(&renderer.surf_events, 0, {target_tick = 2, kind = .Control, control = {1, 0}}))
	testing.expect(t, ocean_surf_event_submit(&renderer.surf_events, 0, {target_tick = 3, kind = .Source_Stop}))
	surfboard_fixture_boundary_reset(value)
	testing.expect(t, !renderer.nearshore.tick_pending)
	testing.expect_value(t, renderer.macro.accumulator, f32(0.25))
	testing.expect_value(t, renderer.surf_events.count, 1)
	testing.expect_value(t, renderer.surf_events.queue[0].kind, Ocean_Surf_Event_Kind.Source_Stop)
}

@(test)
ocean_surf_source_rejection_preserves_pending_and_sequence :: proc(t: ^testing.T) {
	value := new(Client_State)
	defer free(value)
	renderer := &value.terrain.ocean
	ocean_surf_fixture_init(&renderer.nearshore, {0, 0, 1}, .Deep)
	renderer.nearshore.tick_pending = true
	renderer.nearshore.time_backlog = 0.01
	renderer.macro.accumulator = 0.25
	testing.expect(t, !ocean_surf_source_submit(value, {}))
	testing.expect(t, renderer.nearshore.tick_pending)
	testing.expect_value(t, renderer.surf_events.next_sequence, u64(0))
	for index in 0 ..< 128 {
		testing.expect(t, ocean_surf_event_submit(&renderer.surf_events, 0, {target_tick = u64(index + 2), kind = .Source_Stop}))
	}
	testing.expect(t, !ocean_surf_source_submit(value, {}, true))
	testing.expect(t, renderer.nearshore.tick_pending)
	testing.expect_value(t, renderer.surf_events.next_sequence, u64(128))
	ocean_surf_events_reset(&renderer.surf_events)
	testing.expect(t, ocean_surf_source_submit(value, {}, true))
	testing.expect(t, !renderer.nearshore.tick_pending)
	testing.expect_value(t, renderer.macro.accumulator, f32(0.25))
	testing.expect_value(t, renderer.surf_events.journal_count, 1)
	ocean_surf_events_apply_due(value)
	testing.expect_value(t, renderer.surf_events.journal_count, 1)
}
