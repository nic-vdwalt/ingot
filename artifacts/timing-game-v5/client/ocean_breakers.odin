package main

import shared "../shared"
import "core:math"
import rl "ingot:gfx"

OCEAN_BREAKER_FRONT_MAX :: 16
OCEAN_BREAKER_SEARCH_RADIUS :: 7
OCEAN_BREAKER_SEARCH_MAX ::
	(OCEAN_BREAKER_SEARCH_RADIUS * 2 + 1) * (OCEAN_BREAKER_SEARCH_RADIUS * 2 + 1)
OCEAN_BREAKER_CREST_SEGMENTS :: 20
OCEAN_BREAKER_CROSS_SEGMENTS :: 12
OCEAN_BREAKER_CREST_SAMPLES :: OCEAN_BREAKER_CREST_SEGMENTS + 1
OCEAN_BREAKER_CROSS_SAMPLES :: OCEAN_BREAKER_CROSS_SEGMENTS + 1
OCEAN_BREAKER_VERTICES_PER_FRONT :: OCEAN_BREAKER_CREST_SAMPLES * OCEAN_BREAKER_CROSS_SAMPLES
OCEAN_BREAKER_INDICES_PER_FRONT :: OCEAN_BREAKER_CREST_SEGMENTS * OCEAN_BREAKER_CROSS_SEGMENTS * 6
OCEAN_BREAKER_VERTICES_MAX :: OCEAN_BREAKER_FRONT_MAX * OCEAN_BREAKER_VERTICES_PER_FRONT
OCEAN_BREAKER_INDICES_MAX :: OCEAN_BREAKER_FRONT_MAX * OCEAN_BREAKER_INDICES_PER_FRONT
OCEAN_SPRAY_PARTICLE_MAX :: 2_048

Ocean_Spray_Particle :: struct {
	position: [3]f32,
	velocity: [3]f32,
	age:      f32,
	lifetime: f32,
	foam:     f32,
	active:   bool,
}

Ocean_Breaker_Front :: struct {
	center:    [3]f32,
	direction: [3]f32,
	tangent:   [3]f32,
	height:    f32,
	depth:     f32,
	width:     f32,
	curl:      f32,
	foam:      f32,
	period:    f32,
	phase:     f32,
	packet_id: u32,
	crest_id:  i32,
	segment_id: i32,
	impact_emitted: bool,
	breaking:  f32,
	exit_age:  f32,
	active:    bool,
}

Ocean_Breaker_Renderer :: struct {
	fronts:                [OCEAN_BREAKER_FRONT_MAX]Ocean_Breaker_Front,
	vertices:              [OCEAN_BREAKER_VERTICES_MAX]rl.Gpu_3D_Vertex,
	indices:               [OCEAN_BREAKER_INDICES_MAX]u32,
	mesh:                  rl.Gpu_Mesh,
	mesh_dirty:            bool,
	spray_mesh:            rl.Gpu_Mesh,
	front_count:           u32,
	rejected_offshore:     u32,
	rejected_envelope:     u32,
	rejected_class:        u32,
	rejected_phase:        u32,
	vertex_count:          u32,
	index_count:           u32,
	uploaded_vertex_count: u32,
	uploaded_index_count:  u32,
	spray:                 [OCEAN_SPRAY_PARTICLE_MAX]Ocean_Spray_Particle,
	spray_count:           u32,
	last_time:             f32,
	last_focus_direction:  [3]f32,
	last_packet_signature: u64,
	last_water_revision:   u64,
	emitted_cycles:        [OCEAN_BREAKER_FRONT_MAX]i64,
	debug_impact_crests:    [OCEAN_NEARSHORE_BREAK_SEGMENT_MAX]i32,
	debug_impact_valid:     [OCEAN_NEARSHORE_BREAK_SEGMENT_MAX]bool,
}

Ocean_Breaker_Force_Sample :: struct {
	flow_velocity: [3]f32,
	acceleration:  [3]f32,
	drag:          f32,
	whitewater:    f32,
	active:        bool,
}

Ocean_Breaker_Profile_Sample :: struct {
	forward:        f32,
	height:         f32,
	normal_forward: f32,
	normal_up:      f32,
	foam:           f32,
}

Ocean_Breaker_Candidate :: struct {
	front: Ocean_Breaker_Front,
	score: f32,
}

