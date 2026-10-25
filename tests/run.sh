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
export OMARCHY_TOOL_WINDOWS_SHARED="$work/Windows"
export OMARCHY_TOOL_UDEV_RULES="$work/70-omarchy-tool-webhid.rules"
export OMARCHY_TOOL_HIDRAW_SYS="$work/sys"
fake_hid() {
  mkdir -p "$OMARCHY_TOOL_HIDRAW_SYS/$1/device"
  printf 'HID_ID=%s\nHID_NAME=%s\n' "$2" "$3" >"$OMARCHY_TOOL_HIDRAW_SYS/$1/device/uevent"
}
fake_hid hidraw5 0003:00001B1C:00002B0D "Corsair CORSAIR VANGUARD 96 Keyboard"
fake_hid hidraw6 0003:00001B1C:00002B0D "Corsair CORSAIR VANGUARD 96 Keyboard"
fake_hid hidraw2 0003:0000093A:0000822A "GLORIOUS Model O 2 Wireless"
fake_hid hidraw9 0005:0000046D:0000B023 "Bluetooth thing"
winfolder="$OMARCHY_TOOL_WINDOWS_SHARED/Omarchy Tool"
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
check "disable removes the record" '[[ ! -e $OMARCHY_TOOL_STATE_DIR/windows-disks.applied ]]'
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
check "writer refuses three folders" '! bash "$repo/bin/compose-shares.sh" "$work/disk-a" "$work/disk b" "$work/disk-c" 2>/dev/null'
check "writer refuses dot-dot paths" '! bash "$repo/bin/compose-shares.sh" "/home/../etc" 2>/dev/null'
check "writer refuses quotes" 'mkdir -p "$work/q\"x" && ! bash "$repo/bin/compose-shares.sh" "$work/q\"x" 2>/dev/null'
check "writer refuses symlinked paths" 'ln -s /etc "$work/link" && ! bash "$repo/bin/compose-shares.sh" "$work/link/ssl" 2>/dev/null'
check "add refuses symlinked paths" '! "$tool" windows-disks add "$work/link/ssl" X 2>/dev/null'
check "writer left compose alone" 'cmp -s "$compose" "$work/compose-original"'

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
"$tool" windows-disks enable
bash "$OMARCHY_TOOL_STATE_DIR/uninstall.sh" "$repo"
check "uninstaller is a no-op while plugin exists" '[[ -e $OMARCHY_TOOL_STATE_DIR/windows-disks.applied ]] && grep -q ":/shared2" "$compose"'
bash "$OMARCHY_TOOL_STATE_DIR/uninstall.sh" "$work/missing-plugin"
check "uninstall restores the compose" 'cmp -s "$compose" "$work/compose-original"'
check "uninstall removes state and config" '[[ ! -e $OMARCHY_TOOL_STATE_DIR && ! -e $OMARCHY_TOOL_CONFIG_DIR ]]'
check "uninstall removes the Windows folder" '[[ ! -e $winfolder ]]'
check "uninstall leaves the menu as it was" 'cmp -s "$OMARCHY_TOOL_MENU_FILE" "$work/menu-original"'

# No VM installed: nothing to do, nothing written.
mv "$compose" "$work/compose-away"
check "status reports no VM" '[[ $(wd .vmInstalled) == false && $(wd .summary) == "Windows no está instalado" ]]'
check "apply without VM succeeds" '"$tool" windows-disks enable'
mv "$work/compose-away" "$compose"
rm -rf "$OMARCHY_TOOL_CONFIG_DIR" "$OMARCHY_TOOL_STATE_DIR"

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
