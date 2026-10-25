# shellcheck shell=bash
# Module: usb-windows
#
# Hands chosen USB devices to Omarchy's Windows VM, so their Windows-only apps
# (Glorious CORE, iCUE, ...) can see them.
#
# The module switch prepares the VM: it gets /dev/bus/usb (compose_sync in
# bin/omarchy-tool writes it through bin/compose-edit.sh under pkexec; it
# takes effect when Windows next starts). Each device's own switch then means
# "this one in Windows": while a prepared Windows runs, switching it on hands
# it over on the spot and off gives it back (bin/usb-live.sh through the QEMU
# monitor), nothing has to be closed. Devices left on go over by themselves
# when Windows opens: the panel polls bin/usb-watch.sh and runs sync-live
# when the VM appears. SUPER+ALT+U, or "Devolver periféricos a Linux" inside
# Windows, gives everything back and switches those devices off.
#
# The cursor of a passed mouse moves on the VM's own screen, not in the remote
# window Omarchy shows. console-open starts Windows without that window (the
# launcher with --keep-alive and a no-op xfreerdp3 first on PATH) and opens
# the VM screen (dockurr/windows' noVNC on 127.0.0.1:8006) as a web app;
# console-close stops it.
#
# $STATE_DIR/usb-live.state remembers moves for the current VM run: its first
# line is the QEMU pid, then "+id" (moved to Windows) or "-id" (moved back).

USB_WINDOWS_SYS="${OMARCHY_TOOL_USB_SYS:-/sys/bus/usb/devices}"
USB_WINDOWS_MAX=4
USB_WINDOWS_IDS="${OMARCHY_TOOL_USB_IDS:-/usr/share/hwdata/usb.ids}"
USB_WINDOWS_SHARED="${OMARCHY_TOOL_WINDOWS_SHARED:-$HOME/Windows}"
USB_WINDOWS_FOLDER="$USB_WINDOWS_SHARED/Omarchy Tool/Periféricos"
USB_WINDOWS_RETURN_CMD="Devolver periféricos a Linux.cmd"

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

# Devices whose switch is on (wanted in Windows), while the feature is on.
usb_windows_wanted() {
  usb_windows_enabled || return 0
  config_get -r '.modules["usb-windows"].devices // [] | .[] | .id' | head -n "$USB_WINDOWS_MAX"
}

usb_windows_compose_args() {
  usb_windows_enabled && echo "--usb-bus live"
  return 0
}

usb_windows_apply() {
  mkdir -p -- "$STATE_DIR"
  install -m 0644 -- "$TOOL_DIR/bin/usb-live.sh" "$STATE_DIR/usb-live.sh"
  hotkeys_sync
  compose_sync || fail "no se pudo cambiar la configuración de Windows"
  usb_windows_sync_windows_folder
}

# "Devolver periféricos a Linux" in Shared › Omarchy Tool › Periféricos: run
# inside Windows, it leaves .devolver-usb there, and the panel (polling
# usb-watch.sh) runs check-request, for when SUPER+ALT+U is forgotten. The
# folder is shared with other modules: only our files come and go.
usb_windows_sync_windows_folder() {
  local folder=$USB_WINDOWS_FOLDER
  if usb_windows_enabled && [[ -f $COMPOSE_FILE && -d $USB_WINDOWS_SHARED ]]; then
    mkdir -p -- "$folder"
    cp -f -- "$TOOL_DIR/windows/$USB_WINDOWS_RETURN_CMD" "$folder/"
  elif [[ -d $folder ]]; then
    rm -f -- "$folder/$USB_WINDOWS_RETURN_CMD" "$folder/.devolver-usb"
    rmdir -- "$folder" "${folder%/*}" 2>/dev/null || true
  fi
}

# check-request: give everything back if Windows asked for it.
usb_windows_check_request() {
  local request="$USB_WINDOWS_FOLDER/.devolver-usb"
  [[ -e $request ]] || return 0
  rm -f -- "$request"
  usb_windows_enabled || return 0
  usb_windows_move linux --all
}

