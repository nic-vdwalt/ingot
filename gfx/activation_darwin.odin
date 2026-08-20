#+build darwin
package gfx

import NS "core:sys/darwin/Foundation"

@(private)
_platform_activate_application :: proc() {
	application := NS.Application_sharedApplication()
	if application == nil do return
	NS.Application_activateIgnoringOtherApps(application, true)
}
