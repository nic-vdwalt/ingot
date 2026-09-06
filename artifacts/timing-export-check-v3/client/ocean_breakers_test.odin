#+build !js
package main

import shared "../shared"
import "core:math"
import "core:testing"

@(test)
ocean_breaker_arrival_uses_carrier_not_envelope :: proc(t: ^testing.T) {
	packet := Ocean_Render_Packet {
		id = OCEAN_DEBUG_TEST_PULSE_ID,
		period = 8,
		phase_speed = 25,
		phase_epoch = 10,
	}
	coordinate := f32(4)
	phase, crest, before := ocean_breaker_arrival(packet, coordinate, 11.9)
	testing.expect(t, !before)
	arrived_phase, arrived_crest, arrived := ocean_breaker_arrival(packet, coordinate, 12.1)
	testing.expect(t, arrived)
	testing.expect_value(t, arrived_crest, crest + 1)
	testing.expect_value(t, arrived_phase, phase)
	carrier := coordinate * ocean_packet_wave_number(packet) - f32(math.TAU) / packet.period * (12 - packet.phase_epoch)
	testing.expect(t, abs(math.sin(carrier) - 1) < 0.00001)
	packet.phase_epoch += 80
	shifted_phase, shifted_crest, shifted := ocean_breaker_arrival(packet, coordinate, 92.1)
	testing.expect_value(t, shifted, arrived)
	testing.expect_value(t, shifted_crest, arrived_crest)
	testing.expect(t, abs((92.1 / packet.period + shifted_phase) - (12.1 / packet.period + phase)) < 0.00001)
}

@(test)
ocean_breaker_mesh_does_not_emit_physics_events :: proc(t: ^testing.T) {
	value := new(Ocean_Breaker_Renderer)
	defer free(value)
	ocean_breaker_front_add(value, {0, 0, 1_080}, {1, 0, 0}, {0, 1, 0}, 2, 1)
	ocean_breakers_mesh_fill(value, 12)
	ocean_breakers_mesh_fill(value, 20)
	testing.expect_value(t, value.spray_count, u32(0))
	testing.expect(t, value.mesh_dirty)
	value.mesh_dirty = false
	ocean_breakers_upload(value)
	testing.expect_value(t, value.mesh.id, u32(0))
}

@(test)
ocean_breaker_classification_is_deterministic :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		ocean_breaker_classify(350, 8_000, 25),
		shared.Wave_Breaker_Type.Plunging,
	)
	testing.expect_value(
		t,
		ocean_breaker_classify(80, 3_000, 10),
		shared.Wave_Breaker_Type.Spilling,
	)
	testing.expect_value(
		t,
		ocean_breaker_classify(2_800, 8_000, 25),
		shared.Wave_Breaker_Type.Surging,
	)
	testing.expect_value(t, ocean_breaker_classify(0, 0, 0), shared.Wave_Breaker_Type.None)
}

@(test)
ocean_breaker_unchanged_inputs_skip_update :: proc(t: ^testing.T) {
	focus := [3]f32{0, 0, 1}
	testing.expect(t, !ocean_breakers_update_required(0, focus, focus, 7, 7, 9, 9))
	testing.expect(t, ocean_breakers_update_required(1.0 / 60.0, focus, focus, 7, 7, 9, 9))
	testing.expect(t, ocean_breakers_update_required(0, focus, focus, 8, 7, 9, 9))
	testing.expect(t, ocean_breakers_update_required(0, focus, focus, 7, 7, 10, 9))
	testing.expect(t, ocean_breakers_update_required(0, {0, 1, 0}, focus, 7, 7, 9, 9))
}

@(test)
ocean_breaker_mesh_is_strictly_bounded :: proc(t: ^testing.T) {
	value := new(Ocean_Breaker_Renderer)
	defer free(value)
	for _ in 0 ..< OCEAN_BREAKER_FRONT_MAX + 5 {
		ocean_breaker_front_add(value, {0, 0, 1_080}, {1, 0, 0}, {0, 1, 0}, 2, 0.8)
	}
	testing.expect_value(t, value.front_count, u32(OCEAN_BREAKER_FRONT_MAX))
	ocean_breakers_mesh_fill(value, 4)
	testing.expect_value(
		t,
		value.vertex_count,
		u32(OCEAN_BREAKER_FRONT_MAX * OCEAN_BREAKER_VERTICES_PER_FRONT),
	)
	testing.expect_value(
		t,
		value.index_count,
		u32(OCEAN_BREAKER_FRONT_MAX * OCEAN_BREAKER_INDICES_PER_FRONT),
	)
	testing.expect(t, value.vertex_count <= OCEAN_BREAKER_VERTICES_MAX)
	testing.expect(t, value.index_count <= OCEAN_BREAKER_INDICES_MAX)
}

