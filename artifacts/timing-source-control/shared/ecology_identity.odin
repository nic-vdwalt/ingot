package shared

ecology_hash_mix :: proc(value: u64) -> u64 {
	result := value
	result = (result ~ (result >> 30)) * 0xbf58476d1ce4e5b9
	result = (result ~ (result >> 27)) * 0x94d049bb133111eb
	return result ~ (result >> 31)
}

genome_id :: proc(genome: Genome) -> Genome_Id {
	hash := ecology_hash_mix(
		u64(genome.metabolism) |
		u64(genome.growth) << 16 |
		u64(genome.mobility) << 32,
	)
	hash = ecology_hash_mix(hash ~ u64(i64(genome.thermal_preference_mk)))
	hash = ecology_hash_mix(hash ~ u64(genome.chemical_preference))
	if hash == 0 do hash = 1
	return Genome_Id(hash)
}

lineage_id_founder :: proc(world_seed, vent_id: u64) -> Lineage_Id {
	hash := ecology_hash_mix(world_seed ~ vent_id * 0x9e3779b97f4a7c15)
	if hash == 0 do hash = 1
	return Lineage_Id(hash)
}

species_id_from_genome :: proc(id: Genome_Id) -> Species_Id {
	hash := ecology_hash_mix(u64(id) ~ 0x53504543494553)
	if hash == 0 do hash = 1
	return Species_Id(hash)
}
