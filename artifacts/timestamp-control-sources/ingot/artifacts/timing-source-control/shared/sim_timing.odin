package shared

import "core:time"

// Sim_Stage names the coarse groups of work inside one authoritative tick.
// The declaration order is the execution order in sim_tick and
// world_planetary_step, so a timing record reads as a timeline.
Sim_Stage :: enum u8 {
	Construction,
	Production,
	Waterfield,
	Climate_Dynamics,
	Climate,
	Sea_Ice,
	Biogeochemistry,
	Ocean,
	Biogeochemistry_Transport,
	Waves,
	Geology,
	Diagnostics,
	Ecology,
	Flush,
	// Asynchronous planetary preparation: time the tick spent waiting for
	// the prepared state and the cost of swapping it in.
	Planetary_Wait,
	Planetary_Commit,
}

SIM_STAGE_NAMES :: [Sim_Stage]string {
	.Construction              = "construction",
	.Production                = "production",
	.Waterfield                = "waterfield",
	.Climate_Dynamics          = "climate.dynamics",
	.Climate                   = "climate",
	.Sea_Ice                   = "sea_ice",
	.Biogeochemistry           = "biogeo",
	.Ocean                     = "ocean",
	.Biogeochemistry_Transport = "biogeo.transport",
	.Waves                     = "waves",
	.Geology                   = "geology",
	.Diagnostics               = "diagnostics",
	.Ecology                   = "ecology",
	.Flush                     = "flush",
	.Planetary_Wait            = "planetary.wait",
	.Planetary_Commit          = "planetary.commit",
}

// Sim_Tick_Timing is an optional wall-clock breakdown of one tick. It is
// diagnostic only: it never influences simulation state, so a nil timing
// pointer skips every clock read and the authoritative path stays free of
// wall-clock reads.
Sim_Tick_Timing :: struct {
	tick:     u64,
	total_ms: f64,
	stage_ms: [Sim_Stage]f64,
	_started: time.Tick,
	_stage:   time.Tick,
}

sim_timing_begin :: proc(timing: ^Sim_Tick_Timing, tick: u64) {
	if timing == nil do return
	timing.tick = tick
	timing.total_ms = 0
	timing.stage_ms = {}
	timing._started = time.tick_now()
	timing._stage = timing._started
}

// sim_timing_mark closes the interval since the previous mark (or begin) and
// attributes it to `stage`. Stages entered more than once accumulate.
sim_timing_mark :: proc(timing: ^Sim_Tick_Timing, stage: Sim_Stage) {
	if timing == nil do return
	now := time.tick_now()
	timing.stage_ms[stage] += time.duration_milliseconds(time.tick_diff(timing._stage, now))
	timing._stage = now
}

sim_timing_end :: proc(timing: ^Sim_Tick_Timing) {
	if timing == nil do return
	timing.total_ms = time.duration_milliseconds(time.tick_diff(timing._started, time.tick_now()))
}
