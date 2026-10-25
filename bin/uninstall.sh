#!/bin/bash

# Removes every trace omarchy-tool leaves outside its plugin folder. `omarchy
# plugin remove` never runs plugin code, so `omarchy-tool apply` copies this
# script to $STATE_DIR, and two things run it once the plugin folder is gone:
# the panel as the shell unloads it, and the Windows launcher on its next run.
#
#   uninstall.sh [plugin-dir]   With a plugin dir, do nothing while it exists.

plugin_dir=${1:-}
if [[ -n $plugin_dir && -e $plugin_dir/manifest.json ]]; then
  exit 0
fi

data_home=${XDG_DATA_HOME:-$HOME/.local/share}
config_home=${XDG_CONFIG_HOME:-$HOME/.config}
state_dir="${OMARCHY_TOOL_STATE_DIR:-$data_home/omarchy-tool}"
config_dir="${OMARCHY_TOOL_CONFIG_DIR:-$config_home/omarchy-tool}"
desktop="${OMARCHY_TOOL_APPLICATIONS_DIR:-$data_home/applications}/windows-vm.desktop"
menu="${OMARCHY_TOOL_MENU_FILE:-$config_home/omarchy/extensions/omarchy-menu.jsonc}"

# Hand the Windows app back to Omarchy's own launcher.
if [[ -f $desktop ]] && grep '^Exec=' "$desktop" | grep -qF -- "$state_dir/windows-vm-launch"; then
  restore="uwsm app -- omarchy-windows-vm launch"
  [[ -s $state_dir/windows-vm.exec ]] && restore=$(head -n1 "$state_dir/windows-vm.exec")
  tmp=$(mktemp "$desktop.XXXXXX") &&
    awk -v exec_line="Exec=$restore" '!done && /^Exec=/ { print exec_line; done = 1; next } { print }' "$desktop" >"$tmp" &&
    { chmod --reference="$desktop" -- "$tmp" 2>/dev/null || true; } &&
    mv -f -- "$tmp" "$desktop"
fi

# Our Omarchy menu row (written by `omarchy-tool apply`, tagged by its id).
if [[ -f $menu ]]; then
  sed -i '/^  "omarchy-tool": {.*omarchy-shell omarchy-tool toggle/d' "$menu"
fi

rm -rf -- "$state_dir" "$config_dir"
