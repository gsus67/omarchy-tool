# shellcheck shell=bash
# Sourced by run.sh: Proton's user-session lifecycle, no real package/session IO.
ep() { "$tool" status | jq -r ".modules[\"exe-proton\"]$1"; }
proton_state="$OMARCHY_TOOL_STATE_DIR/exe-proton"
proton_entry="$OMARCHY_TOOL_APPLICATIONS_DIR/omarchy-tool-run-exe.desktop"
export XDG_CONFIG_HOME="$work/xdg-config"
export UMU_FOLDERS_PATH="$XDG_DATA_HOME"
export OMARCHY_TOOL_TEST_UMU="$work/umu-present"
export OMARCHY_TOOL_TEST_MULTILIB="$work/multilib-enabled"
export OMARCHY_TOOL_TEST_SYSTEMD_LOG="$work/systemd.log"
export OMARCHY_TOOL_TEST_SYSTEMCTL_LOG="$work/systemctl.log"
export OMARCHY_TOOL_TEST_UMU_LOG="$work/umu.log"
export OMARCHY_TOOL_TEST_NOTIFY_LOG="$work/proton-notify.log"
export OMARCHY_TOOL_TEST_MIME_LOG="$work/mime.log"
export OMARCHY_TOOL_TEST_UNIT="$work/preparation-unit"
export OMARCHY_TOOL_TEST_PRIV_LOG="$work/proton-priv.log"
export OMARCHY_TOOL_PRIV="$work/priv"
mkdir -p "$XDG_CONFIG_HOME"
# pacman-conf uses the parsed enabled repository list (including Include files).
cat >"$work/quiet-bin/pacman-conf" <<'FAKE'
#!/bin/bash
[[ $* == --repo-list ]] || exit 1
printf 'core\nextra\n'
[[ ! -f $OMARCHY_TOOL_TEST_MULTILIB ]] || echo multilib
FAKE
cp "$work/quiet-bin/pacman" "$work/icons-pacman"
cat >"$work/quiet-bin/pacman" <<'FAKE'
#!/bin/bash
case "$*" in
  '-Q umu-launcher') [[ -f $OMARCHY_TOOL_TEST_UMU ]] ;;
  '-S --needed --noconfirm umu-launcher')
    [[ ${OMARCHY_TOOL_TEST_PACMAN_FAIL:-} != install ]] || exit 1
    echo "$*" >>"$OMARCHY_TOOL_TEST_PACMAN_LOG"
    touch "$OMARCHY_TOOL_TEST_UMU" ;;
  '-R --noconfirm umu-launcher')
    [[ ${OMARCHY_TOOL_TEST_PACMAN_FAIL:-} != remove ]] || exit 1
    echo "$*" >>"$OMARCHY_TOOL_TEST_PACMAN_LOG"
    rm -f "$OMARCHY_TOOL_TEST_UMU" ;;
  *) exit 1 ;;
esac
FAKE
cat >"$work/quiet-bin/xdg-mime" <<'FAKE'
#!/usr/bin/python3
import configparser
import os
from pathlib import Path
import sys
path = Path(os.environ['XDG_CONFIG_HOME']) / 'mimeapps.list'
c = configparser.ConfigParser(interpolation=None)
c.read(path)
a = sys.argv[1:]
if a[:2] == ['query', 'default']:
    print(c.get('Default Applications', a[2], fallback='').rstrip(';'))
elif a[0] == 'default':
    with open(os.environ['OMARCHY_TOOL_TEST_MIME_LOG'], 'a') as log:
        log.write(' '.join(a) + '\n')
    if os.environ.get('OMARCHY_TOOL_TEST_MIME_FAIL') == a[2]:
        sys.exit(1)
    if not c.has_section('Default Applications'):
        c.add_section('Default Applications')
    c.set('Default Applications', a[2], a[1] + ';')
    with path.open('w') as f:
        c.write(f, space_around_delimiters=False)
