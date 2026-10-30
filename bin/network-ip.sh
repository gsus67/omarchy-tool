#!/bin/bash

# Show or set how one wired/Wi-Fi adapter gets its IPv4 address and its DNS,
# the way omarchy-dns does for every adapter at once. The network-ip module
# copies this file to $STATE_DIR, and the Omarchy menu runs that copy from
# Setup › Network › IP and Setup › Network › DNS.
#
#   network-ip.sh list                          JSON: wired/Wi-Fi adapters and their settings
#   network-ip.sh ip DEVICE                     Print DHCP or Custom
#   network-ip.sh ip DEVICE DHCP [--notify]     Address and gateway from the router again
#   network-ip.sh ip DEVICE Custom [ADDRESS/PREFIX GATEWAY]
#                                               Static address; asks when not given
#   network-ip.sh dns DEVICE                    Print DHCP, Cloudflare, Google or Custom
#   network-ip.sh dns DEVICE PROVIDER [--notify]  DHCP, Cloudflare or Google
#   network-ip.sh dns DEVICE Custom ["SERVERS"] Own servers; asks when not given
#
# --notify reports errors as a desktop notification: the menu runs those rows
# with no terminal to show them in.
#
# Settings belong to the connection active on that adapter; a disconnected
# adapter has none to change. Runs as the session user: NetworkManager's polkit
# rules let a local session modify system connections, so nothing needs root.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/i18n.sh
source "$HERE/i18n.sh"
# DNS servers this script copied into a connection when its IP went static,
# one "uuid servers" line each, so DHCP takes back only those.
DNS_RECORD="${OMARCHY_TOOL_STATE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-tool}/network-ip.dns"
NOTIFY=false

die() {
  local message
  message=$(tool_text "$@")
  printf 'network-ip: %s\n' "$message" >&2
  if [[ $NOTIFY == true ]]; then
    omarchy-notification-send -u critical "$(tool_text 'Red')" "$message" >/dev/null 2>&1 || true
  fi
  exit 1
}

# --- adapters ---------------------------------------------------------------

# Wired and Wi-Fi adapters as "device type state" lines.
adapters() {
  local device type state
  while IFS=: read -r device type state; do
    case $type in
      ethernet | wifi) printf '%s %s %s\n' "$device" "$type" "${state%% *}" ;;
    esac
  done < <(nmcli -t -f DEVICE,TYPE,STATE device status)
}

conn_uuid=""
conn_device=""

