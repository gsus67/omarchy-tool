# shellcheck shell=bash
# Module: network-ip. Adds Setup › Network › IP to the Omarchy menu, next to
# Omarchy's own DNS entry; the rows run a copy of bin/network-ip.sh. No root:
# NetworkManager lets the session user change connections.
NETWORK_IP_HELPER="$STATE_DIR/network-ip.sh"
# Our rows, by id and by the helper they run; no user row matches both.
NETWORK_IP_ROW_PATTERN='^  "setup\.network\.ip(\.dhcp|\.custom)?": \{.*/network-ip\.sh'

network_ip_enabled() {
  [[ $(config_get '.modules["network-ip"].enabled // false') == true ]]
}

# The helper path goes inside single quotes in the menu's shell commands and
# inside a JSON string, so it may not contain quotes, backslashes or `$`.
network_ip_rows() {
  local helper=$NETWORK_IP_HELPER
  [[ $helper =~ ^[A-Za-z0-9_./\ -]+$ ]] || fail "$(tool_text 'ruta no válida para el menú: %1' "$helper")"
  cat <<EOF
  "setup.network.ip": {"icon":"󰩠","label":"IP","when":"[[ -f '$helper' ]]"},
  "setup.network.ip.dhcp": {"icon":"󰩟","label":"DHCP","checked":"[[ \\"\$(bash '$helper')\\" == \\"DHCP\\" ]]","action":"bash '$helper' DHCP --notify"},
  "setup.network.ip.custom": {"icon":"","label":"Custom","checked":"[[ \\"\$(bash '$helper')\\" == \\"Custom\\" ]]","action":"omarchy-launch-floating-terminal-with-presentation \\"bash '$helper' Custom\\""},
EOF
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
  local enabled=false applied=false info='{}'
  if network_ip_enabled; then
    enabled=true
    if cmp -s -- "$TOOL_DIR/bin/network-ip.sh" "$NETWORK_IP_HELPER" &&
      { [[ ! -f $MENU_FILE ]] || [[ $(network_ip_menu_rows) == "$(network_ip_rows)" ]]; }; then
      applied=true
    fi
    info=$(OMARCHY_TOOL_STATE_DIR=$STATE_DIR bash "$TOOL_DIR/bin/network-ip.sh" info 2>/dev/null) || info='{}'
  elif [[ ! -e $NETWORK_IP_HELPER && -z $(network_ip_menu_rows) ]]; then
    applied=true
  fi
  jq -n --argjson enabled "$enabled" --argjson applied "$applied" --argjson network "$info" \
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

# "Volver a DHCP" on the module page.
network_ip_dhcp() {
  OMARCHY_TOOL_STATE_DIR=$STATE_DIR bash "$TOOL_DIR/bin/network-ip.sh" DHCP
}
