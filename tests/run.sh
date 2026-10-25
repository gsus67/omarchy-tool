#!/bin/bash

# Backend tests for omarchy-tool. Runs against a throwaway config, state,
# applications dir, menu and VM compose, so it never touches the real system.
# The privileged compose writer runs unprivileged here (OMARCHY_TOOL_PRIV="").
#
#   tests/run.sh

set -uo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tool="$repo/bin/omarchy-tool"
# Shared folders must live under /home, /mnt, /media or /run/media.
mkdir -p "$HOME/.cache"
work=$(mktemp -d "$HOME/.cache/omarchy-tool-test.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

export OMARCHY_TOOL_CONFIG_DIR="$work/config"
export OMARCHY_TOOL_STATE_DIR="$work/my state"
export OMARCHY_TOOL_APPLICATIONS_DIR="$work/applications"
export OMARCHY_TOOL_MENU_FILE="$work/omarchy-menu.jsonc"
export OMARCHY_TOOL_COMPOSE="$work/docker-compose.yml"
export OMARCHY_TOOL_PRIV=""
# Never see the real Windows VM: "no VM" unless a test sets a fake pid.
export OMARCHY_TOOL_VM_PID=""
export OMARCHY_TOOL_HYPR_DIR="$work/hypr"
mkdir -p "$OMARCHY_TOOL_HYPR_DIR"
printf -- '-- user config\nrequire("hypr.bindings")\n' >"$OMARCHY_TOOL_HYPR_DIR/hyprland.lua"
cp "$OMARCHY_TOOL_HYPR_DIR/hyprland.lua" "$work/hyprland-original"
export OMARCHY_TOOL_WINDOWS_SHARED="$work/Windows"
export OMARCHY_TOOL_UDEV_RULES="$work/70-omarchy-tool-webhid.rules"
export OMARCHY_TOOL_HIDRAW_SYS="$work/sys"
export OMARCHY_TOOL_USB_SYS="$work/usb"
fake_usb() {
  mkdir -p "$OMARCHY_TOOL_USB_SYS/$1"
  printf '%s\n' "$2" >"$OMARCHY_TOOL_USB_SYS/$1/idVendor"
  printf '%s\n' "$3" >"$OMARCHY_TOOL_USB_SYS/$1/idProduct"
  printf '%s\n' "$4" >"$OMARCHY_TOOL_USB_SYS/$1/bDeviceClass"
  printf '%s\n' "$5" >"$OMARCHY_TOOL_USB_SYS/$1/manufacturer"
  printf '%s\n' "$6" >"$OMARCHY_TOOL_USB_SYS/$1/product"
}
fake_usb 1-3 093a 822a 00 GLORIOUS "Model O 2 Wireless"
fake_usb 1-4 1b1c 2b0d 00 Corsair "CORSAIR VANGUARD 96"
fake_usb usb1 1d6b 0002 09 Linux "xHCI Host Controller"
fake_usb 1-14 8087 0033 e0 "" ""
export OMARCHY_TOOL_USB_IDS="$work/usb.ids"
printf '8087  Intel Corp.\n\t0032  AX210 Bluetooth\n\t0033  AX211 Bluetooth\n8088  Other\n' >"$OMARCHY_TOOL_USB_IDS"
fake_hid() {
  mkdir -p "$OMARCHY_TOOL_HIDRAW_SYS/$1/device"
  printf 'HID_ID=%s\nHID_NAME=%s\n' "$2" "$3" >"$OMARCHY_TOOL_HIDRAW_SYS/$1/device/uevent"
}
fake_hid hidraw5 0003:00001B1C:00002B0D "Corsair CORSAIR VANGUARD 96 Keyboard"
fake_hid hidraw6 0003:00001B1C:00002B0D "Corsair CORSAIR VANGUARD 96 Keyboard"
fake_hid hidraw2 0003:0000093A:0000822A "GLORIOUS Model O 2 Wireless"
fake_hid hidraw9 0005:0000046D:0000B023 "Bluetooth thing"
winroot="$OMARCHY_TOOL_WINDOWS_SHARED/Omarchy Tool"
winfolder="$winroot/Discos"
usbfolder="$winroot/Periféricos"
mkdir -p "$OMARCHY_TOOL_WINDOWS_SHARED"
mkdir -p "$OMARCHY_TOOL_APPLICATIONS_DIR" "$work/disk-a" "$work/disk b" "$work/disk-c"

desktop="$OMARCHY_TOOL_APPLICATIONS_DIR/windows-vm.desktop"
cat >"$desktop" <<'EOF'
[Desktop Entry]
Name=Windows
Exec=uwsm app -- omarchy-windows-vm launch
Icon=windows
Type=Application
EOF

compose="$OMARCHY_TOOL_COMPOSE"
cat >"$compose" <<'EOF'
services:
  windows:
    image: dockurr/windows
    environment:
      VERSION: "11"
      ARGUMENTS: "-rtc base=localtime,clock=host,driftfix=slew"
    devices:
      - /dev/kvm
      - /dev/net/tun
    volumes:
      - /var/lib/omarchy/windows/mounts/users/1000/storage:/storage
      - /var/lib/omarchy/windows/mounts/users/1000/shared:/shared
    restart: "no"
EOF
chmod 0640 "$compose"
cp "$compose" "$work/compose-original"

cat >"$OMARCHY_TOOL_MENU_FILE" <<'EOF'
{
  // user comment
  "personal": {"icon":"x","label":"Personal"},
}
EOF
cp "$OMARCHY_TOOL_MENU_FILE" "$work/menu-original"

failures=0
pass() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; failures=$((failures + 1)); }
check() { if eval "$2"; then pass "$1"; else bad "$1"; fi; }
wd() { "$tool" status | jq -r ".modules[\"windows-disks\"]$1"; }