# Select DEVICE's active connection, or stop with a clear message.
use_device() {
  local device=$1 name type state
  [[ $device =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || die 'adaptador no válido: %1' "$device"
  while read -r name type state; do
    [[ $name == "$device" ]] || continue
    [[ $state == connected ]] || die '%1 no está conectado' "$device"
    conn_device=$device
    conn_uuid=$(nmcli -g GENERAL.CON-UUID device show "$device")
    [[ -n $conn_uuid ]] || die '%1 no está conectado' "$device"
    return 0
  done < <(adapters)
  die 'no hay ningún adaptador de cable o Wi-Fi llamado %1' "$device"
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

reapply() {
  nmcli device reapply "$conn_device" >/dev/null 2>&1 ||
    nmcli connection up "$conn_uuid" >/dev/null ||
    die 'no se pudo aplicar el cambio a %1' "$conn_device"
}

modify() {
  nmcli connection modify "$conn_uuid" "$@" >/dev/null || die 'no se pudo cambiar %1' "$conn_device"
}

# --- IPv4 validation --------------------------------------------------------

OCTET='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'

valid_ipv4() {
  [[ $1 =~ ^$OCTET\.$OCTET\.$OCTET\.$OCTET$ ]]
}

# Hex groups and colons only, at most one "::", 2-39 characters.
valid_ipv6() {
  [[ $1 =~ ^[0-9A-Fa-f:]{2,39}$ && $1 == *:* && $1 != *:::* ]] || return 1
  local rest=${1#*::}
  [[ $rest != *::* ]]
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
  printf '%s' "${answer:-$default}"
}

# --- DNS record -------------------------------------------------------------

record_get() {
  [[ -f $DNS_RECORD ]] && awk -v uuid="$conn_uuid" '$1 == uuid { print $2; exit }' "$DNS_RECORD"
  return 0
}

record_set() {
  local servers=$1 tmp
  mkdir -p -- "$(dirname -- "$DNS_RECORD")"
  tmp=$(mktemp "$DNS_RECORD.XXXXXX")
  { [[ -f $DNS_RECORD ]] && awk -v uuid="$conn_uuid" '$1 != uuid' "$DNS_RECORD"
    [[ -n $servers ]] && printf '%s %s\n' "$conn_uuid" "$servers"; } >"$tmp" || true
  if [[ -s $tmp ]]; then
    mv -f -- "$tmp" "$DNS_RECORD"
  else
    rm -f -- "$tmp" "$DNS_RECORD"
  fi
}

# --- IP ---------------------------------------------------------------------

ip_mode() {
  case $(conn_get ipv4.method) in
    auto) echo DHCP ;;
    manual) echo Custom ;;
    *) conn_get ipv4.method ;;
  esac
}

ip_dhcp() {
  local args=(ipv4.method auto ipv4.addresses "" ipv4.gateway "") recorded
  recorded=$(record_get)
  # Release only DNS this script copied, and only while still unchanged.
  if [[ -n $recorded && $(conn_get ipv4.dns) == "$recorded" ]]; then
    args+=(ipv4.dns "")
  fi
  modify "${args[@]}"
  record_set ""
  reapply
}

# ip_custom [ADDRESS/PREFIX GATEWAY]: the panel passes both, the menu's
# terminal asks for them.
ip_custom() {
  local address=${1:-} gateway=${2:-} servers dns_args=()
  if (($# < 2)); then
    echo "$(tool_text 'Adaptador: %1 (%2)' "$conn_device" "$(conn_get connection.id)")"
    address=$(ask 'IP/prefijo' "$(device_get IP4.ADDRESS)")
    gateway=$(ask 'Puerta de enlace' "$(device_get IP4.GATEWAY)")
  fi
  address=${address//[[:space:]]/}
  gateway=${gateway//[[:space:]]/}
  check_custom "$address" "$gateway"

  # A static address gets no DNS from the router. Without DNS of its own,
  # keep the servers in use now so names still resolve.
  servers=""
  if [[ -z $(conn_get ipv4.dns) ]]; then
    servers=$(nmcli -g IP4.DNS device show "$conn_device" | sed 's/ | /,/g')
    [[ -n $servers ]] && dns_args=(ipv4.dns "$servers")
  fi
  modify ipv4.method manual ipv4.addresses "$address" ipv4.gateway "$gateway" "${dns_args[@]}"
  [[ -n $servers ]] && record_set "$(conn_get ipv4.dns)"
  reapply
  echo "$(tool_text 'IP fija %1 con puerta de enlace %2.' "$address" "$gateway")"
}

# --- DNS --------------------------------------------------------------------

# omarchy-dns writes a NetworkManager global DNS that overrides every
# connection's own; per-adapter DNS only applies while it is on DHCP.
global_dns() {
  if command -v omarchy-dns >/dev/null; then
    omarchy-dns 2>/dev/null || echo DHCP
  else
    echo DHCP
  fi
}

dns_mode() {
  local servers
  if [[ $(conn_get ipv4.ignore-auto-dns) != yes ]]; then
    echo DHCP
    return
  fi
  servers=$(conn_get ipv4.dns)
  case $servers in
    1.1.1.1,1.0.0.1) echo Cloudflare ;;
    8.8.8.8,8.8.4.4) echo Google ;;
    *) echo Custom ;;
  esac
}

# set_dns IPV4_LIST IPV6_LIST, each comma separated; both empty means DHCP.
set_dns() {
  local ipv4=$1 ipv6=$2 auto=yes
  [[ -n $ipv4$ipv6 ]] && auto=no
  if [[ $auto == yes && $(ip_mode) == Custom ]]; then
    die 'con IP fija el router no da DNS; elige Cloudflare, Google o Custom'
  fi
  modify ipv4.ignore-auto-dns "$([[ $auto == yes ]] && echo no || echo yes)" ipv4.dns "$ipv4" \
    ipv6.ignore-auto-dns "$([[ $auto == yes ]] && echo no || echo yes)" ipv6.dns "$ipv6"
  # Chosen DNS are no longer the ones copied for a static IP.
  record_set ""
  reapply
}

# dns_custom ["SERVERS"]: the panel passes them, the menu's terminal asks.
dns_custom() {
  local answer=${1:-} server ipv4="" ipv6=""
  if (($# < 1)); then
    echo "$(tool_text 'Adaptador: %1 (%2)' "$conn_device" "$(conn_get connection.id)")"
    answer=$(ask 'Servidores DNS separados por espacios' "")
  fi
  for server in ${answer//,/ }; do
    if valid_ipv4 "$server"; then
      ipv4+="${ipv4:+,}$server"
    elif valid_ipv6 "$server"; then
      ipv6+="${ipv6:+,}$server"
    else
      die 'servidor DNS no válido: %1' "$server"
    fi
  done
  [[ -n $ipv4$ipv6 ]] || die 'no se indicó ningún servidor DNS'
  set_dns "$ipv4" "$ipv6"
  echo "$(tool_text 'DNS de %1: %2' "$conn_device" "${ipv4}${ipv4:+${ipv6:+,}}${ipv6}")"
}

dns_command() {
  local provider=${1:-} global
  shift || true
  if [[ $provider != "" ]]; then
    global=$(global_dns)
    [[ $global == DHCP ]] ||
      die 'Omarchy usa DNS %1 en todos los adaptadores; ponlo en DHCP para elegir DNS por adaptador' "$global"
  fi
  case $provider in
    "") dns_mode ;;
    DHCP | dhcp) set_dns "" "" ;;
    Cloudflare | cloudflare) set_dns "1.1.1.1,1.0.0.1" "2606:4700:4700::1111,2606:4700:4700::1001" ;;
    Google | google) set_dns "8.8.8.8,8.8.4.4" "2001:4860:4860::8888,2001:4860:4860::8844" ;;
    Custom | custom) dns_custom "$@" ;;
    *) usage ;;
  esac
}

