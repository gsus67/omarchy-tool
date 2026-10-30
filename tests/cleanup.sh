# shellcheck shell=bash
# Sourced by run.sh: the cleanup module with fake system commands and folders.
# Nothing here reaches pacman, the journal or the real coredumps.
cleanup_root="$work/cleanup"
cleanup_fake_bin="$cleanup_root/bin"
mkdir -p "$cleanup_fake_bin" "$cleanup_root/tmp" "$cleanup_root/cache" "$cleanup_root/proc/self" "$cleanup_root/core" "$cleanup_root/journal" "$cleanup_root/run-journal"
: >"$cleanup_root/proc/self/mountinfo"
cleanup_saved_path=$PATH
cleanup_saved_priv=$OMARCHY_TOOL_PRIV
export PATH="$cleanup_fake_bin:$PATH"
export OMARCHY_TOOL_CLEANUP_TEMP_DIR="$cleanup_root/tmp" OMARCHY_TOOL_CLEANUP_CACHE_DIR="$cleanup_root/cache"
export OMARCHY_TOOL_CLEANUP_PROC_DIR="$cleanup_root/proc" OMARCHY_TOOL_CLEANUP_COREDUMP_DIR="$cleanup_root/core"
export OMARCHY_TOOL_CLEANUP_JOURNAL_DIR="$cleanup_root/journal" OMARCHY_TOOL_CLEANUP_RUNTIME_JOURNAL_DIR="$cleanup_root/run-journal"
cleanup_priv_log="$cleanup_root/priv.log"
cleanup_notify_log="$work/notify-all.log"
cleanup_orphans="$cleanup_root/orphans"
cleanup_transaction="$cleanup_root/transaction"
cleanup_packages="$cleanup_root/paccache"
export cleanup_priv_log cleanup_orphans cleanup_transaction cleanup_packages cleanup_root
: >"$cleanup_orphans"
: >"$cleanup_transaction"
: >"$cleanup_packages"

cat >"$cleanup_fake_bin/pacman" <<'FAKE'
#!/bin/bash
case $1 in
  -Qdtq) [[ -s $cleanup_orphans ]] || exit 1; cat "$cleanup_orphans" ;;
  -Rs) cat "$cleanup_transaction" ;;
  -Qlq) ;;
  -Rns) [[ -z ${CLEANUP_TEST_REMOVAL_FAILS:-} ]] || exit 1; : >"$cleanup_orphans"; : >"$cleanup_transaction" ;;
  *) exit 9 ;;
esac
FAKE
cat >"$cleanup_fake_bin/paccache" <<'FAKE'
#!/bin/bash
case $* in
  '-d -k3 -vv --nocolor') echo '==> Candidate packages:'; cat "$cleanup_packages"; echo '==> finished' ;;
  -rk3) while IFS= read -r package; do rm -f -- "$package"; done <"$cleanup_packages"; : >"$cleanup_packages" ;;
  *) exit 9 ;;
esac
FAKE
cat >"$cleanup_fake_bin/journalctl" <<'FAKE'
#!/bin/bash
[[ $* == '--rotate --vacuum-size=50M' ]] || exit 9
FAKE
cat >"$cleanup_fake_bin/find" <<'FAKE'
#!/bin/bash
[[ $* == '/var/lib/systemd/coredump -mindepth 1 -maxdepth 1 -type f -delete' ]] || exit 9
exec /usr/bin/find "$cleanup_root/core" -mindepth 1 -maxdepth 1 -type f -delete
FAKE
# Stands in for pkexec: logs the exact command, and only maps the four allowed binaries.
cat >"$cleanup_fake_bin/fake-priv" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >>"$cleanup_priv_log"
case $1 in
  /usr/bin/pacman | /usr/bin/paccache | /usr/bin/journalctl | /usr/bin/find) ;;
  *) exit 77 ;;
