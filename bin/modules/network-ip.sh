# shellcheck shell=bash
# Module: network-ip. Adds per-adapter rows to the Omarchy menu: Setup ›
# Network › IP (DHCP or a static address) and, next to Omarchy's own DNS
# choices for every adapter, one DNS submenu per adapter. The rows run a copy
# of bin/network-ip.sh. No root: NetworkManager lets the session user change
# connections.
NETWORK_IP_HELPER="$STATE_DIR/network-ip.sh"
# Our rows, by id and by the helper they run; no user row matches both.
NETWORK_IP_ROW_PATTERN='^  "setup\.network\.(ip|dns)[.A-Za-z0-9_-]*": \{.*/network-ip\.sh'

network_ip_enabled() {
  [[ $(config_get '.modules["network-ip"].enabled // false') == true ]]
}

network_ip_helper() {
  OMARCHY_TOOL_STATE_DIR=$STATE_DIR bash "$TOOL_DIR/bin/network-ip.sh" "$@"
}

# Wired and Wi-Fi adapters as "device type" lines, connected or not: the menu
# hides a disconnected one by itself.
network_ip_adapters() {
  network_ip_helper list 2>/dev/null | jq -r '.adapters[] | "\(.device) \(.type)"' 2>/dev/null
  return 0
}

# One menu row: "  "<id>": {<fields>},".
network_ip_row() {
  printf '  "%s": {%s},\n' "$1" "$2"
}

# The helper path and device names go inside single quotes in the menu's
# shell commands and inside JSON strings, so neither may contain quotes,
# backslashes or `$`.
network_ip_rows() {
  local helper=$NETWORK_IP_HELPER device type label icon run when id provider glyph
  # Nerd Font glyphs as UTF-8 bytes: $'\U...' only works in a UTF-8 locale.
  local ip_icon=$'\xf3\xb0\xa9\xa0' dhcp_icon=$'\xf3\xb0\xa9\x9f' custom_icon=$'\xef\x81\x80'
  local cloudflare_icon=$'\xf3\xb0\x85\x9f' google_icon=$'\xf3\xb0\x8a\xad'
  [[ $helper =~ ^[A-Za-z0-9_./\ -]+$ ]] || fail "$(tool_text 'ruta no válida para el menú: %1' "$helper")"
  network_ip_row setup.network.ip "\"icon\":\"$ip_icon\",\"label\":\"IP\",\"when\":\"[[ -f '$helper' ]]\""
  while read -r device type; do
    [[ $device =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || continue
    if [[ $type == wifi ]]; then
      label="Wi-Fi ($device)" icon=$'\xf3\xb0\x96\xa9'
    else
      label="Ethernet ($device)" icon=$'\xf3\xb0\x88\x80'
    fi
    run="bash '$helper'"
    # Hidden while the adapter has no connection to change.
    when="$run ip '$device' >/dev/null 2>&1"
    id="if-${device//./-}"

    network_ip_row "setup.network.ip.$id" "\"icon\":\"$icon\",\"label\":\"$label\",\"when\":\"$when\""
    network_ip_row "setup.network.ip.$id.dhcp" "\"icon\":\"$dhcp_icon\",\"label\":\"DHCP\",\"checked\":\"[[ \\\"\$($run ip '$device')\\\" == DHCP ]]\",\"action\":\"$run ip '$device' DHCP --notify\""
    network_ip_row "setup.network.ip.$id.custom" "\"icon\":\"$custom_icon\",\"label\":\"Custom\",\"checked\":\"[[ \\\"\$($run ip '$device')\\\" == Custom ]]\",\"action\":\"omarchy-launch-floating-terminal-with-presentation \\\"$run ip '$device' Custom\\\"\""

    network_ip_row "setup.network.dns.$id" "\"icon\":\"$icon\",\"label\":\"$label\",\"when\":\"$when\""
    for provider in DHCP Cloudflare Google; do
      case $provider in
        DHCP) glyph=$dhcp_icon ;;
        Cloudflare) glyph=$cloudflare_icon ;;
        Google) glyph=$google_icon ;;
      esac
      network_ip_row "setup.network.dns.$id.${provider,,}" "\"icon\":\"$glyph\",\"label\":\"$provider\",\"checked\":\"[[ \\\"\$($run dns '$device')\\\" == $provider ]]\",\"action\":\"$run dns '$device' $provider --notify\""
    done
    network_ip_row "setup.network.dns.$id.custom" "\"icon\":\"$custom_icon\",\"label\":\"Custom\",\"checked\":\"[[ \\\"\$($run dns '$device')\\\" == Custom ]]\",\"action\":\"omarchy-launch-floating-terminal-with-presentation \\\"$run dns '$device' Custom\\\"\""
  done < <(network_ip_adapters)
}

network_ip_menu_rows() {
  [[ -f $MENU_FILE ]] && grep -E -- "$NETWORK_IP_ROW_PATTERN" "$MENU_FILE"
  return 0
}

network_ip_menu_remove() {
  local tmp
  [[ -f $MENU_FILE ]] && grep -qE -- "$NETWORK_IP_ROW_PATTERN" "$MENU_FILE" || return 0
  tmp=$(mktemp "$MENU_FILE.XXXXXX")
  grep -vE -- "$NETWORK_IP_ROW_PATTERN" "$MENU_FILE" >"$tmp"
  mv -f -- "$tmp" "$MENU_FILE"
}

network_ip_apply() {
  local rows
  if network_ip_enabled; then
    install_helper_i18n
    install -m 0644 -- "$TOOL_DIR/bin/network-ip.sh" "$NETWORK_IP_HELPER"
    [[ -f $MENU_FILE ]] || return 0
    rows=$(network_ip_rows) || return 1
    # Rewrite only when different: Omarchy reloads the menu on every change.
    if [[ $(network_ip_menu_rows) != "$rows" ]]; then
      network_ip_menu_remove
      menu_insert_rows "$rows"
    fi
  else
    network_ip_menu_remove
    rm -f -- "$NETWORK_IP_HELPER" "$STATE_DIR/network-ip.dns"
  fi
}

network_ip_status() {
  local enabled=false applied=false network='{"globalDns":"DHCP","adapters":[]}'
  if network_ip_enabled; then
    enabled=true
    if cmp -s -- "$TOOL_DIR/bin/network-ip.sh" "$NETWORK_IP_HELPER" &&
      { [[ ! -f $MENU_FILE ]] || [[ $(network_ip_menu_rows) == "$(network_ip_rows)" ]]; }; then
      applied=true
    fi
    network=$(network_ip_helper list 2>/dev/null) || network='{"globalDns":"DHCP","adapters":[]}'
  elif [[ ! -e $NETWORK_IP_HELPER && -z $(network_ip_menu_rows) ]]; then
    applied=true
  fi
  jq -n --argjson enabled "$enabled" --argjson applied "$applied" --argjson network "$network" \
    '{enabled: $enabled, applied: $applied, network: $network, summary: (if $enabled then "Activado" else "Desactivado" end)}'
}

network_ip_enable() {
  config_update '.modules["network-ip"].enabled = true'
  network_ip_apply
}

network_ip_disable() {
  config_update '.modules["network-ip"].enabled = false'
  network_ip_apply
}

# "Volver a DHCP" on the module page: network-ip dhcp DEVICE.
network_ip_dhcp() {
  network_ip_helper ip "${1:-}" DHCP
}