check "status is valid JSON" '[[ $(wd .enabled) == false ]]'
check "summary says disabled" '[[ $(wd .summary) == Desactivado ]]'
check "starts with no disks" '[[ $(wd ".disks | length") == 0 ]]'

# Choosing disks while off only saves the choice.
"$tool" windows-disks add "$work/disk-a" DiskA
"$tool" windows-disks add "$work/disk b/" "Disk B"
check "adds two disks" '[[ $(wd ".disks | length") == 2 ]]'
check "trailing slash is stripped" '[[ $(wd ".disks[1].path") == "$work/disk b" ]]'
check "disks get Data2 and Data3" '[[ $(wd ".disks[0].share") == "\\\\host.lan\\Data2" && $(wd ".disks[1].share") == "\\\\host.lan\\Data3" ]]'
check "compose untouched while off" 'cmp -s "$compose" "$work/compose-original"'
check "third disk is refused" '! "$tool" windows-disks add "$work/disk-c" C 2>/dev/null && [[ $(wd ".disks | length") == 2 ]]'
check "re-adding a saved disk is allowed" '"$tool" windows-disks add "$work/disk-a" DiskA'
check "re-adding keeps the disk in its place" '"$tool" windows-disks add "$work/disk-a" DiskA && [[ $(wd ".disks[0].path") == "$work/disk-a" ]]'
check "unsafe name characters are replaced" '"$tool" windows-disks add "$work/disk-a" "a,b" && [[ $(wd ".disks[0].name") == a_b ]]'
"$tool" windows-disks remove "$work/disk-a"
"$tool" windows-disks remove "$work/disk b"
"$tool" windows-disks add "$work/disk-a" DiskA
"$tool" windows-disks add "$work/disk b" "Disk B"

check "rejects folders outside disk/home roots" '! "$tool" windows-disks add /etc X 2>/dev/null && ! "$tool" windows-disks add /tmp X 2>/dev/null'
check "rejects sharing /" '! "$tool" windows-disks add / X 2>/dev/null && ! "$tool" windows-disks add // X 2>/dev/null'
check "rejects colon paths" 'mkdir -p "$work/a:b" && ! "$tool" windows-disks add "$work/a:b" X 2>/dev/null'
check "rejects missing folder" '! "$tool" windows-disks add "$work/nope" X 2>/dev/null'

# On: both folders become /shared2 and /shared3 right after Omarchy's /shared.
"$tool" windows-disks enable
check "enable adds /shared2" 'grep -qxF "      - \"$work/disk-a:/shared2\"" "$compose"'
check "enable adds /shared3" 'grep -qxF "      - \"$work/disk b:/shared3\"" "$compose"'
check "shares sit right after /shared" '[[ $(grep -A1 ":/shared$" "$compose" | tail -n1) == *":/shared2\"" ]]'
check "Omarchy mounts kept" 'grep -q ":/storage$" "$compose" && [[ $(grep -c ":/shared$" "$compose") == 1 ]]'
check "compose mode kept" '[[ $(stat -c %a "$compose") == 640 ]]'
check "status reports applied" '[[ $(wd .applied) == true ]]'
check "summary counts disks" '[[ $(wd .summary) == "Comparte 2 discos" ]]'

