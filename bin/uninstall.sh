#!/bin/bash

# Removes every trace omarchy-tool leaves outside its plugin folder. `omarchy
# plugin remove` never runs plugin code, so `omarchy-tool apply` copies this
# script to $STATE_DIR, and the panel runs it as the shell unloads it once the
# plugin folder is gone.
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

# What we added to the Windows VM (shared disks, USB devices) lives in
# Omarchy's root-owned compose; taking it out needs the password once.
editor=''
if [[ -f $state_dir/compose.applied && -f $state_dir/compose-edit.sh ]]; then
  editor="$state_dir/compose-edit.sh"
elif [[ -f $state_dir/windows-disks.applied && -f $state_dir/compose-shares.sh ]]; then
  editor="$state_dir/compose-shares.sh" # v0.0.7-v0.0.10
fi
if [[ -n $editor ]]; then
  if [[ -n ${OMARCHY_TOOL_PRIV+x} ]]; then
    ${OMARCHY_TOOL_PRIV:+$OMARCHY_TOOL_PRIV} /usr/bin/bash "$editor" || true
  else
    pkexec /usr/bin/bash "$editor" || true
  fi
fi

# Browser access to peripherals: the udev rule is root's; one more password.
webhid_rules="${OMARCHY_TOOL_UDEV_RULES:-/etc/udev/rules.d/70-omarchy-tool-webhid.rules}"
if [[ -f $webhid_rules && -f $state_dir/udev-webhid.sh ]]; then
  if [[ -n ${OMARCHY_TOOL_PRIV+x} ]]; then
    ${OMARCHY_TOOL_PRIV:+$OMARCHY_TOOL_PRIV} /usr/bin/bash "$state_dir/udev-webhid.sh" || true
  else
    pkexec /usr/bin/bash "$state_dir/udev-webhid.sh" || true
  fi
fi

# ~/Windows/Omarchy Tool: keep only Discos › "Quitar discos" while Windows still
# has letters from "Activar discos" (it deletes itself once run); drop the rest.
windows_root="${OMARCHY_TOOL_WINDOWS_SHARED:-$HOME/Windows}/Omarchy Tool"
for windows_folder in "$windows_root/Discos" "$windows_root"; do
  [[ -d $windows_folder ]] || continue
  rm -f -- "$windows_folder/.plugin-activo" "$windows_folder/Activar discos.cmd" "$windows_folder/discos.txt"
  [[ -e $windows_folder/.letras-puestas ]] || rm -f -- "$windows_folder/omarchy-tool.ps1" "$windows_folder/Quitar discos.cmd"
done
rm -rf -- "$windows_root/Periféricos"
rm -f -- "$windows_root/Devolver periféricos a Linux.cmd" "$windows_root/.devolver-usb"
rmdir -- "$windows_root/Discos" "$windows_root" 2>/dev/null || true

# Older versions pointed the Windows app at our own launcher; hand it back.
if [[ -f $desktop ]] && grep '^Exec=' "$desktop" | grep -qF -- "$state_dir/windows-vm-launch"; then
  restore="uwsm app -- omarchy-windows-vm launch"
  [[ -s $state_dir/windows-vm.exec ]] && restore=$(head -n1 "$state_dir/windows-vm.exec")
  tmp=$(mktemp "$desktop.XXXXXX") &&
    awk -v exec_line="Exec=$restore" '!done && /^Exec=/ { print exec_line; done = 1; next } { print }' "$desktop" >"$tmp" &&
    { chmod --reference="$desktop" -- "$tmp" 2>/dev/null || true; } &&
    mv -f -- "$tmp" "$desktop"
fi

# Keyboard shortcuts: our Lua file and the guarded line that loads it.
hypr_dir="${OMARCHY_TOOL_HYPR_DIR:-$config_home/hypr}"
rm -f -- "$hypr_dir/omarchy-tool.lua"
mark="-- Added by omarchy-tool: keyboard shortcuts of its features, loaded only while they exist."
if [[ -f $hypr_dir/hyprland.lua ]] && grep -qF -- "$mark" "$hypr_dir/hyprland.lua"; then
  tmp=$(mktemp "$hypr_dir/hyprland.lua.XXXXXX") &&
    awk -v mark="$mark" '
      $0 == mark { skip = 1; next }
      skip && /omarchy-tool\.lua/ { skip = 0; next }
      { skip = 0; lines[++n] = $0 }
      END {
        while (n > 0 && lines[n] == "") n--
        for (i = 1; i <= n; i++) print lines[i]
      }
    ' "$hypr_dir/hyprland.lua" >"$tmp" &&
    mv -f -- "$tmp" "$hypr_dir/hyprland.lua"
  [[ -z ${OMARCHY_TOOL_HYPR_DIR:-} ]] && hyprctl reload >/dev/null 2>&1 || true
fi

# Our Omarchy menu row (written by `omarchy-tool apply`, tagged by its id).
if [[ -f $menu ]]; then
  sed -i '/^  "omarchy-tool": {.*omarchy-shell omarchy-tool toggle/d' "$menu"
fi

rm -rf -- "$state_dir" "$config_dir"
