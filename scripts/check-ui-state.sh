#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
patterns='default_text_system|default_spell_system|active_runtime|active_frame|legacy_text_system|module_ivl|module_spell_memo|module_spell_menu|pane_origin_x|sync_legacy_metrics|^[[:space:]]*theme:[[:space:]]*Theme|^[[:space:]]*(sc|scf)[[:space:]]*::[[:space:]]*proc'
if grep -R -n -E --include='*.odin' "$patterns" "$root/ui"; then
	echo "forbidden ambient UI state found" >&2
	exit 1
fi
if grep -R -n -E --include='*.odin' 'ingot:gfx|rl\.' "$root/ui"; then
	echo "forbidden gfx dependency found in ui" >&2
	exit 1
fi
# Tier guard: the facade tier is the bare-named ^Ui surface. A ui_-prefixed
# procedure that takes a ^Ui is the duplicate-tier rot this split removed, so
# fail the build rather than let the two naming schemes drift back apart.
if grep -R -n -E --include='*.odin' -A2 '^ui_[a-z_0-9]+ :: proc' "$root/ui" |
	grep -E 'u: \^Ui,|u: \^Ui\)'; then
	echo "forbidden ui_-prefixed facade procedure taking a ^Ui" >&2
	exit 1
fi
