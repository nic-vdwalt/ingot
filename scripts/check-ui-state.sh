#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
patterns='default_text_system|default_spell_system|active_runtime|active_frame|legacy_text_system|module_ivl|module_spell_memo|module_spell_menu|pane_origin_x|sync_legacy_metrics|^[[:space:]]*theme:[[:space:]]*Theme|^[[:space:]]*(sc|scf)[[:space:]]*::[[:space:]]*proc'
if grep -R -n -E --include='*.odin' "$patterns" "$root/ui"; then
	echo "forbidden ambient UI state found" >&2
	exit 1
fi
