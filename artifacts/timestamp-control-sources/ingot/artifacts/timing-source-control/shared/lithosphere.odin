package shared

import "core:math"

LITHOSPHERE_PLATE_COUNT :: 16
LITHOSPHERE_CANDIDATE_COUNT :: 256
LITHOSPHERE_BOUNDARY_WIDTH :: f32(0.055)
LITHOSPHERE_OCEANIC_HEIGHT :: f32(-15)
LITHOSPHERE_CONTINENTAL_HEIGHT :: f32(7)
LITHOSPHERE_SPEED_MIN_MM_YR :: i32(8)
LITHOSPHERE_SPEED_MAX_MM_YR :: i32(95)
LITHOSPHERE_STEP_MAX_YEARS :: u32(25_000)
LITHOSPHERE_SITE_MAX_DOT :: f32(0.9995)
LITHOSPHERE_PROFILE_MAX_DISTANCE :: f32(150)

Plate_Crust :: enum u8 {
	Oceanic,
	Continental,
}

Plate_Role :: enum u8 {
	Interior,
	Subducting,
	Overriding,
	Colliding,
	Diverging,
	Transforming,
}

Lithosphere_Plate :: struct {
	id:                u8,
	genesis_centre:    [3]f32,
	centre:            [3]f32,
	crust:             Plate_Crust,
	euler_pole:        [3]f32,
	speed_mm_yr:       i32,
	base_crust_age_ka: u32,
	base_thickness_m:  u32,
	rotation_radians:  f64,
}

Lithosphere :: struct {
	seed:                 u64,
	genesis_config: Tectonic_Genesis_Config,
	continental_centres: [TECTONIC_CONTINENT_COUNT][3]f32,
	geological_age_years: u64,
	revision:             u64,
	plates:               [LITHOSPHERE_PLATE_COUNT]Lithosphere_Plate,
}

Lithosphere_Sample :: struct {
	plate_id:           u8,
	neighbour_plate_id: u8,
	crust:              Plate_Crust,
	neighbour_crust:    Plate_Crust,
	boundary:           Plate_Boundary,
	role:               Plate_Role,
	boundary_strength:  f32,
	boundary_distance:  f32,
	convergence:        f32,
	divergence:         f32,
	shear:              f32,
	normal_speed_mm_yr: i32,
	shear_speed_mm_yr:  u32,
	boundary_normal:    [3]f32,
	boundary_tangent:   [3]f32,
	crust_elevation:    f32,
	tectonic_relief:    f32,
	elevation:          f32,
}

@(private)
_lithosphere_dot :: proc(a, b: [3]f32) -> f32 {
	return a.x * b.x + a.y * b.y + a.z * b.z
}

@(private)
_lithosphere_cross :: proc(a, b: [3]f32) -> [3]f32 {
	return {
		a.y * b.z - a.z * b.y,
		a.z * b.x - a.x * b.z,
		a.x * b.y - a.y * b.x,
	}
}

@(private)
_lithosphere_hash_direction :: proc(seed, serial: u64) -> [3]f32 {
	longitude := f64(geology_hash(seed ~ 0x243f6a8885a308d3, serial) >> 11) / f64(u64(1) << 53) * 2 * math.PI
	vertical := f64(geology_hash(seed ~ 0x13198a2e03707344, serial) >> 11) / f64(u64(1) << 53) * 2 - 1
	radial := math.sqrt(max(f64(0), 1 - vertical * vertical))
	return {f32(radial * math.cos(longitude)), f32(radial * math.sin(longitude)), f32(vertical)}
}

@(private)
_lithosphere_speed :: proc(seed: u64, id: int) -> i32 {
	hash := geology_hash(seed ~ 0xbe5466cf34e90c6c, u64(id))
	magnitude := LITHOSPHERE_SPEED_MIN_MM_YR +
		i32(hash & 0xffff) * (LITHOSPHERE_SPEED_MAX_MM_YR - LITHOSPHERE_SPEED_MIN_MM_YR) / i32(0xffff)
	if hash & (u64(1) << 63) != 0 do magnitude = -magnitude
	return magnitude
}

lithosphere_plate_velocity_mm_yr :: proc(plate: Lithosphere_Plate, direction: [3]f32) -> [3]f32 {
	radial := _planet_normalize(direction)
	return _lithosphere_cross(plate.euler_pole, radial) * f32(plate.speed_mm_yr)
}

@(private)
_lithosphere_rotate :: proc(direction, pole: [3]f32, angle: f64) -> [3]f32 {
	cosine := f32(math.cos(angle))
	sine := f32(math.sin(angle))
	rotated := direction * cosine + _lithosphere_cross(pole, direction) * sine +
		pole * (_lithosphere_dot(pole, direction) * (1 - cosine))
	return _planet_normalize(rotated)
}

