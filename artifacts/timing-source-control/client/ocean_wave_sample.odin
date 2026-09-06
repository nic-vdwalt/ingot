package main

import shared "../shared"
import "core:math"

OCEAN_MACRO_PACKET_MAX :: OCEAN_RENDER_PACKET_MAX
OCEAN_WAVE_FIXED_DT :: f32(1.0 / 60.0)
OCEAN_WAVE_MAX_STEPS_PER_FRAME :: 8
OCEAN_PACKET_RETAIN_BONUS :: f32(0.15)
OCEAN_MACRO_SHOAL_REFERENCE_DEPTH :: f32(3.5)
OCEAN_MACRO_BREAK_DEPTH_RATIO :: f32(0.78)
OCEAN_MACRO_PACKET_HORIZONTAL :: f32(0.48)
OCEAN_MACRO_BACKGROUND_SUPPRESSION :: f32(0.8)

Ocean_Macro_Wave_Field :: struct {
	spectrum:      Ocean_Render_Spectrum,
	time:          f32,
	previous_time: f32,
	accumulator:   f32,
	step_count:    u64,
	revision:      u64,
}

Ocean_Macro_Wave_Query :: struct {
	packets:          [OCEAN_MACRO_PACKET_MAX]Ocean_Render_Packet,
	packet_ids:       [OCEAN_MACRO_PACKET_MAX]u32,
	packet_count:     int,
	center_direction: [3]f32,
	field_revision:   u64,
	ready:            bool,
}

Ocean_Wave_Query_Input :: struct {
	position:    [3]f32,
	depth:       f32,
	coverage:    f32,
	sample_time: f32,
}

Ocean_Wave_Field_Sample :: struct {
	displacement: [3]f32,
	normal:       [3]f32,
	velocity:     [3]f32,
	acceleration: [3]f32,
	compression:  f32,
	breaking:     f32,
	breaker_type: shared.Wave_Breaker_Type,
	whitewater:   f32,
	drag:         f32,
	foam:         f32,
}

ocean_wave_normalize :: proc(value: [3]f32) -> ([3]f32, bool) {
	length := math.sqrt(value.x * value.x + value.y * value.y + value.z * value.z)
	if length <= 0.0001 do return {}, false
	return value / length, true
}

ocean_wave_tangent_direction :: proc(radial, supplied: [3]f32) -> ([3]f32, bool) {
	projected :=
		supplied - radial * (supplied.x * radial.x + supplied.y * radial.y + supplied.z * radial.z)
	return ocean_wave_normalize(projected)
}

ocean_wave_query_ids :: proc(query: ^Ocean_Macro_Wave_Query) -> []u32 {
	assert(query != nil, "ocean_wave_query_ids: nil query")
	return query.packet_ids[:query.packet_count]
}

ocean_macro_query_debug_packet_merge :: proc(
	query: ^Ocean_Macro_Wave_Query,
	packet: Ocean_Render_Packet,
	active: bool,
) {
	assert(query != nil, "ocean debug packet merge: nil query")
	if !active do return
	index := query.packet_count
	for candidate, candidate_index in query.packet_ids[:query.packet_count] {
		if candidate == packet.id {
			index = candidate_index
			break
		}
	}
	if index >= OCEAN_MACRO_PACKET_MAX do index = OCEAN_MACRO_PACKET_MAX - 1
	query.packets[index] = packet
	query.packet_ids[index] = packet.id
	query.packet_count = min(max(query.packet_count, index + 1), OCEAN_MACRO_PACKET_MAX)
	query.ready = true
	query.field_revision += 1
}

