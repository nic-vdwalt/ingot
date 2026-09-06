package shared

Genome_Id :: distinct u64
Species_Id :: distinct u64
Lineage_Id :: distinct u64

Life_Stage :: enum u8 {
	Propagule,
	Juvenile,
	Adult,
	Senescent,
}

Organism :: struct {
	birth_tick: u64,
	age_ticks:  u64,
	health:     u32,
	energy:     u64,
	genome:     Genome_Id,
	species:    Species_Id,
	lineage:    Lineage_Id,
	stage:      Life_Stage,
}

Genome :: struct {
	id:                    Genome_Id,
	metabolism:            u16,
	growth:                u16,
	mobility:              u16,
	thermal_preference_mk: i32,
	chemical_preference:   u32,
}

Metabolism :: struct {
	intake_per_step:      u32,
	maintenance_per_step: u32,
	chemical_output:      u32,
}

Reproduction :: struct {
	maturity_ticks:    u64,
	cooldown_ticks:    u64,
	remaining_ticks:   u64,
	mutation_rate_ppm: u32,
}

Creature_Behavior :: enum u8 {
	Walk,
	Idle,
	Graze,
}

Movement :: struct {
	heading_east:    i32,
	heading_north:   i32,
	speed_mm_step:   u32,
	prior:           Planet_Coord,
	destination:     Planet_Coord,
	next_move_tick:  u64,
	decision_serial: u32,
	behavior:        Creature_Behavior,
}

Vent_Origin :: struct {
	vent: Net_Id,
}

Plant :: struct {
	root_depth_mm: u32,
}

Creature_Kind :: enum u8 {
	Gazelle,
}

Creature :: struct {
	sensory_range_mm: u32,
	kind:             Creature_Kind,
}
