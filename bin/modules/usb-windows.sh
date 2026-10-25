# shellcheck shell=bash
# Module: usb-windows
#
# Hands chosen USB devices to Omarchy's Windows VM while it runs, so their
# Windows-only apps (Glorious CORE, iCUE, ...) can see them. dockurr/windows
# documents this as "-device usb-host,vendorid=...,productid=..." in ARGUMENTS
# plus /dev/bus/usb in devices; compose_sync (bin/omarchy-tool) writes both
# through bin/compose-edit.sh under pkexec. While Windows is open, Linux loses
# those devices; they come back when the VM stops. Changes reach Windows the
# next time it starts.

USB_WINDOWS_SYS="${OMARCHY_TOOL_USB_SYS:-/sys/bus/usb/devices}"
USB_WINDOWS_MAX=4

usb_windows_enabled() {
  [[ $(config_get '.modules["usb-windows"].enabled // false') == true ]]
}

usb_windows_valid_id() {
  [[ $1 =~ ^[0-9a-f]{4}:[0-9a-f]{4}$ ]]
}

# Connected USB devices, hubs left out, one per vendor:product, as JSON.
usb_windows_connected_json() {
  local dev id name rows=''
  for dev in "$USB_WINDOWS_SYS"/*; do
    [[ -f $dev/idVendor && -f $dev/idProduct ]] || continue
    [[ $(cat "$dev/bDeviceClass" 2>/dev/null) == 09 ]] && continue
    id="$(<"$dev/idVendor"):$(<"$dev/idProduct")"
    name="$(cat "$dev/manufacturer" 2>/dev/null) $(cat "$dev/product" 2>/dev/null)"
    rows+=$(jq -cn --arg id "${id,,}" --arg name "$name" \
      '{id: $id, name: ($name | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ") | if . == "" then $id else . end)}')$'\n'
  done
  jq -cs 'unique_by(.id)' <<<"$rows"
}

usb_windows_desired() {
  usb_windows_enabled || return 0
  config_get -r '.modules["usb-windows"].devices // [] | .[] | .id' | head -n "$USB_WINDOWS_MAX"
}

usb_windows_compose_args() {
  usb_windows_desired | sed 's/^/--usb /'
}

usb_windows_apply() {
  compose_sync || fail "no se pudo cambiar la configuración de Windows"
}

usb_windows_status() {
  local enabled=false installed=false applied=false connected devices
  usb_windows_enabled && enabled=true
  [[ -f $COMPOSE_FILE ]] && installed=true
  compose_in_sync --usb && applied=true
  connected=$(usb_windows_connected_json)
  devices=$(config_get -c '.modules["usb-windows"].devices // []')
  jq -n --argjson enabled "$enabled" --argjson installed "$installed" --argjson applied "$applied" \
    --argjson connected "$connected" --argjson devices "$devices" --argjson max "$USB_WINDOWS_MAX" \
    '{enabled: $enabled, vmInstalled: $installed, applied: $applied, max: $max,
      devices: [$devices[] | . as $d | . + {connected: any($connected[]; .id == $d.id)}],
      candidates: [$connected[] | . as $c | . + {selected: any($devices[]; .id == $c.id)}],
      summary: (if ($installed | not) then "Windows no está instalado"
        elif $enabled then ($devices | length | tostring) + " en Windows" else "Desactivado" end)}'
}

usb_windows_enable() {
  config_update '.modules["usb-windows"].enabled = true'
  usb_windows_apply
}

usb_windows_disable() {
  config_update '.modules["usb-windows"].enabled = false'
  usb_windows_apply
}

# add <vvvv:pppp> [name]
usb_windows_add() {
  local id=${1:-} name=${2:-} count
  id=${id,,}
  usb_windows_valid_id "$id" || fail "usage: omarchy-tool usb-windows add <vvvv:pppp> [name]"
  count=$(config_get '[.modules["usb-windows"].devices // [] | .[] | select(.id != $id)] | length' --arg id "$id")
  ((count < USB_WINDOWS_MAX)) || fail "máximo $USB_WINDOWS_MAX dispositivos; quita uno antes"
  if [[ -z $name ]]; then
    name=$(usb_windows_connected_json | jq -r --arg id "$id" '.[] | select(.id == $id) | .name')
  fi
  name=$(tr -cd '[:print:]' <<<"${name:-$id}" | head -c 64)
  config_update '.modules["usb-windows"].devices |= (. // [] |
      if any(.[]; .id == $id) then map(if .id == $id then .name = $name else . end)
      else . + [{id: $id, name: $name}] end)' \
    --arg id "$id" --arg name "$name"
  usb_windows_apply
}

# remove <vvvv:pppp>
usb_windows_remove() {
  local id=${1:-}
  id=${id,,}
  usb_windows_valid_id "$id" || fail "usage: omarchy-tool usb-windows remove <vvvv:pppp>"
  config_update '.modules["usb-windows"].devices |= (. // [] | map(select(.id != $id)))' --arg id "$id"
  usb_windows_apply
}
