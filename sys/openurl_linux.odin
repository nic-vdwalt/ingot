// open_url (Linux): launch the default browser via xdg-open.
package sys

import "core:os"
import "core:time"

open_url :: proc(url: string) {
	// argv spawn (no shell) so URLs/paths with quotes or spaces can't be
	// misinterpreted or injected into a shell command line.
	p, err := os.process_start({command = {"xdg-open", url}})
	if err == nil {
		// xdg-open hands off to the browser and exits almost immediately; reap
		// with a short timeout so the child doesn't linger as a zombie.
		_, _ = os.process_wait(p, time.Second)
	}
}
