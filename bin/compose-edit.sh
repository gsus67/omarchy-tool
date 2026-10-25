#!/bin/bash

# Sets what omarchy-tool adds to Omarchy's Windows VM compose. Run as root
# through pkexec by omarchy-tool and by uninstall.sh.
#
#   compose-edit.sh [--share FOLDER]... [--usb VVVV:PPPP]... [--usb-bus live]
#
#   --share  up to 2 folders; the first becomes \\host.lan\Data2 and the second
#            \\host.lan\Data3 in Windows (dockurr/windows serves /shared2 and
#            /shared3 next to Omarchy's /shared).
#   --usb    up to 4 USB devices handed to Windows while the VM runs: a
#            "-device usb-host" in ARGUMENTS plus /dev/bus/usb in devices, as
#            dockurr/windows documents for USB passthrough.
#   --usb-bus live  only USB access, so devices can be handed to the running VM
#            on demand (usb-live.sh) without any being taken at boot. It is a
#            live bind of /dev/bus/usb plus a cgroup rule for USB devices
#            (char major 189), not a `devices:` copy: QEMU resets a device it
#            takes and it comes back under a new number, which a copy made at
#            container start would not have.
#
# No options removes all of it. Only our own pieces are ever touched: the
# /shared2 and /shared3 binds, the usb-host devices in ARGUMENTS and lines
# ending in "# omarchy-tool". Everything else is copied as is.

set -euo pipefail

fail() {
  echo "compose-edit: $*" >&2
  exit 1
}

compose=/var/lib/omarchy/windows/docker-compose.yml
# Tests run this unprivileged against a scratch compose.
if ((EUID != 0)) && [[ -n ${OMARCHY_TOOL_COMPOSE:-} ]]; then
  compose=$OMARCHY_TOOL_COMPOSE
fi

shares=()
usbs=()
usb_bus=false
while (($#)); do
  case $1 in
    --share)
      (($# >= 2)) || fail "--share needs a folder"
      folder=$2
      # Only disk and home locations; nothing YAML or the bind syntax would
      # reinterpret (quotes, backslashes, colons, commas, comments, newlines).
      [[ $folder =~ ^/(mnt|media|run/media|home)/[^\"\\:,#$'\n']+$ ]] || fail "refusing folder: $folder"
      [[ $folder != */.. && $folder != */../* && $folder != */. && $folder != */./* ]] || fail "refusing folder: $folder"
      [[ -d $folder && ! -L $folder ]] || fail "not a folder: $folder"
      # No symlink anywhere on the way: /home/x/link could lead to /etc.
      [[ $(realpath -e -- "$folder") == "$folder" ]] || fail "refusing a path through a symlink: $folder"
      shares+=("$folder")
      shift 2
      ;;
    --usb)
      (($# >= 2)) || fail "--usb needs a device id"
      [[ $2 =~ ^[0-9a-f]{4}:[0-9a-f]{4}$ ]] || fail "refusing device id: $2"
      usbs+=("$2")
      shift 2
      ;;
    --usb-bus)
      # "live" since v0.0.25; "on" (v0.0.14-v0.0.24) means the same now.
      [[ ${2:-} == live || ${2:-} == on ]] || fail "--usb-bus takes: live"
      usb_bus=true
      shift 2
      ;;
    *) fail "unknown option: $1" ;;
  esac
done
((${#shares[@]} <= 2)) || fail "at most two folders"
((${#usbs[@]} <= 4)) || fail "at most four USB devices"

[[ -f $compose && ! -L $compose ]] || exit 0
[[ $(grep -c '^[[:space:]]*-[[:space:]]*[^[:space:]].*:/shared$' "$compose") == 1 ]] ||
  fail "unexpected compose layout (/shared)"
((${#usbs[@]})) && usb_bus=true
if [[ $usb_bus == true ]]; then
  [[ $(grep -c '^    volumes:[[:space:]]*$' "$compose") == 1 ]] ||
    fail "unexpected compose layout (volumes)"
fi
if ((${#usbs[@]})); then
  [[ $(grep -c '^[[:space:]]*ARGUMENTS:[[:space:]]*".*"[[:space:]]*$' "$compose") == 1 ]] ||
    fail "unexpected compose layout (ARGUMENTS)"
  [[ $(grep -c '^[[:space:]]*-[[:space:]]*/dev/net/tun[[:space:]]*$' "$compose") == 1 ]] ||
    fail "unexpected compose layout (devices)"
fi

share_rows=''
index=2
for folder in "${shares[@]+"${shares[@]}"}"; do
  share_rows+="      - \"$folder:/shared$index\""$'\n'
  index=$((index + 1))
done
share_rows=${share_rows%$'\n'}

usb_args=''
for id in "${usbs[@]+"${usbs[@]}"}"; do
  # The id lets usb-live.sh hand the device back while Windows runs.
  usb_args+=" -device usb-host,id=omt${id%:*}${id#*:},vendorid=0x${id%:*},productid=0x${id#*:}"
done

tmp=$(mktemp "$compose.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
awk -v shares="$share_rows" -v usb_args="$usb_args" -v usb_bus="$usb_bus" '
  # Ours from an earlier run: dropped, then written again below if wanted.
  /^[[:space:]]*-[[:space:]]*"?[^[:space:]].*:\/shared[23]"?[[:space:]]*$/ { next }
  /# omarchy-tool[[:space:]]*$/ { next }
  /^    volumes:[[:space:]]*$/ && usb_bus == "true" {
    print "    device_cgroup_rules: # omarchy-tool"
    print "      - \"c 189:* rwm\" # omarchy-tool"
    print
    print "      - /dev/bus/usb:/dev/bus/usb # omarchy-tool"
    next
  }
  /^[[:space:]]*ARGUMENTS:[[:space:]]*".*"[[:space:]]*$/ {
    gsub(/ -device usb-host,(id=omt[0-9a-f]+,)?vendorid=0x[0-9a-f][0-9a-f][0-9a-f][0-9a-f],productid=0x[0-9a-f][0-9a-f][0-9a-f][0-9a-f]/, "")
    if (usb_args != "") sub(/"[[:space:]]*$/, usb_args "\"")
    print
    next
  }
  { print }
  /^[[:space:]]*-[[:space:]]*[^[:space:]].*:\/shared$/ && shares != "" { print shares }
' "$compose" >"$tmp"

chmod --reference="$compose" -- "$tmp"
if ((EUID == 0)); then
  chown --reference="$compose" -- "$tmp"
fi
mv -f -- "$tmp" "$compose"
trap - EXIT