else:
    sys.exit(1)
FAKE
cat >"$work/quiet-bin/systemd-run" <<'FAKE'
#!/bin/bash
printf '%s\n' "$@" >>"$OMARCHY_TOOL_TEST_SYSTEMD_LOG"
[[ ${OMARCHY_TOOL_TEST_SYSTEMD_FAIL:-} != true ]] || exit 1
# Log without executing: prove enabling never waits for wineboot/downloads.
touch "$OMARCHY_TOOL_TEST_UNIT"
FAKE
cat >"$work/quiet-bin/systemctl" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >>"$OMARCHY_TOOL_TEST_SYSTEMCTL_LOG"
case "$*" in
  '--user show omarchy-tool-exe-proton-prepare.service --property=LoadState --value')
    if [[ -f $OMARCHY_TOOL_TEST_UNIT ]]; then echo loaded; else echo not-found; exit 1; fi ;;
  '--user stop omarchy-tool-exe-proton-prepare.service')
    [[ ${OMARCHY_TOOL_TEST_STOP_FAIL:-} != true ]] || exit 1
    rm -f "$OMARCHY_TOOL_TEST_UNIT" ;;
  *) exit 1 ;;
esac
FAKE
cat >"$work/quiet-bin/notify-send" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >>"$OMARCHY_TOOL_TEST_NOTIFY_LOG"
FAKE
cat >"$work/quiet-bin/umu-run" <<'FAKE'
#!/bin/bash
printf '%s\n' "$WINEPREFIX|$GAMEID|$PROTONPATH|$PWD|$*" >>"$OMARCHY_TOOL_TEST_UMU_LOG"
if [[ $* == 'wineboot -u' ]]; then
  mkdir -p "$UMU_FOLDERS_PATH/Steam/compatibilitytools.d/GE-Proton-test" "$WINEPREFIX/drive_c"
  touch "$WINEPREFIX/drive_c/saves"
  [[ ${OMARCHY_TOOL_TEST_WINEBOOT_FAIL:-} != true ]] || exit 1