ocean_breaker_classify :: proc(
	slope_milli, period_ms, steepness_milli: u32,
) -> shared.Wave_Breaker_Type {
	if slope_milli > 2_400 do return .Surging
	if slope_milli >= 180 && period_ms >= 5_500 && steepness_milli >= 18 do return .Plunging
	if slope_milli > 0 do return .Spilling
	return .None
}

@(private)
ocean_breaker_front_add :: proc(
	value: ^Ocean_Breaker_Renderer,
	center, direction, tangent: [3]f32,
	height, breaking: f32,
	period := f32(8),
	width_scale := f32(1),
	packet_id := u32(0),
	crest_id := i32(0),
	phase := f32(0),
	water_depth := f32(4),
) {
	assert(value != nil, "ocean_breaker_front_add: nil renderer")
	if value.front_count >= OCEAN_BREAKER_FRONT_MAX do return
	index := value.front_count
	value.fronts[index] = {
		center    = center,
		direction = direction,
		tangent   = tangent,
		height    = clamp(height, 0.2, 8),
		depth     = max(water_depth, f32(0.02)),
		width     = clamp(height * 6 * width_scale, 4, 96),
		curl      = clamp(0.35 + breaking * 0.65, 0.35, 1),
		foam      = clamp(breaking, 0, 1),
		period    = clamp(period, 2, 20),
		phase     = phase,
		packet_id = packet_id,
		crest_id  = crest_id,
		breaking  = breaking,
		active    = true,
	}
	value.front_count += 1
}

@(private)
ocean_breaker_index_in :: proc(indices: []int, index: int) -> int {
	for candidate, position in indices {
		if candidate == index do return position
	}
	return -1
}

@(private)
ocean_breaker_search :: proc(world: ^shared.World, focus_index: int, output: []int) -> int {
	assert(world != nil, "ocean_breaker_search: nil world")
	if len(output) == 0 do return 0
	queue: [OCEAN_BREAKER_SEARCH_MAX]int
	depths: [OCEAN_BREAKER_SEARCH_MAX]u8
	queue[0] = focus_index
	count := 1
	cursor := 0
	for cursor < count {
		index := queue[cursor]
		depth := depths[cursor]
		cursor += 1
		if world.planetary.waves.breaker_type[index] == .Plunging {
			output[ocean_breaker_index_in(output[:], -1)] = index
		}
		if depth >= OCEAN_BREAKER_SEARCH_RADIUS do continue
		for neighbour_u32 in world.planetary.grid.neighbours[index] {
			neighbour := int(neighbour_u32)
			if ocean_breaker_index_in(queue[:count], neighbour) >= 0 do continue
			if count >= OCEAN_BREAKER_SEARCH_MAX do break
			queue[count] = neighbour
			depths[count] = depth + 1
			count += 1
		}
	}
	result := 0
	for index in output {
		if index < 0 do break
		result += 1
	}
	return result
}

ocean_breaker_arrival :: proc(packet: Ocean_Render_Packet, coordinate, sample_time: f32) -> (phase: f32, crest_id: i32, arrived: bool) {
	phase = -packet.phase_epoch / packet.period - coordinate * ocean_packet_wave_number(packet) / f32(math.TAU) + 0.25
	cycle := math.floor(sample_time / packet.period + phase)
	crest_id = i32(cycle)
	arrival_time := (cycle - phase) * packet.period
	arrived = arrival_time >= packet.phase_epoch && sample_time >= arrival_time
	return
}

