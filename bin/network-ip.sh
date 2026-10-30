#!/bin/bash

# Show or set how the active wired/Wi-Fi connection gets its IPv4 address,
# the way omarchy-dns does for DNS. The network-ip module copies this file to
# $STATE_DIR, and the Omarchy menu runs that copy from Setup › Network › IP.
#
#   network-ip.sh            Print DHCP or Custom (or another ipv4.method)
#   network-ip.sh info       JSON with connection, mode, address and gateway
#   network-ip.sh DHCP       Get address, gateway and DNS from the router again
#   network-ip.sh DHCP --notify   Same, reporting errors as a desktop notification
#   network-ip.sh Custom     Ask for address/prefix and gateway, then set them
#
# Runs as the session user: NetworkManager's polkit rules let a local session
# modify system connections, so nothing here needs root.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/i18n.sh
source "$HERE/i18n.sh"
# DNS servers this script copied into a connection, so DHCP takes back only those.
DNS_RECORD="${OMARCHY_TOOL_STATE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-tool}/network-ip.dns"

# The menu's DHCP row runs with no terminal to show errors in.
NOTIFY=false

die() {
  local message
  message=$(tool_text "$@")
  printf 'network-ip: %s\n' "$message" >&2
  if [[ $NOTIFY == true ]]; then
    omarchy-notification-send -u critical "$(tool_text 'IP de red')" "$message" >/dev/null 2>&1 || true
  fi
  exit 1
}

# --- active connection ------------------------------------------------------

conn_uuid=""
conn_device=""

find_connection() {
  local uuid type device
  while IFS=: read -r uuid type device; do
    case $type in
      802-3-ethernet | 802-11-wireless)
        conn_uuid=$uuid
        conn_device=$device
        return 0
        ;;
    esac
  done < <(nmcli -t -f UUID,TYPE,DEVICE connection show --active)
  die 'no hay ninguna conexión por cable o Wi-Fi activa'
}

conn_get() {
  nmcli -g "$1" connection show "$conn_uuid"
}

# First value of a device property (nmcli -g joins several with " | ").
device_get() {
  local value
  value=$(nmcli -g "$1" device show "$conn_device")
  printf '%s' "${value%% | *}"
}

current_mode() {
  case $(conn_get ipv4.method) in
    auto) echo DHCP ;;
    manual) echo Custom ;;
    *) conn_get ipv4.method ;;
  esac
}

reapply() {
  nmcli device reapply "$conn_device" >/dev/null 2>&1 ||
    nmcli connection up "$conn_uuid" >/dev/null ||
    die 'no se pudo aplicar el cambio a %1' "$conn_device"
}

# --- IPv4 validation --------------------------------------------------------

OCTET='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'

valid_ipv4() {
  [[ $1 =~ ^$OCTET\.$OCTET\.$OCTET\.$OCTET$ ]]
}

ipv4_to_int() {
  local a b c d
  IFS=. read -r a b c d <<<"$1"
  echo $(((a << 24) | (b << 16) | (c << 8) | d))
}