fi
exit "${OMARCHY_TOOL_TEST_RUN_RC:-0}"
FAKE
chmod +x "$work/quiet-bin/"{pacman,pacman-conf,xdg-mime,systemd-run,systemctl,notify-send,umu-run}
cat >"$XDG_CONFIG_HOME/mimeapps.list" <<'MIME'
# preserve this comment
[Default Applications]
application/x-ms-dos-executable=old-exe.desktop;
application/x-msi=old-msi.desktop;
text/plain=editor.desktop;
[Added Associations]
text/plain=editor.desktop;
MIME
cp "$XDG_CONFIG_HOME/mimeapps.list" "$work/mime-original"
check "exe-proton registered and starts disabled/applied" '"$tool" modules | grep -x exe-proton >/dev/null && [[ $(ep .enabled) == false && $(ep .applied) == true ]]'
check "exe-proton refuses missing multilib with a Spanish explanation" '! "$tool" exe-proton enable 2>"$work/proton-error" && grep -q "multilib no está habilitado" "$work/proton-error" && [[ ! -e $OMARCHY_TOOL_TEST_UMU && ! -e $proton_entry && ! -e $proton_state/umu-installed ]]'
touch "$OMARCHY_TOOL_TEST_MULTILIB"
check "exe-proton cancelled privilege keeps defaults untouched" '! OMARCHY_TOOL_PRIV=false "$tool" exe-proton apply 2>/dev/null && cmp -s "$XDG_CONFIG_HOME/mimeapps.list" "$work/mime-original"'
check "exe-proton failed package install does not claim it" '! OMARCHY_TOOL_TEST_PACMAN_FAIL=install "$tool" exe-proton apply 2>/dev/null && [[ ! -f $proton_state/umu-installed && ! -e $proton_entry ]]'
priv_before=$(wc -l <"$OMARCHY_TOOL_TEST_PRIV_LOG")
"$tool" exe-proton apply
check "exe-proton installs missing umu in exactly one privileged call" '[[ $(wc -l <"$OMARCHY_TOOL_TEST_PRIV_LOG") == $((priv_before + 1)) && -f $proton_state/umu-installed ]] && grep -qx -- "-S --needed --noconfirm umu-launcher" "$OMARCHY_TOOL_TEST_PACMAN_LOG"'
check "exe-proton installs the versioned runner as an executable user copy" 'cmp -s "$repo/bin/run-exe.sh" "$proton_state/run-exe" && [[ $(stat -c %a "$proton_state/run-exe") == 755 && $(stat -c %u "$proton_state/run-exe") == "$EUID" ]]'
check "exe-proton desktop quotes a state path with spaces and all five MIME types" 'grep -qxF "Exec=/usr/bin/bash \"$proton_state/run-exe\" %f" "$proton_entry" && grep -qxF "NoDisplay=true" "$proton_entry" && grep -qxF "MimeType=application/x-ms-dos-executable;application/vnd.microsoft.portable-executable;application/x-msdownload;application/x-msi;application/x-ms-installer;" "$proton_entry"'
check "exe-proton enables all MIME defaults and saves distinct/empty predecessors" '[[ $(xdg-mime query default application/x-msi) == omarchy-tool-run-exe.desktop && $(jq -r ".[\"application/x-msi\"]" "$proton_state/defaults.json") == old-msi.desktop && $(jq -r ".[\"application/x-msdownload\"]" "$proton_state/defaults.json") == "" && $(ep .applied) == true ]]'
check "exe-proton schedules detached preparation without executing umu in panel" 'grep -qxF -- --user "$OMARCHY_TOOL_TEST_SYSTEMD_LOG" && grep -qxF -- --no-block "$OMARCHY_TOOL_TEST_SYSTEMD_LOG" && grep -qxF -- --collect "$OMARCHY_TOOL_TEST_SYSTEMD_LOG" && grep -qxF -- --unit=omarchy-tool-exe-proton-prepare "$OMARCHY_TOOL_TEST_SYSTEMD_LOG" && grep -qxF "$proton_state/prepare.sh" "$OMARCHY_TOOL_TEST_SYSTEMD_LOG" && grep -qxF "$HOME/.local/share/umu/default" "$OMARCHY_TOOL_TEST_SYSTEMD_LOG" && [[ ! -e $OMARCHY_TOOL_TEST_UMU_LOG ]]'
cp "$proton_state/defaults.json" "$work/defaults-original"
cp "$OMARCHY_TOOL_TEST_SYSTEMD_LOG" "$work/systemd-original"
check "exe-proton repeated apply keeps original defaults and schedules only once" 'OMARCHY_TOOL_PRIV=false "$tool" exe-proton apply && cmp -s "$proton_state/defaults.json" "$work/defaults-original" && cmp -s "$OMARCHY_TOOL_TEST_SYSTEMD_LOG" "$work/systemd-original"'
rm -f "$proton_entry"
check "exe-proton reapply repairs missing desktop without privilege" 'OMARCHY_TOOL_PRIV=false "$tool" exe-proton apply && [[ -f $proton_entry ]]'
# Run just the queued worker under the fakes to verify its actual command/env.
bash "$proton_state/prepare.sh" "$HOME/.local/share/umu/default"
check "exe-proton preparation uses umu GE-Proton wineboot and notifies readiness" 'grep -qF "umu-default|GE-Proton|" "$OMARCHY_TOOL_TEST_UMU_LOG" && grep -qF "wineboot -u" "$OMARCHY_TOOL_TEST_UMU_LOG" && grep -q "Preparando GE-Proton…" "$OMARCHY_TOOL_TEST_NOTIFY_LOG" && grep -q "Listo: ya puedes abrir .exe con doble clic" "$OMARCHY_TOOL_TEST_NOTIFY_LOG" && grep -qxF "$UMU_FOLDERS_PATH/Steam/compatibilitytools.d/GE-Proton-test" "$proton_state/downloaded"'
# Runner preserves arguments (including spaces), .MSI handling and failures.
touch "$work/program name.EXE" "$work/setup name.MSI"
"$proton_state/run-exe" "$work/program name.EXE"
"$proton_state/run-exe" "$work/setup name.MSI"
check "exe-proton runner dispatches EXE and MSI in their containing directory" 'grep -qF "|$work|$work/program name.EXE" "$OMARCHY_TOOL_TEST_UMU_LOG" && grep -qF "|$work|msiexec /i $work/setup name.MSI" "$OMARCHY_TOOL_TEST_UMU_LOG"'
check "exe-proton runner reports failure, preserves exit code and cache log" 'OMARCHY_TOOL_TEST_RUN_RC=23 "$proton_state/run-exe" "$work/program name.EXE"; [[ $? == 23 ]] && grep -qF "Falló: program name.EXE" "$OMARCHY_TOOL_TEST_NOTIFY_LOG" && grep -qF "Código 23. Log:" "$OMARCHY_TOOL_TEST_NOTIFY_LOG" && [[ -f $XDG_CACHE_HOME/run-exe.log ]]'
check "exe-proton cancellation retains ownership and defaults for retry" '! OMARCHY_TOOL_PRIV=false "$tool" exe-proton disable 2>/dev/null && [[ -f $proton_state/umu-installed && -f $proton_entry && $(xdg-mime query default application/x-msi) == omarchy-tool-run-exe.desktop ]]'
"$tool" exe-proton apply
check "exe-proton disable stops prep, removes owned package/download and keeps saves" '[[ ! -d $proton_state && ! -e $proton_entry && ! -e $OMARCHY_TOOL_TEST_UMU && ! -e $UMU_FOLDERS_PATH/Steam/compatibilitytools.d/GE-Proton-test && -f $HOME/.local/share/umu/default/drive_c/saves ]] && grep -qxF -- "--user stop omarchy-tool-exe-proton-prepare.service" "$OMARCHY_TOOL_TEST_SYSTEMCTL_LOG"'
check "exe-proton restores per-MIME defaults, unsets empty ones, preserves others" '[[ $(xdg-mime query default application/x-ms-dos-executable) == old-exe.desktop && $(xdg-mime query default application/x-msi) == old-msi.desktop && -z $(xdg-mime query default application/x-msdownload) && $(xdg-mime query default text/plain) == editor.desktop ]] && ! grep -q omarchy-tool-run-exe "$XDG_CONFIG_HOME/mimeapps.list"'
check "exe-proton disable is idempotent without privilege" 'OMARCHY_TOOL_PRIV=false "$tool" exe-proton disable && [[ $(ep .applied) == true ]]'
# Existing installs are never claimed, including umu's other compatibility dir.
touch "$OMARCHY_TOOL_TEST_UMU"
mkdir -p "$UMU_FOLDERS_PATH/umu/compatibilitytools/GE-Proton-existing"
cp "$OMARCHY_TOOL_TEST_SYSTEMD_LOG" "$work/systemd-original"
check "exe-proton keeps existing umu, skips GE-Proton download and asks no password" 'OMARCHY_TOOL_PRIV=false "$tool" exe-proton enable && [[ ! -e $proton_state/umu-installed && ! -e $proton_state/downloaded && ! -e $proton_state/queued ]] && cmp -s "$OMARCHY_TOOL_TEST_SYSTEMD_LOG" "$work/systemd-original"'
"$tool" exe-proton disable
check "exe-proton does not remove a pre-existing package or GE-Proton" '[[ -f $OMARCHY_TOOL_TEST_UMU && -d $UMU_FOLDERS_PATH/umu/compatibilitytools/GE-Proton-existing ]]'
check "exe-proton partial MIME failure retains the entire original snapshot" '! OMARCHY_TOOL_TEST_MIME_FAIL=application/x-msdownload "$tool" exe-proton enable 2>/dev/null && [[ $(jq -r ".[\"application/x-msi\"]" "$proton_state/defaults.json") == old-msi.desktop ]]'
"$tool" exe-proton disable
check "exe-proton partial MIME failure can be disabled with all defaults restored" '[[ $(xdg-mime query default application/x-ms-dos-executable) == old-exe.desktop && $(xdg-mime query default application/x-msi) == old-msi.desktop && -z $(xdg-mime query default application/x-msdownload) && ! -d $proton_state ]]'
# Exact legacy reference, embedded so the .ref files can be removed.
mkdir -p "$HOME/.local/bin" "$XDG_DATA_HOME/applications"
cat >"$HOME/.local/bin/run-exe" <<'LEGACY'
#!/bin/bash
# Ejecuta un .exe/.msi con Proton (GE-Proton) vía umu-launcher
export WINEPREFIX="${WINEPREFIX:-$HOME/.local/share/umu/default}"
export GAMEID="${GAMEID:-umu-default}"
export PROTONPATH="${PROTONPATH:-GE-Proton}"
f="$1"; [ -n "$f" ] || exit 1
log="$HOME/.cache/run-exe.log"
mkdir -p "$(dirname "$log")"
cd "$(dirname "$f")" || exit 1
name=$(basename "$f")
notify-send -i wine "Ejecutando con Proton" "$name" 2>/dev/null
case "${f,,}" in
  *.msi) umu-run msiexec /i "$f" >"$log" 2>&1 ;;
  *)     umu-run "$f" >"$log" 2>&1 ;;
