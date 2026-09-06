#+build !js
package main

import shared "../shared"
import "core:math"
import "core:testing"

@(test)
ocean_debug_height_is_depth_limited_crest_to_trough :: proc(t: ^testing.T) {
	field := Ocean_Macro_Wave_Field{}
	query := Ocean_Macro_Wave_Query{packet_count = 1, ready = true}
	query.packets[0] = {
		id = OCEAN_DEBUG_TEST_PULSE_ID,
		center = {1080, 0, 0},
		direction = {0, 1, 0},
		period = 8,
		phase_speed = 12,
		significant_height = 2,
		envelope_length = 100,
		envelope_width = 100,
	}
	depths := [3]f32{100, 4, 1}
	for depth in depths {
		trough := ocean_macro_wave_sample(&field, &query, query.packets[0].center, depth, 1, 2)
		crest := ocean_macro_wave_sample(&field, &query, query.packets[0].center, depth, 1, 6)
		expected := min(f32(2), depth * OCEAN_MACRO_BREAK_DEPTH_RATIO)
		testing.expect(t, abs(crest.displacement.x - trough.displacement.x - expected) < 0.00001)
		testing.expect(t, abs(crest.velocity.x) + abs(trough.velocity.x) < 0.00001)
	}
	testing.expect_value(t, ocean_debug_depth_amplitude(2, 0, 1), f32(0))
	testing.expect_value(t, ocean_debug_depth_amplitude(2, 100, 0), f32(0))
	query.packets[0].id = 123
	normal := ocean_macro_wave_sample(&field, &query, query.packets[0].center, 100, 1, 2)
	expected_normal := (-f32(1) * 0.78 - math.sin(f32(math.PI) * 0.5 * 1.04) * 0.22) * 0.5
	testing.expect(t, abs(normal.displacement.x - expected_normal) < 0.00001)
}

@(test)
ocean_continuous_wave_height_combines_independent_variance :: proc(t: ^testing.T) {
	testing.expect(t, abs(ocean_continuous_wave_height(3, 4) - 5) < 0.0001)
	testing.expect_value(t, ocean_continuous_wave_height(-2, -4), f32(0))
}

@(test)
ocean_macro_swell_only_displacement_is_nonzero_and_time_varying :: proc(t: ^testing.T) {
	field := Ocean_Macro_Wave_Field {
		spectrum = {direction = {0, 1, 0}, swell_height = 4, peak_period = 10},
	}
	query: Ocean_Macro_Wave_Query
	position := [3]f32{6_371_000, 37, 19}
	first := ocean_macro_wave_sample(&field, &query, position, 100, 1, 0)
	second := ocean_macro_wave_sample(&field, &query, position, 100, 1, 1)
	first_length := math.sqrt(
		first.displacement.x * first.displacement.x +
		first.displacement.y * first.displacement.y +
		first.displacement.z * first.displacement.z,
	)
	delta := second.displacement - first.displacement
	delta_length := math.sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
	testing.expect(t, first_length > 0.001)
	testing.expect(t, delta_length > 0.001)
	for component in second.displacement {
		testing.expect(t, !math.is_nan(component))
		testing.expect(t, !math.is_inf(component, 0))
	}
}

@(test)
ocean_macro_background_phase_varies_along_world_wave_direction :: proc(t: ^testing.T) {
	field := Ocean_Macro_Wave_Field {
		spectrum = {direction = {0, 1, 0}, wind_sea_height = 2, peak_period = 8},
	}
	query: Ocean_Macro_Wave_Query
	first_position := [3]f32{1_080, 0, 0}
	second_position := [3]f32{1_079.8, 20, 0}
	first := ocean_macro_wave_sample(&field, &query, first_position, 20, 1, 0)
	second := ocean_macro_wave_sample(&field, &query, second_position, 20, 1, 0)
	first_radial, _ := ocean_wave_normalize(first_position)
	second_radial, _ := ocean_wave_normalize(second_position)
	first_height :=
		first.displacement.x * first_radial.x +
		first.displacement.y * first_radial.y +
		first.displacement.z * first_radial.z
	second_height :=
		second.displacement.x * second_radial.x +
		second.displacement.y * second_radial.y +
		second.displacement.z * second_radial.z
	testing.expect(t, abs(first_height - second_height) > 0.01)
}

