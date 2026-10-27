# shellcheck shell=bash
# Module: exe-icons. Only the system copy needs privilege; user registration
# and failed-thumbnail cache cleanup stay in the logged-in user's session.
EXE_ICONS_BIN="${OMARCHY_TOOL_EXE_BIN_DIR:-/usr/local/bin}"
EXE_ICONS_FILE="$EXE_ICONS_BIN/omarchy-tool-exe-thumbnailer"
EXE_ICONS_THUMBNAILERS="${OMARCHY_TOOL_THUMBNAILERS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/thumbnailers}"
EXE_ICONS_ENTRY="$EXE_ICONS_THUMBNAILERS/omarchy-tool-exe.thumbnailer"

exe_icons_enabled() {
  [[ $(config_get '.modules["exe-icons"].enabled // false') == true ]]
}

exe_icons_installed() {
  local owner=0
  # Scratch installs are deliberately unprivileged, like the udev tests.
  if ((EUID != 0)) && [[ -n ${OMARCHY_TOOL_EXE_BIN_DIR:-} ]]; then
    owner=$EUID
  fi
  [[ -f $EXE_ICONS_FILE && ! -L $EXE_ICONS_FILE &&
     $(stat -c %u -- "$EXE_ICONS_FILE") == "$owner" &&
     $(stat -c %a -- "$EXE_ICONS_FILE") == 755 ]] &&
    cmp -s -- "$TOOL_DIR/bin/exe-thumbnailer" "$EXE_ICONS_FILE"
}

exe_icons_adoptable() {
  bash "$TOOL_DIR/bin/exe-icons.sh" adoptable "$EXE_ICONS_THUMBNAILERS/exe.thumbnailer"
}

exe_icons_apply() {
  local adopt=false
  if exe_icons_enabled; then
    mkdir -p -- "$STATE_DIR"
    install_helper_i18n
    install -m 0644 -- "$TOOL_DIR/bin/exe-icons.sh" "$STATE_DIR/exe-icons.sh"
    install -m 0644 -- "$TOOL_DIR/bin/exe-thumbnailer" "$STATE_DIR/exe-thumbnailer"
    exe_icons_adoptable && adopt=true
    if ! exe_icons_installed || [[ $adopt == true ]]; then
      privileged /usr/bin/bash "$STATE_DIR/exe-icons.sh" install "$EXE_ICONS_THUMBNAILERS/exe.thumbnailer" ||
        fail 'no se pudieron instalar los iconos de .exe'
    fi
    mkdir -p -- "$EXE_ICONS_THUMBNAILERS"
    cat >"$EXE_ICONS_ENTRY" <<EOF
[Thumbnailer Entry]
TryExec=$EXE_ICONS_FILE
Exec=$EXE_ICONS_FILE %i %o %s
MimeType=application/x-ms-dos-executable;application/vnd.microsoft.portable-executable;application/x-msdownload;application/x-msi;
EOF
    python3 "$TOOL_DIR/bin/exe-fail-cache.py" "${XDG_CACHE_HOME:-$HOME/.cache}/thumbnails/fail/gnome-thumbnail-factory"
  else
    if [[ -e $EXE_ICONS_FILE || -L $EXE_ICONS_FILE || -f $STATE_DIR/exe-icons.icoutils-installed ]]; then
      mkdir -p -- "$STATE_DIR"
      install_helper_i18n
      install -m 0644 -- "$TOOL_DIR/bin/exe-icons.sh" "$STATE_DIR/exe-icons.sh"
      privileged /usr/bin/bash "$STATE_DIR/exe-icons.sh" remove ||
        fail 'no se pudieron quitar los iconos de .exe'
    fi
    rm -f -- "$EXE_ICONS_ENTRY" "$STATE_DIR/exe-icons.sh" "$STATE_DIR/exe-thumbnailer" "$STATE_DIR/exe-icons.icoutils-installed"
  fi
}

exe_icons_status() {
  local enabled=false applied=false
  exe_icons_enabled && enabled=true
  if [[ $enabled == true ]]; then
    exe_icons_installed && applied=true
  elif [[ ! -e $EXE_ICONS_FILE && ! -L $EXE_ICONS_FILE && ! -f $STATE_DIR/exe-icons.icoutils-installed ]]; then
    applied=true
  fi
  jq -n --argjson enabled "$enabled" --argjson applied "$applied" \
    '{enabled: $enabled, applied: $applied, summary: (if $enabled then "Activado" else "Desactivado" end)}'
}

exe_icons_enable() {
  config_update '.modules["exe-icons"].enabled = true'
  exe_icons_apply
}

exe_icons_disable() {
  config_update '.modules["exe-icons"].enabled = false'
  exe_icons_apply
}