ocean_breakers_extract :: proc(
	value: ^Ocean_Breaker_Renderer,
	nearshore: ^Ocean_Nearshore,
	packets: []Ocean_Render_Packet,
	focus_direction: [3]f32,
	sample_time := f32(0),
) {
	assert(value != nil && nearshore != nil, "ocean_breakers_extract: nil input")
	previous_fronts := value.fronts
	previous_count := value.front_count
	value.front_count = 0
	value.rejected_offshore = 0
	value.rejected_envelope = 0
	value.rejected_class = 0
	value.rejected_phase = 0
	if !nearshore.ready do return
	candidates: [OCEAN_NEARSHORE_BREAK_SEGMENT_MAX]Ocean_Breaker_Candidate
	candidate_count := 0
	segments: [OCEAN_NEARSHORE_BREAK_SEGMENT_MAX]Ocean_Nearshore_Break_Segment
	for packet in packets {
		if packet.significant_height <= 0 || packet.period <= 0 do continue
		break_depth := packet.significant_height / OCEAN_MACRO_BREAK_DEPTH_RATIO
		segment_count := ocean_nearshore_break_segments(nearshore, break_depth, segments[:])
		wavelength := max(
			f32(shared.wave_deep_water_wavelength_mm(u32(packet.period * 1_000))) / 1_000,
			f32(0.1),
		)
		steepness_milli := u32(
			clamp(packet.significant_height / wavelength * 1_000, f32(0), f32(4_000)),
		)
		for segment, segment_index in segments[:segment_count] {
			radial, ok := ocean_wave_normalize(segment.center)
			if !ok do continue
			visibility :=
				radial.x * focus_direction.x +
				radial.y * focus_direction.y +
				radial.z * focus_direction.z
			if visibility <= 0 do continue
			frame := ocean_packet_frame(radial, segment.center, packet, sample_time)
			if !frame.valid do continue
			direction := frame.direction
			if direction.x * segment.shallow_normal.x +
				   direction.y * segment.shallow_normal.y +
				   direction.z * segment.shallow_normal.z <=
			   0 {
				value.rejected_offshore += 1
				continue
			}
			envelope := frame.envelope
			if envelope < 0.05 {
				value.rejected_envelope += 1
				continue
			}
			breaker_type := ocean_breaker_classify(
				u32(clamp(segment.bed_slope * 1_000, f32(0), f32(4_000))),
				u32(packet.period * 1_000),
				steepness_milli,
			)
			if breaker_type != .Plunging {
				value.rejected_class += 1
				continue
			}
			strength :=
				clamp(
					(packet.significant_height / max(segment.depth, f32(0.02)) -
							OCEAN_MACRO_BREAK_DEPTH_RATIO) *
						2 +
					segment.foam +
					0.35,
					f32(0),
					f32(1),
				) *
				envelope
			if strength <= 0 do continue
			phase := -f32(segment_index) / f32(max(segment_count, 1))
			crest_id := i32(segment_index)
			if packet.id == OCEAN_DEBUG_TEST_PULSE_ID {
				arrived: bool
				phase, crest_id, arrived = ocean_breaker_arrival(packet, frame.carrier_coordinate, sample_time)
				arrival_time := (f32(crest_id) - phase) * packet.period
				arrival_frame := ocean_packet_frame(radial, segment.center, packet, arrival_time)
				if !arrived || arrival_frame.envelope < 0.05 {
					value.rejected_phase += 1
					continue
				}
			}
			candidate := Ocean_Breaker_Candidate {
				front = {
					center = segment.center,
					direction = direction,
					tangent = segment.tangent,
					height = clamp(packet.significant_height, 0.2, 8),
					depth = max(segment.depth, f32(0.02)),
					width = clamp(packet.envelope_width, f32(4), f32(96)),
					curl = clamp(0.35 + strength * 0.65, f32(0.35), f32(1)),
					foam = strength,
					period = clamp(packet.period, f32(2), f32(20)),
					phase = phase,
					packet_id = packet.id,
					crest_id = crest_id,
					segment_id = i32(segment_index),
					breaking = strength,
					active = true,
				},
				score = strength * 2 +
				envelope +
				visibility,
			}
			insert := candidate_count
			for index in 0 ..< candidate_count {
				if candidate.score > candidates[index].score {
					insert = index
					break
				}
			}
			limit := min(candidate_count + 1, OCEAN_NEARSHORE_BREAK_SEGMENT_MAX)
			for index := limit - 1; index > insert; index -= 1 do candidates[index] = candidates[index - 1]
			if insert < OCEAN_NEARSHORE_BREAK_SEGMENT_MAX do candidates[insert] = candidate
			candidate_count = limit
		}
	}
	value.front_count = u32(min(candidate_count, OCEAN_BREAKER_FRONT_MAX))
	for index in 0 ..< int(value.front_count) {
		front := candidates[index].front
		for previous in previous_fronts[:previous_count] {
			if previous.packet_id == front.packet_id && previous.crest_id == front.crest_id && previous.segment_id == front.segment_id {
				front.impact_emitted = previous.impact_emitted
				break
			}
		}
		value.fronts[index] = front
	}
}

ocean_breaker_smoothstep :: proc(low, high, value: f32) -> f32 {
	t := clamp((value - low) / max(high - low, f32(0.0001)), 0, 1)
	return t * t * (3 - 2 * t)
}