@(private)
_lithosphere_stabilize_sites :: proc(value: ^Lithosphere) {
	assert(value != nil, "_lithosphere_stabilize_sites: nil lithosphere")
	for plate_index in 0 ..< LITHOSPHERE_PLATE_COUNT {
		for neighbour_index in plate_index + 1 ..< LITHOSPHERE_PLATE_COUNT {
			plate := &value.plates[plate_index]
			neighbour := &value.plates[neighbour_index]
			if _lithosphere_dot(plate.centre, neighbour.centre) <= LITHOSPHERE_SITE_MAX_DOT do continue
			plate.centre = _planet_normalize(plate.centre + plate.genesis_centre * 0.001)
			neighbour.centre = _planet_normalize(neighbour.centre + neighbour.genesis_centre * 0.001)
		}
	}
}

lithosphere_step :: proc(value: ^Lithosphere, physical_radius_m: u64, years: u32) {
	assert(value != nil, "lithosphere_step: nil lithosphere")
	assert(physical_radius_m > 0, "lithosphere_step: zero radius")
	assert(years <= LITHOSPHERE_STEP_MAX_YEARS, "lithosphere_step: years")
	if years == 0 do return
	for &plate in value.plates {
		angle := f64(plate.speed_mm_yr) * f64(years) / (f64(physical_radius_m) * 1_000)
		plate.rotation_radians += angle
		plate.centre = _lithosphere_rotate(plate.genesis_centre, plate.euler_pole, plate.rotation_radians)
	}
	value.geological_age_years += u64(years)
	value.revision += 1
}

lithosphere_generate :: proc(value: ^Lithosphere, seed: u64) {
	assert(value != nil, "lithosphere_generate: nil lithosphere")
	value^ = {}
	value.seed = seed
	tectonic_genesis_generate(value)
	candidates: [LITHOSPHERE_CANDIDATE_COUNT][3]f32
	for &candidate, index in candidates do candidate = _lithosphere_hash_direction(seed, u64(index))
	chosen: [LITHOSPHERE_CANDIDATE_COUNT]bool
	first := int(geology_hash(seed, 0) % LITHOSPHERE_CANDIDATE_COUNT)
	for plate_index in 0 ..< LITHOSPHERE_PLATE_COUNT {
		best := first
		if plate_index > 0 {
			best_distance := f32(-1)
			for candidate, candidate_index in candidates {
				if chosen[candidate_index] do continue
				nearest_dot := f32(-1)
				for prior in 0 ..< plate_index {
					nearest_dot = max(nearest_dot, _lithosphere_dot(candidate, value.plates[prior].centre))
				}
				distance := 1 - nearest_dot
				if distance > best_distance {
					best_distance = distance
					best = candidate_index
				}
			}
		}
		if plate_index >= LITHOSPHERE_PLATE_COUNT / 2 {
			best = int(geology_hash(seed ~ 0x7193, u64(plate_index)) % LITHOSPHERE_CANDIDATE_COUNT)
			for chosen[best] do best = (best + 1) % LITHOSPHERE_CANDIDATE_COUNT
		}
		chosen[best] = true
		_lithosphere_init_plate(value, plate_index, candidates[best])
	}
}

@(private)
_lithosphere_init_plate :: proc(value: ^Lithosphere, index: int, centre: [3]f32) {
	assert(value != nil, "_lithosphere_init_plate: nil lithosphere")
	assert(index >= 0 && index < LITHOSPHERE_PLATE_COUNT, "_lithosphere_init_plate: index")
	plate_hash := geology_hash(value.seed ~ 0x452821e638d01377, u64(index))
	crust := Plate_Crust.Oceanic
	if plate_hash % 100 < 42 do crust = .Continental
	age := u32(5_000 + (plate_hash >> 8) % 170_000)
	thickness := u32(6_000 + (plate_hash >> 32) % 4_000)
	if crust == .Continental {
		age = u32(100_000 + (plate_hash >> 8) % 2_900_000)
		thickness = u32(28_000 + (plate_hash >> 32) % 22_000)
	}
	value.plates[index] = {
		id = u8(index),
		genesis_centre = centre,
		centre = centre,
		crust = crust,
		euler_pole = _lithosphere_hash_direction(value.seed ~ 0x082efa98ec4e6c89, u64(index)),
		speed_mm_yr = _lithosphere_speed(value.seed, index),
		base_crust_age_ka = age,
		base_thickness_m = thickness,
	}
}

