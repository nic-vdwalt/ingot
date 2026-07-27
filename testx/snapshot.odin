package testx

// log is used only under `when UPDATE_SNAPSHOTS`; @(require) keeps the import
// from tripping the -strict-style unused-import check in normal builds.
@(require) import "core:log"
import "core:testing"

// Set with -define:ODIN_TEST_UPDATE_SNAPSHOTS=true to print actual output for
// manual paste-back. Odin cannot rewrite source, so update is print-only.
UPDATE_SNAPSHOTS :: #config(ODIN_TEST_UPDATE_SNAPSHOTS, false)

// snap compares actual against an inline expected block, failing with a diff.
snap :: proc(t: ^testing.T, actual, expected: string, loc := #caller_location) {
	assert(t != nil, "snap: nil t")
	when UPDATE_SNAPSHOTS {
		log.infof("[snapshot @ %v]\n%s", loc, actual)
	} else {
		testing.expectf(
			t,
			actual == expected,
			"snapshot mismatch at %v\n--- expected ---\n%s\n--- actual ---\n%s",
			loc,
			expected,
			actual,
		)
	}
}
