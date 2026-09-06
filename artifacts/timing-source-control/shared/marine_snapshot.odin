package shared

marine_ecology_snapshot_size :: proc(state: ^Marine_Ecology) -> int {
	return 8 * (19 + int(state.lineage_count) * 13 + len(state.cells) * 36)
}

marine_snapshot_scalar :: proc(buffer: []u8, cursor: ^int, value: ^u64, reading: bool) -> bool {
	if cursor^ < 0 || cursor^ > len(buffer) - 8 do return false
	if reading {
		value^ = 0
		for index in 0 ..< 8 do value^ |= u64(buffer[cursor^ + index]) << uint(8 * index)
	} else {
		for index in 0 ..< 8 do buffer[cursor^ + index] = u8(value^ >> uint(8 * index))
	}
	cursor^ += 8
	return true
}

marine_snapshot_body :: proc(state: ^Marine_Ecology, buffer: []u8, reading: bool) -> bool {
	cursor := 24
	fields := [12]^u64{&state.seed, &state.step, &state.elapsed_seconds, &state.birth_serial, &state.revision, &state.initial_mass, &state.suppressed_mutations, &state.local_extinctions, &state.global_extinctions, &state.guild_mass[0], &state.guild_mass[1], &state.guild_mass[2]}
	for field in fields do if !marine_snapshot_scalar(buffer, &cursor, field, reading) do return false
	flags := [2]u64{u64(state.mutation_enabled), u64(state.frozen)}
	for &flag in flags {
		if !marine_snapshot_scalar(buffer, &cursor, &flag, reading) || flag > 1 do return false
	}
	state.mutation_enabled, state.frozen = flags[0] != 0, flags[1] != 0
	for &lineage in state.lineages[:state.lineage_count] {
		traits := lineage.traits
		values := [13]u64{u64(traits.guild), u64(traits.body), u64(traits.adult_mass), u64(traits.elongation), u64(traits.appendages), u64(traits.armour), u64(traits.oxygen_tolerance), u64(traits.feeding_specialization), u64(lineage.parent), lineage.born, lineage.occupied_steps, u64(lineage.established), u64(lineage.extinct)}
		for &value in values do if !marine_snapshot_scalar(buffer, &cursor, &value, reading) do return false
		if values[0] > 2 || values[1] > 3 || values[2] > 1000 || values[8] > MARINE_MAX_LINEAGES || values[11] > 1 || values[12] > 1 do return false
		for index in 3 ..< 8 do if values[index] > 1000 do return false
		lineage = {traits = {Marine_Guild(values[0]), Marine_Body(values[1]), u32(values[2]), u16(values[3]), u16(values[4]), u16(values[5]), u16(values[6]), u16(values[7])}, parent = u32(values[8]), born = values[9], occupied_steps = values[10], established = values[11] != 0, extinct = values[12] != 0}
	}
	for &cell in state.cells {
		pools := [4]^u64{&cell.inorganic, &cell.producers, &cell.suspended, &cell.deposited}
		for pool in pools do if !marine_snapshot_scalar(buffer, &cursor, pool, reading) do return false
		for &cohort in cell.cohorts {
			identity := u64(cohort.lineage)
			if !marine_snapshot_scalar(buffer, &cursor, &identity, reading) || identity > u64(state.lineage_count) do return false
			cohort.lineage = u32(identity)
			if !marine_snapshot_scalar(buffer, &cursor, &cohort.mass, reading) do return false
			if !marine_snapshot_scalar(buffer, &cursor, &cohort.reserve, reading) do return false
			if !marine_snapshot_scalar(buffer, &cursor, &cohort.age, reading) do return false
		}
	}
	reserved: u64
	if !marine_snapshot_scalar(buffer, &cursor, &reserved, reading) || reserved != 0 do return false
	length := u64(len(buffer))
	if !marine_snapshot_scalar(buffer, &cursor, &length, reading) do return false
	return length == u64(len(buffer)) && cursor == len(buffer)
}

marine_ecology_snapshot_write :: proc(state: ^Marine_Ecology, buffer: []u8) -> (int, bool) {
	if !marine_ecology_valid(state) do return 0, false
	size := marine_ecology_snapshot_size(state)
	if len(buffer) < size do return 0, false
	cursor := 0
	header := [3]u64{1, u64(len(state.cells)), u64(state.lineage_count)}
	for &value in header do if !marine_snapshot_scalar(buffer[:size], &cursor, &value, false) do return 0, false
	if !marine_snapshot_body(state, buffer[:size], false) do return 0, false
	return size, true
}

marine_ecology_snapshot_read :: proc(state: ^Marine_Ecology, buffer: []u8) -> bool {
	cursor := 0
	header: [3]u64
	for &value in header do if !marine_snapshot_scalar(buffer, &cursor, &value, true) do return false
	if header[0] != 1 || header[1] == 0 || header[1] > PLANET_SIM_CELL_COUNT || header[2] < 4 || header[2] > MARINE_MAX_LINEAGES do return false
	expected := 8 * (19 + int(header[2]) * 13 + int(header[1]) * 36)
	if len(buffer) != expected do return false
	temporary: Marine_Ecology
	if !marine_ecology_init(&temporary, 0, context.allocator, int(header[1])) do return false
	defer marine_ecology_deinit(&temporary)
	temporary.lineage_count = u32(header[2])
	if !marine_snapshot_body(&temporary, buffer, true) || !marine_ecology_valid(&temporary) do return false
	if temporary.initial_mass != 0 && marine_total_mass(&temporary) != temporary.initial_mass do return false
	state^, temporary = temporary, state^
	return true
}