# Letters: X and Y by default, changeable, never shared between disks or Z.
check "default letters are X and Y" '[[ $(wd ".disks[0].letter") == X && $(wd ".disks[1].letter") == Y ]]'
check "Windows folder has the scripts" '[[ -f $winfolder/omarchy-tool.ps1 && -f "$winfolder/Activar discos.cmd" && -f "$winfolder/Quitar discos.cmd" && -e $winfolder/.plugin-activo ]]'
printf 'X|\\\\host.lan\\Data2|DiskA\r\nY|\\\\host.lan\\Data3|Disk B\r\n' >"$work/discos-expected"
check "discos.txt lists letter, share and name" 'cmp -s "$winfolder/discos.txt" "$work/discos-expected"'
check "Windows scripts keep CRLF" 'file "$winfolder/Activar discos.cmd" | grep -q CRLF'
check "letter can be changed" '"$tool" windows-disks letter "$work/disk-a" m && [[ $(wd ".disks[0].letter") == M ]] && grep -q "^M|" "$winfolder/discos.txt"'
check "letter Z is refused" '! "$tool" windows-disks letter "$work/disk-a" Z 2>/dev/null'
check "a taken letter is refused" '! "$tool" windows-disks letter "$work/disk-a" Y 2>/dev/null'
check "next skips the taken letter" '"$tool" windows-disks letter "$work/disk-a" X && "$tool" windows-disks letter "$work/disk-a" next && [[ $(wd ".disks[0].letter") == W ]]'
"$tool" windows-disks letter "$work/disk-a" X
check "status says letters not set yet" '[[ $(wd .lettersSet) == false ]]'

before=$(md5sum <"$compose")
OMARCHY_TOOL_PRIV="false" "$tool" apply
check "apply does not rewrite when nothing changed" '[[ $(md5sum <"$compose") == "$before" ]]'

# Omarchy rewrote the compose (Windows reinstalled): apply puts the shares back.
cp "$work/compose-original" "$compose"
touch -d "+1 minute" "$compose"
check "status notices a rewritten compose" '[[ $(wd .applied) == false ]]'
"$tool" apply
check "apply re-adds shares after a rewrite" '[[ $(grep -c ":/shared[23]\"$" "$compose") == 2 ]]'

"$tool" windows-disks remove "$work/disk-a"
check "removing a disk renumbers the rest" 'grep -qxF "      - \"$work/disk b:/shared2\"" "$compose" && ! grep -q ":/shared3" "$compose"'
"$tool" windows-disks add "$work/disk-a" DiskA

# Off: compose back to exactly what Omarchy wrote, our record gone.
touch "$winfolder/.letras-puestas"
check "status sees letters set in Windows" '[[ $(wd .lettersSet) == true ]]'
"$tool" windows-disks disable
check "disable restores the compose" 'cmp -s "$compose" "$work/compose-original"'
check "disable removes the record" '[[ ! -e $OMARCHY_TOOL_STATE_DIR/compose.applied ]]'
check "disable keeps disk choices" '[[ $(wd ".disks | length") == 2 ]]'
check "disable leaves only Quitar while Windows has letters" '[[ -f "$winfolder/Quitar discos.cmd" && -f $winfolder/omarchy-tool.ps1 && ! -e "$winfolder/Activar discos.cmd" && ! -e $winfolder/.plugin-activo ]]'
rm -f "$winfolder/.letras-puestas"
"$tool" apply
check "without letters in Windows the folder goes" '[[ ! -e $winfolder ]]'

# Disks saved before letters existed get distinct ones.
jq '.modules["windows-disks"].disks |= map(del(.letter))' "$OMARCHY_TOOL_CONFIG_DIR/config.json" >"$work/c.json" && mv "$work/c.json" "$OMARCHY_TOOL_CONFIG_DIR/config.json"
"$tool" apply
check "missing letters are filled in, distinct" '[[ $(wd ".disks[0].letter") == X && $(wd ".disks[1].letter") == Y ]]'

# A cancelled password prompt leaves things as they were and reports it.
check "failed privileged write is reported" '! OMARCHY_TOOL_PRIV="false" "$tool" windows-disks enable 2>/dev/null'
check "failed write changes nothing" 'cmp -s "$compose" "$work/compose-original" && [[ $(wd .applied) == false ]]'
"$tool" windows-disks disable

# The root writer refuses anything else, even when called directly.
check "writer refuses three folders" '! bash "$repo/bin/compose-edit.sh" --share "$work/disk-a" --share "$work/disk b" --share "$work/disk-c" 2>/dev/null'
check "writer refuses dot-dot paths" '! bash "$repo/bin/compose-edit.sh" --share "/home/../etc" 2>/dev/null'
check "writer refuses quotes" 'mkdir -p "$work/q\"x" && ! bash "$repo/bin/compose-edit.sh" --share "$work/q\"x" 2>/dev/null'
check "writer refuses symlinked paths" 'ln -s /etc "$work/link" && ! bash "$repo/bin/compose-edit.sh" --share "$work/link/ssl" 2>/dev/null'
check "add refuses symlinked paths" '! "$tool" windows-disks add "$work/link/ssl" X 2>/dev/null'
check "writer left compose alone" 'cmp -s "$compose" "$work/compose-original"'

