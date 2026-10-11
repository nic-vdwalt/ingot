#!/usr/bin/env bash
# Build and run tools/odingate, the Odin-source gate, from the shell launchers.
#
# ingot_build_odingate <root> [odin flags...]
#   Builds tools/odingate once per gate run into a scratch directory and
#   exports INGOT_ODINGATE with the binary path. Extra arguments are passed to
#   odin build (the launchers forward their own flags, e.g. -define:...).
#
# ingot_odingate_files <root>
#   Writes `git ls-files '*.odin'` to a scratch file and prints its path. The
#   gate never shells out to git itself, so the file list is owned here.

ingot_build_odingate() {
	local root="$1"
	shift
	local out_dir="${TMPDIR:-/tmp}/ingot-odingate"
	mkdir -p "$out_dir"
	INGOT_ODINGATE="$out_dir/odingate"
	export INGOT_ODINGATE
	echo "== building tools/odingate =="
	# ingot_odin (scripts/odin-toolchain.sh) retries a compiler that died from a
	# signal; a consumer that sources only this file still gets a plain build.
	local runner=odin
	if declare -F ingot_odin >/dev/null; then
		runner=ingot_odin
	fi
	"$runner" build "$root/tools/odingate" "-collection:ingot=$root" "-out:$INGOT_ODINGATE" "$@"
}

ingot_odingate_files() {
	local root="$1"
	local list="${TMPDIR:-/tmp}/ingot-odingate/files.txt"
	mkdir -p "$(dirname "$list")"
	(cd "$root" && git ls-files '*.odin') >"$list"
	printf '%s\n' "$list"
}
