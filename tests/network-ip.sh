# shellcheck shell=bash
# Sourced by tests/run.sh. network-ip: Setup › Network › IP rows in the Omarchy
# menu and the helper they run, against a fake nmcli that keeps one wired
# connection's settings in files and logs every change.

nm="$work/nm"
mkdir -p "$nm" "$work/nm-bin"
reset_nm() {
  rm -f -- "$nm"/*
  printf '%s\n' 'uuid-1:802-3-ethernet:enp6s0' 'uuid-lo:loopback:lo' 'uuid-br:bridge:docker0' >"$nm/active"
  printf 'Wired connection 1\n' >"$nm/conn.connection.id"
  printf 'auto\n' >"$nm/conn.ipv4.method"
  printf '\n' >"$nm/conn.ipv4.dns"
  printf '10.0.0.227/24\n' >"$nm/dev.IP4.ADDRESS"
  printf '10.0.0.1\n' >"$nm/dev.IP4.GATEWAY"
  printf '10.0.0.1 | 10.0.10.1\n' >"$nm/dev.IP4.DNS"
}
cat >"$work/nm-bin/nmcli" <<FAKE
#!/bin/bash
nm="$nm"
case "\$*" in
  "-t -f UUID,TYPE,DEVICE connection show --active") cat "\$nm/active" ;;
  "-g "*" connection show uuid-1") cat "\$nm/conn.\$2" 2>/dev/null || echo ;;
  "-g "*" device show enp6s0") cat "\$nm/dev.\$2" ;;
  "connection modify uuid-1 "*)
    shift 3
    printf '%s|' "\$@" >>"\$nm/modify.log"; echo >>"\$nm/modify.log"
    while (( \$# >= 2 )); do printf '%s\n' "\$2" >"\$nm/conn.\$1"; shift 2; done ;;
  "device reapply enp6s0") echo reapply >>"\$nm/apply.log" ;;
  *) echo "fake nmcli: unexpected \$*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$work/nm-bin/nmcli"
export PATH="$work/nm-bin:$PATH"
reset_nm

ni() { "$tool" status | jq -r ".modules[\"network-ip\"]$1"; }
helper="$OMARCHY_TOOL_STATE_DIR/network-ip.sh"
ip_rows() { grep -c '^  "setup\.network\.ip' "$OMARCHY_TOOL_MENU_FILE"; }
# The menu file as Omarchy's MenuModel.js reads it: drop whole-line comments
# and trailing commas, then parse as JSON.
menu_json() {
  python3 -c 'import json, re, sys
raw = open(sys.argv[1]).read()
raw = re.sub(r"(?m)^\s*//[^\n]*(\n|$)", "", raw)
raw = re.sub(r",(\s*[}\]])", r"\1", raw)
print(json.dumps(json.loads(raw)))' "$OMARCHY_TOOL_MENU_FILE"
}

"$tool" apply
cp "$OMARCHY_TOOL_MENU_FILE" "$work/menu-before-ip"
check "network-ip is registered and starts off, applied" '"$tool" modules | grep -x network-ip >/dev/null && [[ $(ni .enabled) == false && $(ni .applied) == true && $(ni .summary) == Desactivado ]]'

"$tool" network-ip enable
check "network-ip enable adds the three IP rows" '[[ $(ip_rows) == 3 ]]'
check "network-ip rows keep the user rows and the closing brace" 'grep -q "\"personal\"" "$OMARCHY_TOOL_MENU_FILE" && [[ $(tail -n1 "$OMARCHY_TOOL_MENU_FILE") == "}" ]]'
check "network-ip menu parses the way Omarchy reads it" '[[ $(menu_json | jq -r "[.[\"setup.network.ip\"].label, .[\"setup.network.ip.dhcp\"].label, .[\"setup.network.ip.custom\"].label] | join(\",\")") == "IP,DHCP,Custom" ]] && [[ $(menu_json | jq -r ".personal.label") == Personal ]]'
check "network-ip rows run the copied helper" '[[ $(menu_json | jq -r ".[\"setup.network.ip.dhcp\"].action") == "bash '"'"'$helper'"'"' DHCP --notify" ]] && [[ $(menu_json | jq -r ".[\"setup.network.ip.custom\"].action") == "omarchy-launch-floating-terminal-with-presentation \"bash '"'"'$helper'"'"' Custom\"" ]] && cmp -s "$repo/bin/network-ip.sh" "$helper"'
check "network-ip checked conditions follow the helper" 'eval "$(menu_json | jq -r ".[\"setup.network.ip.dhcp\"].checked")" && ! eval "$(menu_json | jq -r ".[\"setup.network.ip.custom\"].checked")"'
cp "$OMARCHY_TOOL_MENU_FILE" "$work/menu-with-ip"
"$tool" network-ip enable
"$tool" apply
check "network-ip enable and apply are idempotent" 'cmp -s "$OMARCHY_TOOL_MENU_FILE" "$work/menu-with-ip"'
check "network-ip enabled status is applied and shows the connection" '[[ $(ni .applied) == true && $(ni .summary) == Activado && $(ni .network.connection) == "Wired connection 1" && $(ni .network.mode) == DHCP && $(ni .network.address) == 10.0.0.227/24 && $(ni .network.gateway) == 10.0.0.1 ]]'
check "network-ip helper prints the current mode" '[[ $(bash "$helper") == DHCP ]]'