esac
rc=$?
[ $rc -ne 0 ] && notify-send -u critical -i dialog-error "Falló: $name" "Código $rc. Log: $log" 2>/dev/null
exit $rc
LEGACY
cp "$HOME/.local/bin/run-exe" "$work/run-exe-original"
printf '[Desktop Entry]\nType=Application\nExec=%s/.local/bin/run-exe %%f\n' "$HOME" >"$XDG_DATA_HOME/applications/run-exe.desktop"
check "exe-proton recognizes exact manual script and home-specific Exec" '"$tool" exe-proton adoptable'
printf '# edited\n' >>"$HOME/.local/bin/run-exe"
check "exe-proton refuses edited legacy script" '! "$tool" exe-proton adoptable'
"$tool" exe-proton enable
check "exe-proton keeps modified manual files" '[[ -f $HOME/.local/bin/run-exe && -f $XDG_DATA_HOME/applications/run-exe.desktop ]]'
"$tool" exe-proton disable
cp "$work/run-exe-original" "$HOME/.local/bin/run-exe"
sed -i 's|^Exec=.*|Exec=/opt/other %f|' "$XDG_DATA_HOME/applications/run-exe.desktop"
check "exe-proton refuses legacy desktop pointing elsewhere" '! "$tool" exe-proton adoptable'
printf '[Desktop Entry]\nExec=%s/.local/bin/run-exe %%f\n' "$HOME" >"$XDG_DATA_HOME/applications/run-exe.desktop"
xdg-mime default run-exe.desktop application/x-msi
"$tool" exe-proton enable
check "exe-proton adopts manual files and takes over MIME with only one handler" '[[ ! -e $HOME/.local/bin/run-exe && ! -e $XDG_DATA_HOME/applications/run-exe.desktop && -f $proton_entry && $(xdg-mime query default application/x-msi) == omarchy-tool-run-exe.desktop ]]'
"$tool" exe-proton disable
check "exe-proton does not restore the deleted manual handler" '[[ -z $(xdg-mime query default application/x-msi) && $(xdg-mime query default application/x-ms-dos-executable) == old-exe.desktop ]]'
# Failed scheduling/preparation/removal is recoverable without losing ownership.
rm -rf "$UMU_FOLDERS_PATH/umu/compatibilitytools/GE-Proton-existing"
rm -f "$OMARCHY_TOOL_TEST_UMU"
check "exe-proton failed background scheduling is reported and retryable" '! OMARCHY_TOOL_TEST_SYSTEMD_FAIL=true "$tool" exe-proton enable 2>/dev/null && [[ ! -e $proton_state/queued && -f $proton_state/umu-installed ]]'
"$tool" exe-proton apply
check "exe-proton failed wineboot still records its download and notifies failure" '! OMARCHY_TOOL_TEST_WINEBOOT_FAIL=true bash "$proton_state/prepare.sh" "$HOME/.local/share/umu/default" && [[ -s $proton_state/downloaded ]] && grep -q "No se pudo preparar GE-Proton" "$OMARCHY_TOOL_TEST_NOTIFY_LOG"'
check "exe-proton failed stop keeps state, entry and package" '! OMARCHY_TOOL_TEST_STOP_FAIL=true "$tool" exe-proton disable 2>/dev/null && [[ -f $proton_state/umu-installed && -f $proton_entry && -f $OMARCHY_TOOL_TEST_UMU ]]'
check "exe-proton failed package removal keeps ownership for retry" '! OMARCHY_TOOL_TEST_PACMAN_FAIL=remove "$tool" exe-proton apply 2>/dev/null && [[ -f $proton_state/umu-installed ]]'
"$tool" exe-proton apply
check "exe-proton apply retries removal and keeps prefix after failed preparation" '[[ ! -d $proton_state && -f $HOME/.local/share/umu/default/drive_c/saves && ! -e $UMU_FOLDERS_PATH/Steam/compatibilitytools.d/GE-Proton-test ]]'
"$tool" exe-proton enable
# The copy must work after the repository disappears: no TOOL_DIR dependency.
check "exe-proton copied uninstall cancellation retains ownership" '! OMARCHY_TOOL_PRIV=false bash "$OMARCHY_TOOL_STATE_DIR/uninstall.sh" "$work/missing-plugin" && [[ -d $proton_state && -f $proton_state/umu-installed ]]'
bash "$OMARCHY_TOOL_STATE_DIR/uninstall.sh" "$work/missing-plugin"
check "exe-proton copied uninstaller restores MIME and removes state but never saves" '[[ ! -d $OMARCHY_TOOL_STATE_DIR && ! -e $proton_entry && ! -e $OMARCHY_TOOL_TEST_UMU && -f $HOME/.local/share/umu/default/drive_c/saves && $(xdg-mime query default application/x-ms-dos-executable) == old-exe.desktop && -z $(xdg-mime query default application/x-msi) ]]'
check "exe-proton uninstall is idempotent without privilege" 'OMARCHY_TOOL_PRIV=false bash "$repo/bin/uninstall.sh" "$work/missing-plugin"'
cp "$work/icons-pacman" "$work/quiet-bin/pacman"
export OMARCHY_TOOL_PRIV=""

