#!/bin/bash
# User-session runner; keep the manual setup's prefix and environment overrides.
set -uo pipefail
helper_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$helper_dir/../i18n.sh"
export WINEPREFIX="${WINEPREFIX:-$HOME/.local/share/umu/default}"
export GAMEID="${GAMEID:-umu-default}"
export PROTONPATH="${PROTONPATH:-GE-Proton}"
[[ -n ${1:-} ]] || exit 1
file=$(realpath -m -- "$1")
log="${XDG_CACHE_HOME:-$HOME/.cache}/run-exe.log"
mkdir -p -- "$(dirname -- "$log")"
cd -- "$(dirname -- "$file")" || exit 1
name=$(basename -- "$file")
notify-send -i wine "$(tool_text 'Ejecutando con Proton')" "$name" 2>/dev/null || true
case ${file,,} in
  *.msi) umu-run msiexec /i "$file" >"$log" 2>&1 ;;
  *) umu-run "$file" >"$log" 2>&1 ;;
esac
rc=$?
if ((rc != 0)); then
  notify-send -u critical -i dialog-error "$(tool_text 'Falló: %1' "$name")" \
    "$(tool_text 'Código %1. Log: %2' "$rc" "$log")" 2>/dev/null || true
fi
exit "$rc"