ocean_macro_query_update :: proc(
	query: ^Ocean_Macro_Wave_Query,
	world: ^shared.World,
	center: [3]f32,
	sample_time := OCEAN_QUERY_TIME_UNKNOWN,
) -> bool {
	assert(query != nil && world != nil, "ocean_macro_query_update: nil input")
	direction, ok := ocean_wave_normalize(center)
	if !ok do return false
	previous_ids := query.packet_ids
	previous_count := query.packet_count
	previous_packets := query.packets
	packets := weather_ocean_render_packets(
		world,
		direction,
		ocean_wave_query_ids(query),
		&query.packets,
	)
	query.packet_count = len(packets)
	for &packet in query.packets[:query.packet_count] {
		ocean_ring_packet_continue(&packet, previous_packets[:previous_count], sample_time)
	}
	for index in 0 ..< OCEAN_MACRO_PACKET_MAX {
		query.packet_ids[index] = 0
		if index < query.packet_count do query.packet_ids[index] = query.packets[index].id
	}
	changed := !query.ready || previous_count != query.packet_count
	if !changed {
		for index in 0 ..< query.packet_count {
			if previous_ids[index] != query.packet_ids[index] {
				changed = true
				break
			}
		}
	}
	query.center_direction = direction
	query.ready = true
	if changed do query.field_revision += 1
	return changed
}

ocean_macro_depth_amplitude :: proc(height, depth, coverage: f32) -> f32 {
	target_rms := max(height, 0) * 0.25
	wet := ocean_breaker_smoothstep(0.04, 0.42, coverage)
	finite_depth := max(depth, f32(0.04))
	shoaling := clamp(
		math.sqrt(OCEAN_MACRO_SHOAL_REFERENCE_DEPTH / finite_depth),
		f32(1),
		f32(2.4),
	)
	return min(target_rms * shoaling, finite_depth * OCEAN_MACRO_BREAK_DEPTH_RATIO) * wet
}

ocean_debug_depth_amplitude :: proc(height, depth, coverage: f32) -> f32 {
	return 0.5 * min(clamp(height, f32(0), f32(20)), max(depth, f32(0)) * OCEAN_MACRO_BREAK_DEPTH_RATIO) * ocean_breaker_smoothstep(0.04, 0.42, coverage)
}

ocean_packet_envelope :: proc(longitudinal, lateral, length, width: f32) -> f32 {
	packet_length := max(length, f32(1))
	packet_width := max(width, f32(1))
	if abs(longitudinal) >= packet_length * 3 || abs(lateral) >= packet_width * 3 do return 0
	return math.exp(
		-longitudinal * longitudinal / (packet_length * packet_length) -
		lateral * lateral / (packet_width * packet_width),
	)
}

OCEAN_RING_ENVELOPE_SIGMAS :: f32(2)
OCEAN_RING_CONTINUE_TOLERANCE :: f32(0.25)
OCEAN_QUERY_TIME_UNKNOWN :: f32(-1)

// Chord-based arc length: acos of a dot product loses about half a unit of
// precision next to the centre in f32, which is most of a short debug band.
ocean_great_circle_distance :: proc(a, b: [3]f32) -> f32 {
	delta := a - b
	chord := math.sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
	return 2 * math.asin(clamp(chord * 0.5, f32(0), f32(1))) * f32(shared.PLANET_RADIUS)
}

ocean_ring_envelope :: proc(distance, front, band: f32) -> f32 {
	sigma := max(band, f32(1))
	offset := distance - front
	if abs(offset) > sigma * OCEAN_RING_ENVELOPE_SIGMAS do return 0
	return math.exp(-offset * offset / (sigma * sigma))
}

ocean_ring_front :: proc(packet: Ocean_Render_Packet, sample_time: f32) -> f32 {
	return packet.front_radius + packet.front_speed * max(sample_time - packet.phase_epoch, f32(0))
}

