# shellcheck shell=bash
# Module: usb-windows
#
# Lets chosen USB devices be handed to Omarchy's Windows VM, so their
# Windows-only apps (Glorious CORE, iCUE, ...) can see them. Switched on, the
# VM gets /dev/bus/usb (compose_sync in bin/omarchy-tool writes it through
# bin/compose-edit.sh under pkexec; it takes effect when Windows next starts),
# but every device stays in Linux until the user moves it.
#
# While Windows runs, `move linux|windows <id>` hands a device over to Windows
# or back to Linux on the spot (bin/usb-live.sh through the QEMU monitor),
# so nothing in Windows has to be closed. $STATE_DIR/usb-live.state remembers
# those moves for the current VM run: its first line is the QEMU pid, then
# "+id" (moved to Windows) or "-id" (moved back to Linux).

USB_WINDOWS_SYS="${OMARCHY_TOOL_USB_SYS:-/sys/bus/usb/devices}"
USB_WINDOWS_MAX=4
USB_WINDOWS_IDS="${OMARCHY_TOOL_USB_IDS:-/usr/share/hwdata/usb.ids}"

usb_windows_enabled() {
  [[ $(config_get '.modules["usb-windows"].enabled // false') == true ]]
}

usb_windows_valid_id() {
  [[ $1 =~ ^[0-9a-f]{4}:[0-9a-f]{4}$ ]]
}

# Name from the system USB id database, for devices that report none.
usb_windows_db_name() {
  local vendor=${1%:*} product=${1#*:}
  [[ -f $USB_WINDOWS_IDS ]] || return 0
  awk -v v="$vendor" -v p="$product" '
    /^[0-9a-f]{4}  / { inv = ($1 == v); if (inv) vname = substr($0, 7); next }
    inv && /^\t[0-9a-f]{4}  / && substr($1, 1) == p { print vname " " substr($0, 8); exit }
  ' "$USB_WINDOWS_IDS"
}

# Connected USB devices, hubs left out, one per vendor:product, as JSON.
usb_windows_connected_json() {
  local dev id name rows=''
  for dev in "$USB_WINDOWS_SYS"/*; do
    [[ -f $dev/idVendor && -f $dev/idProduct ]] || continue
    [[ $(cat "$dev/bDeviceClass" 2>/dev/null) == 09 ]] && continue
    id="$(<"$dev/idVendor"):$(<"$dev/idProduct")"
    name="$(cat "$dev/manufacturer" 2>/dev/null) $(cat "$dev/product" 2>/dev/null)"
    [[ -n ${name// /} ]] || name=$(usb_windows_db_name "${id,,}")
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
  [[ -n $(usb_windows_desired) ]] && echo "--usb-bus on"
  return 0
}

usb_windows_apply() {
  mkdir -p -- "$STATE_DIR"
  install -m 0644 -- "$TOOL_DIR/bin/usb-live.sh" "$STATE_DIR/usb-live.sh"
  compose_sync || fail "no se pudo cambiar la configuración de Windows"
}

# QEMU of the running Omarchy Windows VM (dockurr/windows), if any.
usb_windows_vm_pid() {
  if [[ -n ${OMARCHY_TOOL_VM_PID+x} ]]; then
    echo "$OMARCHY_TOOL_VM_PID"
    return
  fi
  pgrep -f '^qemu-system-x86_64 .*monitor unix:/run/shm/monitor.sock' | head -n1
}

usb_windows_vm_started() {
  local pid=$1
  if [[ -n ${OMARCHY_TOOL_VM_STARTED+x} ]]; then
    echo "$OMARCHY_TOOL_VM_STARTED"
    return
  fi
  date -d "$(ps -o lstart= -p "$pid")" +%s 2>/dev/null || echo 0
}

usb_windows_live_state() {
  echo "$STATE_DIR/usb-live.state"
}

# Whether <id> is in Windows right now: moved there during this VM run (or,
# for a compose from v0.0.12-v0.0.13, taken at boot) and not moved back.
usb_windows_in_windows() {
  local id=$1 pid=$2 state last
  state=$(usb_windows_live_state)
  if [[ -f $state && $(head -n1 "$state") == "$pid" ]]; then
    last=$(tail -n +2 "$state" | grep -x -- "[+-]$id" | tail -n1)
    [[ $last == "+$id" ]] && return 0
    [[ $last == "-$id" ]] && return 1
  fi
  grep -qx -- "--usb $id" <<<"$(compose_applied)" &&
    (($(usb_windows_vm_started "$pid") >= $(compose_mtime)))
}

# move linux|windows <vvvv:pppp>
usb_windows_move() {
  local where=${1:-} id=${2:-} pid state action
  id=${id,,}
  [[ $where == linux || $where == windows ]] && usb_windows_valid_id "$id" ||
    fail "usage: omarchy-tool usb-windows move linux|windows <vvvv:pppp>"
  pid=$(usb_windows_vm_pid)
  [[ -n $pid ]] || fail "Windows no está abierto"
  action=attach
  [[ $where == linux ]] && action=detach
  mkdir -p -- "$STATE_DIR"
  install -m 0644 -- "$TOOL_DIR/bin/usb-live.sh" "$STATE_DIR/usb-live.sh"
  privileged /usr/bin/bash "$STATE_DIR/usb-live.sh" "$action" "$id" || fail "no se pudo mover el dispositivo"
  state=$(usb_windows_live_state)
  [[ -f $state && $(head -n1 "$state") == "$pid" ]] || echo "$pid" >"$state"
  if [[ $where == windows ]]; then echo "+$id" >>"$state"; else echo "-$id" >>"$state"; fi
}

usb_windows_status() {
  local enabled=false installed=false applied=false connected devices pid inwin='[]' id ready=false
  usb_windows_enabled && enabled=true
  pid=$(usb_windows_vm_pid)
  if [[ -n $pid ]]; then
    # This VM run started with /dev/bus/usb, so devices can be handed over.
    grep -qx -- "--usb-bus on" <<<"$(compose_applied)" &&
      (($(usb_windows_vm_started "$pid") >= $(compose_mtime))) && ready=true
    while IFS= read -r id; do
      [[ -n $id ]] && usb_windows_in_windows "$id" "$pid" && inwin=$(jq -c --arg id "$id" '. + [$id]' <<<"$inwin")
    done < <(config_get -r '.modules["usb-windows"].devices // [] | .[] | .id')
  fi
  [[ -f $COMPOSE_FILE ]] && installed=true
  compose_in_sync --usb-bus && applied=true
  connected=$(usb_windows_connected_json)
  devices=$(config_get -c '.modules["usb-windows"].devices // []')
  jq -n --argjson enabled "$enabled" --argjson installed "$installed" --argjson applied "$applied" \
    --argjson connected "$connected" --argjson devices "$devices" --argjson max "$USB_WINDOWS_MAX" \
    --argjson running "$([[ -n $pid ]] && echo true || echo false)" --argjson inwin "$inwin" --argjson ready "$ready" \
    '{enabled: $enabled, vmInstalled: $installed, applied: $applied, max: $max, vmRunning: $running, liveReady: $ready,
      devices: [$devices[] | . as $d | . + {connected: any($connected[]; .id == $d.id), inWindows: any($inwin[]; . == $d.id)}],
      candidates: [$connected[] | . as $c | . + {selected: any($devices[]; .id == $c.id)}],
      summary: (if ($installed | not) then "Windows no está instalado"
        elif $enabled then ($inwin | length | tostring) + " en Windows" else "Desactivado" end)}'
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
