# shellcheck shell=bash
# Module: web-devices
#
# Lets the browser talk to chosen USB devices (WebHID), so web configurators
# like CORSAIR Web Hub can set them up from Linux. Out of the box every
# /dev/hidraw node is root-only: Chromium lists the device but connecting does
# nothing. bin/udev-webhid.sh, run as root through pkexec, writes one udev
# rule per chosen device tagging it "uaccess", so only the logged-in user gets
# access, and takes that access back when a device is dropped.
#
# The rules file itself is world-readable, so it is the record of what is
# applied: apply only asks for the password when it differs from the choice.

WEB_DEVICES_RULES="${OMARCHY_TOOL_UDEV_RULES:-/etc/udev/rules.d/70-omarchy-tool-webhid.rules}"
WEB_DEVICES_SYS="${OMARCHY_TOOL_HIDRAW_SYS:-/sys/class/hidraw}"

web_devices_enabled() {
  [[ $(config_get '.modules["web-devices"].enabled // false') == true ]]
}

web_devices_valid_id() {
  [[ $1 =~ ^[0-9a-f]{4}:[0-9a-f]{4}$ ]]
}

# Connected USB HID devices, one per vendor:product, as JSON.
web_devices_connected_json() {
  local node uevent id name rows=''
  for node in "$WEB_DEVICES_SYS"/hidraw*; do
    uevent="$node/device/uevent"
    [[ -f $uevent ]] || continue
    id=$(sed -n 's/^HID_ID=0003:0000\([0-9A-Fa-f]\{4\}\):0000\([0-9A-Fa-f]\{4\}\)$/\1:\2/p' "$uevent")
    [[ -n $id ]] || continue
    name=$(sed -n 's/^HID_NAME=//p' "$uevent")
    rows+=$(jq -cn --arg id "${id,,}" --arg name "$name" '{id: $id, name: ($name | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" "))}')$'\n'
  done
  jq -cs 'unique_by(.id)' <<<"$rows"
}

web_devices_desired() {
  web_devices_enabled || return 0
  config_get -r '.modules["web-devices"].devices // [] | .[] | .id' | sort -u
}

web_devices_applied() {
  [[ -f $WEB_DEVICES_RULES ]] || return 0
  sed -n 's/.*ATTRS{idVendor}=="\([0-9a-f]\{4\}\)", ATTRS{idProduct}=="\([0-9a-f]\{4\}\)".*/\1:\2/p' \
    "$WEB_DEVICES_RULES" | sort -u
}

web_devices_apply() {
  local ids=()
  mkdir -p -- "$STATE_DIR"
  install_helper_i18n
  install -m 0644 -- "$TOOL_DIR/bin/udev-webhid.sh" "$STATE_DIR/udev-webhid.sh"
  [[ $(web_devices_desired) == "$(web_devices_applied)" ]] && return 0
  mapfile -t ids < <(web_devices_desired)
  privileged /usr/bin/bash "$STATE_DIR/udev-webhid.sh" "${ids[@]}" ||
    fail "no se pudo cambiar el permiso de los periféricos"
}

web_devices_status() {
  local enabled=false applied=false connected devices
  web_devices_enabled && enabled=true
  [[ $(web_devices_desired) == "$(web_devices_applied)" ]] && applied=true
  connected=$(web_devices_connected_json)
  devices=$(config_get -c '.modules["web-devices"].devices // []')
  jq -n --argjson enabled "$enabled" --argjson applied "$applied" \
    --argjson connected "$connected" --argjson devices "$devices" \
    '{enabled: $enabled, applied: $applied,
      devices: [$devices[] | . as $d | . + {connected: any($connected[]; .id == $d.id)}],
      candidates: [$connected[] | . as $c | . + {selected: any($devices[]; .id == $c.id)}],
      summary: (if $enabled then ($devices | length | tostring) + " con acceso" else "Desactivado" end)}'
}

web_devices_enable() {
  config_update '.modules["web-devices"].enabled = true'
  web_devices_apply
}

web_devices_disable() {
  config_update '.modules["web-devices"].enabled = false'
  web_devices_apply
}

# add <vvvv:pppp> [name]
web_devices_add() {
  local id=${1:-} name=${2:-}
  id=${id,,}
  web_devices_valid_id "$id" || fail "usage: omarchy-tool web-devices add <vvvv:pppp> [name]"
  if [[ -z $name ]]; then
    name=$(web_devices_connected_json | jq -r --arg id "$id" '.[] | select(.id == $id) | .name')
  fi
  name=$(tr -cd '[:print:]' <<<"${name:-$id}" | head -c 64)
  config_update '.modules["web-devices"].devices |= (. // [] | map(select(.id != $id)) + [{id: $id, name: $name}])' \
    --arg id "$id" --arg name "$name"
  web_devices_apply
}

# remove <vvvv:pppp>
web_devices_remove() {
  local id=${1:-}
  id=${id,,}
  web_devices_valid_id "$id" || fail "usage: omarchy-tool web-devices remove <vvvv:pppp>"
  config_update '.modules["web-devices"].devices |= (. // [] | map(select(.id != $id)))' --arg id "$id"
  web_devices_apply
}
