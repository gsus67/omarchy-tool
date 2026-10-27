#!/bin/bash
# Package changes only. Called once through pkexec, never runs Windows code.
set -euo pipefail
helper_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$helper_dir/../i18n.sh"
marker="$helper_dir/umu-installed"
case ${1:-} in
  install)
    if ! pacman -Q umu-launcher >/dev/null 2>&1; then
      if ! pacman-conf --repo-list | grep -qxF multilib; then
        printf 'exe-proton: %s\n' "$(tool_text 'El repositorio multilib no está habilitado. Habilítalo antes de activar este módulo.')" >&2
        exit 1
      fi
      pacman -S --needed --noconfirm umu-launcher
      touch -- "$marker"
    fi
    ;;
  remove)
    if [[ -f $marker ]]; then
      if pacman -Q umu-launcher >/dev/null 2>&1; then
        pacman -R --noconfirm umu-launcher
      fi
      rm -f -- "$marker"
    fi
    ;;
  *) exit 1 ;;
esac