// A ring re-projected from the simulation carries the authoritative front
// radius; the renderer keeps extrapolating from the epoch it already holds
// while that radius agrees with its own prediction, so the front never snaps
// back on the next wave step. A query with no clock (physics bodies) pins the
// front to the authoritative radius instead of extrapolating from nothing.
ocean_ring_packet_continue :: proc(
	packet: ^Ocean_Render_Packet,
	previous: []Ocean_Render_Packet,
	sample_time: f32,
) {
	assert(packet != nil, "ocean_ring_packet_continue: nil packet")
	if !packet.radial do return
	if sample_time < 0 {
		packet.front_speed = 0
		packet.phase_epoch = 0
		return
	}
	for candidate in previous {
		if candidate.id != packet.id || !candidate.radial do continue
		extrapolated := ocean_ring_front(candidate, sample_time)
		tolerance := max(packet.band * OCEAN_RING_CONTINUE_TOLERANCE, f32(1))
		if abs(extrapolated - packet.front_radius) <= tolerance {
			packet.front_radius = candidate.front_radius
			packet.front_speed = candidate.front_speed
			packet.direction = candidate.direction
			packet.phase_epoch = candidate.phase_epoch
			return
		}
		break
	}
	packet.phase_epoch = sample_time
}

Ocean_Packet_Frame :: struct {
	direction:          [3]f32,
	envelope:           f32,
	carrier_coordinate: f32,
	valid:              bool,
}

// Resolves one render packet at a surface position: the tangent direction
// the crests travel, the envelope weight, and the coordinate the carrier
// phase runs along. Rings measure both from the source; directional packets
// from the packet centre along its travel direction.
ocean_packet_frame :: proc(
	radial: [3]f32,
	position: [3]f32,
	packet: Ocean_Render_Packet,
	sample_time: f32,
) -> Ocean_Packet_Frame {
	result: Ocean_Packet_Frame
	if packet.radial {
		center_radial, center_valid := ocean_wave_normalize(packet.center)
		if !center_valid do return result
		center_dot :=
			radial.x * center_radial.x + radial.y * center_radial.y + radial.z * center_radial.z
		distance := ocean_great_circle_distance(radial, center_radial)
		direction, direction_valid := ocean_wave_tangent_direction(
			radial,
			radial * center_dot - center_radial,
		)
		if !direction_valid {
			_, direction, _ = shared.planet_basis(radial)
		}
		result.direction = direction
		result.envelope = ocean_ring_envelope(
			distance,
			ocean_ring_front(packet, sample_time),
			packet.band,
		)
		result.carrier_coordinate = distance
		result.valid = true
		return result
	}
	direction, direction_valid := ocean_wave_tangent_direction(radial, packet.direction)
	if !direction_valid do return result
	tangent := [3]f32 {
		radial.y * direction.z - radial.z * direction.y,
		radial.z * direction.x - radial.x * direction.z,
		radial.x * direction.y - radial.y * direction.x,
	}
	offset := position - packet.center
	longitudinal := offset.x * direction.x + offset.y * direction.y + offset.z * direction.z
	if packet.id == OCEAN_DEBUG_TEST_PULSE_ID {
		longitudinal -= packet.front_speed * max(sample_time - packet.phase_epoch, f32(0))
	}
	lateral := offset.x * tangent.x + offset.y * tangent.y + offset.z * tangent.z
	result.direction = direction
	result.envelope = ocean_packet_envelope(
		longitudinal,
		lateral,
		packet.envelope_length,
		packet.envelope_width,
	)
	result.carrier_coordinate =
		position.x * direction.x + position.y * direction.y + position.z * direction.z
	if packet.id == OCEAN_DEBUG_TEST_PULSE_ID {
		result.carrier_coordinate = offset.x * direction.x + offset.y * direction.y + offset.z * direction.z
	}
	result.valid = true
	return result
}

ocean_packet_wave_number :: proc(packet: Ocean_Render_Packet) -> f32 {
	omega := f32(math.TAU) / max(packet.period, f32(0.25))
	if packet.id == OCEAN_DEBUG_TEST_PULSE_ID && packet.phase_speed > 0 {
		return omega * OCEAN_RENDER_METERS_PER_UNIT / packet.phase_speed
	}
	return omega * omega / f32(9.81) * OCEAN_RENDER_METERS_PER_UNIT
}

ocean_packet_carrier_time :: proc(packet: Ocean_Render_Packet, sample_time: f32) -> f32 {
	if packet.id == OCEAN_DEBUG_TEST_PULSE_ID do return max(sample_time - packet.phase_epoch, f32(0))
	return sample_time
}

