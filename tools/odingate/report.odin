package odingate

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

// A gate finding. Messages are the exact strings the Python guards printed so
// that CI logs, docs, and baselines stay valid across the port.
Finding :: struct {
	path:    string,
	line:    int,
	message: string,
	raw:     bool, // print the message alone; it already names its location
}

Report :: struct {
	findings: [dynamic]Finding,
}

report_add :: proc(report: ^Report, path: string, line: int, message: string) {
	assert(report != nil, "report_add: nil report")
	assert(message != "", "report_add: empty message")
	append(&report.findings, Finding{path, line, message, false})
}

report_addf :: proc(report: ^Report, path: string, line: int, format: string, args: ..any) {
	report_add(report, path, line, fmt.aprintf(format, ..args))
}

// report_add_raw records a finding whose message is printed verbatim, for
// guards whose Python output keyed on `path:proc` rather than `path:line`.
report_add_raw :: proc(report: ^Report, path: string, line: int, message: string) {
	assert(report != nil, "report_add_raw: nil report")
	assert(message != "", "report_add_raw: empty message")
	append(&report.findings, Finding{path, line, message, true})
}

report_addf_raw :: proc(report: ^Report, path: string, line: int, format: string, args: ..any) {
	report_add_raw(report, path, line, fmt.aprintf(format, ..args))
}

finding_text :: proc(finding: Finding, allocator := context.allocator) -> string {
	if finding.raw do return finding.message
	return fmt.aprintf(
		"%s:%d: %s",
		finding.path,
		finding.line,
		finding.message,
		allocator = allocator,
	)
}

@(private = "file")
finding_less :: proc(a, b: Finding) -> bool {
	if a.path != b.path do return a.path < b.path
	if a.line != b.line do return a.line < b.line
	return a.message < b.message
}

// report_sort orders findings by (path, line, message) so output is stable
// regardless of walk order.
report_sort :: proc(report: ^Report) {
	assert(report != nil, "report_sort: nil report")
	slice.sort_by(report.findings[:], finding_less)
}

// report_emit prints `{path}:{line}: {message}` per finding and returns the
// gate exit code: EXIT_FINDINGS when anything was reported, else EXIT_OK.
report_emit :: proc(report: ^Report, file: ^os.File) -> int {
	assert(report != nil, "report_emit: nil report")
	assert(file != nil, "report_emit: nil file")
	report_sort(report)
	for finding in report.findings {
		fmt.fprintln(file, finding_text(finding, context.temp_allocator))
	}
	return len(report.findings) > 0 ? EXIT_FINDINGS : EXIT_OK
}

// report_messages joins the sorted findings into one string, for tests that
// compare against the Python scripts' expected output verbatim.
report_messages :: proc(report: ^Report, allocator := context.allocator) -> []string {
	assert(report != nil, "report_messages: nil report")
	report_sort(report)
	lines := make([]string, len(report.findings), allocator)
	for finding, index in report.findings {
		lines[index] = finding_text(finding, allocator)
	}
	return lines
}

report_has_message :: proc(report: ^Report, needle: string) -> bool {
	assert(report != nil, "report_has_message: nil report")
	for finding in report.findings {
		if strings.contains(finding.message, needle) do return true
	}
	return false
}
