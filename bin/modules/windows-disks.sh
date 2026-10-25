# shellcheck shell=bash
# Module: windows-disks
#
# Opens the Omarchy Windows VM with the user's chosen disks attached as RDP
# drives. Omarchy's `omarchy-windows-vm launch` stays in charge of starting the
# VM and connecting; we only put a xfreerdp3 shim first on its PATH that adds
# one /drive: argument per configured disk.
#
# While enabled, the Windows app entry (windows-vm.desktop) launches through a
# small launcher in $STATE_DIR. That launcher falls back to the stock command
# when the plugin is removed, so the Windows entry never breaks.

WINDOWS_DISKS_DESKTOP="${OMARCHY_TOOL_APPLICATIONS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/applications}/windows-vm.desktop"
WINDOWS_DISKS_STOCK_EXEC="uwsm app -- omarchy-windows-vm launch"

windows_disks_launcher() {
  echo "$STATE_DIR/windows-vm-launch"
}

# Exec= value for the launcher, quoted per the desktop entry spec so a data
# dir with spaces stays one argument.
windows_disks_launcher_exec() {
  local path
  path=$(windows_disks_launcher)
  path=${path//\\/\\\\}
  path=${path//\"/\\\"}
  path=${path//\`/\\\`}
  path=${path//\$/\\\$}
  printf 'uwsm app -- "%s"\n' "$path"
}

# Saved disks as NUL-separated name/path pairs: paths may hold any byte that
# survives JSON, and @tsv would escape backslashes and tabs.
windows_disks_saved() {
  config_get -j '.modules["windows-disks"].disks // [] | .[] | .name + "\u0000" + .path + "\u0000"'
}

windows_disks_enabled() {
  [[ $(config_get '.modules["windows-disks"].enabled // false') == true ]]
}

# Disk names become Windows drive labels; keep them to safe characters.
windows_disks_valid_name() {
  [[ $1 =~ ^[A-Za-z0-9._-][A-Za-z0-9\ ._-]{0,31}$ ]]
}

# /drive:<name>,<path> splits on the first comma, so paths may not carry one.
windows_disks_valid_path() {
  [[ $1 == /* && $1 != *,* && $1 != *$'\n'* ]]
}

# Drop trailing slashes, so /mnt/datos/ and /mnt/datos are one disk. "/"
# comes back empty, which callers refuse.
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

windows_disks_desktop_exec() {
  [[ -f $WINDOWS_DISKS_DESKTOP ]] || return 1
  sed -n 's/^Exec=//p' "$WINDOWS_DISKS_DESKTOP" | head -n1
}

windows_disks_set_desktop_exec() {
  local value=$1 tmp
  tmp=$(mktemp "$(dirname -- "$WINDOWS_DISKS_DESKTOP")/.windows-vm.desktop.XXXXXX")
  awk -v exec_line="Exec=$value" '
    !done && /^Exec=/ { print exec_line; done = 1; next }
    { print }
  ' "$WINDOWS_DISKS_DESKTOP" >"$tmp"
  chmod --reference="$WINDOWS_DISKS_DESKTOP" -- "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$WINDOWS_DISKS_DESKTOP"
}

windows_disks_write_launcher() {
  local launcher tmp
  launcher=$(windows_disks_launcher)
  mkdir -p -- "$STATE_DIR"
  tmp=$(mktemp "$STATE_DIR/.windows-vm-launch.XXXXXX")
  cat >"$tmp" <<EOF
#!/bin/bash
# Written by the gsus.tool Omarchy plugin (omarchy-tool windows-disks).
# Opens Windows with your configured disks, or the stock way if the plugin
# is gone.
tool=$(printf '%q' "$TOOL_DIR/bin/omarchy-tool")
if [[ -x \$tool ]]; then
  exec "\$tool" windows-disks launch "\$@"
fi
exec omarchy-windows-vm launch "\$@"
EOF
  chmod 0755 -- "$tmp"
  mv -f -- "$tmp" "$launcher"
}

windows_disks_apply() {
  local wanted current ours=false saved="$STATE_DIR/windows-vm.exec"
  wanted=$(windows_disks_launcher_exec)
  [[ -f $WINDOWS_DISKS_DESKTOP ]] || return 0
  current=$(windows_disks_desktop_exec || true)
  # v0.0.1 test builds wrote the launcher path unquoted; treat it as ours.
  [[ $current == "$wanted" || $current == "uwsm app -- $(windows_disks_launcher)" ]] && ours=true

  if windows_disks_enabled; then
    windows_disks_write_launcher
    if [[ $current != "$wanted" ]]; then
      if [[ $ours == false ]]; then
        mkdir -p -- "$STATE_DIR"
        printf '%s\n' "${current:-$WINDOWS_DISKS_STOCK_EXEC}" >"$saved"
      fi
      windows_disks_set_desktop_exec "$wanted"
    fi
  elif [[ $ours == true ]]; then
    local restore=$WINDOWS_DISKS_STOCK_EXEC
    [[ -s $saved ]] && restore=$(head -n1 "$saved")
    windows_disks_set_desktop_exec "$restore"
    rm -f -- "$saved"
  fi
}

windows_disks_status() {
  local current applied=false installed=false enabled=false disks='[]' candidates
  [[ -f $WINDOWS_DISKS_DESKTOP ]] && installed=true
  current=$(windows_disks_desktop_exec || true)
  [[ $current == "$(windows_disks_launcher_exec)" ]] && applied=true
  windows_disks_enabled && enabled=true

  local name path available
  while IFS= read -r -d '' name && IFS= read -r -d '' path; do
    [[ -n $path ]] || continue
    available=false
    windows_disks_available "$path" && available=true
    disks=$(jq -c --arg name "$name" --arg path "$path" --argjson available "$available" \
      '. + [{name: $name, path: $path, available: $available}]' <<<"$disks")
  done < <(windows_disks_saved)

  candidates=$(windows_disks_candidates_json)
  jq -n --argjson enabled "$enabled" --argjson installed "$installed" --argjson applied "$applied" \
    --argjson disks "$disks" --argjson candidates "$candidates" \
    '{enabled: $enabled, vmInstalled: $installed, applied: $applied, disks: $disks,
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
  local path=${1:-} name=${2:-}
  [[ -n $path ]] || fail "usage: omarchy-tool windows-disks add <path> [name]"
  path=$(windows_disks_normalize "$path")
  [[ -n $path ]] || fail "sharing the whole filesystem (/) is not allowed"
  windows_disks_valid_path "$path" || fail "invalid path: $path"
  [[ -d $path ]] || fail "not a folder: $path"
  if [[ -z $name ]]; then
    name=$(findmnt -no LABEL --target "$path" 2>/dev/null | head -n1 || true)
    [[ -n $name && $(findmnt -no TARGET --target "$path" | head -n1) == "$path" ]] || name=$(basename -- "$path")
  fi
  name=$(tr -c 'A-Za-z0-9 ._\n-' '_' <<<"$name" | head -c 32)
  windows_disks_valid_name "$name" || fail "invalid name: $name"
  config_update '.modules["windows-disks"].disks =
      ((.modules["windows-disks"].disks // []) | map(select(.path != $path and .name != $name)) + [{name: $name, path: $path}])' \
    --arg path "$path" --arg name "$name"
}

# remove <path>
windows_disks_remove() {
  local path=${1:-}
  [[ -n $path ]] || fail "usage: omarchy-tool windows-disks remove <path>"
  path=$(windows_disks_normalize "$path")
  config_update '.modules["windows-disks"].disks = ((.modules["windows-disks"].disks // []) | map(select(.path != $path)))' \
    --arg path "$path"
}

# One /drive: argument per line for every configured disk that is present.
windows_disks_rdp_args() {
  local name path
  windows_disks_enabled || return 0
  while IFS= read -r -d '' name && IFS= read -r -d '' path; do
    [[ -n $path ]] || continue
    windows_disks_valid_name "$name" && windows_disks_valid_path "$path" || continue
    windows_disks_available "$path" || continue
    printf '/drive:%s,%s\n' "$name" "$path"
  done < <(windows_disks_saved)
}

# launch [omarchy-windows-vm launch options]
windows_disks_launch() {
  PATH="$TOOL_DIR/bin/shims:$PATH" exec omarchy-windows-vm launch "$@"
}