ocean_macro_wave_sample :: proc(
	field: ^Ocean_Macro_Wave_Field,
	query: ^Ocean_Macro_Wave_Query,
	position: [3]f32,
	depth, coverage, sample_time: f32,
) -> Ocean_Wave_Field_Sample {
	assert(field != nil && query != nil, "ocean_macro_wave_sample: nil input")
	radial, valid := ocean_wave_normalize(position)
	if !valid do return {}
	primary, primary_valid := ocean_wave_tangent_direction(radial, field.spectrum.direction)
	if !primary_valid {
		_, primary, _ = shared.planet_basis(radial)
	}
	phase_direction, phase_valid := ocean_wave_normalize(field.spectrum.direction)
	if !phase_valid do phase_direction = primary
	secondary := [3]f32 {
		radial.y * primary.z - radial.z * primary.y,
		radial.z * primary.x - radial.x * primary.z,
		radial.x * primary.y - radial.y * primary.x,
	}
	result := Ocean_Wave_Field_Sample {
		normal = radial,
	}
	continuous_height := ocean_continuous_wave_height(
		field.spectrum.wind_sea_height,
		field.spectrum.swell_height,
	)
	background_amplitude := ocean_macro_depth_amplitude(continuous_height, depth, coverage)
	period := max(field.spectrum.peak_period, f32(2))
	omega := f32(math.TAU) / period
	wave_number := omega * omega / f32(9.81) * OCEAN_RENDER_METERS_PER_UNIT
	phase_coordinate :=
		position.x * phase_direction.x +
		position.y * phase_direction.y +
		position.z * phase_direction.z
	carrier := phase_coordinate * wave_number - omega * sample_time
	cross_direction, _ := ocean_wave_normalize(primary * 0.82 + secondary * 0.57)
	crossing := phase_coordinate * wave_number * 1.17 - omega * 1.08 * sample_time
	background_height :=
		(math.sin(carrier) * 0.76 + math.sin(crossing) * 0.24) * background_amplitude
	background_horizontal :=
		primary * math.cos(carrier) * background_amplitude * 0.42 +
		cross_direction * math.cos(crossing) * background_amplitude * 0.10
	background_displacement := background_horizontal + radial * background_height
	background_velocity :=
		radial *
			((-math.cos(carrier) * 0.76 * omega - math.cos(crossing) * 0.24 * omega * 1.08) *
					background_amplitude) +
		primary * (math.sin(carrier) * omega * background_amplitude * 0.42) +
		cross_direction * (math.sin(crossing) * omega * 1.08 * background_amplitude * 0.10)
	background_slope :=
		primary * (math.cos(carrier) * 0.76 * background_amplitude * wave_number) +
		cross_direction * (math.cos(crossing) * 0.24 * background_amplitude * wave_number * 1.17)
	packet_displacement: [3]f32
	packet_velocity: [3]f32
	packet_slope: [3]f32
	packet_envelope_union := f32(0)
	packet_weight_sum := f32(0)
	for packet in query.packets[:query.packet_count] {
		frame := ocean_packet_frame(radial, position, packet, sample_time)
		if !frame.valid do continue
		packet_direction := frame.direction
		envelope := frame.envelope
		carrier_coordinate := frame.carrier_coordinate
		debug_packet := packet.id == OCEAN_DEBUG_TEST_PULSE_ID
		packet_amplitude :=
			ocean_macro_depth_amplitude(packet.significant_height, depth, coverage) * envelope
		if debug_packet do packet_amplitude = ocean_debug_depth_amplitude(packet.significant_height, depth, coverage) * envelope
		primary_weight := f32(1) if debug_packet else f32(0.78)
		sideband_weight := f32(0) if debug_packet else f32(0.22)
		packet_omega := f32(math.TAU) / max(packet.period, f32(0.25))
		packet_wave_number := ocean_packet_wave_number(packet)
		carrier_time := ocean_packet_carrier_time(packet, sample_time)
		packet_carrier := carrier_coordinate * packet_wave_number - packet_omega * carrier_time
		sideband :=
			carrier_coordinate * packet_wave_number * 1.08 - packet_omega * 1.04 * carrier_time
		height := (math.sin(packet_carrier) * primary_weight + math.sin(sideband) * sideband_weight) * packet_amplitude
		packet_displacement +=
			radial * height +
			packet_direction *
				math.cos(packet_carrier) *
				packet_amplitude *
				OCEAN_MACRO_PACKET_HORIZONTAL
		packet_velocity +=
			radial *
				((-math.cos(packet_carrier) * primary_weight * packet_omega -
							math.cos(sideband) * sideband_weight * packet_omega * 1.04) *
						packet_amplitude) +
			packet_direction *
				(math.sin(packet_carrier) *
						packet_omega *
						packet_amplitude *
						OCEAN_MACRO_PACKET_HORIZONTAL)
		packet_slope +=
			packet_direction *
			(math.cos(packet_carrier) * primary_weight * packet_amplitude * packet_wave_number +
					math.cos(sideband) * sideband_weight * packet_amplitude * packet_wave_number * 1.08)
		compression := max(
			math.sin(packet_carrier) * packet_amplitude * packet_wave_number,
			f32(0),
		)
		result.compression += compression
		result.foam = max(result.foam, compression)
		if packet.breaking > result.breaking {
			result.breaking = packet.breaking
			result.breaker_type = packet.breaker_type
		}
		packet_envelope_union = 1 - (1 - packet_envelope_union) * (1 - envelope)
		packet_weight_sum += envelope
	}
	overlap_scale := min(f32(1), 1 / max(packet_weight_sum, f32(1)))
	packet_displacement *= overlap_scale
	packet_velocity *= overlap_scale
	packet_slope *= overlap_scale
	packet_mix := clamp(packet_envelope_union, f32(0), f32(1))
	background_scale := math.sqrt(max(1 - packet_mix * packet_mix, f32(0)))
	result.displacement = background_displacement * background_scale + packet_displacement
	result.velocity = background_velocity * background_scale + packet_velocity
	normal := radial - background_slope * background_scale - packet_slope
	result.normal, _ = ocean_wave_normalize(normal)
	return result
}

