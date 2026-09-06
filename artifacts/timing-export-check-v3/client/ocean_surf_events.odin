package main

import "core:math"

Ocean_Surf_Time_Ledger :: struct {
	eligible_scaled: f64,
	clip_rejected: f64,
	cap_rejected: f64,
}

Ocean_Surf_Event_Kind :: enum {
	Control,
	Source_Set,
	Source_Stop,
}

Ocean_Surf_Event :: struct {
	target_tick: u64,
	sequence: u64,
	kind: Ocean_Surf_Event_Kind,
	control: [2]f32,
	packet: Ocean_Render_Packet,
}

Ocean_Surf_Events :: struct {
	queue: [128]Ocean_Surf_Event,
	count: int,
	journal: [512]Ocean_Surf_Event,
	journal_count: int,
	journal_cursor: int,
	journal_overwrites: u64,
	next_sequence: u64,
	control: [2]f32,
	rejected: u64,
}

ocean_surf_event_submit :: proc(events: ^Ocean_Surf_Events, completed_tick: u64, requested: Ocean_Surf_Event) -> bool {
	if requested.target_tick <= completed_tick || events.next_sequence == ~u64(0) {
		events.rejected += 1
		return false
	}
	for component in requested.control {
		if !(component >= -1 && component <= 1) {
			events.rejected += 1
			return false
		}
	}
	if requested.kind == .Source_Set {
		packet := requested.packet
		if packet.id != OCEAN_DEBUG_TEST_PULSE_ID || !(packet.period > 0) ||
		   !(packet.band > 0) || !(packet.front_speed > 0) || !(packet.significant_height > 0) {
			events.rejected += 1
			return false
		}
		values := [18]f32{packet.period, packet.band, packet.front_speed, packet.significant_height,
			packet.phase_speed, packet.group_speed, packet.phase_epoch, packet.total_travel,
			packet.envelope_length, packet.envelope_width, packet.front_radius,
			packet.center.x, packet.center.y, packet.center.z,
			packet.direction.x, packet.direction.y, packet.direction.z, 0}
		for component in values {
			if math.is_nan(component) || math.is_inf(component, 0) {
				events.rejected += 1
				return false
			}
		}
	}
	insertion := events.count
	for insertion > 0 && events.queue[insertion - 1].target_tick > requested.target_tick {
		insertion -= 1
	}
	coalesce := insertion > 0 && requested.kind == .Control &&
		events.queue[insertion - 1].kind == .Control &&
		events.queue[insertion - 1].target_tick == requested.target_tick &&
		events.queue[insertion - 1].sequence == events.next_sequence
	if coalesce && events.queue[insertion - 1].control == requested.control do return true
	if !coalesce && events.count == len(events.queue) {
		events.rejected += 1
		return false
	}
	event := requested
	events.next_sequence += 1
	event.sequence = events.next_sequence
	if event.kind == .Source_Set {
		event.packet.phase_epoch = f32(event.target_tick - 1) * OCEAN_WAVE_FIXED_DT
		event.packet.total_travel = 0
	}
	if coalesce {
		events.queue[insertion - 1] = event
		return true
	}
	for index := events.count; index > insertion; index -= 1 {
		events.queue[index] = events.queue[index - 1]
	}
	events.queue[insertion] = event
	events.count += 1
	return true
}

ocean_surf_event_record :: proc(events: ^Ocean_Surf_Events, event: Ocean_Surf_Event) {
	events.journal[events.journal_cursor] = event
	events.journal_cursor = (events.journal_cursor + 1) % len(events.journal)
	if events.journal_count < len(events.journal) {
		events.journal_count += 1
	} else {
		events.journal_overwrites += 1
	}
}

ocean_surf_events_reset :: proc(events: ^Ocean_Surf_Events) {
	events^ = {}
}

ocean_surf_events_apply_due :: proc(value: ^Client_State) {
	renderer := &value.terrain.ocean
	events := &renderer.surf_events
	boundary := u64(renderer.macro.step_count) + 1
	for events.count > 0 && events.queue[0].target_tick <= boundary {
		event := events.queue[0]
		for index in 1 ..< events.count do events.queue[index - 1] = events.queue[index]
		events.count -= 1
		events.queue[events.count] = {}
		switch event.kind {
		case .Control:
			events.control = event.control
			value.surfboard.control = event.control
		case .Source_Set:
			debug_ocean_test_pulse_apply(value, event.packet)
		case .Source_Stop:
			debug_ocean_test_pulse_clear(value)
		}
		ocean_surf_event_record(events, event)
	}
}

ocean_surf_control_submit :: proc(renderer: ^Ocean_Renderer, control: [2]f32) -> bool {
	if !renderer.nearshore.fixture_active do return false
	target := u64(renderer.macro.step_count) + 1
	if renderer.nearshore.tick_pending do target += 1
	desired := renderer.surf_events.control
	for event in renderer.surf_events.queue[:renderer.surf_events.count] {
		if event.kind == .Control && event.target_tick <= target do desired = event.control
	}
	if desired == control do return true
	return ocean_surf_event_submit(&renderer.surf_events, u64(renderer.macro.step_count), {
		target_tick = target, kind = .Control, control = control,
	})
}

ocean_surf_source_submit :: proc(value: ^Client_State, packet: Ocean_Render_Packet, stop := false) -> bool {
	renderer := &value.terrain.ocean
	if !renderer.nearshore.fixture_active do return false
	event := Ocean_Surf_Event{
		target_tick = u64(renderer.macro.step_count) + 1,
		kind = .Source_Stop if stop else .Source_Set,
		packet = packet,
	}
	event.packet.phase_epoch = f32(event.target_tick - 1) * OCEAN_WAVE_FIXED_DT
	if !ocean_surf_event_submit(&renderer.surf_events, u64(renderer.macro.step_count), event) do return false
	debug_ocean_fixture_cancel_pending_tick(renderer)
	ocean_surf_events_apply_due(value)
	return true
}