# SUPER+ALT+U gives everything in Windows back to Linux, with no mouse needed.
# dont_inhibit: it works even while the Windows window holds the keyboard.
usb_windows_hotkeys() {
  usb_windows_enabled || return 0
  printf 'o.bind("SUPER + ALT + U", "Devolver periféricos a Linux", %s, { dont_inhibit = true })\n' \
    "$(jq -Rn --arg cmd "$(printf '%q' "$TOOL_DIR/bin/omarchy-tool") usb-windows move linux --all" '$cmd')"
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

# Whether this VM run started with /dev/bus/usb, so devices can be handed over.
usb_windows_live_ready() {
  local pid=$1
  [[ -n $pid ]] && grep -qx -- "--usb-bus live" <<<"$(compose_applied)" &&
    (($(usb_windows_vm_started "$pid") >= $(compose_mtime)))
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

usb_windows_notify() {
  omarchy-notification-send -g "󰦬" "$@" >/dev/null 2>&1 || true
}

# Hand <ids> to Windows (attach) or back to Linux (detach) in one pkexec call,
# and remember it for this VM run.
usb_windows_live() {
  local action=$1 pid=$2 state id
  shift 2
  (($#)) || return 0
  mkdir -p -- "$STATE_DIR"
  install -m 0644 -- "$TOOL_DIR/bin/usb-live.sh" "$STATE_DIR/usb-live.sh"
  privileged /usr/bin/bash "$STATE_DIR/usb-live.sh" "$action" "$@" || return 1
  state=$(usb_windows_live_state)
  [[ -f $state && $(head -n1 "$state") == "$pid" ]] || echo "$pid" >"$state"
  for id in "$@"; do
    if [[ $action == attach ]]; then echo "+$id" >>"$state"; else echo "-$id" >>"$state"; fi
  done
  if [[ $action == attach ]]; then
    # Say how to get it back right when it is gone: the mouse may be the one.
    usb_windows_notify -t 15000 "Ahora en Windows" \
      "Para devolverlo a Linux: SUPER + ALT + U, o en Windows abre Shared › Omarchy Tool › Periféricos › Devolver periféricos a Linux."
  fi
}

# sync-live: make a running, prepared Windows hold exactly the devices whose
# switch is on (and that are plugged in). The panel runs it when Windows opens
# and after every switch change.
usb_windows_sync_live() {
  local pid id attach=() detach=() connected
  pid=$(usb_windows_vm_pid)
  usb_windows_live_ready "$pid" || return 0
  connected=$(usb_windows_connected_json)
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    jq -e --arg id "$id" 'any(.[]; .id == $id)' <<<"$connected" >/dev/null || continue
    usb_windows_in_windows "$id" "$pid" || attach+=("$id")
  done < <(usb_windows_wanted)
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    grep -qxF -- "$id" <<<"$(usb_windows_wanted)" && continue
    usb_windows_in_windows "$id" "$pid" && detach+=("$id")
  done < <(usb_windows_known_ids)
  usb_windows_live detach "$pid" "${detach[@]}" || fail "no se pudo devolver el dispositivo a Linux"
  usb_windows_live attach "$pid" "${attach[@]}" || fail "no se pudo pasar el dispositivo a Windows"
}

# Every device this VM run may hold: saved ones plus any moved during it.
usb_windows_known_ids() {
  local state
  state=$(usb_windows_live_state)
  {
    config_get -r '.modules["usb-windows"].devices // [] | .[] | .id'
    [[ -f $state ]] && tail -n +2 "$state" | sed 's/^[+-]//'
  } | sort -u
}

# move linux --all (SUPER+ALT+U, "Devolver periféricos a Linux"): give back
# everything and switch those devices off, so it doesn't go over again.
# move linux|windows <vvvv:pppp>: one device, switch included.
usb_windows_move() {
  local where=${1:-} arg=${2:-} pid id ids=()
  [[ $where == linux || $where == windows ]] || fail "usage: omarchy-tool usb-windows move linux|windows <vvvv:pppp>|--all"
  pid=$(usb_windows_vm_pid)

  if [[ $arg == --all && $where == linux ]]; then
    config_update '.modules["usb-windows"].devices = []'
    if [[ -n $pid ]]; then
      while IFS= read -r id; do
        [[ -n $id ]] && usb_windows_in_windows "$id" "$pid" && ids+=("$id")
      done < <(usb_windows_known_ids)
    fi
    if ((${#ids[@]} == 0)); then
      usb_windows_notify "Nada que devolver" "No hay periféricos en Windows."
      return 0
    fi
    if ! usb_windows_live detach "$pid" "${ids[@]}"; then
      usb_windows_notify -u critical "No se pudieron devolver los periféricos" "Prueba otra vez o cierra Windows."
      fail "no se pudo devolver los dispositivos"
    fi
    usb_windows_notify "Periféricos devueltos a Linux" "${#ids[@]} dispositivo(s) de vuelta; su interruptor queda apagado."
    return 0
  fi

  id=${arg,,}
  usb_windows_valid_id "$id" || fail "usage: omarchy-tool usb-windows move linux|windows <vvvv:pppp>|--all"
  if [[ $where == windows ]]; then usb_windows_add "$id"; else usb_windows_remove "$id"; fi
}

usb_windows_rdp_open() {
  if [[ -n ${OMARCHY_TOOL_RDP_OPEN+x} ]]; then
    [[ $OMARCHY_TOOL_RDP_OPEN == 1 ]]
    return
  fi
  pgrep -x xfreerdp3 >/dev/null
}

# Open viewer windows (noVNC web app). Never real windows under tests.
usb_windows_viewer_windows() {
  [[ -z ${OMARCHY_TOOL_HYPR_DIR:-} ]] && command -v hyprctl >/dev/null || return 0
  hyprctl clients -j 2>/dev/null | jq -r '.[] | select(.class | startswith("chrome-127.0.0.1__")) | .address'
}

# console-open: Windows on its own screen, where a passed mouse shows.
usb_windows_console_open() {
  local user pass url
  [[ -f $COMPOSE_FILE ]] || fail "Windows no está instalado"
  usb_windows_enabled || fail "enciende primero Periféricos en Windows"
  if usb_windows_rdp_open; then
    usb_windows_notify "Cierra antes la ventana de Windows" "Este modo usa la pantalla propia de Windows en vez de la ventana normal."
    fail "cierra antes la ventana de Windows"
  fi
  if [[ -z $(usb_windows_vm_pid) ]]; then
    usb_windows_notify "Abriendo Windows con tu ratón" "Tarda un poco. Se abrirá la pantalla de Windows y tus periféricos encendidos pasarán solos."
    PATH="$TOOL_DIR/bin/no-rdp:$PATH" omarchy-windows-vm launch --keep-alive >/dev/null 2>&1 ||
      fail "no se pudo abrir Windows"
  fi
  # Already open: bring it up instead of opening a second one.
  local open
  open=$(usb_windows_viewer_windows | head -n1)
  if [[ -n $open ]]; then
    hyprctl dispatch "hl.dsp.window.focus({ window = \"address:$open\" })" >/dev/null 2>&1 || true
    return 0
  fi
  # The viewer is behind the same user and password as Windows itself.
  user=$(sed -n 's/^USERNAME=//p' "$HOME/.config/windows/credentials" 2>/dev/null | head -n1)
  pass=$(sed -n 's/^PASSWORD=//p' "$HOME/.config/windows/credentials" 2>/dev/null | head -n1)
  # resize=scale: noVNC fits the Windows screen to the window.
  url="http://127.0.0.1:8006/?resize=scale"
  if [[ -n $user && -n $pass ]]; then
    url="http://$(jq -rn --arg v "$user" '$v|@uri'):$(jq -rn --arg v "$pass" '$v|@uri')@127.0.0.1:8006/?resize=scale"
  fi
  omarchy-launch-webapp "$url" >/dev/null 2>&1 &
  disown
}

# console-close: give everything back and shut Windows down.
usb_windows_console_close() {
  local window
  usb_windows_sync_live_off || true
  while IFS= read -r window; do
    [[ -n $window ]] && hyprctl dispatch "hl.dsp.window.close({ window = \"address:$window\" })" >/dev/null 2>&1
  done < <(usb_windows_viewer_windows)
  omarchy-windows-vm stop >/dev/null 2>&1 || fail "no se pudo apagar Windows"
}

usb_windows_status() {
  local enabled=false installed=false applied=false connected devices pid inwin='[]' id ready=false
  usb_windows_enabled && enabled=true
  pid=$(usb_windows_vm_pid)
  if [[ -n $pid ]]; then
    usb_windows_live_ready "$pid" && ready=true
    while IFS= read -r id; do
      [[ -n $id ]] && usb_windows_in_windows "$id" "$pid" && inwin=$(jq -c --arg id "$id" '. + [$id]' <<<"$inwin")
    done < <(usb_windows_known_ids)
  fi
  [[ -f $COMPOSE_FILE ]] && installed=true
  compose_in_sync --usb-bus && applied=true
  connected=$(usb_windows_connected_json)
  devices=$(config_get -c '.modules["usb-windows"].devices // []')
  jq -n --argjson enabled "$enabled" --argjson installed "$installed" --argjson applied "$applied" \
    --argjson connected "$connected" --argjson devices "$devices" --argjson max "$USB_WINDOWS_MAX" \
    --argjson running "$([[ -n $pid ]] && echo true || echo false)" --argjson inwin "$inwin" --argjson ready "$ready" \
    --arg request "$USB_WINDOWS_FOLDER/.devolver-usb" --arg watch "$TOOL_DIR/bin/usb-watch.sh" \
    --argjson rdp "$(usb_windows_rdp_open && echo true || echo false)" \
    '{enabled: $enabled, rdpOpen: $rdp, vmInstalled: $installed, applied: $applied, max: $max, vmRunning: $running, liveReady: $ready,
      requestFile: $request, watcher: $watch, inWindows: $inwin,
      devices: [$devices[] | . as $d | . + {connected: any($connected[]; .id == $d.id), inWindows: any($inwin[]; . == $d.id)}],
      candidates: [$connected[] | . as $c | . + {selected: any($devices[]; .id == $c.id), inWindows: any($inwin[]; . == $c.id)}],
      summary: (if ($installed | not) then "Windows no está instalado"
        elif $enabled then ($inwin | length | tostring) + " en Windows" else "Desactivado" end)}'
}

usb_windows_enable() {
  config_update '.modules["usb-windows"].enabled = true'
  usb_windows_apply
  usb_windows_sync_live
}

# Off: everything goes back to Linux first, then the VM loses USB access.
usb_windows_disable() {
  config_update '.modules["usb-windows"].enabled = false'
  usb_windows_sync_live_off
  usb_windows_apply
}

usb_windows_sync_live_off() {
  local pid id ids=()
  pid=$(usb_windows_vm_pid)
  [[ -n $pid ]] || return 0
  while IFS= read -r id; do
    [[ -n $id ]] && usb_windows_in_windows "$id" "$pid" && ids+=("$id")
  done < <(usb_windows_known_ids)
  usb_windows_live detach "$pid" "${ids[@]}" || fail "no se pudo devolver los dispositivos a Linux"
}

# add <vvvv:pppp> [name]: switch a device on (to Windows now, if it is open).
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
  usb_windows_sync_live
}

# remove <vvvv:pppp>: switch a device off (back to Linux now, if in Windows).
usb_windows_remove() {
  local id=${1:-}
  id=${id,,}
  usb_windows_valid_id "$id" || fail "usage: omarchy-tool usb-windows remove <vvvv:pppp>"
  config_update '.modules["usb-windows"].devices |= (. // [] | map(select(.id != $id)))' --arg id "$id"
  usb_windows_sync_live
}