esac
command=$(dirname -- "${BASH_SOURCE[0]}")/$(basename -- "$1")
shift
exec "$command" "$@"
FAKE
chmod 700 "$cleanup_fake_bin"/*
export OMARCHY_TOOL_PRIV="$cleanup_fake_bin/fake-priv"

cleanup_config() { jq -c "$1" "$OMARCHY_TOOL_CONFIG_DIR/config.json"; }
cleanup_notes() { wc -l <"$cleanup_notify_log"; }

mkdir -p "$cleanup_root/cache/uv" "$cleanup_root/cache/uv2" "$cleanup_root/cache/con espacio" "$cleanup_root/cache/mi\"app"
printf x >"$cleanup_root/cache/uv/data"
printf x >"$cleanup_root/cache/uv2/data"
printf x >"$cleanup_root/cache/run-exe.log"

check "cleanup status is constant and always on" '"$tool" status | jq -e ".modules.cleanup.enabled == true and .modules.cleanup.applied == true" >/dev/null'
check "cleanup is listed and its list works" '"$tool" cleanup list | jq -e "[.categories[].id] == [\"cache\"]" >/dev/null'
check "cleanup has nothing that runs by itself" '! grep -Eq "^cleanup_(apply|startup)\b" "$repo/bin/modules/cleanup.sh"'
check "a cache mark survives another run" '"$tool" cleanup cache-mark "[\"uv\"]" on && [[ $("$tool" cleanup list | jq -c "[.categories[0].rows[].folders[]|select(.marked).name]") == "[\"uv\"]" ]]'
"$tool" cleanup cache-mark '["uv"]' on
check "a mark on a folder that is gone can be dropped" 'printf "{\"modules\":{\"cleanup\":{\"cacheMarked\":[\"uv\",\"gone\"]}}}\n" >"$OMARCHY_TOOL_CONFIG_DIR/config.json" && "$tool" cleanup cache-mark "[\"gone\"]" off && [[ $(cleanup_config ".modules.cleanup.cacheMarked") == "[\"uv\"]" ]]'
check "marking twice keeps one mark" '"$tool" cleanup cache-mark "[\"uv\"]" on && [[ $(cleanup_config ".modules.cleanup.cacheMarked") == "[\"uv\"]" ]]'
check "names with quotes and spaces survive the config" '"$tool" cleanup cache-mark "[\"con espacio\",\"mi\\\"app\"]" on && [[ $(cleanup_config ".modules.cleanup.cacheMarked|length") == 3 ]] && "$tool" cleanup cache-mark "[\"con espacio\",\"mi\\\"app\"]" off && [[ $(cleanup_config ".modules.cleanup.cacheMarked") == "[\"uv\"]" ]]'
cleanup_before=$(md5sum <"$OMARCHY_TOOL_CONFIG_DIR/config.json")
check "an invalid mark changes nothing and says why" '! "$tool" cleanup cache-mark "[\"../x\"]" on 2>"$cleanup_root/error" && grep -qF "carpeta de caché no válida" "$cleanup_root/error" && [[ $(md5sum <"$OMARCHY_TOOL_CONFIG_DIR/config.json") == "$cleanup_before" ]]'
check "an unknown mark state is refused" '! "$tool" cleanup cache-mark "[\"uv\"]" maybe 2>/dev/null && [[ $(md5sum <"$OMARCHY_TOOL_CONFIG_DIR/config.json") == "$cleanup_before" ]]'
check "an unmarked cache folder is refused" '! "$tool" cleanup clean cache "[\"uv2\"]" 2>/dev/null && [[ -f $cleanup_root/cache/uv2/data ]]'
check "a request with one unmarked folder removes nothing" '! "$tool" cleanup clean cache "[\"uv\",\"uv2\"]" 2>/dev/null && [[ -f $cleanup_root/cache/uv/data && -f $cleanup_root/cache/uv2/data ]]'
: >"$cleanup_notify_log"
check "a marked folder goes, loose files stay, one notification" '"$tool" cleanup clean cache "[\"uv\"]" && [[ ! -e $cleanup_root/cache/uv && -f $cleanup_root/cache/run-exe.log && $(cleanup_notes) == 1 ]] && grep -qF "Limpieza terminada" "$cleanup_notify_log"'
mkdir -p "$cleanup_root/proc/100/fd"
ln -s "$cleanup_root/cache/uv2/data" "$cleanup_root/proc/100/fd/0"
"$tool" cleanup cache-mark '["uv2"]' on
: >"$cleanup_notify_log"
check "a folder in use is skipped and named" '"$tool" cleanup clean cache "[\"uv2\"]" && [[ -f $cleanup_root/cache/uv2/data ]] && grep -qF "uv2" "$cleanup_notify_log" && [[ $(cleanup_notes) == 1 ]]'
rm -rf "$cleanup_root/proc/100"
check "an empty temp folder cleans fine" '"$tool" cleanup clean tmp'

# The lock: a long clean must not stall the page's list.
mkfifo "$cleanup_root/release"
flock "$XDG_RUNTIME_DIR/omarchy-tool.lock" bash -c 'touch "$1"; read -r _ <"$2"' _ "$cleanup_root/held" "$cleanup_root/release" &
cleanup_holder=$!
until [[ -e $cleanup_root/held ]]; do sleep 0.05; done
check "the list does not wait for the lock" 'timeout 5 "$tool" cleanup list >/dev/null'
check "cleaning waits for the lock" 'timeout 0.5 "$tool" cleanup clean tmp; [[ $? == 124 ]]'
check "marking waits for the lock" 'timeout 0.5 "$tool" cleanup cache-mark "[\"uv2\"]" on; [[ $? == 124 ]]'
printf '\n' >"$cleanup_root/release"
wait "$cleanup_holder"

# Password actions: exact commands, nothing from the page, one notification.
cleanup_package="$cleanup_root/pkg/a-1-x86_64.pkg.tar.zst"
mkdir -p "$cleanup_root/pkg"
printf x >"$cleanup_package"
printf '%s\n' "$cleanup_package" >"$cleanup_packages"
: >"$cleanup_priv_log"
: >"$cleanup_notify_log"
check "pacman cache uses the fixed command" '"$tool" cleanup clean paccache && [[ $(<"$cleanup_priv_log") == "/usr/bin/paccache -rk3" && ! -e $cleanup_package && $(cleanup_notes) == 1 ]]'
: >"$cleanup_priv_log"
mkdir -p "$cleanup_root/journal/machine"
head -c 53000000 /dev/urandom >"$cleanup_root/journal/machine/system.journal"
check "the journal uses the fixed command" '"$tool" cleanup clean journal && [[ $(<"$cleanup_priv_log") == "/usr/bin/journalctl --rotate --vacuum-size=50M" ]]'
rm -rf "$cleanup_root/journal/machine"
printf x >"$cleanup_root/core/core.1"
: >"$cleanup_priv_log"
: >"$cleanup_notify_log"
check "refusing the password changes nothing and notifies once" '! OMARCHY_TOOL_PRIV=false "$tool" cleanup clean coredumps 2>/dev/null && [[ -f $cleanup_root/core/core.1 && $(cleanup_notes) == 1 ]]'
: >"$cleanup_notify_log"
check "coredumps use the fixed command" '"$tool" cleanup clean coredumps && [[ $(<"$cleanup_priv_log") == "/usr/bin/find /var/lib/systemd/coredump -mindepth 1 -maxdepth 1 -type f -delete" && ! -e $cleanup_root/core/core.1 && $(cleanup_notes) == 1 ]]'

printf 'orphan-app\n' >"$cleanup_orphans"
printf 'orphan-app\nunused-lib\n' >"$cleanup_transaction"
cleanup_revision=$("$tool" cleanup list | jq -r '.categories[]|select(.id=="orphans").revision')
: >"$cleanup_priv_log"
check "orphans need the revision that was shown" '! "$tool" cleanup clean orphans 2>/dev/null && [[ ! -s $cleanup_priv_log ]]'
check "a changed removal is refused before asking" 'printf "orphan-app\nunused-lib\nother\n" >"$cleanup_transaction"; ! "$tool" cleanup clean orphans "$cleanup_revision" 2>"$cleanup_root/error" && [[ ! -s $cleanup_priv_log ]] && grep -qF "cambiaron" "$cleanup_root/error"; cleanup_status=$?; printf "orphan-app\nunused-lib\n" >"$cleanup_transaction"; (exit $cleanup_status)'
check "an invalid current orphan is refused before asking" 'printf -- "--root\n" >"$cleanup_orphans"; ! "$tool" cleanup clean orphans "$cleanup_revision" 2>/dev/null && [[ ! -s $cleanup_priv_log ]]; cleanup_status=$?; printf "orphan-app\n" >"$cleanup_orphans"; (exit $cleanup_status)'
: >"$cleanup_notify_log"
check "a failed removal reports once" '! CLEANUP_TEST_REMOVAL_FAILS=1 "$tool" cleanup clean orphans "$cleanup_revision" 2>/dev/null && [[ $(cleanup_notes) == 1 ]]'
: >"$cleanup_priv_log"
: >"$cleanup_notify_log"
check "orphans are removed by the names pacman gives now" '"$tool" cleanup clean orphans "$cleanup_revision" && [[ $(<"$cleanup_priv_log") == "/usr/bin/pacman -Rns --noconfirm orphan-app" && $(cleanup_notes) == 1 ]]'
: >"$cleanup_priv_log"
check "no orphans left means no removal" '! "$tool" cleanup clean orphans "$cleanup_revision" 2>/dev/null; [[ ! -s $cleanup_priv_log ]]'
: >"$cleanup_priv_log"
check "an unknown category is refused" '! "$tool" cleanup clean nope 2>/dev/null && [[ ! -s $cleanup_priv_log ]]'
check "a page can't pass a package name" 'printf "orphan-app\n" >"$cleanup_orphans"; printf "orphan-app\n" >"$cleanup_transaction"; ! "$tool" cleanup clean orphans "evil-package" 2>/dev/null && [[ ! -s $cleanup_priv_log ]]'

export PATH=$cleanup_saved_path OMARCHY_TOOL_PRIV=$cleanup_saved_priv
"$tool" cleanup cache-mark '["uv2"]' on
check "uninstalling removes the marks and leaves the caches" 'bash "$repo/bin/uninstall.sh" "$work/missing-plugin"; [[ ! -e $OMARCHY_TOOL_CONFIG_DIR/config.json && -f $cleanup_root/cache/uv2/data ]]'
unset OMARCHY_TOOL_CLEANUP_TEMP_DIR OMARCHY_TOOL_CLEANUP_CACHE_DIR OMARCHY_TOOL_CLEANUP_PROC_DIR OMARCHY_TOOL_CLEANUP_COREDUMP_DIR OMARCHY_TOOL_CLEANUP_JOURNAL_DIR OMARCHY_TOOL_CLEANUP_RUNTIME_JOURNAL_DIR