ocean_breaker_lifecycle :: proc(
	crest_phase, breaking, exit_age: f32,
) -> (
	pitch, plunge, collapse, fade: f32,
) {
	phase := clamp(crest_phase, 0, 1)
	strength := clamp(breaking, 0, 1)
	pitch = ocean_breaker_smoothstep(0.08, 0.42, phase) * strength
	plunge = ocean_breaker_smoothstep(0.30, 0.68, phase) * strength
	collapse = max(ocean_breaker_smoothstep(0.72, 0.98, phase), clamp(exit_age, 0, 1))
	fade = 1 - ocean_breaker_smoothstep(0, 1, exit_age)
	return
}

ocean_breaker_force_sample :: proc(
	value: ^Ocean_Breaker_Renderer,
	position: [3]f32,
	sample_time: f32,
) -> Ocean_Breaker_Force_Sample {
	assert(value != nil, "ocean_breaker_force_sample: nil renderer")
	result: Ocean_Breaker_Force_Sample
	for front in value.fronts[:value.front_count] {
		if !front.active do continue
		radial, radial_ok := ocean_wave_normalize(front.center)
		if !radial_ok do continue
		offset := position - front.center
		forward :=
			offset.x * front.direction.x +
			offset.y * front.direction.y +
			offset.z * front.direction.z
		lateral :=
			offset.x * front.tangent.x + offset.y * front.tangent.y + offset.z * front.tangent.z
		vertical := offset.x * radial.x + offset.y * radial.y + offset.z * radial.z
		lateral_envelope :=
			1 - ocean_breaker_smoothstep(front.width * 0.35, front.width * 0.5, abs(lateral))
		forward_envelope :=
			1 - ocean_breaker_smoothstep(front.height * 0.75, front.height * 2, abs(forward))
		vertical_envelope :=
			1 - ocean_breaker_smoothstep(front.height * 0.65, front.height * 1.5, abs(vertical))
		envelope := lateral_envelope * forward_envelope * vertical_envelope
		if envelope <= 0 do continue
		crest_phase := sample_time / front.period + front.phase
		crest_phase -= math.floor(crest_phase)
		pitch, plunge, collapse, fade := ocean_breaker_lifecycle(
			crest_phase,
			front.breaking,
			front.exit_age,
		)
		strength := envelope * fade
		phase_speed := OCEAN_NEARSHORE_GRAVITY * front.period / f32(math.TAU)
		result.flow_velocity +=
			front.direction * phase_speed * (0.25 * pitch + 0.75 * collapse) * strength
		result.acceleration += front.direction * OCEAN_NEARSHORE_GRAVITY * plunge * strength
		result.acceleration += radial * OCEAN_NEARSHORE_GRAVITY * pitch * strength * 0.35
		result.acceleration -= radial * OCEAN_NEARSHORE_GRAVITY * plunge * strength * 0.25
		result.drag = max(result.drag, collapse * strength * 6)
		result.whitewater = max(result.whitewater, max(collapse, plunge) * strength)
		result.active = true
	}
	acceleration_length := math.sqrt(
		result.acceleration.x * result.acceleration.x +
		result.acceleration.y * result.acceleration.y +
		result.acceleration.z * result.acceleration.z,
	)
	maximum_acceleration := f32(35)
	if acceleration_length > maximum_acceleration {
		result.acceleration *= maximum_acceleration / acceleration_length
	}
	return result
}

ocean_breaker_spray_emit :: proc(value: ^Ocean_Breaker_Renderer, front: Ocean_Breaker_Front) {
	if value.spray_count >= OCEAN_SPRAY_PARTICLE_MAX do return
	for particle_index in 0 ..< 8 {
		if value.spray_count >= OCEAN_SPRAY_PARTICLE_MAX do break
		for &particle in value.spray {
			if particle.active do continue
			spread := (f32(particle_index) / 7 - 0.5) * front.width
			particle = {
				position = front.center + front.tangent * spread + front.direction * front.height * 0.4,
				velocity = front.direction *
					front.height *
					(0.8 +
							f32(particle_index) *
								0.04) + front.center / max(math.sqrt(front.center.x * front.center.x + front.center.y * front.center.y + front.center.z * front.center.z), f32(0.0001)) * front.height * 1.6,
				lifetime = 1.2 + f32(particle_index % 3) * 0.25,
				foam     = front.foam,
				active   = true,
			}
			value.spray_count += 1
			break
		}
	}
}