# --- list -------------------------------------------------------------------

cmd_list() {
  local device type state rows=() row
  while read -r device type state; do
    conn_device=$device
    conn_uuid=""
    [[ $state == connected ]] && conn_uuid=$(nmcli -g GENERAL.CON-UUID device show "$device")
    if [[ -n $conn_uuid ]]; then
      row=$(jq -n --arg device "$device" --arg type "$type" --arg connection "$(conn_get connection.id)" \
        --arg ip "$(ip_mode)" --arg dns "$(dns_mode)" --arg address "$(device_get IP4.ADDRESS)" \
        --arg gateway "$(device_get IP4.GATEWAY)" \
        --arg servers "$(printf '%s,%s' "$(conn_get ipv4.dns)" "$(conn_get ipv6.dns)" | tr ',' ' ' | xargs)" \
        '{device: $device, type: $type, connected: true, connection: $connection, ip: $ip, dns: $dns,
          dnsServers: $servers, address: $address, gateway: $gateway}')
    else
      row=$(jq -n --arg device "$device" --arg type "$type" '{device: $device, type: $type, connected: false}')
    fi
    rows+=("$row")
  done < <(adapters)
  if ((${#rows[@]})); then
    printf '%s\n' "${rows[@]}" | jq -s --arg global "$(global_dns)" '{globalDns: $global, adapters: .}'
  else
    jq -n --arg global "$(global_dns)" '{globalDns: $global, adapters: []}'
  fi
}

usage() {
  echo "Usage: network-ip.sh list | ip DEVICE [DHCP|Custom] | dns DEVICE [DHCP|Cloudflare|Google|Custom] [--notify]" >&2
  exit 1
}

# --notify may come anywhere; everything else is positional.
args=()
for arg in "$@"; do
  if [[ $arg == --notify ]]; then
    NOTIFY=true
  else
    args+=("$arg")
  fi
done
set -- "${args[@]}"

case ${1:-} in
  list) cmd_list ;;
  ip | dns)
    use_device "${2:-}"
    if [[ $1 == ip ]]; then
      case ${3:-} in
        "") ip_mode ;;
        DHCP | dhcp) ip_dhcp ;;
        Custom | custom) ip_custom "${@:4}" ;;
        *) usage ;;
      esac
    else
      dns_command "${@:3}"
    fi
    ;;
  *) usage ;;
esac