@(test)
ocean_macro_overlapping_packets_remain_bounded :: proc(t: ^testing.T) {
	field := Ocean_Macro_Wave_Field{}
	packet := Ocean_Render_Packet {
		id                 = 1,
		center             = {1_080, 0, 0},
		direction          = {0, 1, 0},
		significant_height = 4,
		period             = 8,
		envelope_length    = 200,
		envelope_width     = 200,
	}
	one := Ocean_Macro_Wave_Query {
		packet_count = 1,
	}
	one.packets[0] = packet
	four := Ocean_Macro_Wave_Query {
		packet_count = 4,
	}
	for &candidate, index in four.packets[:4] {
		candidate = packet
		candidate.id = u32(index + 1)
	}
	position := [3]f32{1_080, 0, 0}
	one_sample := ocean_macro_wave_sample(&field, &one, position, 20, 1, 1)
	four_sample := ocean_macro_wave_sample(&field, &four, position, 20, 1, 1)
	one_length := math.sqrt(
		one_sample.displacement.x * one_sample.displacement.x +
		one_sample.displacement.y * one_sample.displacement.y +
		one_sample.displacement.z * one_sample.displacement.z,
	)
	four_length := math.sqrt(
		four_sample.displacement.x * four_sample.displacement.x +
		four_sample.displacement.y * four_sample.displacement.y +
		four_sample.displacement.z * four_sample.displacement.z,
	)
	testing.expect(t, abs(four_length - one_length) < 0.001)
}

@(test)
ocean_macro_packet_envelope_has_bounded_support :: proc(t: ^testing.T) {
	testing.expect(t, ocean_packet_envelope(0, 0, 10, 5) > 0.99)
	testing.expect(t, ocean_packet_envelope(29, 0, 10, 5) > 0)
	testing.expect_value(t, ocean_packet_envelope(30, 0, 10, 5), f32(0))
	testing.expect_value(t, ocean_packet_envelope(0, 15, 10, 5), f32(0))
}

@(test)
ocean_wave_query_uses_explicit_time_and_includes_breaker_acceleration :: proc(t: ^testing.T) {
	renderer := new(Ocean_Renderer)
	defer free(renderer)
	query: Ocean_Macro_Wave_Query
	position := [3]f32{0, 0, 1_080}
	ocean_breaker_front_add(&renderer.breakers, position, {1, 0, 0}, {0, 1, 0}, 4, 1, 8)
	sample_time := f32(4)
	result := ocean_wave_query_sample(
		renderer,
		&query,
		{position = position, depth = 4, coverage = 1, sample_time = sample_time},
	)
	expected := ocean_breaker_force_sample(&renderer.breakers, position, sample_time)
	testing.expect_value(t, result.acceleration, expected.acceleration)
	testing.expect(
		t,
		result.acceleration.x != 0 || result.acceleration.y != 0 || result.acceleration.z != 0,
	)
}

@(private = "file")
_ring_test_position :: proc(center: [3]f32, azimuth, distance: f32) -> [3]f32 {
	_, east, north := shared.planet_basis(center)
	angle := distance / shared.PLANET_RADIUS
	direction :=
		center * math.cos(angle) +
		(east * math.cos(azimuth) + north * math.sin(azimuth)) * math.sin(angle)
	return shared.planet_position(direction, 0)
}

