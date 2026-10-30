# shellcheck shell=bash
# Module: proton-saves. Its switch in Extras is the automatic copy at startup, which
# needs a folder the user chose. Saving and loading work without it: they are the
# exe-proton module's saves-* actions, and the copy itself is exe_proton_startup.

proton_saves_status() {
  local enabled=false
  [[ $(config_get '.modules["exe-proton"].savesAuto // false') == true ]] && enabled=true
  jq -n --argjson enabled "$enabled" \
    '{enabled: $enabled, applied: true, summary: (if $enabled then "Activado" else "Desactivado" end)}'
}

proton_saves_enable() {
  [[ -n $(config_get '.modules["exe-proton"].savesFolder // ""' -r) ]] ||
    fail "$(tool_text 'Primero elige la carpeta donde se guardarán las copias: entra en Copias de Proton y pulsa Aplicar.')"
  config_update '.modules["exe-proton"].savesAuto = true'
}

proton_saves_disable() {
  config_update '.modules["exe-proton"].savesAuto = false'
}