ocean_breaker_spray_step :: proc(value: ^Ocean_Breaker_Renderer, frame_dt: f32) {
	if frame_dt <= 0 do return
	active_count := u32(0)
	for &particle in value.spray {
		if !particle.active do continue
		particle.age += frame_dt
		if particle.age >= particle.lifetime {
			particle = {}
			continue
		}
		radial :=
			particle.position /
			max(
				math.sqrt(
					particle.position.x * particle.position.x +
					particle.position.y * particle.position.y +
					particle.position.z * particle.position.z,
				),
				f32(0.0001),
			)
		particle.velocity -= radial * OCEAN_NEARSHORE_GRAVITY * frame_dt
		particle.velocity *= max(1 - frame_dt * 0.35, f32(0))
		particle.position += particle.velocity * frame_dt
		active_count += 1
	}
	value.spray_count = active_count
}

ocean_breaker_profile_sample :: proc(
	front: Ocean_Breaker_Front,
	q, pitch, plunge, collapse, fade: f32,
) -> Ocean_Breaker_Profile_Sample {
	face_q := min(q / 0.58, f32(1))
	lip_q := max((q - 0.58) / 0.42, f32(0))
	depth_limit := max(front.depth * OCEAN_MACRO_BREAK_DEPTH_RATIO, f32(0.2))
	scale := min(front.height, depth_limit)
	height_profile := math.sin(face_q * f32(math.PI) * 0.5) * (1 - lip_q * 0.42)
	forward_profile := face_q * face_q * 0.22 + lip_q * (1.15 - lip_q * 0.82) * front.curl * pitch
	forward_profile += lip_q * plunge * 0.75
	height_profile -= lip_q * lip_q * plunge * 0.72
	height_profile *= (1 - collapse * 0.75) * fade
	forward_profile *= (1 - collapse * 0.45) * fade
	face_derivative := f32(1 / 0.58) if q < 0.58 else f32(0)
	lip_derivative := f32(1 / 0.42) if q >= 0.58 else f32(0)
	height_derivative := math.cos(face_q * f32(math.PI) * 0.5) * f32(math.PI) * 0.5 * face_derivative * (1 - lip_q * 0.42)
	height_derivative -= math.sin(face_q * f32(math.PI) * 0.5) * lip_derivative * 0.42
	height_derivative -= 2 * lip_q * lip_derivative * plunge * 0.72
	height_derivative *= (1 - collapse * 0.75)
	forward_derivative := 2 * face_q * face_derivative * 0.22
	forward_derivative += lip_derivative * ((1.15 - 2 * lip_q * 0.82) * front.curl * pitch + plunge * 0.75)
	forward_derivative *= (1 - collapse * 0.45)
	normal_length := max(math.sqrt(height_derivative * height_derivative + forward_derivative * forward_derivative), f32(0.00001))
	foam := clamp(
		front.foam * ocean_breaker_smoothstep(0.50, 0.72, q) +
		plunge * ocean_breaker_smoothstep(0.82, 1, q),
		0,
		1,
	)
	return {
		forward = forward_profile * scale,
		height = height_profile * scale,
		normal_forward = -height_derivative / normal_length,
		normal_up = forward_derivative / normal_length,
		foam = foam,
	}
}

