#!/bin/bash
# Detached user-session preparation, owned and stopped by a transient unit.
set -euo pipefail
helper_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$helper_dir/../i18n.sh"
export WINEPREFIX=$1 GAMEID=umu-default PROTONPATH=GE-Proton
# Record only new GE-Proton versions, including a completed download followed
# by a failed wineboot. Never include the Wine prefix in this inventory.
record_downloads() {
  local compat version
  while IFS= read -r compat; do
    for version in "$compat"/GE-Proton*; do
      [[ -d $version && ! -L $version ]] || continue
      printf '%s\n' "$version"
    done
  done <"$helper_dir/compat-dirs"
}
# The caller skips preparation if a GE-Proton version exists in either dir.
# Check again: another application may have installed one before we started.
if [[ -n $(record_downloads) ]]; then
  touch -- "$helper_dir/prepared"
  exit 0
fi
trap 'record_downloads >"$helper_dir/downloaded"' EXIT
notify-send -i wine "$(tool_text 'Preparando GE-Proton…')" 2>/dev/null || true
log="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-tool-proton-prepare.log"
mkdir -p -- "$(dirname -- "$log")"
if umu-run wineboot -u >"$log" 2>&1; then
  touch -- "$helper_dir/prepared"
  notify-send -i wine "$(tool_text 'Listo: ya puedes abrir .exe con doble clic')" 2>/dev/null || true
else
  notify-send -u critical -i dialog-error "$(tool_text 'No se pudo preparar GE-Proton')" \
    "$(tool_text 'Consulta el registro: %1' "$log")" 2>/dev/null || true
  exit 1
fi
