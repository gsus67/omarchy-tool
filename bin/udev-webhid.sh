#!/bin/bash

# Lets the logged-in user's browser reach chosen USB HID devices (WebHID, for
# web configurators like CORSAIR Web Hub). Run as root through pkexec by
# omarchy-tool (web-devices module) and by uninstall.sh.
#
#   udev-webhid.sh [vvvv:pppp ...]
#
# Writes one udev rule per device that tags its hidraw nodes "uaccess", so
# logind grants the active session access. No devices removes the rule file.
# Access already granted to a device that is no longer listed is revoked.

set -euo pipefail
helper_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ -f $helper_dir/i18n.sh ]]; then
  source "$helper_dir/i18n.sh"
else
  tool_text() { printf '%s' "$1"; }
fi

fail() {
  printf 'udev-webhid: %s\n' "$(tool_text "$*")" >&2
  exit 1
}

rules=/etc/udev/rules.d/70-omarchy-tool-webhid.rules
sys=/sys/class/hidraw
apply=true
# Tests run this unprivileged against scratch paths and skip udev itself.
if ((EUID != 0)) && [[ -n ${OMARCHY_TOOL_UDEV_RULES:-} ]]; then
  rules=$OMARCHY_TOOL_UDEV_RULES
  sys=${OMARCHY_TOOL_HIDRAW_SYS:-$sys}
  apply=false
fi

ids=()
for id in "$@"; do
  [[ $id =~ ^[0-9a-f]{4}:[0-9a-f]{4}$ ]] || fail "$(tool_text 'refusing device id: %1' "$id")"
  ids+=("$id")
done

old=()
if [[ -f $rules ]]; then
  mapfile -t old < <(sed -n 's/.*ATTRS{idVendor}=="\([0-9a-f]\{4\}\)", ATTRS{idProduct}=="\([0-9a-f]\{4\}\)".*/\1:\2/p' "$rules")
fi

if ((${#ids[@]})); then
  tmp=$(mktemp "$rules.XXXXXX")
  trap 'rm -f -- "$tmp"' EXIT
  {
    echo "# Written by omarchy-tool (web-devices). Lets the browser of the logged-in"
    echo "# user configure these devices. Remove with: omarchy-tool web-devices disable"
    for id in "${ids[@]}"; do
      printf 'SUBSYSTEM=="hidraw", ATTRS{idVendor}=="%s", ATTRS{idProduct}=="%s", TAG+="uaccess"\n' "${id%:*}" "${id#*:}"
    done
  } >"$tmp"
  chmod 0644 -- "$tmp"
  mv -f -- "$tmp" "$rules"
  trap - EXIT
else
  rm -f -- "$rules"
fi

# hidraw nodes of devices dropped from the list: take back access already
# granted, so nothing lingers until the next replug.
dropped=()
for id in "${old[@]+"${old[@]}"}"; do
  [[ " ${ids[*]-} " == *" $id "* ]] || dropped+=("$id")
done

if [[ $apply == true ]]; then
  udevadm control --reload-rules
  for node in "$sys"/hidraw*; do
    [[ -e $node ]] || continue
    hid=$(sed -n 's/^HID_ID=0003:0000\([0-9A-Fa-f]\{4\}\):0000\([0-9A-Fa-f]\{4\}\)$/\1:\2/p' "$node/device/uevent")
    hid=${hid,,}
    for id in "${dropped[@]+"${dropped[@]}"}"; do
      [[ $hid == "$id" ]] && setfacl -b -- "/dev/$(basename -- "$node")"
    done
  done
  udevadm trigger --action=change --subsystem-match=hidraw
fi
