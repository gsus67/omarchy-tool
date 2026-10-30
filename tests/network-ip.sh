# shellcheck shell=bash
# Sourced by tests/run.sh. network-ip: per-adapter IP and DNS rows in the
# Omarchy menu and the helper they run, against a fake nmcli that keeps two
# adapters' connections in files and logs every change, and a fake
# omarchy-dns whose global provider is a file.

nm="$work/nm"
mkdir -p "$nm" "$work/nm-bin"
reset_nm() {
  rm -f -- "$nm"/*
  printf '%s\n' 'eth0:ethernet:connected' 'wlo1:wifi:connected' 'lo:loopback:connected (externally)' \
    'docker0:bridge:connected (externally)' >"$nm/devices"
  printf 'uuid-e\n' >"$nm/dev.eth0.GENERAL.CON-UUID"
  printf 'uuid-w\n' >"$nm/dev.wlo1.GENERAL.CON-UUID"
  printf '10.0.0.227/24\n' >"$nm/dev.eth0.IP4.ADDRESS"
  printf '10.0.0.1\n' >"$nm/dev.eth0.IP4.GATEWAY"
  printf '10.0.0.1 | 10.0.10.1\n' >"$nm/dev.eth0.IP4.DNS"
  printf '192.168.1.40/24\n' >"$nm/dev.wlo1.IP4.ADDRESS"
  printf '192.168.1.1\n' >"$nm/dev.wlo1.IP4.GATEWAY"
  printf '192.168.1.1\n' >"$nm/dev.wlo1.IP4.DNS"
  for uuid in uuid-e uuid-w; do
    printf 'auto\n' >"$nm/conn.$uuid.ipv4.method"
    printf 'no\n' >"$nm/conn.$uuid.ipv4.ignore-auto-dns"
    printf '\n' >"$nm/conn.$uuid.ipv4.dns"
  done
  printf 'Wired connection 1\n' >"$nm/conn.uuid-e.connection.id"
  printf 'Casa\n' >"$nm/conn.uuid-w.connection.id"
  printf 'DHCP\n' >"$nm/global-dns"
}
cat >"$work/nm-bin/nmcli" <<FAKE
#!/bin/bash
nm="$nm"
case "\$*" in
  "-t -f DEVICE,TYPE,STATE device status") cat "\$nm/devices" ;;
  "-g "*" device show "*) cat "\$nm/dev.\$5.\$2" 2>/dev/null || echo ;;
  "-g "*" connection show "*) cat "\$nm/conn.\$5.\$2" 2>/dev/null || echo ;;
  "connection modify "*)
    uuid=\$3
    shift 3
    { printf '%s|' "\$uuid" "\$@"; echo; } >>"\$nm/modify.log"
    while (( \$# >= 2 )); do printf '%s\n' "\$2" >"\$nm/conn.\$uuid.\$1"; shift 2; done ;;
  "device reapply "*) echo "reapply \$3" >>"\$nm/apply.log" ;;
  *) echo "fake nmcli: unexpected \$*" >&2; exit 1 ;;
esac
FAKE
printf '#!/bin/bash\ncat "%s/global-dns"\n' "$nm" >"$work/nm-bin/omarchy-dns"
chmod +x "$work/nm-bin/nmcli" "$work/nm-bin/omarchy-dns"
export PATH="$work/nm-bin:$PATH"
reset_nm

ni() { "$tool" status | jq -r ".modules[\"network-ip\"]$1"; }
helper="$OMARCHY_TOOL_STATE_DIR/network-ip.sh"
our_rows() { grep -cE '^  "setup\.network\.(ip|dns)' "$OMARCHY_TOOL_MENU_FILE"; }
# The menu file as Omarchy's MenuModel.js reads it: drop whole-line comments
# and trailing commas, then parse as JSON.
menu_json() {
  python3 -c 'import json, re, sys
raw = open(sys.argv[1]).read()
raw = re.sub(r"(?m)^\s*//[^\n]*(\n|$)", "", raw)
raw = re.sub(r",(\s*[}\]])", r"\1", raw)
print(json.dumps(json.loads(raw)))' "$1"
}
menu() { menu_json "$OMARCHY_TOOL_MENU_FILE" | jq -r "$1"; }
last_modify() { tail -n1 "$nm/modify.log"; }
q="'"

"$tool" apply
cp "$OMARCHY_TOOL_MENU_FILE" "$work/menu-before-ip"
check "network-ip is registered and starts off, applied" '"$tool" modules | grep -x network-ip >/dev/null && [[ $(ni .enabled) == false && $(ni .applied) == true && $(ni .summary) == Desactivado ]]'