# --- Proton save copies: same throwaway home, default prefix and folder.
export OMARCHY_TOOL_WINESERVER_PID=""
saves_user="$HOME/.local/share/umu/default/drive_c/users/steamuser"
saves_dir="$HOME/Documents/Partidas Proton"
mkdir -p "$saves_user/Saved Games/Mi Juego"
printf 'partida' >"$saves_user/Saved Games/Mi Juego/slot.sav"
check "saves listing works while the Proton module is off" '"$tool" exe-proton saves-list >"$work/saves-list.json" && jq -e ".prefixExists and .groups == [{name:\"Mi Juego\",area:\"Saved Games\",bytes:7}] and .copies == []" "$work/saves-list.json" >/dev/null'
: >"$work/notify-all.log"
check "save asks for no password and sends one completion notification" 'priv_before=$(wc -l <"$OMARCHY_TOOL_TEST_PRIV_LOG") && OMARCHY_TOOL_PRIV=false "$tool" exe-proton saves-save && [[ $(wc -l <"$OMARCHY_TOOL_TEST_PRIV_LOG") == "$priv_before" && $(wc -l <"$work/notify-all.log") == 1 ]] && grep -qF "Partidas y datos guardados." "$work/notify-all.log"'
saves_name=$(find "$saves_dir" -name 'partidas-*' -printf '%f\n')
check "preview lists what a copy contains" '[[ $("$tool" exe-proton saves-preview "$saves_name" | jq -r ".groups[0].name") == "Mi Juego" ]]'
check "open Proton refuses save with the reason and a notification" '! OMARCHY_TOOL_WINESERVER_PID=4242 "$tool" exe-proton saves-save 2>"$work/saves-error" && grep -qF "cierra Proton antes de guardar o cargar" "$work/saves-error" && grep -qF "cierra Proton antes de guardar o cargar" "$work/notify-all.log"'
printf 'nueva' >"$saves_user/Saved Games/Mi Juego/slot.sav"
: >"$work/notify-all.log"
check "load restores the copy and says a previous copy was kept" '"$tool" exe-proton saves-load "$saves_name" && [[ $(<"$saves_user/Saved Games/Mi Juego/slot.sav") == partida ]] && [[ -n $(find "$saves_dir" -name "antes-de-cargar-*") ]] && grep -qF "Partidas y datos cargados. Se conservó una copia previa." "$work/notify-all.log"'
check "bad copy name fails with a reason and changes nothing" '! "$tool" exe-proton saves-load "../x" 2>"$work/saves-error" && grep -qF "nombre de copia no válido" "$work/saves-error"'
check "status keeps its lightweight Proton shape" '"$tool" status | jq -e ".modules[\"exe-proton\"] | keys == [\"applied\",\"enabled\",\"summary\"]" >/dev/null'
check "explicit WINEPREFIX selects another prefix" 'mkdir -p "$work/other-prefix/drive_c/users/steamuser/Documents/Otro" && printf x >"$work/other-prefix/drive_c/users/steamuser/Documents/Otro/a" && [[ $(WINEPREFIX="$work/other-prefix" "$tool" exe-proton saves-list | jq -r ".groups[0].name") == Otro ]]'

