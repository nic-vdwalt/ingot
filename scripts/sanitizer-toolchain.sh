#!/usr/bin/env bash
# Source this file, then call ingot_use_sanitizer_clang before an
# `odin build`/`odin test` that passes -sanitize:address or -sanitize:thread.
#
# Odin instruments code with its own LLVM but links through the `clang` on
# PATH. On macOS that is Apple clang, whose sanitizer runtime exports an
# Apple-specific ABI check (___asan_version_mismatch_check_apple_clang_*), so
# objects instrumented by upstream LLVM fail to link against it. Linking with
# the upstream clang whose major version matches Odin's LLVM pairs the
# instrumentation with the runtime it was built for.
#
# Override the search with INGOT_SANITIZER_CLANG_DIR=<dir containing clang>.

ingot_odin_llvm_major() {
	odin report 2>/dev/null |
		sed -n 's/^[[:space:]]*Backend:[[:space:]]*LLVM[[:space:]]*\([0-9][0-9]*\)\..*/\1/p' |
		head -n 1
}

ingot_clang_major() {
	"$1/clang" --version 2>/dev/null |
		sed -n 's/.*clang version \([0-9][0-9]*\)\..*/\1/p' |
		head -n 1
}

ingot_use_sanitizer_clang() {
	[ "$(uname -s)" = "Darwin" ] || return 0
	if ! clang --version 2>/dev/null | grep -q "^Apple clang"; then
		return 0
	fi
	local major
	major="$(ingot_odin_llvm_major)"
	if [ -z "$major" ]; then
		echo "sanitizer: could not read Odin's LLVM version from 'odin report'" >&2
		return 1
	fi
	local candidates=()
	if [ -n "${INGOT_SANITIZER_CLANG_DIR:-}" ]; then
		candidates+=("$INGOT_SANITIZER_CLANG_DIR")
	fi
	if command -v brew >/dev/null 2>&1; then
		local prefix
		prefix="$(brew --prefix "llvm@$major" 2>/dev/null || true)"
		if [ -n "$prefix" ]; then
			candidates+=("$prefix/bin")
		fi
	fi
	candidates+=("/opt/homebrew/opt/llvm@$major/bin" "/usr/local/opt/llvm@$major/bin")
	local dir
	for dir in "${candidates[@]}"; do
		if [ -x "$dir/clang" ] && [ "$(ingot_clang_major "$dir")" = "$major" ]; then
			export PATH="$dir:$PATH"
			return 0
		fi
	done
	echo "sanitizer: Odin uses LLVM $major, but no clang $major was found to link with." >&2
	echo "sanitizer: Apple clang's sanitizer runtime rejects upstream-LLVM objects." >&2
	echo "sanitizer: install it with 'brew install llvm@$major', set" >&2
	echo "sanitizer: INGOT_SANITIZER_CLANG_DIR to its bin directory, or use SAN=none." >&2
	return 1
}
