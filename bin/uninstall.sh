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

# Another install is still there (the plugin id changed in v0.0.30, so the
# old and new folders can coexist while moving over): it owns the system.
if [[ -n $plugin_dir ]]; then
  for manifest in "${OMARCHY_TOOL_PLUGINS_DIR:-$config_home/omarchy/plugins}"/*/manifest.json; do
    [[ -f $manifest ]] || continue
    case $(jq -r '.id // empty' "$manifest" 2>/dev/null) in
      omarchy-tool | io.github.gsus67.omarchy-tool) exit 0 ;;
    esac
  done
fi
state_dir="${OMARCHY_TOOL_STATE_DIR:-$data_home/omarchy-tool}"
config_dir="${OMARCHY_TOOL_CONFIG_DIR:-$config_home/omarchy-tool}"
desktop="${OMARCHY_TOOL_APPLICATIONS_DIR:-$data_home/applications}/windows-vm.desktop"
menu="${OMARCHY_TOOL_MENU_FILE:-$config_home/omarchy/extensions/omarchy-menu.jsonc}"
if [[ -f $state_dir/i18n.sh ]]; then
  # shellcheck source=/dev/null
  source "$state_dir/i18n.sh"
else
  tool_text() { printf '%s' "$1"; }
fi

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
    ${OMARCHY_TOOL_PRIV:+$OMARCHY_TOOL_PRIV} /usr/bin/bash "$editor" || exit 1
  else
    pkexec /usr/bin/bash "$editor" || exit 1
  fi
fi

# Browser access to peripherals: the udev rule is root's; one more password.
webhid_rules="${OMARCHY_TOOL_UDEV_RULES:-/etc/udev/rules.d/70-omarchy-tool-webhid.rules}"
if [[ -f $webhid_rules && -f $state_dir/udev-webhid.sh ]]; then
  if [[ -n ${OMARCHY_TOOL_PRIV+x} ]]; then
    ${OMARCHY_TOOL_PRIV:+$OMARCHY_TOOL_PRIV} /usr/bin/bash "$state_dir/udev-webhid.sh" || exit 1
  else
    pkexec /usr/bin/bash "$state_dir/udev-webhid.sh" || exit 1
  fi
fi

# Windows program icons: remove the system helper and only our own package.
# Keep the copied helper and ownership marker if the password is cancelled,
# so a later uninstall can finish instead of forgetting an installed package.
exe_bin="${OMARCHY_TOOL_EXE_BIN_DIR:-/usr/local/bin}/omarchy-tool-exe-thumbnailer"
if [[ -e $exe_bin || -L $exe_bin || -f $state_dir/exe-icons.icoutils-installed ]]; then
  if [[ ! -f $state_dir/exe-icons.sh ]]; then
    printf 'omarchy-tool: %s\n' "$(tool_text 'no se pudieron quitar los iconos de .exe')" >&2
    exit 1
  fi
  if [[ -n ${OMARCHY_TOOL_PRIV+x} ]]; then
    ${OMARCHY_TOOL_PRIV:+$OMARCHY_TOOL_PRIV} /usr/bin/bash "$state_dir/exe-icons.sh" remove || exit 1
  else
    pkexec /usr/bin/bash "$state_dir/exe-icons.sh" remove || exit 1
  fi
fi
rm -f -- "${OMARCHY_TOOL_THUMBNAILERS_DIR:-$data_home/thumbnailers}/omarchy-tool-exe.thumbnailer"

# Proton cleanup is entirely user-side except removal of our own package.
# The copied script also stops preparation before deleting its inventory.
# Copies of the prefix's data are the user's: they are never in this inventory.
if [[ -d $state_dir/exe-proton ]]; then
  bash "$state_dir/exe-proton/cleanup.sh" || exit 1
fi

# The extension and bookmark are user-owned; keep the ledger on any failure.
if [[ -f $state_dir/disk-tiles/manage.py ]]; then
  python3 "$state_dir/disk-tiles/manage.py" disable "$state_dir/disk-tiles" || exit 1
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
  # Setup › Network › IP and per-adapter DNS rows; the network keeps its settings.
  sed -i -E '/^  "setup\.network\.(ip|dns)[.A-Za-z0-9_-]*": \{.*\/network-ip\.sh/d' "$menu"
fi

rm -rf -- "$state_dir" "$config_dir"
