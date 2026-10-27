# shellcheck shell=bash
# User-only Nautilus integration. The external copy also survives plugin removal.
DISK_TILES_STATE="$STATE_DIR/disk-tiles"

disk_tiles_enabled() {
  [[ $(config_get '.modules["disk-tiles"].enabled // false') == true ]]
}

disk_tiles_apply() {
  if disk_tiles_enabled; then
    python3 "$TOOL_DIR/bin/disk-tiles.py" probe "$DISK_TILES_STATE" ||
      fail 'no se pudo activar Discos en mosaicos'
    mkdir -p -- "$DISK_TILES_STATE"
    install_uninstaller
    install -m 0644 -- "$TOOL_DIR/bin/disk-tiles.py" "$DISK_TILES_STATE/manage.py"
    python3 "$DISK_TILES_STATE/manage.py" enable "$DISK_TILES_STATE" "$TOOL_DIR/nautilus/disk_tiles.py" ||
      fail 'no se pudo activar Discos en mosaicos'
  elif [[ -f $DISK_TILES_STATE/manage.py ]]; then
    python3 "$DISK_TILES_STATE/manage.py" disable "$DISK_TILES_STATE" ||
      fail 'no se pudo desactivar Discos en mosaicos'
  fi
}

disk_tiles_status() {
  local enabled=false applied=false
  disk_tiles_enabled && enabled=true
  if [[ $enabled == true ]]; then
    if [[ -f $DISK_TILES_STATE/manage.py ]]; then
      python3 "$DISK_TILES_STATE/manage.py" check "$DISK_TILES_STATE" && applied=true
    fi
  elif [[ ! -d $DISK_TILES_STATE ]]; then
    applied=true
  fi
  jq -n --argjson enabled "$enabled" --argjson applied "$applied" \
    '{enabled:$enabled, applied:$applied, summary:(if $enabled then "Activado" else "Desactivado" end)}'
}

disk_tiles_enable() {
  # Verify before saving the enabled choice or writing integration files.
  python3 "$TOOL_DIR/bin/disk-tiles.py" probe "$DISK_TILES_STATE" ||
    fail 'no se pudo activar Discos en mosaicos'
  config_update '.modules["disk-tiles"].enabled = true'
  disk_tiles_apply
}

disk_tiles_disable() {
  config_update '.modules["disk-tiles"].enabled = false'
  disk_tiles_apply
}
