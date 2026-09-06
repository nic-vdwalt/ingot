package shared

// Load-time benchmarks. These allocate a full world (tens of megabytes) and
// take seconds each, so they are compiled out of the normal test run and
// enabled explicitly:
//
//   bash build.sh bench
//   odin test shared -collection:ingot=../ingot -o:speed \
//       -define:FORGE_BENCH=true
//
// They are deliberately GPU-free so they run in CI and on a headless machine.

import "core:fmt"
import "core:testing"
import "core:time"

BENCH_ENABLED :: #config(FORGE_BENCH, false)
BENCH_REPEATS :: 3

// _bench reports the best of BENCH_REPEATS runs. Best-of rejects scheduler
// noise without hiding a genuine regression, which a mean would smear. It is
// compiled unconditionally so this file's imports are always used; only the
// expensive @(test) bodies below are gated.
_bench :: proc(name: string, work: proc()) {
	assert(work != nil, "_bench: nil work")
	best := max(time.Duration)
	for _ in 0 ..< BENCH_REPEATS {
		start := time.tick_now()
		work()
		elapsed := time.tick_since(start)
		if elapsed < best do best = elapsed
	}
	fmt.printf("[bench] %-34s %9.2f ms\n", name, time.duration_milliseconds(best))
}

// Keeps the suite non-empty (ODIN_TEST_FAIL_ON_EMPTY) and documents how to
// turn the real benchmarks on when they are compiled out.
@(test)
bench_harness_reports_state :: proc(t: ^testing.T) {
	when BENCH_ENABLED {
		testing.expect(t, BENCH_REPEATS > 0, "bench_harness: repeats must be positive")
	} else {
		testing.expect(t, !BENCH_ENABLED, "bench_harness: disabled without the define")
	}
}

when BENCH_ENABLED {
	@(private = "file")
	bench_field: ^Foundation_Field
	@(private = "file")
	bench_world: ^World

	// The 1921x1921 analytic foundation bake: the multi-second cost the
	// loading screen hides on a worker thread.
	@(test)
	bench_foundation_generate :: proc(t: ^testing.T) {
		field := new(Foundation_Field)
		defer free(field)
		foundation_init(field)
		defer foundation_deinit(field)
		bench_field = field
		_bench("foundation_generate 1921x1921", proc() {
			_ = foundation_generate(bench_field, TERRAIN_SEED)
		})
		testing.expect(t, bench_field.seed == TERRAIN_SEED, "bench_foundation_generate: no output")
	}

	// waterfield_step sweeps all 3,690,241 cells and runs 4x per second inside
	// sim_tick, so its cost is a per-tick floor for the whole simulation.
	@(test)
	bench_waterfield_step :: proc(t: ^testing.T) {
		world := new(World)
		defer free(world)
		testing.expect(t, world_init_seed(world, TERRAIN_SEED), "bench_waterfield_step: world init")
		defer world_deinit(world)
		bench_world = world
		_bench("waterfield_step 1921x1921", proc() {_ = waterfield_step(bench_world, 0)})
	}

	// terrain_sample is six bilinear interpolations over six foundation
	// arrays. The client's grid bake calls it once per vertex across a
	// 3841x3841 grid, so this measures that bake's inner cost in isolation.
	@(test)
	bench_terrain_sample :: proc(t: ^testing.T) {
		world := new(World)
		defer free(world)
		testing.expect(t, world_init_seed(world, TERRAIN_SEED), "bench_terrain_sample: world init")
		defer world_deinit(world)
		bench_world = world
		_bench("terrain_sample x6.5M", proc() {
			step := f32(2 * WORLD_HALF_SIZE) / f32(2560)
			for row in 0 ..< 2561 {
				world_y := -WORLD_HALF_SIZE + f32(row) * step
				for column in 0 ..< 2561 {
					_ = terrain_sample(bench_world, -WORLD_HALF_SIZE + f32(column) * step, world_y)
				}
			}
		})
		testing.expect(t, bench_world.foundation.seed == TERRAIN_SEED, "bench_terrain_sample: seed")
	}

	// The full world build as the loading screen performs it: foundation bake
	// plus ECS allocation plus the initial water fill.
	@(test)
	bench_world_init_seed :: proc(t: ^testing.T) {
		_bench("world_init_seed full", proc() {
			world := new(World)
			defer free(world)
			if world_init_seed(world, TERRAIN_SEED) do world_deinit(world)
		})
		testing.expect(t, true, "bench_world_init_seed: completed")
	}

	// A drag-sculpt: one second of dragging at 60 Hz issues roughly this many
	// terraform commands, and every one of them used to refill all 3,690,241
	// waterfield ground cells. This is the bench the rect refill exists for.
	//
	// The three brush sizes are measured separately because the rect scales
	// with the brush while the old full refill did not: if a future change
	// reintroduces a whole-field sweep, the three rows collapse to the same
	// number and the regression is obvious rather than merely slower.
	BENCH_TERRAFORM_COMMANDS :: 60

	@(private = "file")
	bench_radius: i32

	@(test)
	bench_terraform_drag :: proc(t: ^testing.T) {
		for radius in TERRAFORM_RADIUS_MIN ..= TERRAFORM_RADIUS_MAX {
			// Only the extremes and the default are worth a row; the two
			// in-between sizes add runtime without adding information.
			if radius != TERRAFORM_RADIUS_MIN &&
			   radius != TERRAFORM_RADIUS &&
			   radius != TERRAFORM_RADIUS_MAX {
				continue
			}
			world := new(World)
			defer free(world)
			testing.expect(t, world_init_seed(world, TERRAIN_SEED), "bench_terraform_drag: world init")
			defer world_deinit(world)
			player_entity, ok_player := spawn_player(world, 0)
			testing.expect(t, ok_player, "bench_terraform_drag: player")
			_ = player_entity
			bench_world = world
			bench_radius = radius
			span := terraform_cell_span(radius)
			_bench(
				fmt.tprintf("terraform drag x%d, %dx%d brush", BENCH_TERRAFORM_COMMANDS, span, span),
				proc() {
					// The charge would exhaust the starting stockpile long
					// before the command count is reached, and a refused
					// command does no work at all - which would benchmark the
					// validator rather than the edit. Refunding the exact cost
					// after each apply keeps every command doing real work.
					refund: [Resource_Kind]u64
					refund[.Ore] = terraform_cost_ore(bench_radius)
					for index in 0 ..< BENCH_TERRAFORM_COMMANDS {
						// Alternate direction so the centre delta never
						// saturates and starts refusing mid-run.
						direction := i8(1) if index % 2 == 0 else i8(-1)
						_ = apply_command(
							bench_world,
							Command {
								kind = .Terraform,
								player = 0,
								grid_x = 0,
								grid_y = 0,
								direction = direction,
								terraform_radius = i8(bench_radius),
							},
						)
						_refund(bench_world, bench_world.players[0], refund)
					}
				},
			)
		}
	}

	// The whole-field refill, kept as the baseline the rect refill is
	// measured against. One of these used to run per terraform command.
	@(test)
	bench_waterfield_full_refill :: proc(t: ^testing.T) {
		world := new(World)
		defer free(world)
		testing.expect(t, world_init_seed(world, TERRAIN_SEED), "bench_waterfield_full_refill: init")
		defer world_deinit(world)
		bench_world = world
		_bench("waterfield full refill 1921x1921", proc() {
			waterfield_terrain_changed(bench_world)
		})
		testing.expect(t, bench_world.waterfield.revision > 0, "bench_waterfield_full_refill: no run")
	}
}