ocean_breakers_mesh_fill :: proc(value: ^Ocean_Breaker_Renderer, time := f32(0)) {
	assert(value != nil, "ocean_breakers_mesh_fill: nil renderer")
	vertex_cursor := 0
	index_cursor := 0
	for front_index in 0 ..< int(value.front_count) {
		front := value.fronts[front_index]
		radial :=
			front.center /
			max(
				math.sqrt(
					front.center.x * front.center.x +
					front.center.y * front.center.y +
					front.center.z * front.center.z,
				),
				0.0001,
			)
		crest_phase := time / front.period + front.phase
		crest_phase -= math.floor(crest_phase)
		pitch, plunge, collapse, fade := ocean_breaker_lifecycle(
			crest_phase,
			front.breaking,
			front.exit_age,
		)
		base := vertex_cursor
		for crest_index in 0 ..= OCEAN_BREAKER_CREST_SEGMENTS {
			s := f32(crest_index) / f32(OCEAN_BREAKER_CREST_SEGMENTS)
			span := (s - 0.5) * front.width
			end_fade :=
				ocean_breaker_smoothstep(0, 0.12, s) * (1 - ocean_breaker_smoothstep(0.88, 1, s))
			for cross_index in 0 ..= OCEAN_BREAKER_CROSS_SEGMENTS {
				q := f32(cross_index) / f32(OCEAN_BREAKER_CROSS_SEGMENTS)
				profile := ocean_breaker_profile_sample(front, q, pitch, plunge, collapse, fade)
				position :=
					front.center +
					front.tangent * span +
					radial * (profile.height * end_fade) +
					front.direction * (profile.forward * end_fade)
				normal := radial * profile.normal_up + front.direction * profile.normal_forward
				normal_length := max(
					math.sqrt(normal.x * normal.x + normal.y * normal.y + normal.z * normal.z),
					0.0001,
				)
				assert(vertex_cursor < OCEAN_BREAKER_VERTICES_MAX, "ocean breaker vertex overflow")
				value.vertices[vertex_cursor] = {
					position = position,
					normal   = normal / normal_length,
					scalar   = profile.foam,
					uv       = {max(front.height * 1.3, f32(0.2)), 2},
				}
				vertex_cursor += 1
			}
		}
		for crest_index in 0 ..< OCEAN_BREAKER_CREST_SEGMENTS {
			for cross_index in 0 ..< OCEAN_BREAKER_CROSS_SEGMENTS {
				a := u32(base + crest_index * OCEAN_BREAKER_CROSS_SAMPLES + cross_index)
				b := a + 1
				c := a + OCEAN_BREAKER_CROSS_SAMPLES
				d := c + 1
				assert(
					index_cursor + 6 <= OCEAN_BREAKER_INDICES_MAX,
					"ocean breaker index overflow",
				)
				value.indices[index_cursor + 0] = a
				value.indices[index_cursor + 1] = c
				value.indices[index_cursor + 2] = b
				value.indices[index_cursor + 3] = b
				value.indices[index_cursor + 4] = c
				value.indices[index_cursor + 5] = d
				index_cursor += 6
			}
		}
	}
	value.vertex_count = u32(vertex_cursor)
	value.index_count = u32(index_cursor)
	value.mesh_dirty = true
}

ocean_breaker_packet_signature :: proc(packets: []Ocean_Render_Packet) -> u64 {
	result := u64(len(packets))
	for packet in packets {
		result = result * 1_099_511_628_211 ~ u64(packet.id)
		result = result * 1_099_511_628_211 ~ u64(transmute(u32)packet.significant_height)
	}
	return result
}

ocean_breakers_update_required :: proc(
	fixed_dt: f32,
	focus, previous_focus: [3]f32,
	packet_signature, previous_packet_signature, water_revision, previous_water_revision: u64,
) -> bool {
	if fixed_dt > 0 do return true
	if packet_signature != previous_packet_signature || water_revision != previous_water_revision do return true
	return(
		focus.x * previous_focus.x + focus.y * previous_focus.y + focus.z * previous_focus.z <
		0.999999 \
	)
}

ocean_breakers_advance :: proc(
	value: ^Ocean_Breaker_Renderer,
	world: ^shared.World,
	nearshore: ^Ocean_Nearshore,
	packets: []Ocean_Render_Packet,
	focus_direction: [3]f32,
	time, fixed_dt: f32,
) {
	assert(value != nil && world != nil && nearshore != nil, "ocean_breakers_update: nil input")
	packet_signature := ocean_breaker_packet_signature(packets)
	update_required := ocean_breakers_update_required(
		fixed_dt,
		focus_direction,
		value.last_focus_direction,
		packet_signature,
		value.last_packet_signature,
		world.waterfield.revision,
		value.last_water_revision,
	)
	if !update_required do return
	value.last_focus_direction = focus_direction
	value.last_packet_signature = packet_signature
	value.last_water_revision = world.waterfield.revision
	ocean_breakers_extract(value, nearshore, packets, focus_direction, time)
	ocean_breaker_spray_step(value, fixed_dt)
	if fixed_dt > 0 {
		for &front, front_index in value.fronts[:value.front_count] {
			cycle_position := time / front.period + front.phase
			cycle := i64(math.floor(cycle_position))
			if front.packet_id == OCEAN_DEBUG_TEST_PULSE_ID {
				segment := clamp(int(front.segment_id), 0, OCEAN_NEARSHORE_BREAK_SEGMENT_MAX - 1)
				already_emitted := value.debug_impact_valid[segment] && value.debug_impact_crests[segment] == front.crest_id
				if !already_emitted && cycle_position - f32(cycle) >= 0.72 {
					ocean_breaker_spray_emit(value, front)
					value.debug_impact_valid[segment] = true
					value.debug_impact_crests[segment] = front.crest_id
					front.impact_emitted = true
				}
			} else if front.breaking > 0.72 && value.emitted_cycles[front_index] != cycle {
				ocean_breaker_spray_emit(value, front)
				value.emitted_cycles[front_index] = cycle
			}
		}
	}
	ocean_breakers_mesh_fill(value, time)
	value.last_time = time
}