# Invalid input never reaches nmcli.
bad_custom() { ! printf '%s\n%s\n' "$1" "$2" | bash "$helper" Custom >/dev/null 2>&1 && [[ ! -e $nm/modify.log ]]; }
check "network-ip rejects an address without prefix" 'bad_custom 10.0.0.50 10.0.0.1'
check "network-ip rejects a bad octet" 'bad_custom 10.0.0.300/24 10.0.0.1'
check "network-ip rejects octets with leading zeros" 'bad_custom 10.0.0.050/24 10.0.0.1'
check "network-ip rejects prefix 0 and 33" 'bad_custom 10.0.0.50/0 10.0.0.1 && bad_custom 10.0.0.50/33 10.0.0.1'
check "network-ip rejects a gateway outside the subnet" 'bad_custom 10.0.0.50/24 10.0.1.1'
check "network-ip rejects a gateway equal to the address" 'bad_custom 10.0.0.50/24 10.0.0.50'
check "network-ip rejects network and broadcast addresses" 'bad_custom 10.0.0.0/24 10.0.0.1 && bad_custom 10.0.0.255/24 10.0.0.1 && bad_custom 10.0.0.50/24 10.0.0.255'
check "network-ip rejects shell text" 'bad_custom "10.0.0.50/24;reboot" 10.0.0.1 && bad_custom 10.0.0.50/24 "\$(id)"'

printf '\n\n' | bash "$helper" Custom >/dev/null
check "network-ip Custom keeps the shown values on Enter and copies the DNS in use" '[[ $(cat "$nm/modify.log") == "ipv4.method|manual|ipv4.addresses|10.0.0.227/24|ipv4.gateway|10.0.0.1|ipv4.dns|10.0.0.1,10.0.10.1|" ]] && grep -qx reapply "$nm/apply.log" && [[ $(bash "$helper") == Custom ]]'
check "network-ip records only the DNS it copied" '[[ $(cat "$OMARCHY_TOOL_STATE_DIR/network-ip.dns") == "uuid-1 10.0.0.1,10.0.10.1" ]]'
"$tool" network-ip dhcp
check "network-ip DHCP takes back the copied DNS" '[[ $(tail -n1 "$nm/modify.log") == "ipv4.method|auto|ipv4.addresses||ipv4.gateway||ipv4.dns||" ]] && [[ ! -e $OMARCHY_TOOL_STATE_DIR/network-ip.dns && $(bash "$helper") == DHCP ]]'

reset_nm
printf '1.1.1.1\n' >"$nm/conn.ipv4.dns"
printf '192.168.1.20/24\n192.168.1.1\n' | bash "$helper" Custom >/dev/null
check "network-ip Custom keeps DNS the connection already has" '[[ $(cat "$nm/modify.log") == "ipv4.method|manual|ipv4.addresses|192.168.1.20/24|ipv4.gateway|192.168.1.1|" ]] && [[ ! -e $OMARCHY_TOOL_STATE_DIR/network-ip.dns ]]'
bash "$helper" DHCP
check "network-ip DHCP leaves DNS it did not copy" '[[ $(tail -n1 "$nm/modify.log") == "ipv4.method|auto|ipv4.addresses||ipv4.gateway||" ]] && [[ $(cat "$nm/conn.ipv4.dns") == 1.1.1.1 ]]'

reset_nm
printf '\n\n' | bash "$helper" Custom >/dev/null
printf '9.9.9.9\n' >"$nm/conn.ipv4.dns"
bash "$helper" DHCP
check "network-ip DHCP leaves DNS changed after it copied them" '[[ $(cat "$nm/conn.ipv4.dns") == 9.9.9.9 && ! -e $OMARCHY_TOOL_STATE_DIR/network-ip.dns ]]'

printf 'uuid-lo:loopback:lo\n' >"$nm/active"
check "network-ip without wired or Wi-Fi fails clearly" '[[ $(bash "$helper" DHCP 2>&1) == *"no hay ninguna conexión por cable o Wi-Fi activa"* ]]'
check "network-ip DHCP from the menu reports errors as a notification" '! bash "$helper" DHCP --notify 2>/dev/null && grep -q "IP de red" "$work/notify-all.log"'
check "network-ip status without a connection still answers" '[[ $(ni .enabled) == true && $(ni .network.connection) == null ]]'
reset_nm

"$tool" network-ip disable
check "network-ip disable removes only its rows and helper" 'cmp -s "$OMARCHY_TOOL_MENU_FILE" "$work/menu-before-ip" && [[ ! -e $helper && $(ni .applied) == true && $(ni .summary) == Desactivado ]]'

"$tool" network-ip enable
cp "$OMARCHY_TOOL_MENU_FILE" "$work/menu-uninstall"
OMARCHY_TOOL_MENU_FILE="$work/menu-uninstall" OMARCHY_TOOL_STATE_DIR="$work/ip-uninstall-state" \
  OMARCHY_TOOL_CONFIG_DIR="$work/ip-uninstall-config" bash "$repo/bin/uninstall.sh"
check "uninstall removes the IP rows and keeps user rows" '[[ $(grep -c "^  \"setup\.network\.ip" "$work/menu-uninstall") == 0 ]] && grep -q "\"personal\"" "$work/menu-uninstall"'
"$tool" network-ip disable