# The address must be a usable host of its subnet, and the gateway another
# host of that same subnet.
check_custom() {
  local address=$1 gateway=$2 ip prefix mask net host_ip host_gw last
  [[ $address == */* ]] || die 'falta el prefijo en %1 (por ejemplo /24)' "$address"
  ip=${address%/*}
  prefix=${address#*/}
  valid_ipv4 "$ip" || die 'dirección IP no válida: %1' "$ip"
  [[ $prefix =~ ^([1-9]|[12][0-9]|3[0-2])$ ]] || die 'prefijo no válido: %1' "$prefix"
  valid_ipv4 "$gateway" || die 'puerta de enlace no válida: %1' "$gateway"

  mask=$(((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF))
  net=$(($(ipv4_to_int "$ip") & mask))
  host_ip=$(($(ipv4_to_int "$ip") & ~mask & 0xFFFFFFFF))
  host_gw=$(($(ipv4_to_int "$gateway") & ~mask & 0xFFFFFFFF))
  last=$((~mask & 0xFFFFFFFF))

  ((($(ipv4_to_int "$gateway") & mask) == net)) || die 'la puerta de enlace %1 no está en la red de %2' "$gateway" "$address"
  [[ $ip != "$gateway" ]] || die 'la IP y la puerta de enlace no pueden ser iguales'
  # /31 and /32 have no network or broadcast address to avoid.
  if ((prefix <= 30)); then
    ((host_ip != 0 && host_ip != last)) || die '%1 no es una dirección de equipo de esa red' "$ip"
    ((host_gw != 0 && host_gw != last)) || die '%1 no es una dirección de equipo de esa red' "$gateway"
  fi
}

# --- DNS kept across manual mode --------------------------------------------

# Manual mode gets no DNS from the router. If the connection has none of its
# own (omarchy-dns sets them when a provider is chosen), keep the servers in
# use now so names still resolve, and remember them for DHCP.
keep_dns_args() {
  local servers
  [[ -z $(conn_get ipv4.dns) ]] || return 0
  servers=$(nmcli -g IP4.DNS device show "$conn_device" | sed 's/ | /,/g')
  [[ -n $servers ]] && printf '%s\n' ipv4.dns "$servers"
  return 0
}

record_dns() {
  mkdir -p -- "$(dirname -- "$DNS_RECORD")"
  printf '%s %s\n' "$conn_uuid" "$(conn_get ipv4.dns)" >"$DNS_RECORD"
}

# Only DNS servers this script copied, and still unchanged since.
dns_to_release() {
  local uuid servers
  [[ -f $DNS_RECORD ]] || return 1
  read -r uuid servers <"$DNS_RECORD"
  [[ $uuid == "$conn_uuid" && -n $servers && $(conn_get ipv4.dns) == "$servers" ]]
}

# --- commands ---------------------------------------------------------------

cmd_info() {
  find_connection
  jq -n --arg connection "$(conn_get connection.id)" --arg device "$conn_device" \
    --arg mode "$(current_mode)" --arg address "$(device_get IP4.ADDRESS)" \
    --arg gateway "$(device_get IP4.GATEWAY)" \
    '{connection: $connection, device: $device, mode: $mode, address: $address, gateway: $gateway}'
}

cmd_dhcp() {
  local args=(ipv4.method auto ipv4.addresses "" ipv4.gateway "")
  find_connection
  if dns_to_release; then
    args+=(ipv4.dns "")
  fi
  nmcli connection modify "$conn_uuid" "${args[@]}" >/dev/null || die 'no se pudo cambiar %1' "$conn_device"
  rm -f -- "$DNS_RECORD"
  reapply
}

# Enter keeps the value shown in brackets. The question goes to stderr: the
# caller captures stdout as the answer.
ask() {
  local prompt=$1 default=$2 answer=""
  if [[ -n $default ]]; then
    printf '%s [%s]: ' "$(tool_text "$prompt")" "$default" >&2
  else
    printf '%s: ' "$(tool_text "$prompt")" >&2
  fi
  read -r answer || answer=""
  answer=${answer//[[:space:]]/}
  printf '%s' "${answer:-$default}"
}

cmd_custom() {
  local address gateway dns_args
  find_connection
  echo "$(tool_text 'Conexión: %1 (%2)' "$(conn_get connection.id)" "$conn_device")"
  address=$(ask 'IP/prefijo' "$(device_get IP4.ADDRESS)")
  gateway=$(ask 'Puerta de enlace' "$(device_get IP4.GATEWAY)")
  check_custom "$address" "$gateway"

  mapfile -t dns_args < <(keep_dns_args)
  nmcli connection modify "$conn_uuid" ipv4.method manual ipv4.addresses "$address" \
    ipv4.gateway "$gateway" "${dns_args[@]}" >/dev/null || die 'no se pudo cambiar %1' "$conn_device"
  ((${#dns_args[@]})) && record_dns
  reapply
  echo "$(tool_text 'IP fija %1 con puerta de enlace %2.' "$address" "$gateway")"
}

case ${1:-} in
  "")
    find_connection
    current_mode
    ;;
  info) cmd_info ;;
  DHCP | dhcp)
    [[ ${2:-} == --notify ]] && NOTIFY=true
    cmd_dhcp
    ;;
  Custom | custom) cmd_custom ;;
  *)
    echo "Usage: network-ip.sh [info|DHCP|Custom]" >&2
    exit 1
    ;;
esac
