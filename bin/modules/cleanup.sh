# shellcheck shell=bash
# Module: cleanup. Removes what the user confirms on its page, one category at a
# time, and leaves nothing behind but the cache folders they marked, in the config.
# Nothing runs in the background and nothing is switched on, so it has no apply.
#
# bin/cleanup.py finds things and deletes what the user owns. What needs a password
# is here: only system binaries with fixed arguments, never a script of ours as root.

cleanup_status() {
  printf '%s\n' '{"enabled":true,"applied":true,"summary":"Limpieza manual del sistema"}'
}

cleanup_helper() {
  python3 "$TOOL_DIR/bin/cleanup.py" "$@"
}

# The helper's error, in the user's language.
cleanup_error() {
  local message
  message=$(jq -r '.error // empty' <<<"$1" 2>/dev/null || true)
  tool_text "${message:-no se pudo completar la limpieza}"
}

cleanup_list() {
  cleanup_helper list
}

# cleanup cache-mark NAMES_JSON on|off
cleanup_cache_mark() {
  local names=${1:-} state=${2:-} output
  case $state in
    on | off) ;;
    *) fail "$(tool_text 'usa on u off')" ;;
  esac
  output=$(cleanup_helper validate-cache "$names") || fail "$(cleanup_error "$output")"
  names=$(jq -c .names <<<"$output")
  if [[ $state == on ]]; then
    config_update '.modules.cleanup.cacheMarked = (((.modules.cleanup.cacheMarked // []) + $names) | unique)' --argjson names "$names"
  else
    config_update '.modules.cleanup.cacheMarked = ((.modules.cleanup.cacheMarked // []) - $names)' --argjson names "$names"
  fi
}

# The panel may have closed meanwhile, so the outcome always ends in a notification.
cleanup_report() {
  local result=$1 freed skipped names message
  freed=$(jq -r '.freedBytes' <<<"$result" | numfmt --to=iec --suffix=B)
  skipped=$(jq -r '.skippedCount' <<<"$result")
  names=$(jq -r '.skippedNames[:5] | join(", ")' <<<"$result")
  message=$(tool_text 'Limpieza terminada: se liberaron %1.' "$freed")
  if ((skipped > 0)); then
    message+=" $(tool_text 'Se omitieron %1, en uso o sin permiso.' "$skipped")"
    [[ -z $names ]] || message+=" $names"
  fi
  operation_notice normal "$message"
}

cleanup_refuse() {
  operation_notice critical "$1"
  fail "$1"
}

# What the cleanup removes is decided here, again, whatever the page showed: its
# only say on packages is the revision, which must match what pacman answers now.
cleanup_system_clean() {
  local category=$1 revision=${2:-} plan output status=0 packages=()
  if [[ $category == orphans && -z $revision ]]; then
    cleanup_refuse "$(tool_text 'los paquetes huérfanos cambiaron; vuelve a revisarlos')"
  fi
  plan=$(cleanup_helper prepare "$category" "$revision") || cleanup_refuse "$(cleanup_error "$plan")"
  if [[ $(jq -r .count <<<"$plan") == 0 ]]; then
    operation_notice normal "$(tool_text 'No hay nada que limpiar.')"
    return 0
  fi
  case $category in
    paccache) privileged /usr/bin/paccache -rk3 >/dev/null 2>&1 || status=$? ;;
    journal) privileged /usr/bin/journalctl --rotate --vacuum-size=50M >/dev/null 2>&1 || status=$? ;;
    coredumps) privileged /usr/bin/find /var/lib/systemd/coredump -mindepth 1 -maxdepth 1 -type f -delete >/dev/null 2>&1 || status=$? ;;
    orphans)
      mapfile -t packages < <(jq -r '.packages[]' <<<"$plan")
      privileged /usr/bin/pacman -Rns --noconfirm "${packages[@]}" >/dev/null 2>&1 || status=$?
      ;;
  esac
  if ((status != 0)); then
    cleanup_refuse "$(tool_text 'No se pudo completar %1. Puede faltar la contraseña.' "$(tool_text 'Limpieza')")"
  fi
  output=$(cleanup_helper finish <<<"$plan") || cleanup_refuse "$(cleanup_error "$output")"
  cleanup_report "$output"
}

# cleanup clean tmp | cache NAMES_JSON | paccache | coredumps | journal | orphans REVISION
cleanup_clean() {
  local category=${1:-} selection=${2:-} output
  case $category in
    tmp)
      output=$(cleanup_helper clean tmp) || cleanup_refuse "$(cleanup_error "$output")"
      cleanup_report "$output"
      ;;
    cache)
      # Only what the switches marked, even if something else is asked for.
      if ! jq -e --argjson marked "$(config_get '.modules.cleanup.cacheMarked // []' -c)" \
        'type == "array" and length > 0 and (. - $marked | length == 0)' <<<"$selection" >/dev/null 2>&1; then
        cleanup_refuse "$(tool_text 'carpeta de caché no válida')"
      fi
      output=$(cleanup_helper clean cache "$selection") || cleanup_refuse "$(cleanup_error "$output")"
      cleanup_report "$output"
      ;;
    paccache | coredumps | journal | orphans) cleanup_system_clean "$category" "$selection" ;;
    *) fail "$(tool_text 'acción de limpieza no válida')" ;;
  esac
}
