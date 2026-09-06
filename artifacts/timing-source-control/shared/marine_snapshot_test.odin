package shared

import "core:testing"

@(test)
marine_snapshot_roundtrip_continuation_and_rejection :: proc(t: ^testing.T) {
	first, restored: Marine_Ecology
	testing.expect(t, marine_ecology_init(&first, 54019, context.allocator, 1))
	testing.expect(t, marine_ecology_init(&restored, 0, context.allocator, 1))
	defer marine_ecology_deinit(&first)
	defer marine_ecology_deinit(&restored)
	marine_seed_cell(&first.cells[0], 1000000)
	first.initial_mass = 1000000
	forcing := [1]Ecology_Environment{{water_depth_mm = 10000, surface_par = 1000, temperature_mk = 290000, dissolved_oxygen = 1000}}
	testing.expect(t, marine_ecology_advance_fixture(&first, forcing[:], 500))
	buffer := make([]u8, marine_ecology_snapshot_size(&first))
	defer delete(buffer)
	written, ok := marine_ecology_snapshot_write(&first, buffer)
	testing.expect(t, ok && written == len(buffer))
	testing.expect(t, marine_ecology_snapshot_read(&restored, buffer))
	testing.expect(t, first.cells[0] == restored.cells[0])
	testing.expect(t, marine_ecology_advance_fixture(&first, forcing[:], 500))
	testing.expect(t, marine_ecology_advance_fixture(&restored, forcing[:], 500))
	testing.expect(t, first.cells[0] == restored.cells[0] && first.birth_serial == restored.birth_serial)
	testing.expect(t, first.lineage_count == restored.lineage_count)
	for lineage, index in first.lineages[:first.lineage_count] do testing.expect(t, lineage == restored.lineages[index])
	before := restored.cells[0]
	testing.expect(t, !marine_ecology_snapshot_read(&restored, buffer[:len(buffer)-1]))
	buffer[len(buffer)-1] = 255
	testing.expect(t, !marine_ecology_snapshot_read(&restored, buffer))
	testing.expect(t, restored.cells[0] == before)
}