ocean_breakers_upload :: proc(value: ^Ocean_Breaker_Renderer) {
	assert(value != nil)
	if !value.mesh_dirty do return
	if value.vertex_count == 0 {
		value.mesh_dirty = false
		return
	}
	vertices := value.vertices[:value.vertex_count]
	indices := value.indices[:value.index_count]
	if value.mesh.id == 0 ||
	   value.uploaded_vertex_count != value.vertex_count ||
	   value.uploaded_index_count != value.index_count {
		if value.mesh.id != 0 do rl.destroy_gpu_mesh(&value.mesh)
		mesh, ok := rl.create_gpu_mesh(vertices, indices, .Triangles)
		if ok {
			value.mesh = mesh
			value.uploaded_vertex_count = value.vertex_count
			value.uploaded_index_count = value.index_count
			value.mesh_dirty = false
		}
		return
	}
	if rl.update_gpu_mesh_vertices(value.mesh, vertices) do value.mesh_dirty = false
}

ocean_breakers_update :: proc(
	value: ^Ocean_Breaker_Renderer,
	world: ^shared.World,
	nearshore: ^Ocean_Nearshore,
	packets: []Ocean_Render_Packet,
	focus_direction: [3]f32,
	time, fixed_dt: f32,
) {
	ocean_breakers_advance(value, world, nearshore, packets, focus_direction, time, fixed_dt)
	ocean_breakers_upload(value)
}

ocean_breakers_draw :: proc(
	value: ^Ocean_Breaker_Renderer,
	pass: ^rl.Gpu_3D_Pass,
	material: rl.Gpu_Material,
) {
	assert(value != nil && pass != nil, "ocean_breakers_draw: nil input")
	if value.front_count > 0 && value.mesh.id != 0 {
		rl.draw_gpu_mesh(pass, value.mesh, rl.Matrix(1), material)
	}
	if value.spray_count == 0 do return
	if value.spray_mesh.id == 0 {
		vertices := [4]rl.Gpu_3D_Vertex {
			{position = {0, 0, 1}, normal = {0, 0, 1}},
			{position = {1, 0, -1}, normal = {1, 0, 0}},
			{position = {-0.5, 0.866, -1}, normal = {-0.5, 0.866, 0}},
			{position = {-0.5, -0.866, -1}, normal = {-0.5, -0.866, 0}},
		}
		indices := [12]u32{0, 1, 2, 0, 2, 3, 0, 3, 1, 1, 3, 2}
		mesh, valid := rl.create_gpu_mesh(vertices[:], indices[:], .Triangles)
		if !valid do return
		value.spray_mesh = mesh
	}
	transforms: [OCEAN_SPRAY_PARTICLE_MAX]rl.Matrix
	count := 0
	for particle in value.spray {
		if !particle.active do continue
		remaining := clamp(1 - particle.age / max(particle.lifetime, f32(0.001)), f32(0), f32(1))
		size := f32(0.035) * remaining
		transform := rl.Matrix(1)
		transform[0, 0] = size
		transform[1, 1] = size
		transform[2, 2] = size
		transform[0, 3] = particle.position.x
		transform[1, 3] = particle.position.y
		transform[2, 3] = particle.position.z
		transforms[count] = transform
		count += 1
	}
	rl.draw_gpu_mesh_instanced(pass, value.spray_mesh, transforms[:count], {color = rl.WHITE, style = .Opaque})
}

ocean_breakers_deinit :: proc(value: ^Ocean_Breaker_Renderer) {
	assert(value != nil, "ocean_breakers_deinit: nil renderer")
	if value.mesh.id != 0 do rl.destroy_gpu_mesh(&value.mesh)
	if value.spray_mesh.id != 0 do rl.destroy_gpu_mesh(&value.spray_mesh)
	value^ = {}
}