# v0.0.9-v0.0.18 kept the disk scripts right in Omarchy Tool: they move to Discos.
"$tool" windows-disks enable
mkdir -p "$winroot"; mv "$winfolder"/* "$winfolder"/.plugin-activo "$winroot/"; touch "$winroot/.letras-puestas"; rmdir "$winfolder"
"$tool" apply
check "old disk files move into Discos" '[[ -f "$winfolder/Activar discos.cmd" && -e $winfolder/.letras-puestas && ! -e "$winroot/Activar discos.cmd" && ! -e $winroot/.letras-puestas ]]'
rm -f "$winfolder/.letras-puestas"
"$tool" windows-disks disable
check "disks off with nothing else leaves no Omarchy Tool folder" '[[ ! -e $winroot ]]'

# Upgrade from the RDP versions: the Windows entry goes back to Omarchy.
mkdir -p "$OMARCHY_TOOL_STATE_DIR"
printf '#!/bin/bash\n' >"$OMARCHY_TOOL_STATE_DIR/windows-vm-launch"
echo "uwsm app -- omarchy-windows-vm launch" >"$OMARCHY_TOOL_STATE_DIR/windows-vm.exec"
sed -i "s|^Exec=.*|Exec=uwsm app -- \"$OMARCHY_TOOL_STATE_DIR/windows-vm-launch\"|" "$desktop"
"$tool" apply
check "old RDP launcher entry is restored" 'grep -qx "Exec=uwsm app -- omarchy-windows-vm launch" "$desktop"'
check "old RDP launcher is deleted" '[[ ! -e $OMARCHY_TOOL_STATE_DIR/windows-vm-launch && ! -e $OMARCHY_TOOL_STATE_DIR/windows-vm.exec ]]'
check "desktop lines kept" 'grep -qx "Icon=windows" "$desktop" && grep -qx "Name=Windows" "$desktop"'

# apply: menu row and uninstaller copy.
"$tool" apply
check "apply adds one menu row" '[[ $(grep -c "^  \"omarchy-tool\": {" "$OMARCHY_TOOL_MENU_FILE") == 1 ]]'
check "menu row sits before the closing brace" '[[ $(tail -n1 "$OMARCHY_TOOL_MENU_FILE") == "}" ]] && grep -q "\"personal\"" "$OMARCHY_TOOL_MENU_FILE"'
check "apply installs the uninstaller" '[[ -x $OMARCHY_TOOL_STATE_DIR/uninstall.sh ]]'

# Uninstall with disks shared: compose, menu, state and config all go.
"$tool" usb-windows add 093a:822a && "$tool" usb-windows enable
"$tool" windows-disks enable
bash "$OMARCHY_TOOL_STATE_DIR/uninstall.sh" "$repo"
check "uninstaller is a no-op while plugin exists" '[[ -e $OMARCHY_TOOL_STATE_DIR/compose.applied ]] && grep -q ":/shared2" "$compose"'
bash "$OMARCHY_TOOL_STATE_DIR/uninstall.sh" "$work/missing-plugin"
check "uninstall restores the compose" 'cmp -s "$compose" "$work/compose-original"'
check "uninstall removes state and config" '[[ ! -e $OMARCHY_TOOL_STATE_DIR && ! -e $OMARCHY_TOOL_CONFIG_DIR ]]'
check "uninstall removes the Windows folder" '[[ ! -e $winfolder ]]'
check "uninstall removes the shortcut" '[[ ! -e $OMARCHY_TOOL_HYPR_DIR/omarchy-tool.lua ]] && cmp -s "$OMARCHY_TOOL_HYPR_DIR/hyprland.lua" "$work/hyprland-original"'
check "uninstall leaves the menu as it was" 'cmp -s "$OMARCHY_TOOL_MENU_FILE" "$work/menu-original"'

# No VM installed: nothing to do, nothing written.
mv "$compose" "$work/compose-away"
check "status reports no VM" '[[ $(wd .vmInstalled) == false && $(wd .summary) == "Windows no está instalado" ]]'
check "apply without VM succeeds" '"$tool" windows-disks enable'
mv "$work/compose-away" "$compose"
rm -rf "$OMARCHY_TOOL_CONFIG_DIR" "$OMARCHY_TOOL_STATE_DIR"

# usb-windows: the switch prepares the VM (/dev/bus/usb); each device's own
# switch means "in Windows", applied live while a prepared Windows runs.
wu() { "$tool" status | jq -r ".modules[\"usb-windows\"]$1"; }
wui() { wu " | .candidates[] | select(.id == \"$1\") | .inWindows"; }
fake_bin2="$work/bin2"; mkdir -p "$fake_bin2"
printf '#!/bin/bash\necho "$*" >>"%s/notify2.log"\n' "$work" >"$fake_bin2/omarchy-notification-send"; chmod +x "$fake_bin2/omarchy-notification-send"
check "usb-windows starts off" '[[ $(wu .enabled) == false && $(wu .summary) == Desactivado ]]'
check "unnamed device gets its name from usb.ids" '[[ $(wu ".candidates[] | select(.id == \"8087:0033\") | .name") == "Intel Corp. AX211 Bluetooth" ]]'
check "lists USB devices, hubs left out" '[[ $(wu ".candidates | length") == 3 ]] && [[ $(wu ".candidates[] | select(.id == \"093a:822a\") | .name") == "GLORIOUS Model O 2 Wireless" ]]'
"$tool" usb-windows add 093A:822A
check "a device switch while off leaves the compose alone" 'cmp -s "$compose" "$work/compose-original"'
"$tool" usb-windows enable
check "enable leaves ARGUMENTS alone (nothing taken at boot)" 'grep -qxF "      ARGUMENTS: \"-rtc base=localtime,clock=host,driftfix=slew\"" "$compose"'
check "enable binds /dev/bus/usb live" 'grep -qxF "      - /dev/bus/usb:/dev/bus/usb # omarchy-tool" "$compose"'
check "enable allows USB devices that appear later" 'grep -B2 "^    volumes:$" "$compose" | grep -qxF "      - \"c 189:* rwm\" # omarchy-tool" && grep -qxF "    device_cgroup_rules: # omarchy-tool" "$compose"'
check "Omarchy mounts still counted right" '[[ $(grep -c ":/shared$" "$compose") == 1 && $(grep -c ":/storage$" "$compose") == 1 ]]'
check "old devices: copy from v0.0.12-v0.0.23 is dropped" 'sed -i "s|^      - /dev/net/tun$|&\n      - /dev/bus/usb # omarchy-tool|" "$compose" && bash "$repo/bin/compose-edit.sh" --usb-bus live && ! grep -qxF "      - /dev/bus/usb # omarchy-tool" "$compose" && [[ $(grep -c "/dev/bus/usb:/dev/bus/usb" "$compose") == 1 ]] && touch -d "+3 seconds" "$compose" && "$tool" apply'
check "usb status applied" '[[ $(wu .applied) == true && $(wu .summary) == "0 en Windows" ]]'
check "status tells the panel what to run" '[[ $(wu .watcher) == "$repo/bin/usb-watch.sh" && $(wu .requestFile) == "$usbfolder/.devolver-usb" ]]'
before=$(md5sum <"$compose")
"$tool" usb-windows remove 093a:822a
"$tool" usb-windows add 093a:822a
check "device switches never touch the compose" '[[ $(md5sum <"$compose") == "$before" ]]'

# Disks and USB live side by side; one change never drops the other.
"$tool" windows-disks add "$work/disk-a" DiskA
"$tool" windows-disks enable
check "disks and usb together" 'grep -q ":/shared2\"$" "$compose" && grep -q "/dev/bus/usb:/dev/bus/usb # omarchy-tool" "$compose"'
check "both modules report applied" '[[ $(wu .applied) == true && $(wd .applied) == true ]]'
"$tool" usb-windows disable
check "usb off keeps the disks" 'grep -q ":/shared2\"$" "$compose" && ! grep -q "/dev/bus/usb" "$compose"'
"$tool" usb-windows enable
"$tool" windows-disks disable
check "disks off keeps usb" '! grep -q ":/shared2" "$compose" && grep -q "/dev/bus/usb" "$compose"'
check "editor still writes boot devices with ids" 'bash "$repo/bin/compose-edit.sh" --usb 093a:822a && touch -d "+3 seconds" "$compose" && grep -q "driftfix=slew -device usb-host,id=omt093a822a,vendorid=0x093a,productid=0x822a\"" "$compose" && "$tool" apply && ! grep -q usb-host "$compose"'

# Live: Windows running and prepared (privileged helper stubbed with "echo").
export OMARCHY_TOOL_VM_STARTED=$(( $(stat -c %Y "$compose") + 5 ))
check "no VM running: sync-live does nothing" 'OMARCHY_TOOL_VM_PID= OMARCHY_TOOL_PRIV=false "$tool" usb-windows sync-live'
check "VM running and prepared" '[[ $(OMARCHY_TOOL_VM_PID=4242 wu .vmRunning) == true && $(OMARCHY_TOOL_VM_PID=4242 wu .liveReady) == true ]]'
check "Windows opening: switched-on devices go over" '[[ $(OMARCHY_TOOL_VM_PID=4242 OMARCHY_TOOL_PRIV=echo PATH="$fake_bin2:$PATH" "$tool" usb-windows sync-live) == *"usb-live.sh attach 093a:822a" ]]'
check "and say how to get them back" 'grep -q "SUPER + ALT + U" "$work/notify2.log"'
check "status: in Windows" '[[ $(OMARCHY_TOOL_VM_PID=4242 wui 093a:822a) == true && $(OMARCHY_TOOL_VM_PID=4242 wu .summary) == "1 en Windows" ]]'
check "sync-live again: nothing to do" '[[ -z $(OMARCHY_TOOL_VM_PID=4242 OMARCHY_TOOL_PRIV=echo "$tool" usb-windows sync-live) ]]'
check "unplugged devices are not attached" '[[ $(OMARCHY_TOOL_VM_PID=4242 "$tool" usb-windows add aaaa:0009 && echo ok) == ok ]] && [[ $(OMARCHY_TOOL_VM_PID=4242 OMARCHY_TOOL_PRIV=echo "$tool" usb-windows sync-live) != *aaaa* ]] && "$tool" usb-windows remove aaaa:0009'
check "switch off while open: back to Linux at once" '[[ $(OMARCHY_TOOL_VM_PID=4242 OMARCHY_TOOL_PRIV=echo "$tool" usb-windows remove 093a:822a) == *"usb-live.sh detach 093a:822a" ]] && [[ $(OMARCHY_TOOL_VM_PID=4242 wui 093a:822a) == false ]]'
check "switch on while open: to Windows at once" '[[ $(OMARCHY_TOOL_VM_PID=4242 OMARCHY_TOOL_PRIV=echo "$tool" usb-windows add 093a:822a) == *"usb-live.sh attach 093a:822a" ]]'
check "a cancelled password is reported and remembered as not moved" '"$tool" usb-windows remove 093a:822a >/dev/null 2>&1; OMARCHY_TOOL_VM_PID=4242 OMARCHY_TOOL_PRIV=false "$tool" usb-windows remove 093a:822a 2>/dev/null; [[ $(OMARCHY_TOOL_VM_PID=4242 wui 093a:822a) == true ]]'
OMARCHY_TOOL_VM_PID=4242 OMARCHY_TOOL_PRIV=true "$tool" usb-windows add 093a:822a
check "a new VM run starts with devices in Linux" '[[ $(OMARCHY_TOOL_VM_PID=5151 wui 093a:822a) == false ]]'
check "VM started before preparing is not ready" '[[ $(OMARCHY_TOOL_VM_PID=4242 OMARCHY_TOOL_VM_STARTED=1 wu .liveReady) == false ]] && [[ -z $(OMARCHY_TOOL_VM_PID=4242 OMARCHY_TOOL_VM_STARTED=1 OMARCHY_TOOL_PRIV=echo "$tool" usb-windows sync-live) ]]'
check "live helper refuses bad ids" '! bash "$repo/bin/usb-live.sh" attach "093a:822a;x" 2>/dev/null'

# SUPER+ALT+U / "Devolver periféricos a Linux": everything back, switches off.
keys="$OMARCHY_TOOL_HYPR_DIR/omarchy-tool.lua"
check "the shortcut exists while the feature is on" 'grep -q "^o.bind(\"SUPER + ALT + U\", \"Devolver periféricos a Linux\", .*usb-windows move linux --all\", { dont_inhibit = true })$" "$keys"'
check "hyprland.lua loads it once" '"$tool" apply && [[ $(grep -c "omarchy-tool.lua" "$OMARCHY_TOOL_HYPR_DIR/hyprland.lua") == 1 ]]'
OMARCHY_TOOL_VM_PID=4242 OMARCHY_TOOL_PRIV=true "$tool" usb-windows add 1b1c:2b0d
check "--all gives every device back in one call" '[[ $(OMARCHY_TOOL_VM_PID=4242 OMARCHY_TOOL_PRIV=echo PATH="$fake_bin2:$PATH" "$tool" usb-windows move linux --all) == *"usb-live.sh detach 093a:822a 1b1c:2b0d" ]] && grep -q "Periféricos devueltos a Linux" "$work/notify2.log"'
check "--all switches those devices off" '[[ $(wu ".devices | length") == 0 && $(OMARCHY_TOOL_VM_PID=4242 wu ".inWindows | length") == 0 ]]'
check "--all with nothing in Windows just says so" 'OMARCHY_TOOL_VM_PID=4242 PATH="$fake_bin2:$PATH" "$tool" usb-windows move linux --all && grep -q "Nada que devolver" "$work/notify2.log"'
check "Windows gets the return file" '[[ -f "$usbfolder/Devolver periféricos a Linux.cmd" ]] && file "$usbfolder/Devolver periféricos a Linux.cmd" | grep -q CRLF'
OMARCHY_TOOL_VM_PID=4242 OMARCHY_TOOL_PRIV=true "$tool" usb-windows add 093a:822a
touch "$usbfolder/.devolver-usb"
check "a request from Windows gives everything back" '[[ $(OMARCHY_TOOL_VM_PID=4242 OMARCHY_TOOL_PRIV=echo "$tool" usb-windows check-request) == *"detach 093a:822a" ]] && [[ ! -e $usbfolder/.devolver-usb && $(wu ".devices | length") == 0 ]]'
check "no request: check-request does nothing" '"$tool" usb-windows check-request'
check "watcher reports pid and request" '[[ $(bash "$repo/bin/usb-watch.sh" "$usbfolder/.devolver-usb") == "pid="*" request=0" ]] && touch "$usbfolder/.devolver-usb" && [[ $(bash "$repo/bin/usb-watch.sh" "$usbfolder/.devolver-usb") == *"request=1" ]] && rm "$usbfolder/.devolver-usb"'
# "Abrir Windows con mi ratón": Windows on its own screen (fake Omarchy tools).
fake_bin3="$work/bin3"; mkdir -p "$fake_bin3"
printf '#!/bin/bash\necho "vm $* path=$PATH" >>"%s/vm.log"\n' "$work" >"$fake_bin3/omarchy-windows-vm"
printf '#!/bin/bash\necho "webapp $*" >>"%s/vm.log"\n' "$work" >"$fake_bin3/omarchy-launch-webapp"
chmod +x "$fake_bin3"/*
check "refused while the normal Windows window is open" '! OMARCHY_TOOL_RDP_OPEN=1 PATH="$fake_bin3:$fake_bin2:$PATH" "$tool" usb-windows console-open 2>/dev/null && [[ ! -e $work/vm.log ]]'
OMARCHY_TOOL_RDP_OPEN=0 PATH="$fake_bin3:$fake_bin2:$PATH" "$tool" usb-windows console-open; sleep 0.3
check "starts Windows kept alive, without the remote window" 'grep -q "^vm launch --keep-alive path=$repo/bin/no-rdp:" "$work/vm.log"'
check "opens the Windows screen fitted to the window" 'grep -q "^webapp http://.*127.0.0.1:8006/?resize=scale$" "$work/vm.log"'
check "no-op RDP shim exits cleanly" 'bash "$repo/bin/no-rdp/xfreerdp3" /v:x'
rm -f "$work/vm.log"
OMARCHY_TOOL_VM_PID=4242 OMARCHY_TOOL_RDP_OPEN=0 PATH="$fake_bin3:$fake_bin2:$PATH" "$tool" usb-windows console-open; sleep 0.3
check "already running: only opens the screen" '! grep -q "^vm " "$work/vm.log" && grep -q "^webapp " "$work/vm.log"'
check "Apagar Windows stops the VM" 'PATH="$fake_bin3:$PATH" "$tool" usb-windows console-close && grep -q "^vm stop" "$work/vm.log"'
check "status says whether the remote window is open" '[[ $(OMARCHY_TOOL_RDP_OPEN=1 wu .rdpOpen) == true && $(OMARCHY_TOOL_RDP_OPEN=0 wu .rdpOpen) == false ]]'
check "fifth usb device is refused" '"$tool" usb-windows add aaaa:0001 && "$tool" usb-windows add aaaa:0002 && "$tool" usb-windows add aaaa:0003 && "$tool" usb-windows add aaaa:0004 && ! "$tool" usb-windows add aaaa:0005 2>/dev/null'
"$tool" usb-windows disable
unset OMARCHY_TOOL_VM_STARTED
check "disable removes the shortcut" '[[ ! -e $keys ]] && cmp -s "$OMARCHY_TOOL_HYPR_DIR/hyprland.lua" "$work/hyprland-original"'
check "disable removes the Periféricos folder" '[[ ! -e $usbfolder ]]'
check "all off restores the compose" 'cmp -s "$compose" "$work/compose-original" && [[ ! -e $OMARCHY_TOOL_STATE_DIR/compose.applied ]]'
check "editor refuses bad usb ids" '! bash "$repo/bin/compose-edit.sh" --usb "1b1c:2b0d,x" 2>/dev/null && cmp -s "$compose" "$work/compose-original"'
check "editor removes usb-host without id (v0.0.12)" 'sed -i "s|driftfix=slew\"|driftfix=slew -device usb-host,vendorid=0x093a,productid=0x822a\"|" "$compose" && bash "$repo/bin/compose-edit.sh" && cmp -s "$compose" "$work/compose-original"'

# Upgrade from v0.0.7-v0.0.10: their record moves into compose.applied.
"$tool" windows-disks enable
mv "$OMARCHY_TOOL_STATE_DIR/compose.applied" "$work/rec"
{ head -n1 "$work/rec"; sed -n "s/^--share //p" "$work/rec"; } >"$OMARCHY_TOOL_STATE_DIR/windows-disks.applied"
touch "$OMARCHY_TOOL_STATE_DIR/compose-shares.sh"
before=$(md5sum <"$compose")
OMARCHY_TOOL_PRIV="false" "$tool" apply
check "old record is migrated without rewriting" '[[ $(md5sum <"$compose") == "$before" ]] && [[ -f $OMARCHY_TOOL_STATE_DIR/compose.applied && ! -e $OMARCHY_TOOL_STATE_DIR/windows-disks.applied && ! -e $OMARCHY_TOOL_STATE_DIR/compose-shares.sh ]]'
"$tool" windows-disks disable
rm -rf "$OMARCHY_TOOL_CONFIG_DIR" "$OMARCHY_TOOL_STATE_DIR"
cp "$work/compose-original" "$compose"

# web-devices: browser (WebHID) access to chosen USB devices via a udev rule.
wv() { "$tool" status | jq -r ".modules[\"web-devices\"]$1"; }
check "web-devices starts off" '[[ $(wv .enabled) == false && $(wv .summary) == Desactivado ]]'
check "lists connected USB devices once each" '[[ $(wv ".candidates | length") == 2 ]] && [[ $(wv ".candidates[] | select(.id == \"1b1c:2b0d\") | .name") == "Corsair CORSAIR VANGUARD 96 Keyboard" ]]'
check "bluetooth HID is not listed" '[[ $(wv " | [.candidates[] | select(.id == \"046d:b023\")] | length") == 0 ]]'
"$tool" web-devices add 1B1C:2B0D
check "adding while off writes no rule" '[[ ! -e $OMARCHY_TOOL_UDEV_RULES ]] && [[ $(wv ".devices[0].name") == "Corsair CORSAIR VANGUARD 96 Keyboard" ]]'
"$tool" web-devices enable
check "enable writes a uaccess rule" 'grep -qxF "SUBSYSTEM==\"hidraw\", ATTRS{idVendor}==\"1b1c\", ATTRS{idProduct}==\"2b0d\", TAG+=\"uaccess\"" "$OMARCHY_TOOL_UDEV_RULES"'
check "status reports applied" '[[ $(wv .applied) == true && $(wv ".devices[0].connected") == true && $(wv .summary) == "1 con acceso" ]]'
"$tool" web-devices add 093a:822a
check "second device gets its own line" '[[ $(grep -c uaccess "$OMARCHY_TOOL_UDEV_RULES") == 2 ]]'
before=$(md5sum <"$OMARCHY_TOOL_UDEV_RULES")
OMARCHY_TOOL_PRIV="false" "$tool" apply
check "apply leaves an up-to-date rule alone" '[[ $(md5sum <"$OMARCHY_TOOL_UDEV_RULES") == "$before" ]]'
check "bad ids are refused" '! "$tool" web-devices add "1b1c:2b0d\"" 2>/dev/null && ! bash "$repo/bin/udev-webhid.sh" "../x" 2>/dev/null'
"$tool" web-devices remove 093a:822a
check "remove drops its line" '[[ $(grep -c uaccess "$OMARCHY_TOOL_UDEV_RULES") == 1 ]]'
"$tool" web-devices disable
check "disable deletes the rule file" '[[ ! -e $OMARCHY_TOOL_UDEV_RULES ]] && [[ $(wv ".devices | length") == 1 ]]'
"$tool" web-devices enable
bash "$OMARCHY_TOOL_STATE_DIR/uninstall.sh" "$work/missing-plugin"
check "uninstall deletes the rule file" '[[ ! -e $OMARCHY_TOOL_UDEV_RULES ]]'
rm -rf "$OMARCHY_TOOL_CONFIG_DIR" "$OMARCHY_TOOL_STATE_DIR"

# self-update from an install under Omarchy's plugin folder: a newer commit
# on the remote gets pulled through Omarchy's updater; an up-to-date one
# doesn't call it.
check "self-update skips a dev checkout" '"$tool" self-update'
fake_bin="$work/bin"
mkdir -p "$fake_bin"
xdg="$work/xdg"
git clone -q --bare "$repo" "$work/origin.git"
git clone -q "$work/origin.git" "$xdg/omarchy/plugins/omarchy-tool"
git clone -q "$work/origin.git" "$work/upstream"
printf '#!/bin/bash\necho called >>"%s/updater.log"\ngit -C "%s" merge -q --ff-only "@{upstream}"\n' "$work" "$xdg/omarchy/plugins/omarchy-tool" >"$fake_bin/omarchy-plugin-update"
printf '#!/bin/bash\necho "$@" >>"%s/notify.log"\n' "$work" >"$fake_bin/omarchy-notification-send"
chmod +x "$fake_bin/omarchy-plugin-update" "$fake_bin/omarchy-notification-send"
installed="$xdg/omarchy/plugins/omarchy-tool/bin/omarchy-tool"
XDG_CONFIG_HOME="$xdg" XDG_RUNTIME_DIR="$work" PATH="$fake_bin:$PATH" "$installed" self-update
check "self-update does nothing when up to date" '[[ ! -e $work/updater.log ]]'
git -C "$work/upstream" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "newer"
git -C "$work/upstream" push -q origin HEAD
XDG_CONFIG_HOME="$xdg" XDG_RUNTIME_DIR="$work" PATH="$fake_bin:$PATH" "$installed" self-update
check "self-update pulls a newer version" '[[ $(git -C "$xdg/omarchy/plugins/omarchy-tool" log -1 --format=%s) == newer ]]'
check "self-update notifies" 'grep -q "Omarchy Tool actualizado" "$work/notify.log"'

check "unknown module fails" '! "$tool" nope status 2>/dev/null'
check "unknown action fails" '! "$tool" windows-disks nope 2>/dev/null'

echo
if ((failures)); then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
