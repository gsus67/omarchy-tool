# shellcheck shell=bash
# Module: windows-disks
#
# Shares up to two of the user's disks with Omarchy's Windows VM the same way
# Omarchy shares ~/Windows: as Samba folders on \\host.lan (Data2 and Data3),
# which Windows can give a drive letter. dockurr/windows serves /shared2 and
# /shared3 when they are mounted, so this module adds those two bind lines to
# Omarchy's root-owned compose (compose_sync in bin/omarchy-tool, through
# bin/compose-edit.sh under pkexec). Changes reach Windows the next time the
# VM starts.
#
# Drive letters: Windows only maps \\host.lan\Data to Z: once, at install. For
# ours the module drops "Omarchy Tool/Discos" into that same Shared folder (~/Windows)
# with "Activar discos" (the same `net use ... /persistent:yes` plus a desktop
# shortcut) and "Quitar discos", which the user runs once inside Windows.

WINDOWS_DISKS_DESKTOP="${OMARCHY_TOOL_APPLICATIONS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/applications}/windows-vm.desktop"
WINDOWS_DISKS_MAX=2
WINDOWS_DISKS_SHARED="${OMARCHY_TOOL_WINDOWS_SHARED:-$HOME/Windows}"
WINDOWS_DISKS_LETTERS="XYWVUTSRQPONMLKJIHGFED"

windows_disks_enabled() {
  [[ $(config_get '.modules["windows-disks"].enabled // false') == true ]]
}

# Disk names are only labels in the panel; keep them to safe characters.
windows_disks_valid_name() {
  [[ $1 =~ ^[A-Za-z0-9._-][A-Za-z0-9\ ._-]{0,31}$ ]]
}

# Same rule compose-edit.sh enforces as root.
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

windows_disks_compose_args() {
  windows_disks_desired | sed 's/^/--share /'
}