@(private)
_lithosphere_nearest_pair :: proc(value: ^Lithosphere, radial: [3]f32) -> (int, int) {
	assert(value != nil, "_lithosphere_nearest_pair: nil lithosphere")
	first, second := 0, 1
	first_dot := _lithosphere_dot(radial, value.plates[first].centre)
	second_dot := _lithosphere_dot(radial, value.plates[second].centre)
	if second_dot > first_dot do first, second, first_dot, second_dot = second, first, second_dot, first_dot
	for index in 2 ..< LITHOSPHERE_PLATE_COUNT {
		dot := _lithosphere_dot(radial, value.plates[index].centre)
		if dot > first_dot {
			second, second_dot = first, first_dot
			first, first_dot = index, dot
		} else if dot > second_dot {
			second, second_dot = index, dot
		}
	}
	return first, second
}

@(private)
_lithosphere_boundary_distance :: proc(radial, owner, neighbour: [3]f32) -> f32 {
	plane := owner - neighbour
	length := math.sqrt(max(_lithosphere_dot(plane, plane), f32(0.000001)))
	signed_sine := clamp(_lithosphere_dot(radial, plane / length), -1, 1)
	return math.asin(signed_sine) * PLANET_RADIUS
}

@(private)
_lithosphere_subduction_role :: proc(plate, neighbour: Lithosphere_Plate) -> Plate_Role {
	if plate.crust != neighbour.crust {
		if plate.crust == .Oceanic do return .Subducting
		return .Overriding
	}
	if plate.crust == .Continental do return .Colliding
	if plate.base_crust_age_ka > neighbour.base_crust_age_ka do return .Subducting
	if plate.base_crust_age_ka < neighbour.base_crust_age_ka do return .Overriding
	if plate.id < neighbour.id do return .Subducting
	return .Overriding
}

@(private)
_lithosphere_kernel :: proc(distance, centre, width: f32) -> f32 {
	assert(width > 0, "_lithosphere_kernel: width")
	t := clamp(1 - abs(distance - centre) / width, 0, 1)
	return t * t * (3 - 2 * t)
}

@(private)
_lithosphere_pair_variation :: proc(seed: u64, plate_a, plate_b: u8, radial: [3]f32) -> (f32, f32) {
	low, high := min(plate_a, plate_b), max(plate_a, plate_b)
	pair := u64(low) | u64(high) << 8
	axis_a := _lithosphere_hash_direction(seed ~ 0xa4093822299f31d0, pair)
	axis_b := _lithosphere_hash_direction(seed ~ 0x299f31d0082efa98, pair)
	long_wave := 0.8 + 0.2 * math.sin(_lithosphere_dot(radial, axis_a) * 17 + f32(pair))
	crest := 0.72 + 0.28 * abs(math.sin(_lithosphere_dot(radial, axis_b) * 43 + f32(pair)))
	return long_wave, crest
}

@(private)
_lithosphere_convergent_relief :: proc(value: ^Lithosphere, result: ^Lithosphere_Sample, radial: [3]f32) -> f32 {
	assert(value != nil && result != nil, "_lithosphere_convergent_relief: nil input")
	distance := result.boundary_distance
	belt, crest := _lithosphere_pair_variation(value.seed, result.plate_id, result.neighbour_plate_id, radial)
	if result.boundary == .Collision {
		broad := _lithosphere_kernel(distance, 0, 125) * 18
		peak := _lithosphere_kernel(distance, 18, 52) * 25 * crest
		foothills := _lithosphere_kernel(distance, 78, 70) * 8
		foreland := _lithosphere_kernel(distance, 138, 42) * 4
		return (broad + peak + foothills - foreland) * result.convergence * belt
	}
	if result.role == .Subducting {
		trench := _lithosphere_kernel(distance, 20, 38) * 24
		wedge := _lithosphere_kernel(distance, 68, 42) * 5
		return (-trench + wedge) * result.convergence * belt
	}
	arc_height := 22 if result.crust == .Continental else 16
	forearc := _lithosphere_kernel(distance, 30, 34) * 5
	arc := _lithosphere_kernel(distance, 82, 48) * f32(arc_height) * crest
	backarc := _lithosphere_kernel(distance, 136, 54) * 4
	return (-forearc + arc + backarc) * result.convergence * belt
}

