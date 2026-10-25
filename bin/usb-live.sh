#!/bin/bash

# Moves a USB device between Linux and the running Omarchy Windows VM without
# closing Windows. Run as root through pkexec by omarchy-tool (usb-windows).
#
#   usb-live.sh attach|detach VVVV:PPPP...
#
# Talks to the QEMU human monitor dockurr/windows keeps at
# /run/shm/monitor.sock inside the omarchy-windows container. The device id
# matches the one compose-edit.sh gives it at boot (omt<vendor><product>), so
# a device Windows took at startup can be handed back too.

set -euo pipefail
helper_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ -f $helper_dir/i18n.sh ]]; then
  source "$helper_dir/i18n.sh"
else
  tool_text() { printf '%s' "$1"; }
fi

fail() {
  printf 'usb-live: %s\n' "$(tool_text "$*")" >&2
  exit 1
}

action=${1:-}
[[ $action == attach || $action == detach ]] && (($# >= 2)) || fail "usage: usb-live.sh attach|detach VVVV:PPPP..."
shift
for id in "$@"; do
  [[ $id =~ ^[0-9a-f]{4}:[0-9a-f]{4}$ ]] || fail "$(tool_text 'refusing device id: %1' "$id")"
done

pid=$(docker inspect --format '{{.State.Pid}}' omarchy-windows 2>/dev/null) || fail "Windows no está abierto"
[[ $pid =~ ^[1-9][0-9]*$ ]] || fail "Windows no está abierto"
# QEMU listens on /run/shm/monitor.sock inside the container, where /run/shm
# is usually a symlink to /dev/shm. Through /proc/<pid>/root an absolute
# symlink would resolve on the host, so follow it inside the container here.
root="/proc/$pid/root"
shm="$root/run/shm"
if [[ -L $shm ]]; then
  target=$(readlink -- "$shm")
  [[ $target == /* ]] && shm="$root$target" || shm="$root/run/$target"
fi
socket="$shm/monitor.sock"
[[ -S $socket ]] || fail "no se encontró el control de la VM"

monitor() {
  printf '%s\n' "$1" | timeout 10 socat -t 2 - "UNIX-CONNECT:$socket" | tr -d '\r'
}

move() {
  local id=$1 vendor=${1%:*} product=${1#*:} dev command usb
  dev="omt$vendor$product"
  if [[ $action == attach ]]; then
    command="device_add usb-host,id=$dev,vendorid=0x$vendor,productid=0x$product"
  else
    command="device_del $dev"
  fi
  monitor "$command" >/dev/null || fail "no se pudo hablar con la VM"

  # Unplugging finishes asynchronously; check the outcome on the USB bus.
  for _ in 1 2 3 4 5; do
    sleep 1
    usb=$(monitor "info usb") || continue
    if [[ $action == attach ]]; then
      grep -q "ID: $dev\b" <<<"$usb" && return 0
    else
      grep -q "ID: $dev\b" <<<"$usb" || return 0
    fi
  done
  if [[ $action == attach ]]; then
    fail "$(tool_text 'Windows no tomó %1 (¿está conectado?)' "$id")"
  fi
  fail "$(tool_text 'Windows no soltó %1' "$id")"
}

for id in "$@"; do
  move "$id"
done
