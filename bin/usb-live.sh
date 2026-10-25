#!/bin/bash

# Moves a USB device between Linux and the running Omarchy Windows VM without
# closing Windows. Run as root through pkexec by omarchy-tool (usb-windows).
#
#   usb-live.sh attach|detach VVVV:PPPP
#
# Talks to the QEMU human monitor dockurr/windows keeps at
# /run/shm/monitor.sock inside the omarchy-windows container. The device id
# matches the one compose-edit.sh gives it at boot (omt<vendor><product>), so
# a device Windows took at startup can be handed back too.

set -euo pipefail

fail() {
  echo "usb-live: $*" >&2
  exit 1
}

action=${1:-}
id=${2:-}
[[ $action == attach || $action == detach ]] || fail "usage: usb-live.sh attach|detach VVVV:PPPP"
[[ $id =~ ^[0-9a-f]{4}:[0-9a-f]{4}$ ]] || fail "refusing device id: $id"
vendor=${id%:*}
product=${id#*:}
dev="omt$vendor$product"

pid=$(docker inspect --format '{{.State.Pid}}' omarchy-windows 2>/dev/null) || fail "Windows no está abierto"
[[ $pid =~ ^[1-9][0-9]*$ ]] || fail "Windows no está abierto"
socket="/proc/$pid/root/run/shm/monitor.sock"
[[ -S $socket ]] || fail "no se encontró el control de la VM"

if [[ $action == attach ]]; then
  command="device_add usb-host,id=$dev,vendorid=0x$vendor,productid=0x$product"
else
  command="device_del $dev"
fi

monitor() {
  printf '%s\n' "$1" | timeout 10 socat -t 2 - "UNIX-CONNECT:$socket" | tr -d '\r'
}

monitor "$command" >/dev/null || fail "no se pudo hablar con la VM"

# Unplugging finishes asynchronously; check the outcome on the USB bus.
for _ in 1 2 3 4 5; do
  sleep 1
  usb=$(monitor "info usb") || continue
  if [[ $action == attach ]]; then
    grep -q "ID: $dev\b" <<<"$usb" && exit 0
  else
    grep -q "ID: $dev\b" <<<"$usb" || exit 0
  fi
done
if [[ $action == attach ]]; then
  fail "Windows no tomó el dispositivo (¿está conectado?)"
fi
fail "Windows no soltó el dispositivo"
