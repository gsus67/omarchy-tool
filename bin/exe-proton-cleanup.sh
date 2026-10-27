#!/bin/bash
# Shared disable/uninstall cleanup; lives outside the plugin for removal.
set -euo pipefail
helper_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# Stop the whole preparation process group before removing its files/package.
if [[ -f $helper_dir/queued ]]; then
  if ! loaded=$(systemctl --user show omarchy-tool-exe-proton-prepare.service --property=LoadState --value); then
    [[ $loaded == not-found ]] || exit 1
  fi
  if [[ $loaded != not-found ]]; then
    systemctl --user stop omarchy-tool-exe-proton-prepare.service
  fi
fi
if [[ -f $helper_dir/umu-installed ]]; then
  if [[ -n ${OMARCHY_TOOL_PRIV+x} ]]; then
    ${OMARCHY_TOOL_PRIV:+$OMARCHY_TOOL_PRIV} /usr/bin/bash "$helper_dir/package.sh" remove
  else
    pkexec /usr/bin/bash "$helper_dir/package.sh" remove
  fi
fi
python3 "$helper_dir/mime.py" remove "$helper_dir"
if [[ -f $helper_dir/downloaded && -f $helper_dir/compat-dirs ]]; then
  while IFS= read -r version; do
    name=${version##*/}
    [[ $name == GE-Proton* && $name != *$'\n'* ]] || continue
    # Only a direct child of the directories recorded before preparation.
    if grep -qxF -- "${version%/*}" "$helper_dir/compat-dirs"; then
      rm -rf -- "$version"
    fi
  done <"$helper_dir/downloaded"
fi
rm -f -- "${OMARCHY_TOOL_APPLICATIONS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/applications}/omarchy-tool-run-exe.desktop"
rm -rf -- "$helper_dir"
