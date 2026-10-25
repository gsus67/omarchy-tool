#!/bin/bash

# Sets the extra shared folders of Omarchy's Windows VM. Run as root through
# pkexec by omarchy-tool (windows-disks module) and by uninstall.sh.
#
#   compose-shares.sh [folder1 [folder2]]
#
# folder1 becomes \\host.lan\Data2 and folder2 \\host.lan\Data3 in Windows
# (dockurr/windows serves /shared2 and /shared3 next to Omarchy's /shared).
# No folders removes them. Only these two bind lines are ever touched; every
# other line of the compose, including Omarchy's own /storage and /shared
# mounts, is copied as is.

set -euo pipefail

fail() {
  echo "compose-shares: $*" >&2
  exit 1
}

compose=/var/lib/omarchy/windows/docker-compose.yml
# Tests run this unprivileged against a scratch compose.
if ((EUID != 0)) && [[ -n ${OMARCHY_TOOL_COMPOSE:-} ]]; then
  compose=$OMARCHY_TOOL_COMPOSE
fi

(($# <= 2)) || fail "at most two folders"

for folder in "$@"; do
  # Only disk and home locations; nothing YAML or the bind syntax would
  # reinterpret (quotes, backslashes, colons, commas, comments, newlines).
  [[ $folder =~ ^/(mnt|media|run/media|home)/[^\"\\:,#$'\n']+$ ]] || fail "refusing folder: $folder"
  [[ $folder != */.. && $folder != */../* && $folder != */. && $folder != */./* ]] || fail "refusing folder: $folder"
  [[ -d $folder && ! -L $folder ]] || fail "not a folder: $folder"
  # No symlink anywhere on the way: /home/x/link could lead to /etc.
  [[ $(realpath -e -- "$folder") == "$folder" ]] || fail "refusing a path through a symlink: $folder"
done

[[ -f $compose && ! -L $compose ]] || exit 0
[[ $(grep -c '^[[:space:]]*-[[:space:]]*[^[:space:]].*:/shared$' "$compose") == 1 ]] ||
  fail "unexpected compose layout"

rows=()
index=2
for folder in "$@"; do
  rows+=("      - \"$folder:/shared$index\"")
  index=$((index + 1))
done

tmp=$(mktemp "$compose.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
rows_text=$(printf '%s\n' "${rows[@]+"${rows[@]}"}")
awk -v rows="$rows_text" '
  /^[[:space:]]*-[[:space:]]*"?[^[:space:]].*:\/shared[23]"?[[:space:]]*$/ { next }
  { print }
  /^[[:space:]]*-[[:space:]]*[^[:space:]].*:\/shared$/ && rows != "" { print rows }
' "$compose" >"$tmp"

chmod --reference="$compose" -- "$tmp"
if ((EUID == 0)); then
  chown --reference="$compose" -- "$tmp"
fi
mv -f -- "$tmp" "$compose"
trap - EXIT