"$tool" network-ip enable
check "network-ip adds IP and DNS rows for each adapter" '[[ $(our_rows) == 17 ]]'
check "network-ip rows keep the user rows and the closing brace" 'grep -q "\"personal\"" "$OMARCHY_TOOL_MENU_FILE" && [[ $(tail -n1 "$OMARCHY_TOOL_MENU_FILE") == "}" ]]'
check "network-ip menu parses the way Omarchy reads it" '[[ $(menu ".[\"setup.network.ip\"].label") == IP && $(menu ".[\"setup.network.ip.if-eth0\"].label") == "Ethernet (eth0)" && $(menu ".[\"setup.network.dns.if-wlo1\"].label") == "Wi-Fi (wlo1)" && $(menu ".personal.label") == Personal ]]'
check "network-ip skips loopback and bridges" '[[ $(menu "[keys[] | select(test(\"if-(lo|docker0)(\\\\.|$)\"))] | length") == 0 ]]'
check "network-ip DNS rows offer Omarchy's four providers" '[[ $(menu "[keys[] | select(startswith(\"setup.network.dns.if-eth0.\"))] | sort | join(\",\")") == "setup.network.dns.if-eth0.cloudflare,setup.network.dns.if-eth0.custom,setup.network.dns.if-eth0.dhcp,setup.network.dns.if-eth0.google" ]]'
check "network-ip rows run the copied helper on their adapter" '[[ $(menu ".[\"setup.network.ip.if-eth0.dhcp\"].action") == "bash ${q}$helper${q} ip ${q}eth0${q} DHCP --notify" && $(menu ".[\"setup.network.ip.if-wlo1.custom\"].action") == "omarchy-launch-floating-terminal-with-presentation \"bash ${q}$helper${q} ip ${q}wlo1${q} Custom\"" && $(menu ".[\"setup.network.dns.if-eth0.google\"].action") == "bash ${q}$helper${q} dns ${q}eth0${q} Google --notify" ]] && cmp -s "$repo/bin/network-ip.sh" "$helper"'
check "network-ip checked conditions follow each adapter" 'eval "$(menu ".[\"setup.network.ip.if-eth0.dhcp\"].checked")" && ! eval "$(menu ".[\"setup.network.ip.if-eth0.custom\"].checked")" && eval "$(menu ".[\"setup.network.dns.if-wlo1.dhcp\"].checked")" && ! eval "$(menu ".[\"setup.network.dns.if-wlo1.google\"].checked")"'
check "network-ip hides a disconnected adapter" 'eval "$(menu ".[\"setup.network.ip.if-wlo1\"].when")" && sed -i "s/^wlo1:wifi:connected$/wlo1:wifi:disconnected/" "$nm/devices" && ! eval "$(menu ".[\"setup.network.ip.if-wlo1\"].when")" && ! eval "$(menu ".[\"setup.network.dns.if-wlo1\"].when")" && eval "$(menu ".[\"setup.network.ip.if-eth0\"].when")"'
reset_nm
cp "$OMARCHY_TOOL_MENU_FILE" "$work/menu-with-ip"
"$tool" network-ip enable
"$tool" apply
check "network-ip enable and apply are idempotent" 'cmp -s "$OMARCHY_TOOL_MENU_FILE" "$work/menu-with-ip"'
check "network-ip status lists each adapter" '[[ $(ni .applied) == true && $(ni .summary) == Activado && $(ni ".network.adapters | length") == 2 && $(ni ".network.adapters[0].connection") == "Wired connection 1" && $(ni ".network.adapters[1].type") == wifi && $(ni ".network.adapters[1].ip") == DHCP && $(ni ".network.adapters[1].dns") == DHCP && $(ni .network.globalDns) == DHCP ]]'

check "network-ip refuses a disconnected adapter" 'sed -i "s/^wlo1:wifi:connected$/wlo1:wifi:disconnected/" "$nm/devices" && [[ $(bash "$helper" ip wlo1 DHCP 2>&1) == *"wlo1 no está conectado"* && ! -e $nm/modify.log && $(ni ".network.adapters[1].connected") == false ]]'
reset_nm
check "network-ip refuses unknown and malformed adapters" '[[ $(bash "$helper" ip eth9 2>&1) == *"no hay ningún adaptador de cable o Wi-Fi llamado eth9"* && $(bash "$helper" ip "eth0;id" 2>&1) == *"adaptador no válido"* ]] && ! bash "$helper" ip lo 2>/dev/null && ! bash "$helper" ip 2>/dev/null'
check "network-ip DHCP from the menu reports errors as a notification" '! bash "$helper" ip eth9 DHCP --notify 2>/dev/null && grep -q "^.*Red" "$work/notify-all.log"'

