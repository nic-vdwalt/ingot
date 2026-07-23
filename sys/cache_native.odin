#+build !js
package sys

import "core:fmt"
import "core:os"

cache_dir :: proc(app: string, allocator := context.temp_allocator) -> (dir: string, ok: bool) {
	assert(len(app) > 0, "cache_dir: empty app")
	when ODIN_OS == .Windows {
		if root := os.get_env("LOCALAPPDATA", allocator); len(root) > 0 {
			return fmt.aprintf("%s/%s", root, app, allocator = allocator), true
		}
	}
	home := os.get_env("HOME", allocator)
	if len(home) == 0 do home = os.get_env("USERPROFILE", allocator)
	when ODIN_OS == .Darwin {
		if len(home) == 0 do return "", false
		return fmt.aprintf("%s/Library/Caches/%s", home, app, allocator = allocator), true
	} else when ODIN_OS != .Windows {
		if root := os.get_env("XDG_CACHE_HOME", allocator); len(root) > 0 {
			return fmt.aprintf("%s/%s", root, app, allocator = allocator), true
		}
	}
	if len(home) == 0 do return "", false
	return fmt.aprintf("%s/.cache/%s", home, app, allocator = allocator), true
}