@(test)
ring_packet_displaces_a_circular_annulus :: proc(t: ^testing.T) {
	field := Ocean_Macro_Wave_Field{}
	center := [3]f32{1, 0, 0}
	packet := Ocean_Render_Packet {
		id                 = 9,
		radial             = true,
		center             = shared.planet_position(center, 0),
		direction          = center * 1.5,
		significant_height = 4,
		period             = 8,
		envelope_length    = 16,
		envelope_width     = 16,
		front_radius       = 40,
		front_speed        = 1.5,
		band               = 16,
		phase_epoch        = 10,
	}
	query := Ocean_Macro_Wave_Query {
		packet_count = 1,
	}
	query.packets[0] = packet
	sample_time := f32(10)
	ring_envelope := [4]f32{}
	for azimuth_index in 0 ..< 4 {
		azimuth := f32(azimuth_index) * f32(math.PI) * 0.5
		position := _ring_test_position(center, azimuth, 40)
		radial, _ := ocean_wave_normalize(position)
		frame := ocean_packet_frame(radial, position, packet, sample_time)
		testing.expect(t, frame.valid)
		ring_envelope[azimuth_index] = frame.envelope
		outward := position - shared.planet_position(center, 0)
		alignment :=
			outward.x * frame.direction.x +
			outward.y * frame.direction.y +
			outward.z * frame.direction.z
		testing.expect(t, alignment > 0)
		sample := ocean_macro_wave_sample(&field, &query, position, 100, 1, sample_time)
		testing.expect(
			t,
			abs(sample.displacement.x) + abs(sample.displacement.y) + abs(sample.displacement.z) >
			0.001,
		)
	}
	for envelope in ring_envelope {
		testing.expect(t, envelope > 0.99)
		testing.expect(t, abs(envelope - ring_envelope[0]) < 0.01)
	}
	center_position := shared.planet_position(center, 0)
	center_frame := ocean_packet_frame(center, center_position, packet, sample_time)
	testing.expect(t, center_frame.valid)
	testing.expect_value(t, center_frame.envelope, f32(0))
	outside := _ring_test_position(center, 0.7, 40 + 16 * OCEAN_RING_ENVELOPE_SIGMAS + 1)
	outside_radial, _ := ocean_wave_normalize(outside)
	outside_frame := ocean_packet_frame(outside_radial, outside, packet, sample_time)
	testing.expect_value(t, outside_frame.envelope, f32(0))
	inside := _ring_test_position(center, 0.7, 40 - 16 * OCEAN_RING_ENVELOPE_SIGMAS + 1)
	inside_radial, _ := ocean_wave_normalize(inside)
	inside_frame := ocean_packet_frame(inside_radial, inside, packet, sample_time)
	testing.expect(t, inside_frame.envelope > 0 && inside_frame.envelope < 0.05)
	later := _ring_test_position(center, 0.7, 40 + 1.5 * 20)
	later_radial, _ := ocean_wave_normalize(later)
	later_frame := ocean_packet_frame(later_radial, later, packet, sample_time + 20)
	testing.expect(t, later_frame.envelope > 0.99)
	stale := _ring_test_position(center, 0.7, 40 + 16 * OCEAN_RING_ENVELOPE_SIGMAS + 1)
	stale_radial, _ := ocean_wave_normalize(stale)
	stale_frame := ocean_packet_frame(stale_radial, stale, packet, sample_time)
	testing.expect_value(t, stale_frame.envelope, f32(0))
	testing.expect(
		t,
		ocean_packet_frame(stale_radial, stale, packet, sample_time + 22).envelope > 0.9,
	)
}

@(test)
ring_packet_continuation_keeps_the_extrapolated_front :: proc(t: ^testing.T) {
	previous := Ocean_Render_Packet {
		id           = 3,
		radial       = true,
		front_radius = 10,
		front_speed  = 2,
		band         = 16,
		phase_epoch  = 4,
	}
	fresh := previous
	fresh.front_radius = 15
	fresh.phase_epoch = 0
	ocean_ring_packet_continue(&fresh, {previous}, 6.4)
	testing.expect_value(t, fresh.front_radius, f32(10))
	testing.expect_value(t, fresh.phase_epoch, f32(4))
	jumped := previous
	jumped.front_radius = 40
	ocean_ring_packet_continue(&jumped, {previous}, 6.4)
	testing.expect_value(t, jumped.front_radius, f32(40))
	testing.expect_value(t, jumped.phase_epoch, f32(6.4))
	pinned := previous
	pinned.front_radius = 15
	ocean_ring_packet_continue(&pinned, {previous}, OCEAN_QUERY_TIME_UNKNOWN)
	testing.expect_value(t, pinned.front_radius, f32(15))
	testing.expect_value(t, pinned.front_speed, f32(0))
	testing.expect_value(t, ocean_ring_front(pinned, 99), f32(15))
}
