# shellcheck shell=bash
# Module: windows-disks
#
# Shares up to two of the user's disks with Omarchy's Windows VM the same way
# Omarchy shares ~/Windows: as Samba folders on \\host.lan (Data2 and Data3),
# which Windows can give a drive letter. dockurr/windows serves /shared2 and
# /shared3 when they are mounted, so this module adds those two bind lines to
# Omarchy's root-owned compose through bin/compose-shares.sh under pkexec.
# Changes reach Windows the next time the VM starts.
#
# The last applied folders and the compose mtime are kept in
# $STATE_DIR/windows-disks.applied, so apply only asks for the password when
# something changed (including Omarchy rewriting the compose on reinstall).

WINDOWS_DISKS_COMPOSE="${OMARCHY_TOOL_COMPOSE:-/var/lib/omarchy/windows/docker-compose.yml}"
WINDOWS_DISKS_DESKTOP="${OMARCHY_TOOL_APPLICATIONS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/applications}/windows-vm.desktop"
WINDOWS_DISKS_MAX=2

windows_disks_enabled() {
  [[ $(config_get '.modules["windows-disks"].enabled // false') == true ]]
}

windows_disks_record() {
  echo "$STATE_DIR/windows-disks.applied"
}

# Disk names are only labels in the panel; keep them to safe characters.
windows_disks_valid_name() {
  [[ $1 =~ ^[A-Za-z0-9._-][A-Za-z0-9\ ._-]{0,31}$ ]]
}

