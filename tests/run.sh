#!/bin/bash

# Backend tests for omarchy-tool. Runs against a throwaway config, state and
# applications dir, so it never touches the real system.
#
#   tests/run.sh

set -uo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tool="$repo/bin/omarchy-tool"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

export OMARCHY_TOOL_CONFIG_DIR="$work/config"
export OMARCHY_TOOL_STATE_DIR="$work/my state"
export OMARCHY_TOOL_APPLICATIONS_DIR="$work/applications"
mkdir -p "$OMARCHY_TOOL_APPLICATIONS_DIR" "$work/disk-a" "$work/disk b" "$work/back\\slash"

desktop="$OMARCHY_TOOL_APPLICATIONS_DIR/windows-vm.desktop"
cat >"$desktop" <<'EOF'
[Desktop Entry]
Name=Windows
Exec=uwsm app -- omarchy-windows-vm launch
Icon=windows
Type=Application
EOF

failures=0
pass() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; failures=$((failures + 1)); }
check() { if eval "$2"; then pass "$1"; else bad "$1"; fi; }

check "status is valid JSON" '"$tool" status | jq -e ".modules[\"windows-disks\"].enabled == false" >/dev/null'
check "summary says disabled" '[[ $("$tool" status | jq -r ".modules[\"windows-disks\"].summary") == Desactivado ]]'
check "starts with no disks" '[[ $("$tool" status | jq ".modules[\"windows-disks\"].disks | length") == 0 ]]'

"$tool" windows-disks add "$work/disk-a" DiskA
"$tool" windows-disks add "$work/disk b/" "Disk B"
check "adds two disks" '[[ $("$tool" status | jq ".modules[\"windows-disks\"].disks | length") == 2 ]]'
check "trailing slash is stripped" '"$tool" status | jq -e --arg p "$work/disk b" "any(.modules[\"windows-disks\"].disks[]; .path == \$p)" >/dev/null'
check "re-adding a path replaces it" '"$tool" windows-disks add "$work/disk-a" DiskA2 && [[ $("$tool" status | jq ".modules[\"windows-disks\"].disks | length") == 2 ]]'

check "rejects comma paths" '! "$tool" windows-disks add "/tmp/a,b" X 2>/dev/null'
check "rejects sharing /" '! "$tool" windows-disks add / X 2>/dev/null && ! "$tool" windows-disks add // X 2>/dev/null'
check "rejects missing folder" '! "$tool" windows-disks add "$work/nope" X 2>/dev/null'
check "unsafe name characters are replaced" '"$tool" windows-disks add "$work/disk-a" "a,b" && [[ $("$tool" status | jq -r --arg p "$work/disk-a" ".modules[\"windows-disks\"].disks[] | select(.path == \$p).name") == "a_b" ]]'
"$tool" windows-disks add "$work/disk-a" DiskA

check "no rdp args while disabled" '[[ -z $("$tool" windows-disks rdp-args) ]]'
check "desktop untouched while disabled" 'grep -qx "Exec=uwsm app -- omarchy-windows-vm launch" "$desktop"'

"$tool" windows-disks enable
launcher="$OMARCHY_TOOL_STATE_DIR/windows-vm-launch"
check "enable points Windows entry at quoted launcher" 'grep -qxF "Exec=uwsm app -- \"$launcher\"" "$desktop"'
check "launcher is executable" '[[ -x $launcher ]]'
check "status reports applied" '"$tool" status | jq -e ".modules[\"windows-disks\"].applied" >/dev/null'
check "rdp args list both disks" '[[ $("$tool" windows-disks rdp-args | wc -l) == 2 ]]'
check "rdp arg keeps spaces" 'grep -qxF "/drive:Disk B,$work/disk b" <<<"$("$tool" windows-disks rdp-args)"'
check "apply is idempotent" '"$tool" apply && [[ $(grep -c "^Exec=" "$desktop") == 1 ]]'

rmdir "$work/disk-a"
check "missing disk is skipped" '[[ $("$tool" windows-disks rdp-args | wc -l) == 1 ]]'
mkdir "$work/disk-a"

# Omarchy rewrote the entry (e.g. reinstalled Windows): apply re-takes it.
sed -i 's|^Exec=.*|Exec=uwsm app -- omarchy-windows-vm launch|' "$desktop"
"$tool" apply
check "apply re-takes a rewritten entry" 'grep -qxF "Exec=uwsm app -- \"$launcher\"" "$desktop"'

"$tool" windows-disks disable
check "disable restores stock entry" 'grep -qx "Exec=uwsm app -- omarchy-windows-vm launch" "$desktop"'
check "other desktop lines kept" 'grep -qx "Icon=windows" "$desktop" && grep -qx "Name=Windows" "$desktop"'

# An unquoted launcher from a v0.0.1 test build still counts as ours.
sed -i "s|^Exec=.*|Exec=uwsm app -- $launcher|" "$desktop"
"$tool" windows-disks enable
"$tool" windows-disks disable
check "legacy unquoted entry restores to stock" 'grep -qx "Exec=uwsm app -- omarchy-windows-vm launch" "$desktop"'

"$tool" windows-disks add "$work/back\\slash" Back
check "backslash path round-trips" '"$tool" status | jq -e --arg p "$work/back\\slash" "any(.modules[\"windows-disks\"].disks[]; .path == \$p and .available)" >/dev/null'
"$tool" windows-disks remove "$work/back\\slash"

"$tool" windows-disks remove "$work/disk-a"
check "remove drops a disk" '[[ $("$tool" status | jq ".modules[\"windows-disks\"].disks | length") == 1 ]]'

# Launcher falls back to the stock command once the plugin is gone.
fake_bin="$work/bin"
mkdir -p "$fake_bin"
printf '#!/bin/bash\necho "stock $*"\n' >"$fake_bin/omarchy-windows-vm"
chmod +x "$fake_bin/omarchy-windows-vm"
sed "s|^tool=.*|tool=$work/missing/omarchy-tool|" "$launcher" >"$work/launcher-orphan"
check "orphaned launcher falls back to stock" '[[ $(PATH="$fake_bin:$PATH" bash "$work/launcher-orphan" --keep-alive) == "stock launch --keep-alive" ]]'

# The shim forwards Omarchy's args and appends the drives.
"$tool" windows-disks enable
printf '#!/bin/bash\nprintf "%%s\\n" "$@"\n' >"$fake_bin/xfreerdp3"
chmod +x "$fake_bin/xfreerdp3"
out=$(PATH="$repo/bin/shims:$fake_bin:$PATH" xfreerdp3 /v:127.0.0.1:3389 /title:"Windows VM")
check "shim keeps original args" 'grep -qx "/title:Windows VM" <<<"$out"'
check "shim appends drives" 'grep -qxF "/drive:Disk B,$work/disk b" <<<"$out"'

check "unknown module fails" '! "$tool" nope status 2>/dev/null'
check "unknown action fails" '! "$tool" windows-disks nope 2>/dev/null'

echo
if ((failures)); then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