# Invalid input never reaches nmcli.
bad_custom() { ! printf '%s\n%s\n' "$1" "$2" | bash "$helper" ip eth0 Custom >/dev/null 2>&1 && [[ ! -e $nm/modify.log ]]; }
check "network-ip rejects an address without prefix" 'bad_custom 10.0.0.50 10.0.0.1'
check "network-ip rejects a bad octet" 'bad_custom 10.0.0.300/24 10.0.0.1'
check "network-ip rejects octets with leading zeros" 'bad_custom 10.0.0.050/24 10.0.0.1'
check "network-ip rejects prefix 0 and 33" 'bad_custom 10.0.0.50/0 10.0.0.1 && bad_custom 10.0.0.50/33 10.0.0.1'
check "network-ip rejects a gateway outside the subnet" 'bad_custom 10.0.0.50/24 10.0.1.1'
check "network-ip rejects a gateway equal to the address" 'bad_custom 10.0.0.50/24 10.0.0.50'
check "network-ip rejects network and broadcast addresses" 'bad_custom 10.0.0.0/24 10.0.0.1 && bad_custom 10.0.0.255/24 10.0.0.1 && bad_custom 10.0.0.50/24 10.0.0.255'
check "network-ip rejects shell text" 'bad_custom "10.0.0.50/24;reboot" 10.0.0.1 && bad_custom 10.0.0.50/24 "\$(id)"'

printf '\n\n' | bash "$helper" ip eth0 Custom >/dev/null 2>&1
check "network-ip Custom changes only that adapter and keeps the DNS in use" '[[ $(cat "$nm/modify.log") == "uuid-e|ipv4.method|manual|ipv4.addresses|10.0.0.227/24|ipv4.gateway|10.0.0.1|ipv4.dns|10.0.0.1,10.0.10.1|" ]] && grep -qx "reapply eth0" "$nm/apply.log" && [[ $(bash "$helper" ip eth0) == Custom && $(bash "$helper" ip wlo1) == DHCP ]]'
printf '192.168.1.50/24\n\n' | bash "$helper" ip wlo1 Custom >/dev/null 2>&1
check "network-ip records copied DNS per adapter" '[[ $(cat "$OMARCHY_TOOL_STATE_DIR/network-ip.dns") == "uuid-e 10.0.0.1,10.0.10.1"$'"'"'\n'"'"'"uuid-w 192.168.1.1" ]]'
"$tool" network-ip dhcp eth0
check "network-ip DHCP takes back only that adapter's copied DNS" '[[ $(last_modify) == "uuid-e|ipv4.method|auto|ipv4.addresses||ipv4.gateway||ipv4.dns||" && $(cat "$OMARCHY_TOOL_STATE_DIR/network-ip.dns") == "uuid-w 192.168.1.1" && $(bash "$helper" ip eth0) == DHCP && $(bash "$helper" ip wlo1) == Custom ]]'
check "network-ip refuses DHCP DNS while the IP is static" '[[ $(bash "$helper" dns wlo1 DHCP 2>&1) == *"con IP fija el router no da DNS"* && $(last_modify) != uuid-w*ignore-auto-dns* ]]'
bash "$helper" dns wlo1 Cloudflare
check "network-ip chosen DNS replace the copied ones and their record" '[[ $(last_modify) == "uuid-w|ipv4.ignore-auto-dns|yes|ipv4.dns|1.1.1.1,1.0.0.1|ipv6.ignore-auto-dns|yes|ipv6.dns|2606:4700:4700::1111,2606:4700:4700::1001|" && ! -e $OMARCHY_TOOL_STATE_DIR/network-ip.dns && $(bash "$helper" dns wlo1) == Cloudflare ]]'
bash "$helper" ip wlo1 DHCP
check "network-ip DHCP keeps DNS chosen for the adapter" '[[ $(last_modify) == "uuid-w|ipv4.method|auto|ipv4.addresses||ipv4.gateway||" && $(cat "$nm/conn.uuid-w.ipv4.dns") == 1.1.1.1,1.0.0.1 ]]'

reset_nm
bash "$helper" dns eth0 Google
check "network-ip sets Google DNS on one adapter only" '[[ $(last_modify) == "uuid-e|ipv4.ignore-auto-dns|yes|ipv4.dns|8.8.8.8,8.8.4.4|ipv6.ignore-auto-dns|yes|ipv6.dns|2001:4860:4860::8888,2001:4860:4860::8844|" && $(bash "$helper" dns eth0) == Google && $(bash "$helper" dns wlo1) == DHCP ]]'
printf '9.9.9.9 2620:fe::fe, 149.112.112.112\n' | bash "$helper" dns eth0 Custom >/dev/null 2>&1
check "network-ip Custom DNS splits IPv4 and IPv6 servers" '[[ $(last_modify) == "uuid-e|ipv4.ignore-auto-dns|yes|ipv4.dns|9.9.9.9,149.112.112.112|ipv6.ignore-auto-dns|yes|ipv6.dns|2620:fe::fe|" && $(bash "$helper" dns eth0) == Custom ]]'
lines=$(wc -l <"$nm/modify.log")
check "network-ip Custom DNS rejects bad or missing servers" '! printf "9.9.9.9 dns.google\n" | bash "$helper" dns eth0 Custom >/dev/null 2>&1 && ! printf "1::2::3\n" | bash "$helper" dns eth0 Custom >/dev/null 2>&1 && ! printf "\$(id)\n" | bash "$helper" dns eth0 Custom >/dev/null 2>&1 && ! printf "\n" | bash "$helper" dns eth0 Custom >/dev/null 2>&1 && [[ $(wc -l <"$nm/modify.log") == "$lines" ]]'
bash "$helper" dns eth0 DHCP
check "network-ip DHCP DNS hands DNS back to the router" '[[ $(last_modify) == "uuid-e|ipv4.ignore-auto-dns|no|ipv4.dns||ipv6.ignore-auto-dns|no|ipv6.dns||" && $(bash "$helper" dns eth0) == DHCP ]]'

