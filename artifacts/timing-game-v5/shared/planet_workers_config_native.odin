#+build !js
package shared

import "core:os"
import "core:strconv"

// PLANETFORGER_PLANET_WORKERS overrides the planetary worker team size for
// profiling experiments (0 runs every planetary job inline on the calling
// thread). Absent or invalid, the team uses PLANET_WORKERS_MAX.
PLANET_WORKERS_ENV :: "PLANETFORGER_PLANET_WORKERS"

planet_workers_default_count :: proc() -> int {
	text := os.get_env(PLANET_WORKERS_ENV, context.temp_allocator)
	if len(text) == 0 do return PLANET_WORKERS_MAX
	count, ok := strconv.parse_int(text)
	if !ok do return PLANET_WORKERS_MAX
	return clamp(count, 0, PLANET_WORKERS_MAX)
}
