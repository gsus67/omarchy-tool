#!/bin/bash
# Locale and catalog tests use only temporary state and never change settings.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${OMARCHY_TOOL_TEST_PARENT:-/tmp}/omarchy-tool-i18n.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/config" "$work/state" "$work/usb" "$work/hid" "$work/disk"
export OMARCHY_TOOL_CONFIG_DIR="$work/config" OMARCHY_TOOL_STATE_DIR="$work/state"
export OMARCHY_TOOL_USB_SYS="$work/usb" OMARCHY_TOOL_HIDRAW_SYS="$work/hid"
export OMARCHY_TOOL_COMPOSE="$work/compose.yml" OMARCHY_TOOL_VM_PID=""
printf '{}\n' > "$OMARCHY_TOOL_COMPOSE"
jq -n --arg path "$work/disk" '{modules:{"windows-disks":{enabled:true,disks:[{path:$path,name:"Mi disco",letter:"X"}]},"usb-windows":{enabled:true,devices:[]},"web-devices":{enabled:true,devices:[{id:"093a:822a",name:"Ratón mío"}]},"exe-icons":{enabled:true}}}' > "$work/config/config.json"

english=$(LC_ALL=C.UTF-8 LC_MESSAGES=es_ES.UTF-8 "$repo/bin/omarchy-tool" status)
jq -e '.language=="en" and .modules["windows-disks"].summary=="Sharing 1 disk" and .modules["usb-windows"].summary=="0 in Windows" and .modules["web-devices"].summary=="1 with access" and .modules["exe-icons"].summary=="Enabled"' <<< "$english" >/dev/null
jq -e '.modules["windows-disks"].disks[0].name=="Mi disco" and .modules["web-devices"].devices[0].name=="Ratón mío"' <<< "$english" >/dev/null
echo 'ok - LC_ALL takes precedence; all summaries are English; user names are unchanged'

spanish=$(env -u LC_ALL -u LC_MESSAGES LANG=es_MX.UTF-8 "$repo/bin/omarchy-tool" status)
jq -e '.language=="es" and .modules["windows-disks"].summary=="Comparte 1 disco" and .modules["usb-windows"].summary=="0 en Windows" and .modules["web-devices"].summary=="1 con acceso" and .modules["exe-icons"].summary=="Activado"' <<< "$spanish" >/dev/null
echo 'ok - Spanish regional locales translate all module summaries'

LC_ALL=C.UTF-8 bash -c 'source "$1/bin/i18n.sh"; [[ $(tool_text "no existe la carpeta: %1" "a&b") == "folder does not exist: a&b" ]]' _ "$repo"
env -u LC_ALL LC_MESSAGES=es LANG=en_US.UTF-8 bash -c 'source "$1/bin/i18n.sh"; [[ $(tool_text "unknown command or module: %1" example) == "comando o módulo desconocido: example" ]]' _ "$repo"
echo 'ok - message locale precedence and literal argument interpolation'

for page in "$repo/ToolPanel.qml" "$repo"/modules/*.qml; do
  /usr/lib/qt6/bin/qmlformat "$page" >/dev/null
done
echo 'ok - translated QML pages parse'