# The module page passes values as arguments: no prompt, same validation.
reset_nm
"$tool" network-ip ip eth0 Custom 10.0.0.60/24 10.0.0.1 >"$work/ip-page.out" 2>&1
check "network-ip page sets a static IP without asking" '[[ $(last_modify) == "uuid-e|ipv4.method|manual|ipv4.addresses|10.0.0.60/24|ipv4.gateway|10.0.0.1|ipv4.dns|10.0.0.1,10.0.10.1|" ]] && ! grep -q "prefijo \[" "$work/ip-page.out"'
lines=$(wc -l <"$nm/modify.log")
check "network-ip page values are validated like typed ones" '! "$tool" network-ip ip eth0 Custom 10.0.0.60/24 10.0.1.1 2>/dev/null && ! "$tool" network-ip ip eth0 Custom "10.0.0.60/24 ; id" 10.0.0.1 2>/dev/null && ! "$tool" network-ip ip eth0 Custom 10.0.0.60/24 "" 2>/dev/null && ! "$tool" network-ip ip eth0 2>/dev/null && [[ $(wc -l <"$nm/modify.log") == "$lines" ]]'
"$tool" network-ip dns wlo1 Custom "9.9.9.9 2620:fe::fe"
check "network-ip page sets own DNS servers without asking" '[[ $(last_modify) == "uuid-w|ipv4.ignore-auto-dns|yes|ipv4.dns|9.9.9.9|ipv6.ignore-auto-dns|yes|ipv6.dns|2620:fe::fe|" && $(ni ".network.adapters[1].dns") == Custom && $(ni ".network.adapters[1].dnsServers") == "9.9.9.9 2620:fe::fe" ]]'
lines=$(wc -l <"$nm/modify.log")
check "network-ip page refuses empty or bad DNS servers" '! "$tool" network-ip dns wlo1 Custom "" 2>/dev/null && ! "$tool" network-ip dns wlo1 Custom "9.9.9.9 \$(id)" 2>/dev/null && ! "$tool" network-ip dns wlo1 2>/dev/null && [[ $(wc -l <"$nm/modify.log") == "$lines" ]]'
"$tool" network-ip dns wlo1 Google
check "network-ip page switches DNS provider" '[[ $(ni ".network.adapters[1].dns") == Google ]]'
reset_nm

printf 'Cloudflare\n' >"$nm/global-dns"
lines=$(wc -l <"$nm/modify.log")
check "network-ip leaves DNS to Omarchy while its global DNS is set" '! bash "$helper" dns eth0 Google --notify 2>/dev/null && [[ $(wc -l <"$nm/modify.log") == "$lines" && $(bash "$helper" dns eth0) == DHCP && $(ni .network.globalDns) == Cloudflare ]] && grep -q "Cloudflare" "$work/notify-all.log"'
check "network-ip still changes IP while Omarchy DNS is set" 'bash "$helper" ip eth0 DHCP'
reset_nm

"$tool" network-ip disable
check "network-ip disable removes only its rows and helper" 'cmp -s "$OMARCHY_TOOL_MENU_FILE" "$work/menu-before-ip" && [[ ! -e $helper && $(ni .applied) == true && $(ni .summary) == Desactivado ]]'

"$tool" network-ip enable
cp "$OMARCHY_TOOL_MENU_FILE" "$work/menu-uninstall"
OMARCHY_TOOL_MENU_FILE="$work/menu-uninstall" OMARCHY_TOOL_STATE_DIR="$work/ip-uninstall-state" \
  OMARCHY_TOOL_CONFIG_DIR="$work/ip-uninstall-config" bash "$repo/bin/uninstall.sh"
check "uninstall removes the IP and DNS rows and keeps user rows" '[[ $(grep -cE "^  \"setup\.network\.(ip|dns)" "$work/menu-uninstall") == 0 ]] && grep -q "\"personal\"" "$work/menu-uninstall"'
"$tool" network-ip disable
