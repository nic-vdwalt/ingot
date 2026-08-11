#!/usr/bin/env bash
set -euo pipefail

example_root="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$example_root/../.." && pwd)"
build_dir="$example_root/build"
host="$example_root/ingot_hot_reload.bin"
collection="-collection:ingot=$repo_root"

case "$(uname -s)" in
Darwin) library_extension=".dylib" ;;
Linux) library_extension=".so" ;;
*)
	echo "hot_reload: build.sh supports macOS and Linux" >&2
	exit 1
	;;
esac

mkdir -p "$build_dir"
echo "Building game$library_extension"
odin build "$example_root/game" "$collection" -build-mode:dll \
	"-out:$build_dir/game_tmp$library_extension" -debug -vet -strict-style -vet-shadowing
mv "$build_dir/game_tmp$library_extension" "$build_dir/game$library_extension"

if pgrep -f "$(basename "$host")" >/dev/null; then
	echo "Hot reloading..."
	exit 0
fi

echo "Building $(basename "$host")"
odin build "$example_root/host" "$collection" "-out:$host" \
	-debug -vet -strict-style -vet-shadowing

if [[ "${1:-}" == "run" ]]; then
	echo "Running $(basename "$host")"
	"$host" &
fi