@(test)
ocean_breaker_surface_has_attached_face_and_overhanging_lip :: proc(t: ^testing.T) {
	value := new(Ocean_Breaker_Renderer)
	defer free(value)
	ocean_breaker_front_add(value, {0, 0, 1_080}, {1, 0, 0}, {0, 1, 0}, 4, 1, 8)
	ocean_breakers_mesh_fill(value, 4)
	center_crest := OCEAN_BREAKER_CREST_SEGMENTS / 2
	base := center_crest * OCEAN_BREAKER_CROSS_SAMPLES
	attached := value.vertices[base]
	crest := value.vertices[base + OCEAN_BREAKER_CROSS_SEGMENTS * 7 / 12]
	lip := value.vertices[base + OCEAN_BREAKER_CROSS_SEGMENTS]
	testing.expect(t, abs(attached.position.z - 1_080) < 0.001)
	testing.expect(t, crest.position.z > attached.position.z)
	testing.expect(t, lip.position.x > crest.position.x)
	testing.expect(t, lip.position.z < crest.position.z)
	testing.expect(t, lip.scalar > attached.scalar)
	testing.expect_value(t, attached.uv.y, f32(2))
	for vertex in value.vertices[:value.vertex_count] {
		for component in vertex.normal {
			testing.expect(t, !math.is_nan(component))
			testing.expect(t, !math.is_inf(component, 0))
		}
	}
}

@(test)
ocean_breaker_profile_normals_follow_surface_derivatives :: proc(t: ^testing.T) {
	front := Ocean_Breaker_Front{height = 4, depth = 8, curl = 1}
	for index in 1 ..< 100 {
		q := f32(index) / 100
		if abs(q - 0.58) < 0.01 do continue
		before := ocean_breaker_profile_sample(front, q - 0.0001, 1, 1, 0.2, 1)
		after := ocean_breaker_profile_sample(front, q + 0.0001, 1, 1, 0.2, 1)
		profile := ocean_breaker_profile_sample(front, q, 1, 1, 0.2, 1)
		forward := after.forward - before.forward
		height := after.height - before.height
		length := math.sqrt(forward * forward + height * height)
		testing.expect(t, abs((profile.normal_forward * forward + profile.normal_up * height) / length) < 0.002)
		testing.expect(t, abs(profile.normal_forward * profile.normal_forward + profile.normal_up * profile.normal_up - 1) < 0.0001)
	}
}

@(test)
ocean_breaker_profile_is_depth_limited_and_overhangs :: proc(t: ^testing.T) {
	deep := Ocean_Breaker_Front {
		height = 6,
		depth  = 8,
		curl   = 1,
		foam   = 1,
	}
	shallow := deep
	shallow.depth = 2
	deep_crest := ocean_breaker_profile_sample(deep, 0.58, 1, 1, 0, 1)
	deep_lip := ocean_breaker_profile_sample(deep, 1, 1, 1, 0, 1)
	shallow_crest := ocean_breaker_profile_sample(shallow, 0.58, 1, 1, 0, 1)
	shallow_lip := ocean_breaker_profile_sample(shallow, 1, 1, 1, 0, 1)
	testing.expect(t, deep_lip.forward > deep_crest.forward)
	testing.expect(t, deep_lip.height < deep_crest.height)
	testing.expect(t, shallow_lip.forward > shallow_crest.forward)
	testing.expect(t, shallow_lip.height < shallow_crest.height)
	testing.expect(t, abs(shallow_crest.height) < abs(deep_crest.height))
}

@(test)
ocean_breaker_lifecycle_is_one_shot_and_fades_after_exit :: proc(t: ^testing.T) {
	early_pitch, early_plunge, early_collapse, early_fade := ocean_breaker_lifecycle(0.15, 1, 0)
	late_pitch, late_plunge, late_collapse, late_fade := ocean_breaker_lifecycle(0.85, 1, 0)
	testing.expect(t, late_pitch >= early_pitch)
	testing.expect(t, late_plunge > early_plunge)
	testing.expect(t, late_collapse > early_collapse)
	testing.expect_value(t, late_fade, early_fade)
	exit_pitch, exit_plunge, exit_collapse, exit_fade := ocean_breaker_lifecycle(0.85, 0, 1)
	testing.expect_value(t, exit_pitch, f32(0))
	testing.expect_value(t, exit_plunge, f32(0))
	testing.expect(t, exit_collapse >= late_collapse)
	testing.expect(t, exit_fade < late_fade)
}

@(test)
ocean_breaker_phase_advances_with_packet_direction :: proc(t: ^testing.T) {
	value := new(Ocean_Breaker_Renderer)
	defer free(value)
	ocean_breaker_front_add(value, {0, 0, 1_080}, {1, 0, 0}, {0, 1, 0}, 2, 1, 8, 1, 1, 0, 0)
	ocean_breaker_front_add(value, {10, 0, 1_080}, {1, 0, 0}, {0, 1, 0}, 2, 1, 8, 1, 1, 1, -0.5)
	phase_near := f32(2) / value.fronts[0].period + value.fronts[0].phase
	phase_near -= math.floor(phase_near)
	phase_forward := f32(2) / value.fronts[1].period + value.fronts[1].phase
	phase_forward -= math.floor(phase_forward)
	testing.expect(t, phase_forward > phase_near)
}