ocean_wave_query_sample :: proc(
	renderer: ^Ocean_Renderer,
	query: ^Ocean_Macro_Wave_Query,
	input: Ocean_Wave_Query_Input,
) -> Ocean_Wave_Field_Sample {
	assert(renderer != nil && query != nil, "ocean_wave_query_sample: nil input")
	result := ocean_macro_wave_sample(
		&renderer.macro,
		query,
		input.position,
		input.depth,
		input.coverage,
		input.sample_time,
	)
	nearshore, local := ocean_nearshore_surface_sample(&renderer.nearshore, input.position)
	if local {
		blend := nearshore.blend
		result.displacement = result.displacement * (1 - blend) + nearshore.displacement * blend
		mixed_normal := result.normal * (1 - blend) + nearshore.normal * blend
		result.normal, _ = ocean_wave_normalize(mixed_normal)
		result.velocity = result.velocity * (1 - blend) + nearshore.velocity * blend
		result.foam = max(result.foam, nearshore.foam * blend)
	}
	breaker := ocean_breaker_force_sample(&renderer.breakers, input.position, input.sample_time)
	result.velocity += breaker.flow_velocity
	result.acceleration += breaker.acceleration
	result.whitewater = breaker.whitewater
	result.drag = breaker.drag
	return result
}

ocean_wave_field_sample :: proc(
	renderer: ^Ocean_Renderer,
	world: ^shared.World,
	query: ^Ocean_Macro_Wave_Query,
	position: [3]f32,
	depth, coverage: f32,
) -> Ocean_Wave_Field_Sample {
	assert(renderer != nil && world != nil && query != nil, "ocean_wave_field_sample: nil input")
	return ocean_wave_query_sample(
		renderer,
		query,
		{
			position = position,
			depth = depth,
			coverage = coverage,
			sample_time = renderer.macro.time,
		},
	)
}
