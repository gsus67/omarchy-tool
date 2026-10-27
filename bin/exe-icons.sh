#!/bin/bash
# System changes for exe-icons, run once through pkexec for install/removal.
# Copied beside exe-thumbnailer and the package ownership marker in STATE_DIR.
set -euo pipefail
helper_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ -f $helper_dir/i18n.sh ]]; then
  # shellcheck source=/dev/null
  source "$helper_dir/i18n.sh"
else
  tool_text() { printf '%s' "$1"; }
fi

fail() {
  printf 'exe-icons: %s\n' "$(tool_text "$*")" >&2
  exit 1
}

bin_dir=/usr/local/bin
# Like udev-webhid.sh, root always uses the real system path. Tests run as
# an ordinary user with a scratch directory and a fake pacman on PATH.
if ((EUID != 0)) && [[ -n ${OMARCHY_TOOL_EXE_BIN_DIR:-} ]]; then
  bin_dir=$OMARCHY_TOOL_EXE_BIN_DIR
fi
target="$bin_dir/omarchy-tool-exe-thumbnailer"
legacy="$bin_dir/exe-thumbnailer"
marker="$helper_dir/exe-icons.icoutils-installed"

# The earlier manual setup: this exact script (never adopt an edited one) and
# a thumbnailer entry that runs it. The entry's path differs per PC.
legacy_pair() {
  [[ -f $legacy && -f ${1:-} ]] || return 1
  [[ $(sha256sum -- "$legacy" | cut -d ' ' -f1) == 49de5a98379929253901837d469d5ed2a172719b9df4d14b5aec9c647f8a201f ]] &&
    grep -qxF "Exec=$legacy %i %o %s" -- "$1"
}

action=${1:-}
case $action in
  adoptable) legacy_pair "${2:-}"; exit ;;
  install|remove) ;;
  *) fail 'uso: exe-icons.sh install|remove' ;;
esac
((EUID == 0)) || [[ -n ${OMARCHY_TOOL_EXE_BIN_DIR:-} ]] || fail 'se necesita permiso de administrador'

case $action in
  install)
    if ! pacman -Q icoutils >/dev/null 2>&1; then
      pacman -S --needed --noconfirm icoutils
      touch -- "$marker"
    fi
    mkdir -p -- "$bin_dir"
    # Nautilus runs thumbnailers in a bubblewrap sandbox that only sees
    # system directories: a copy under $HOME never runs. Install root-owned.
    if ((EUID == 0)); then
      install -o root -g root -m 0755 -- "$helper_dir/exe-thumbnailer" "$target"
    else
      install -m 0755 -- "$helper_dir/exe-thumbnailer" "$target"
    fi
    if legacy_pair "${2:-}"; then
      # Remove both originals in this same privileged run, before the module
      # registers its replacement, so there are never two thumbnailers.
      rm -f -- "$legacy" "$2"
    fi
    ;;
  remove)
    rm -f -- "$target"
    if [[ -f $marker ]]; then
      if pacman -Q icoutils >/dev/null 2>&1; then
        pacman -R --noconfirm icoutils
      fi
      rm -f -- "$marker"
    fi
    ;;
esac