@(test)
ocean_breaker_extract_uses_local_depth_crossing :: proc(t: ^testing.T) {
	nearshore := new(Ocean_Nearshore)
	defer free(nearshore)
	nearshore.ready = true
	nearshore.focus = {0, 0, 1}
	nearshore.east = {1, 0, 0}
	nearshore.north = {0, 1, 0}
	for row in 0 ..< OCEAN_NEARSHORE_EDGE {
		for column in 0 ..< OCEAN_NEARSHORE_EDGE {
			index := ocean_nearshore_index(column, row)
			nearshore.still_depth[index] = 1 + f32(column)
			nearshore.bathymetry[index] = -nearshore.still_depth[index]
		}
	}
	packet := Ocean_Render_Packet {
		id                 = 7,
		center             = shared.planet_position({0, 0, 1}, 0),
		direction          = {-1, 0, 0},
		significant_height = 2,
		period             = 8,
		envelope_length    = 256,
		envelope_width     = 256,
	}
	value := new(Ocean_Breaker_Renderer)
	defer free(value)
	ocean_breakers_extract(value, nearshore, {packet}, {0, 0, 1})
	testing.expect(t, value.front_count > 0)
	if value.front_count == 0 do return
	testing.expect(t, abs(value.fronts[0].depth - 2 / OCEAN_MACRO_BREAK_DEPTH_RATIO) < 0.001)
	front_length := math.sqrt(
		value.fronts[0].center.x * value.fronts[0].center.x +
		value.fronts[0].center.y * value.fronts[0].center.y +
		value.fronts[0].center.z * value.fronts[0].center.z,
	)
	testing.expect(t, front_length > 1_000)
	packet.direction = -packet.direction
	ocean_breakers_extract(value, nearshore, {packet}, {0, 0, 1})
	testing.expect_value(t, value.front_count, u32(0))
	testing.expect(t, value.rejected_offshore > 0)
	packet.direction = {0, 1, 0}
	ocean_breakers_extract(value, nearshore, {packet}, {0, 0, 1})
	for front in value.fronts[:value.front_count] {
		testing.expect(t, front.direction.x < 0)
	}
	packet.direction = {-1, 0, 0}
	packet.period = 2
	ocean_breakers_extract(value, nearshore, {packet}, {0, 0, 1})
	testing.expect_value(t, value.front_count, u32(0))
	testing.expect(t, value.rejected_class > 0)
	ocean_breakers_extract(value, nearshore, {}, {0, 0, 1})
	testing.expect_value(t, value.rejected_class, u32(0))
	testing.expect_value(t, value.rejected_offshore, u32(0))
}

@(test)
ocean_breaker_extract_orients_ring_packets_outward :: proc(t: ^testing.T) {
	nearshore := new(Ocean_Nearshore)
	defer free(nearshore)
	nearshore.ready = true
	nearshore.focus = {0, 0, 1}
	nearshore.east = {1, 0, 0}
	nearshore.north = {0, 1, 0}
	for row in 0 ..< OCEAN_NEARSHORE_EDGE {
		for column in 0 ..< OCEAN_NEARSHORE_EDGE {
			index := ocean_nearshore_index(column, row)
			nearshore.still_depth[index] = 1 + f32(column)
			nearshore.bathymetry[index] = -nearshore.still_depth[index]
		}
	}
	// The depth crossing sits ~174 units west of the focus, so a ring
	// centred on the focus reaches it when its front is that far out.
	source := [3]f32{0, 0, 1}
	packet := Ocean_Render_Packet {
		id                 = 8,
		radial             = true,
		center             = shared.planet_position(source, 0),
		direction          = source * 1.5,
		significant_height = 2,
		period             = 8,
		envelope_length    = 64,
		envelope_width     = 64,
		front_radius       = 174,
		front_speed        = 1.5,
		band               = 64,
		phase_epoch        = 5,
	}
	value := new(Ocean_Breaker_Renderer)
	defer free(value)
	ocean_breakers_extract(value, nearshore, {packet}, {0, 0, 1}, 5)
	testing.expect(t, value.front_count > 0)
	if value.front_count == 0 do return
	front := value.fronts[0]
	testing.expect_value(t, front.packet_id, u32(8))
	testing.expect(t, abs(front.direction.x) > abs(front.direction.y))
	testing.expect(t, abs(front.direction.x) > abs(front.direction.z))
	stale := new(Ocean_Breaker_Renderer)
	defer free(stale)
	ocean_breakers_extract(stale, nearshore, {packet}, {0, 0, 1}, 5 + 64 * 4 / 1.5)
	testing.expect_value(t, stale.front_count, 0)
}