# While a change holds the lock: reads go on, changes wait.
mkfifo "$work/release-lock"
flock "$XDG_RUNTIME_DIR/omarchy-tool.lock" bash -c 'touch "$1"; read -r _ <"$2"' _ "$work/lock-held" "$work/release-lock" &
lock_holder=$!
until [[ -e $work/lock-held ]]; do sleep 0.05; done
check "listing does not wait for the lock" 'timeout 5 "$tool" exe-proton saves-list >/dev/null'
check "preview does not wait for the lock" 'timeout 5 "$tool" exe-proton saves-preview "$saves_name" >/dev/null'
check "saving waits for the lock" 'timeout 0.5 "$tool" exe-proton saves-save; [[ $? == 124 ]]'
check "loading waits for the lock" 'timeout 0.5 "$tool" exe-proton saves-load "$saves_name"; [[ $? == 124 ]]'
printf '\n' >"$work/release-lock"
wait "$lock_holder"

# Neither switching off nor uninstalling touches a copy.
saves_sum=$(find "$saves_dir" -type f -exec md5sum {} + | sort)
"$tool" exe-proton enable
"$tool" exe-proton disable
check "disabling keeps every copy" '[[ $(find "$saves_dir" -type f -exec md5sum {} + | sort) == "$saves_sum" ]]'
"$tool" apply
bash "$OMARCHY_TOOL_STATE_DIR/uninstall.sh" "$work/missing-plugin"
check "uninstalling keeps every copy" '[[ $(find "$saves_dir" -type f -exec md5sum {} + | sort) == "$saves_sum" ]]'