# Free letter for a new disk: the first of X, Y, W, ... not taken by another
# saved disk (Z: is Omarchy's own Shared).
windows_disks_free_letter() {
  local taken i letter
  taken=$(config_get -r '.modules["windows-disks"].disks // [] | .[] | select(.path != $path) | .letter // empty' --arg path "${1:-}")
  for ((i = 0; i < ${#WINDOWS_DISKS_LETTERS}; i++)); do
    letter=${WINDOWS_DISKS_LETTERS:i:1}
    grep -qxF -- "$letter" <<<"$taken" || { echo "$letter"; return; }
  done
  return 1
}

# Keep ~/Windows/Omarchy Tool/Discos in step: the scripts plus discos.txt while disks
# are shared. Otherwise only what Windows needs to undo letters it was given
# (.letras-puestas, written by Activar), or nothing at all.
windows_disks_sync_windows_folder() {
  local root="$WINDOWS_DISKS_SHARED/Omarchy Tool" index=2 letter name path f
  local folder="$root/Discos"
  # v0.0.9-v0.0.18 kept these right in Omarchy Tool; move them, marker included.
  for f in omarchy-tool.ps1 "Activar discos.cmd" "Quitar discos.cmd" discos.txt .plugin-activo .letras-puestas; do
    if [[ -e $root/$f ]]; then
      mkdir -p -- "$folder"
      mv -f -- "$root/$f" "$folder/$f"
    fi
  done
  if [[ $(windows_disks_desired) != "" && -f $COMPOSE_FILE && -d $WINDOWS_DISKS_SHARED ]]; then
    mkdir -p -- "$folder"
    cp -f -- "$TOOL_DIR/windows/omarchy-tool.ps1" "$TOOL_DIR/windows/Activar discos.cmd" \
      "$TOOL_DIR/windows/Quitar discos.cmd" "$folder/"
    : >"$folder/discos.txt"
    while IFS= read -r -d '' letter && IFS= read -r -d '' name && IFS= read -r -d '' path; do
      printf '%s|\\\\host.lan\\Data%s|%s\r\n' "$letter" "$index" "$name" >>"$folder/discos.txt"
      index=$((index + 1))
    done < <(config_get -j '.modules["windows-disks"].disks // [] | .[:2][] | (.letter // "X") + "\u0000" + .name + "\u0000" + .path + "\u0000"')
    : >"$folder/.plugin-activo"
  elif [[ -d $folder ]]; then
    windows_disks_retire_windows_folder "$folder"
  fi
}

# The folder is shared with other modules: drop only our files, and the folder
# once nothing is left in it.
windows_disks_retire_windows_folder() {
  local folder=$1
  rm -f -- "$folder/.plugin-activo" "$folder/Activar discos.cmd" "$folder/discos.txt"
  if [[ ! -e $folder/.letras-puestas ]]; then
    rm -f -- "$folder/omarchy-tool.ps1" "$folder/Quitar discos.cmd"
  fi
  rmdir -- "$folder" "${folder%/*}" 2>/dev/null || true
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

# Disks saved before letters existed (v0.0.7-v0.0.8) get a free one each.
windows_disks_fill_letters() {
  local path letter
  while IFS= read -r path; do
    letter=$(windows_disks_free_letter "$path") || return 0
    config_update '.modules["windows-disks"].disks |= map(if .path == $path then .letter = $letter else . end)' \
      --arg path "$path" --arg letter "$letter"
  done < <(config_get -r '.modules["windows-disks"].disks // [] | .[] | select(.letter == null) | .path')
}

windows_disks_apply() {
  windows_disks_cleanup_rdp
  windows_disks_fill_letters
  compose_sync || fail "no se pudo cambiar la configuración de Windows"
  windows_disks_sync_windows_folder
}

windows_disks_status() {
  local installed=false enabled=false applied=false disks='[]' candidates index=2
  [[ -f $COMPOSE_FILE ]] && installed=true
  windows_disks_enabled && enabled=true
  compose_in_sync --share && applied=true

  local name path letter available
  while IFS= read -r -d '' name && IFS= read -r -d '' path && IFS= read -r -d '' letter; do
    [[ -n $path ]] || continue
    available=false
    windows_disks_available "$path" && available=true
    disks=$(jq -c --arg name "$name" --arg path "$path" --arg letter "$letter" --argjson available "$available" \
      --arg share "\\\\host.lan\\Data$index" \
      '. + [{name: $name, path: $path, letter: $letter, available: $available, share: $share}]' <<<"$disks")
    index=$((index + 1))
  done < <(config_get -j '.modules["windows-disks"].disks // [] | .[] | .name + "\u0000" + .path + "\u0000" + (.letter // "X") + "\u0000"')

  candidates=$(windows_disks_candidates_json)
  jq -n --argjson enabled "$enabled" --argjson installed "$installed" --argjson applied "$applied" \
    --argjson disks "$disks" --argjson candidates "$candidates" --argjson max "$WINDOWS_DISKS_MAX" \
    --argjson lettersSet "$([[ -e "$WINDOWS_DISKS_SHARED/Omarchy Tool/Discos/.letras-puestas" ]] && echo true || echo false)" \
    '{enabled: $enabled, vmInstalled: $installed, applied: $applied, max: $max, disks: $disks, lettersSet: $lettersSet,
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
  local letter
  letter=$(config_get -r '.modules["windows-disks"].disks // [] | .[] | select(.path == $path) | .letter // empty' --arg path "$path")
  [[ -n $letter ]] || letter=$(windows_disks_free_letter "$path") || fail "no quedan letras libres"
  # A disk already saved keeps its place: the order decides Data2 and Data3.
  config_update '.modules["windows-disks"].disks |= (. // [] |
      if any(.[]; .path == $path)
      then map(if .path == $path then .name = $name | .letter = $letter else . end)
      else . + [{name: $name, path: $path, letter: $letter}] end)' \
    --arg path "$path" --arg name "$name" --arg letter "$letter"
  windows_disks_apply
}

# letter <path> <D-Y>: the drive letter Windows gives this disk. "next" picks
# the following free one.
windows_disks_letter() {
  local path=${1:-} letter=${2:-} current i
  [[ -n $path && -n $letter ]] || fail "usage: omarchy-tool windows-disks letter <path> <D-Y|next>"
  path=$(windows_disks_normalize "$path")
  current=$(config_get -r '.modules["windows-disks"].disks // [] | .[] | select(.path == $path) | .letter // "X"' --arg path "$path")
  [[ -n $current ]] || fail "ese disco no está marcado: $path"
  if [[ $letter == next ]]; then
    local taken pos
    taken=$(config_get -r '.modules["windows-disks"].disks // [] | .[] | select(.path != $path) | .letter // empty' --arg path "$path")
    pos=$(( $(expr index "$WINDOWS_DISKS_LETTERS" "$current") ))
    for ((i = 0; i < ${#WINDOWS_DISKS_LETTERS}; i++)); do
      letter=${WINDOWS_DISKS_LETTERS:(pos + i) % ${#WINDOWS_DISKS_LETTERS}:1}
      grep -qxF -- "$letter" <<<"$taken" || break
    done
  fi
  letter=${letter^^}
  letter=${letter%:}
  [[ $letter =~ ^[D-Y]$ ]] || fail "letra no válida: $letter (de D a Y; Z es la de Omarchy)"
  config_get -e 'any(.modules["windows-disks"].disks // [] | .[]; .path != $path and .letter == $letter) | not' \
    --arg path "$path" --arg letter "$letter" >/dev/null || fail "la letra $letter: ya la usa otro disco"
  config_update '.modules["windows-disks"].disks |= map(if .path == $path then .letter = $letter else . end)' \
    --arg path "$path" --arg letter "$letter"
  windows_disks_sync_windows_folder
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
