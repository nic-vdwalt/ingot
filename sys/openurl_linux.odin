// open_url (Linux): launch the default browser via xdg-open.
package sys

import "core:os"
import "core:time"

open_url :: proc(
	url: string,
	options: Open_URL_Options = {allow_http = true, allow_https = true},
) -> Open_URL_Status {
	validated, status := _validate_external_url(url, options)
	if status != .Opened do return status
	p, err := os.process_start({command = {"xdg-open", validated}})
	if err != nil do return .Failed
	state, wait_err := os.process_wait(p, time.Second)
	if wait_err != nil || !state.exited || state.exit_code != 0 do return .Failed
	return .Opened
}