# Same rule compose-shares.sh enforces as root.
windows_disks_valid_path() {
  [[ $1 =~ ^/(mnt|media|run/media|home)/[^\"\\:,#$'\n']+$ ]] &&
    [[ $1 != */.. && $1 != */../* && $1 != */. && $1 != */./* ]]
}

# Drop trailing slashes, so /mnt/datos/ and /mnt/datos are one disk.
windows_disks_normalize() {
  local path=$1
  while [[ $path == */ ]]; do path=${path%/}; done
  printf '%s\n' "$path"
}

# A disk under /mnt, /media or /run/media only counts while something is
# mounted there; otherwise Windows would see the empty mount-point folder.
windows_disks_available() {
  local path=$1 target
  [[ -d $path ]] || return 1
  if [[ $path =~ ^/(mnt|media|run/media)/ ]]; then
    target=$(findmnt -no TARGET -T "$path" 2>/dev/null | head -n1)
    [[ -n $target && $target != / && $target != /home ]] || return 1
  fi
  return 0
}

windows_disks_candidates_json() {
  findmnt -lJ -o TARGET,SOURCE,FSTYPE,LABEL,SIZE 2>/dev/null |
    jq -c '[.filesystems[]?
      | select(.target | test("^/(mnt|media|run/media)/"))
      | select(.fstype | test("^(tmpfs|devtmpfs|overlay|squashfs|autofs)$") | not)
      | {path: .target, label: (.label // ""), size: (.size // ""), fstype: (.fstype // ""), source: (.source // "")}]
      | unique_by(.path)' 2>/dev/null || echo '[]'
}

# Saved disks as NUL-separated name/path pairs.
windows_disks_saved() {
  config_get -j '.modules["windows-disks"].disks // [] | .[] | .name + "\u0000" + .path + "\u0000"'
}

# Folders that should be shared right now: the saved disks while enabled.
windows_disks_desired() {
  windows_disks_enabled || return 0
  config_get -r '.modules["windows-disks"].disks // [] | .[] | .path' | head -n "$WINDOWS_DISKS_MAX"
}

windows_disks_compose_mtime() {
  stat -c %Y -- "$WINDOWS_DISKS_COMPOSE" 2>/dev/null || echo 0
}

# Record: first line the compose mtime after our write, then one folder per line.
windows_disks_record_matches() {
  local record desired
  record=$(windows_disks_record)
  desired=$(windows_disks_desired)
  if [[ -z $desired ]]; then
    [[ ! -e $record ]]
    return
  fi
  [[ -f $record ]] || return 1
  [[ $(head -n1 "$record") == "$(windows_disks_compose_mtime)" ]] || return 1
  [[ $(tail -n +2 "$record") == "$desired" ]]
}

windows_disks_privileged() {
  if [[ -n ${OMARCHY_TOOL_PRIV+x} ]]; then
    ${OMARCHY_TOOL_PRIV:+$OMARCHY_TOOL_PRIV} "$@"
  else
    pkexec "$@"
  fi
}

windows_disks_write_compose() {
  windows_disks_privileged /usr/bin/bash "$STATE_DIR/compose-shares.sh" "$@"
}

# v0.0.1-v0.0.6 shared disks over RDP through a launcher in windows-vm.desktop.
# Hand the entry back to Omarchy and drop that launcher.
windows_disks_cleanup_rdp() {
  local launcher="$STATE_DIR/windows-vm-launch" saved="$STATE_DIR/windows-vm.exec" restore tmp
  if [[ -f $WINDOWS_DISKS_DESKTOP ]] && grep '^Exec=' "$WINDOWS_DISKS_DESKTOP" | grep -qF -- "$launcher"; then
    restore="uwsm app -- omarchy-windows-vm launch"
    [[ -s $saved ]] && restore=$(head -n1 "$saved")
    tmp=$(mktemp "$WINDOWS_DISKS_DESKTOP.XXXXXX")
    awk -v exec_line="Exec=$restore" '!done && /^Exec=/ { print exec_line; done = 1; next } { print }' \
      "$WINDOWS_DISKS_DESKTOP" >"$tmp"
    chmod --reference="$WINDOWS_DISKS_DESKTOP" -- "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$WINDOWS_DISKS_DESKTOP"
  fi
  rm -f -- "$launcher" "$saved"
}

windows_disks_apply() {
  local record folders=()
  record=$(windows_disks_record)
  windows_disks_cleanup_rdp

  mkdir -p -- "$STATE_DIR"
  install -m 0644 -- "$TOOL_DIR/bin/compose-shares.sh" "$STATE_DIR/compose-shares.sh"

  # No VM: nothing to share with, and nothing of ours can be in a compose.
  if [[ ! -f $WINDOWS_DISKS_COMPOSE ]]; then
    rm -f -- "$record"
    return 0
  fi

  windows_disks_record_matches && return 0

  mapfile -t folders < <(windows_disks_desired)
  windows_disks_write_compose "${folders[@]}" || fail "no se pudo cambiar la configuración de Windows"

  if ((${#folders[@]})); then
    { windows_disks_compose_mtime; printf '%s\n' "${folders[@]}"; } >"$record"
  else
    # Off leaves nothing of this module on the system; only the disk choices
    # in the config survive, so switching back on remembers them.
    rm -f -- "$record"
  fi
}

windows_disks_status() {
  local installed=false enabled=false applied=false disks='[]' candidates index=2
  [[ -f $WINDOWS_DISKS_COMPOSE ]] && installed=true
  windows_disks_enabled && enabled=true
  windows_disks_record_matches && applied=true

  local name path available
  while IFS= read -r -d '' name && IFS= read -r -d '' path; do
    [[ -n $path ]] || continue
    available=false
    windows_disks_available "$path" && available=true
    disks=$(jq -c --arg name "$name" --arg path "$path" --argjson available "$available" \
      --arg share "\\\\host.lan\\Data$index" \
      '. + [{name: $name, path: $path, available: $available, share: $share}]' <<<"$disks")
    index=$((index + 1))
  done < <(windows_disks_saved)

  candidates=$(windows_disks_candidates_json)
  jq -n --argjson enabled "$enabled" --argjson installed "$installed" --argjson applied "$applied" \
    --argjson disks "$disks" --argjson candidates "$candidates" --argjson max "$WINDOWS_DISKS_MAX" \
    '{enabled: $enabled, vmInstalled: $installed, applied: $applied, max: $max, disks: $disks,
      summary: (if ($installed | not) then "Windows no está instalado"
        elif $enabled then "Comparte " + ($disks | length | tostring) + (if ($disks | length) == 1 then " disco" else " discos" end)
        else "Desactivado" end),
      candidates: [$candidates[] | . as $c | . + {selected: any($disks[]; .path == $c.path)}]}'
}

windows_disks_enable() {
  config_update '.modules["windows-disks"].enabled = true'
  windows_disks_apply
}

windows_disks_disable() {
  config_update '.modules["windows-disks"].enabled = false'
  windows_disks_apply
}

# add <path> [name]
windows_disks_add() {
  local path=${1:-} name=${2:-} count
  [[ -n $path ]] || fail "usage: omarchy-tool windows-disks add <path> [name]"
  path=$(windows_disks_normalize "$path")
  windows_disks_valid_path "$path" || fail "solo se pueden compartir carpetas de /mnt, /media, /run/media o /home: $path"
  [[ -d $path ]] || fail "no existe la carpeta: $path"
  [[ $(realpath -e -- "$path") == "$path" ]] || fail "la ruta pasa por un enlace; usa la ruta real: $(realpath -e -- "$path")"
  count=$(config_get '[.modules["windows-disks"].disks // [] | .[] | select(.path != $path)] | length' --arg path "$path")
  ((count < WINDOWS_DISKS_MAX)) || fail "máximo $WINDOWS_DISKS_MAX discos; quita uno antes"
  if [[ -z $name ]]; then
    name=$(findmnt -no LABEL --target "$path" 2>/dev/null | head -n1 || true)
    [[ -n $name && $(findmnt -no TARGET --target "$path" | head -n1) == "$path" ]] || name=$(basename -- "$path")
  fi
  name=$(tr -c 'A-Za-z0-9 ._\n-' '_' <<<"$name" | head -c 32)
  windows_disks_valid_name "$name" || fail "invalid name: $name"
  config_update '.modules["windows-disks"].disks =
      ((.modules["windows-disks"].disks // []) | map(select(.path != $path)) + [{name: $name, path: $path}])' \
    --arg path "$path" --arg name "$name"
  windows_disks_apply
}

# remove <path>
windows_disks_remove() {
  local path=${1:-}
  [[ -n $path ]] || fail "usage: omarchy-tool windows-disks remove <path>"
  path=$(windows_disks_normalize "$path")
  config_update '.modules["windows-disks"].disks = ((.modules["windows-disks"].disks // []) | map(select(.path != $path)))' \
    --arg path "$path"
  windows_disks_apply
}
