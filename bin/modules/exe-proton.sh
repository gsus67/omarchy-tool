# shellcheck shell=bash
# Module: exe-proton. Package privilege is separate from all user-session work.
EXE_PROTON_STATE="$STATE_DIR/exe-proton"
EXE_PROTON_ENTRY="${OMARCHY_TOOL_APPLICATIONS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/applications}/omarchy-tool-run-exe.desktop"

exe_proton_enabled() {
  [[ $(config_get '.modules["exe-proton"].enabled // false') == true ]]
}

exe_proton_adoptable() {
  python3 "$TOOL_DIR/bin/exe-proton-mime.py" adoptable "$EXE_PROTON_STATE"
}

exe_proton_apply() {
  local compat version present=false
  if ! exe_proton_enabled; then
    if [[ -d $EXE_PROTON_STATE ]]; then
      bash "$EXE_PROTON_STATE/cleanup.sh" || fail 'no se pudo desactivar Proton'
    fi
    return 0
  fi
  mkdir -p -- "$EXE_PROTON_STATE"
  install_uninstaller
  install -m 0644 -- "$TOOL_DIR/bin/exe-proton.sh" "$EXE_PROTON_STATE/package.sh"
  install -m 0644 -- "$TOOL_DIR/bin/exe-proton-mime.py" "$EXE_PROTON_STATE/mime.py"
  install -m 0644 -- "$TOOL_DIR/bin/exe-proton-cleanup.sh" "$EXE_PROTON_STATE/cleanup.sh"
  install -m 0644 -- "$TOOL_DIR/bin/exe-proton-prepare.sh" "$EXE_PROTON_STATE/prepare.sh"
  install -m 0755 -- "$TOOL_DIR/bin/run-exe.sh" "$EXE_PROTON_STATE/run-exe"
  if ! pacman -Q umu-launcher >/dev/null 2>&1; then
    privileged /usr/bin/bash "$EXE_PROTON_STATE/package.sh" install || fail 'no se pudo instalar umu-launcher'
  fi
  python3 "$EXE_PROTON_STATE/mime.py" apply "$EXE_PROTON_STATE" || fail 'no se pudieron configurar los tipos MIME de Windows'

  # umu's GE-Proton token installs versioned builds in Steam's directory;
  # newer umu tool aliases can also live in umu/compatibilitytools.
  if [[ ! -f $EXE_PROTON_STATE/compat-dirs ]]; then
    compat="${UMU_FOLDERS_PATH:-${XDG_DATA_HOME:-$HOME/.local/share}}"
    printf '%s\n' "$compat/umu/compatibilitytools" "$compat/Steam/compatibilitytools.d" >"$EXE_PROTON_STATE/compat-dirs"
  fi
  while IFS= read -r compat; do
    for version in "$compat"/GE-Proton*; do
      [[ -d $version ]] && present=true
    done
  done <"$EXE_PROTON_STATE/compat-dirs"
  if [[ $present == false && ! -f $EXE_PROTON_STATE/queued ]]; then
    touch -- "$EXE_PROTON_STATE/queued"
    if ! systemd-run --user --collect --no-block --unit=omarchy-tool-exe-proton-prepare \
      --property=KillMode=control-group --expand-environment=no \
      --setenv="HOME=$HOME" --setenv="PATH=$PATH" \
      --setenv="XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}" \
      --setenv="XDG_CACHE_HOME=${XDG_CACHE_HOME:-$HOME/.cache}" \
      --setenv="UMU_FOLDERS_PATH=${UMU_FOLDERS_PATH:-${XDG_DATA_HOME:-$HOME/.local/share}}" \
      --setenv="LANG=${LANG:-en}" --setenv="LC_ALL=${LC_ALL:-}" --setenv="LC_MESSAGES=${LC_MESSAGES:-}" \
      /usr/bin/bash "$EXE_PROTON_STATE/prepare.sh" "$HOME/.local/share/umu/default"; then
      rm -f -- "$EXE_PROTON_STATE/queued"
      fail 'no se pudo iniciar la preparación de GE-Proton'
    fi
  fi
}

exe_proton_status() {
  local enabled=false applied=false
  exe_proton_enabled && enabled=true
  if [[ $enabled == true ]]; then
    if [[ -x $EXE_PROTON_STATE/run-exe && -f $EXE_PROTON_ENTRY && -f $EXE_PROTON_STATE/defaults.json ]] &&
      pacman -Q umu-launcher >/dev/null 2>&1; then
      applied=true
    fi
  elif [[ ! -d $EXE_PROTON_STATE && ! -e $EXE_PROTON_ENTRY ]]; then
    applied=true
  fi
  jq -n --argjson enabled "$enabled" --argjson applied "$applied" \
    '{enabled: $enabled, applied: $applied, summary: (if $enabled then "Activado" else "Desactivado" end)}'
}

exe_proton_enable() {
  config_update '.modules["exe-proton"].enabled = true'
  exe_proton_apply
}

exe_proton_disable() {
  config_update '.modules["exe-proton"].enabled = false'
  exe_proton_apply
}