@(private)
_lithosphere_relief :: proc(value: ^Lithosphere, result: ^Lithosphere_Sample, radial: [3]f32) -> f32 {
	assert(value != nil && result != nil, "_lithosphere_relief: nil input")
	if result.boundary == .Subduction || result.boundary == .Collision {
		return _lithosphere_convergent_relief(value, result, radial)
	}
	distance := result.boundary_distance
	belt, crest := _lithosphere_pair_variation(value.seed, result.plate_id, result.neighbour_plate_id, radial)
	if result.boundary == .Ridge {
		if result.crust == .Oceanic {
			return (_lithosphere_kernel(distance, 0, 38) * 10 * crest +
				_lithosphere_kernel(distance, 48, 70) * 4) * result.divergence * belt
		}
		shoulder := _lithosphere_kernel(distance, 58, 58) * 7
		graben := _lithosphere_kernel(distance, 0, 25) * 10
		return (shoulder - graben) * result.divergence * belt
	}
	if result.boundary == .Transform {
		return -_lithosphere_kernel(distance, 0, 24) * 3 * result.shear * crest
	}
	return 0
}

lithosphere_sample :: proc(value: ^Lithosphere, direction: [3]f32) -> Lithosphere_Sample {
	assert(value != nil, "lithosphere_sample: nil lithosphere")
	radial := _planet_normalize(direction)
	first, second := _lithosphere_nearest_pair(value, radial)
	plate, neighbour := value.plates[first], value.plates[second]
	fraction := tectonic_genesis_continents(value, radial)
	plate.crust = .Continental if fraction >= 0.5 else .Oceanic
	neighbour.crust = .Continental if tectonic_genesis_continents(value, _planet_normalize(radial + (neighbour.centre - plate.centre) * 0.03)) >= 0.5 else .Oceanic
	distance := _lithosphere_boundary_distance(radial, plate.centre, neighbour.centre)
	strength := clamp(1 - distance / LITHOSPHERE_PROFILE_MAX_DISTANCE, 0, 1)
	result := Lithosphere_Sample {
		plate_id = plate.id,
		neighbour_plate_id = neighbour.id,
		crust = plate.crust,
		neighbour_crust = neighbour.crust,
		boundary_strength = strength,
		boundary_distance = distance,
		crust_elevation = LITHOSPHERE_OCEANIC_HEIGHT + fraction * (LITHOSPHERE_CONTINENTAL_HEIGHT - LITHOSPHERE_OCEANIC_HEIGHT),
	}
	if strength <= 0 {
		result.elevation = result.crust_elevation
		return result
	}
	_lithosphere_classify(&result, plate, neighbour, radial)
	result.tectonic_relief = _lithosphere_relief(value, &result, radial)
	result.elevation = result.crust_elevation + result.tectonic_relief
	return result
}

@(private)
_lithosphere_classify :: proc(result: ^Lithosphere_Sample, plate, neighbour: Lithosphere_Plate, radial: [3]f32) {
	assert(result != nil, "_lithosphere_classify: nil result")
	boundary_normal := neighbour.centre - plate.centre
	boundary_normal -= radial * _lithosphere_dot(boundary_normal, radial)
	length := math.sqrt(max(_lithosphere_dot(boundary_normal, boundary_normal), f32(0.000001)))
	boundary_normal /= length
	boundary_tangent := _lithosphere_cross(radial, boundary_normal)
	relative := lithosphere_plate_velocity_mm_yr(neighbour, radial) -
		lithosphere_plate_velocity_mm_yr(plate, radial)
	normal_speed := _lithosphere_dot(relative, boundary_normal)
	tangent_speed := abs(_lithosphere_dot(relative, boundary_tangent))
	result.boundary_normal = boundary_normal
	result.boundary_tangent = boundary_tangent
	result.normal_speed_mm_yr = i32(normal_speed)
	result.shear_speed_mm_yr = u32(tangent_speed)
	result.shear = min(tangent_speed / f32(LITHOSPHERE_SPEED_MAX_MM_YR), f32(1)) * result.boundary_strength
	if abs(normal_speed) <= 1 && tangent_speed <= 1 {
		result.boundary = .Intraplate
		result.role = .Interior
		return
	}
	if normal_speed < -8 {
		result.boundary = .Subduction
		result.role = _lithosphere_subduction_role(plate, neighbour)
		if result.role == .Colliding do result.boundary = .Collision
		result.convergence = min(-normal_speed / f32(LITHOSPHERE_SPEED_MAX_MM_YR), f32(1)) *
			result.boundary_strength
	} else if normal_speed > 8 {
		result.boundary = .Ridge
		result.role = .Diverging
		result.divergence = min(normal_speed / f32(LITHOSPHERE_SPEED_MAX_MM_YR), f32(1)) *
			result.boundary_strength
	} else {
		result.boundary = .Transform
		result.role = .Transforming
		result.shear = min(tangent_speed / f32(LITHOSPHERE_SPEED_MAX_MM_YR), f32(1)) *
			result.boundary_strength
	}
}
