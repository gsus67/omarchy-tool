# Omarchy Tool

**English** · [Español](README.es.md)

A plugin for [Omarchy](https://omarchy.org/) with system utilities you turn on
and off with a switch. It adds a bar icon that opens a panel with one module per
feature. The panel uses Omarchy's theme components and colors, so it changes
with your theme.

Switches show work in progress and notify when a change starts, finishes or
fails. Disk tiles distinguishes installed files from a loaded view: if Files
was already running, it asks you to close and reopen it. Automatic startup
sync does not generate notifications.

![Omarchy Tool panel](preview.png)

The panel, its modules, states and notifications follow the system language
(`LC_ALL`, `LC_MESSAGES`, `LANG`). English and Spanish are included; other
languages fall back to English. Disk and device names are kept as they are. The
helpers inside Windows follow the Windows UI language; their file names and
paths stay the same so existing shortcuts keep working.

## Requirements

- Omarchy with the Quickshell shell plugin system (`omarchy plugin`).
- `jq`, `socat`, `acl` (`setfacl`), `polkit` (`pkexec`) and `udev`, all part of
  a standard Omarchy install. The **.exe icons** module installs `icoutils`
  if it is missing; its cache cleanup uses the system's `python3`.
- **Open .exe with Proton** needs the `multilib` repository enabled. It installs
  `umu-launcher` if missing and uses `xdg-mime`, `notify-send` and the systemd
  user session. It never edits `pacman.conf`.
- The **Windows** modules need Omarchy's Windows VM (`omarchy-windows-vm`,
  based on the `dockurr/windows` image under Docker), already installed from
  the Omarchy menu.
- Actions that change files owned by root ask for your password through
  `pkexec` every time.

## Install, update and remove

```bash
omarchy plugin add https://github.com/gsus67/omarchy-tool.git --enable
omarchy plugin update io.github.gsus67.omarchy-tool
omarchy plugin remove io.github.gsus67.omarchy-tool
```

The plugin keeps itself up to date: it checks GitHub at startup and every 6
hours, and when there is a new version it runs `omarchy plugin update
io.github.gsus67.omarchy-tool` and shows a notification. `omarchy-tool self-update` does the same
on demand.

Your settings are stored in `~/.config/omarchy-tool/config.json`, outside the
plugin, so updates never erase them.

The plugin adds an **Omarchy Tool** entry to the Omarchy menu (if you have
`~/.config/omarchy/extensions/omarchy-menu.jsonc`).

## Leaves no trace

- **Turning a feature off** removes everything that feature wrote to the
  system. Only your choice is remembered (for example, which disks you ticked).
  Proton always keeps your Wine prefix, including installed programs and saves,
  and every copy made with **Proton saves**.
- **Removing the plugin** puts the system back as it was: it removes the disks
  from the Windows configuration (asks for your password), and deletes the
  plugin settings and the menu entry. Since `omarchy plugin remove` does not run
  plugin code, the cleanup is done by a copy of `bin/uninstall.sh` kept outside
  the plugin, which the panel launches when it is unloaded.
- `omarchy-tool uninstall` runs the same cleanup by hand (see
  [Command line](#command-line)).

Files the plugin may write outside its folder, removed by the cleanup except
for the Wine prefix, your Proton copies, diagnostic logs and umu-managed
runtimes/caches:

- `~/.config/omarchy-tool/` (settings) and `~/.local/share/omarchy-tool/`
  (state and the uninstaller copy)
- An entry in `~/.config/omarchy/extensions/omarchy-menu.jsonc`, plus the
  per-adapter IP and DNS entries while **Network per adapter** is on
- `~/.config/hypr/omarchy-tool.lua` and one guarded line in `hyprland.lua`
  (the **SUPER + ALT + U** shortcut)
- The `/shared2`, `/shared3` and `/dev/bus/usb` lines in
  `/var/lib/omarchy/windows/docker-compose.yml`
- `/etc/udev/rules.d/70-omarchy-tool-webhid.rules`
- `/usr/local/bin/omarchy-tool-exe-thumbnailer` and
  `~/.local/share/thumbnailers/omarchy-tool-exe.thumbnailer`
- `~/.local/share/applications/omarchy-tool-run-exe.desktop` and Windows MIME
  defaults in user `mimeapps.list` files (previous defaults are restored)
- A GE-Proton version in umu's compatibility directories, removed only if this
  module downloaded it; pre-existing versions are kept
- `~/.local/share/umu/default/` (Wine prefix, **always kept**) and
  `~/.cache/run-exe.log`, `~/.cache/omarchy-tool-proton-prepare.log` (logs, kept)
- The helpers in the `Omarchy Tool` folder inside the Windows `Shared` folder
  (if drive letters are still set in Windows, **Quitar discos** stays so you
  can remove them, and deletes itself when run)

## Modules

### Disk tiles (Extras)

A switch to open Files on **This PC**, with disk cards, usage bars and free/total
space. Opening a drive navigates normally in Nautilus; explicit folder launches
keep their destination.

Requires Nautilus 50/51, `nautilus-python`, GTK4 and libadwaita. After enabling,
close Files windows and open Files again. No password, package installation or
interruption of file operations. Disable/uninstall removes the extension and
the added bookmark, preserving existing bookmarks and user edits. The view uses
internal Nautilus structures; see [Disk tiles](docs/DISK_TILES.md) for compatibility,
footprint and tests.

### Disks in Windows

Shares disks with Omarchy's Windows VM the same way Omarchy shares `~/Windows`:
as network folders on `\\host.lan` (`Data2` and `Data3`, next to Omarchy's
`Data`). Tick disks mounted under `/mnt`, `/media` or `/run/media`, or add a
folder by its path (`/home` works too).

**Up to 2 disks at a time**, because the Windows image only serves two extra
folders (`Data2` and `Data3`). To use another one, untick one first.

**Drive letters:** Omarchy gives its Shared folder `Z:` once, when Windows is
installed. For your disks you pick the letter in the panel (`X:` and `Y:` by
default) and the plugin puts an **Activar discos** file in Shared › **Omarchy
Tool › Discos**. It does what Omarchy did (`net use X: \\host.lan\Data2
/persistent:yes` and a desktop shortcut) and also names each drive after the
disk in *This PC* (for example "Data (X:)"). Run it once inside Windows; if you
change letters or disks, run it again. **Quitar discos** undoes it and, if the
plugin is off or removed, deletes itself.

How it works: the `dockurr/windows` image used by Omarchy serves `/shared2` and
`/shared3` when they exist. The plugin adds those two lines to the VM
configuration (`/var/lib/omarchy/windows/docker-compose.yml`, owned by root)
with `bin/compose-edit.sh` through `pkexec`, so every change asks for your
password and takes effect the next time Windows starts. That script only
touches those lines and validates the paths. If you reinstall Windows from
Omarchy, the plugin adds them again.

Because they are network folders, a few very strict installers may refuse to
install onto them.

### Devices in Windows

Passes USB devices to Omarchy's Windows VM so you can use apps that only exist
on Windows (for example **Glorious CORE** for a Glorious Model O 2 mouse).
Windows sees them as if they were plugged into it; **while a device is in
Windows, Linux does not have it** (a USB device can only be in one system at a
time). Up to 4 devices.

- **The feature switch** prepares Windows: the VM gets access to USB
  (`/dev/bus/usb` under `devices`, as documented by `dockurr/windows`), written
  by the same `bin/compose-edit.sh` as the disks, through `pkexec`. It takes
  effect the next time you open Windows.
- **Each device switch** means "in Windows": with Windows open it moves right
  away, otherwise as soon as you open it (the panel watches for it with
  `bin/usb-watch.sh`). Off, it comes back to Linux right away. It uses the VM's
  QEMU monitor (`bin/usb-live.sh`, with `pkexec`).
- **Without a mouse:** **SUPER + ALT + U** returns everything to Linux and
  turns those switches off, even while the Windows window has the keyboard (a
  `dont_inhibit` binding in `~/.config/hypr/omarchy-tool.lua`, loaded by
  `hyprland.lua` with a guarded line). Inside Windows, **Shared › Omarchy Tool ›
  Periféricos › Devolver periféricos a Linux** does the same. When you pass
  something to Windows, a notification reminds you of both ways.

About the cursor: Omarchy shows Windows as a **remote session**; a mouse passed
over USB moves the cursor of the VM's "physical" screen, not the one in that
session. To see it, close the Windows window and use **Open Windows with my
mouse**: it starts Windows without the remote window (`omarchy-windows-vm launch
--keep-alive` with an empty `xfreerdp3` first in `PATH`) and opens its own
screen (the `dockurr/windows` noVNC at `127.0.0.1:8006`) as a web app; sign in
with your Windows password and the passed mouse cursor shows up. When you are
done: **SUPER + ALT + U** and **Shut down Windows**.

### Devices in the browser

Lets the browser talk to the USB devices you tick (WebHID), for web
configurators such as **CORSAIR Web Hub**. Without it, Chromium sees the device
but nothing happens when you click connect, because on Linux only root can use
those devices.

The plugin writes a rule to `/etc/udev/rules.d/70-omarchy-tool-webhid.rules`
(with `bin/udev-webhid.sh` through `pkexec`, so it asks for your password) that
grants access only to your logged-in session. When you untick a device, turn
the feature off or remove the plugin, the rule is deleted and the access already
granted is revoked immediately.

Note: with access, any program in your session can talk to that device (for a
keyboard, that includes reading what you type). Tick only what you are going to
configure, and untick it afterwards if you like.

### Extras

**Omarchy › Extras** opens a page with a name and switch for each sub-module,
using the same rows as the main list. Click a name to open its page; its back
arrow returns to Extras, and Extras' back arrow returns to the main list.
Extras itself has no switch. Module ids and saved settings stay the same.

### .exe icons

Under **Omarchy › Extras**, makes Files (Nautilus) show each Windows program's own icon.
Enabling installs `icoutils` if missing and copies the versioned
`bin/exe-thumbnailer` to `/usr/local/bin/omarchy-tool-exe-thumbnailer`, owned
by root with mode 0755. Nautilus runs thumbnailers inside a bubblewrap sandbox
that only sees system directories, so a script under your home cannot run.
The user registration at `~/.local/share/thumbnailers/omarchy-tool-exe.thumbnailer`
handles EXE, MSI and DLL executable MIME types. Only failed GNOME thumbnail
cache entries whose `Thumb::URI` ends in `.exe`, `.msi` or `.dll` (ignoring
case) are cleared so Files retries; other thumbnails stay in place.

`bin/exe-icons.sh` performs installation in one `pkexec` prompt, and removal in
one prompt. Reapplying an identical root-owned system copy asks for no password;
the user registration can be repaired without a prompt. The original manual
`/usr/local/bin/exe-thumbnailer` and `~/.local/share/thumbnailers/exe.thumbnailer`
are adopted only when both match the original files exactly: both are removed
in the same privileged run before registering the replacement.
Turning the module off or uninstalling removes its files and state, and removes
`icoutils` only if this module installed it. A pre-existing package is kept.

### Open .exe with Proton

Under **Omarchy › Extras**, double-click Windows programs (`.exe`/`.msi`) to run
with GE-Proton through `umu-run`. Enabling installs `umu-launcher` with
`pacman -S --needed --noconfirm umu-launcher` in one `pkexec` prompt only when
missing. If `multilib` is disabled, it reports an error without changing
`pacman.conf`. A pre-existing package is never removed.

The versioned `bin/run-exe.sh` is installed as a user-owned executable at
`~/.local/share/omarchy-tool/exe-proton/run-exe`; it never runs as root. A hidden
`omarchy-tool-run-exe.desktop` handler becomes the default for the five Windows
executable/installer MIME types. The module saves the previous default for each
one once, restores them on disable/uninstall, and unsets ones previously empty.
An exact original `~/.local/bin/run-exe` (SHA-256 match) paired with
`~/.local/share/applications/run-exe.desktop` whose Exec points to it is adopted:
both manual files are removed, leaving one handler. A deleted manual handler
is not restored on disable; modified manual setups are kept.

Preparation runs in a detached systemd user unit, so the panel never waits for
the download or prefix initialization. It notifies “Preparing GE-Proton…” and
then “Ready: you can now double-click .exe files”, or reports a failure.
It uses umu's own `PROTONPATH=GE-Proton umu-run wineboot -u`, and skips this when
GE-Proton already exists in `~/.local/share/umu/compatibilitytools` or
`~/.local/share/Steam/compatibilitytools.d`. Only versions downloaded by this
module are recorded for removal; stopping the module stops background preparation
first. umu's runtime/cache files remain managed by umu.

The runner uses `msiexec /i` for MSI, sends start/failure notifications and logs
to `~/.cache/run-exe.log`; preparation logs to
`~/.cache/omarchy-tool-proton-prepare.log`. Its default prefix is
`~/.local/share/umu/default` (`GAMEID=umu-default`), matching the manual setup.
The runner respects `WINEPREFIX`, `GAMEID` and `PROTONPATH` overrides.
**Disabling or uninstalling never deletes this prefix or its games/saves.**
If you want to erase them, delete `~/.local/share/umu/default` yourself.
XDG data/cache locations and umu's `UMU_FOLDERS_PATH` are respected.

### Proton saves

An entry of its own under **Omarchy › Extras**, with no switch. It copies what
Windows programs keep in the Proton prefix to one archive and restores it later.
It works with **Open .exe with Proton** off, as long as the prefix exists.

- **What is copied:** `Documents`, `Saved Games` and `AppData/{Local,LocalLow,Roaming}`
  under `drive_c/users/steamuser`, leaving out `AppData/Local/{dxvk,Temp,Microsoft,Programs,openvr}`
  and `AppData/Roaming/Microsoft`. Links are never followed. Games opened from
  Steam use their own prefix and are not included.
- **See it first:** the page lists what **Save** will include. **View** lists what
  a copy contains, and only then offers **Load**.
- **Loading** overwrites what the copy holds and leaves everything else, so a slot
  created after the copy stays. It first makes an `antes-de-cargar-…` copy, and
  won't load if that fails. A copy with unsafe paths, links or damage is refused
  whole before anything changes.
- **With Proton open** (a `wineserver` running), saving and loading are refused.
- **Where:** `<folder>/Partidas Proton/`, with `~/Documents` as the default folder.
  A chosen folder must exist and be outside the prefix. If its `Partidas Proton`
  subfolder later goes missing, or its disk is listed in `/etc/fstab` and isn't
  mounted, the copy fails instead of writing to the system disk. A folder that
  uninstalling would delete is refused. Copies are private (`0700`/`0600`);
  disks without Unix permissions, like NTFS, can't enforce that, and a disk shared
  with the Windows VM exposes them there. `AppData` can hold programs' sessions.
- **Automatic copy at startup:** off until you turn it on. It runs once when the
  Omarchy shell starts, from the plugin's existing startup step: no service, timer
  or background process. It makes `automatica-…` only if something changed, skips
  while Proton is open and notifies if the disk is missing. The 5 newest automatic
  copies are kept; manual and `antes-de-cargar` copies are never deleted.
  **The last session has no copy until the next startup, so use Save before
  reinstalling.**

Disabling or uninstalling never touches a copy.

### Cleanup

An entry of its own under **Omarchy › Extras**, with no switch: nothing stays on
and nothing runs in the background. Sizes are worked out when you open the page,
as real disk use. A row with nothing to clean, or whose tool is missing, isn't
shown. Every **Clean** first says what will go and how much, and asks to confirm.
A notification reports what was freed and what was skipped.

| Row | What goes | What protects you |
|---|---|---|
| Temp files (in RAM) | Your own entries in `/tmp` | Only with nothing open inside and no change in 24 hours |
| Program caches | The `~/.cache` folders you marked | A folder a program is using is skipped and named |
| Pacman packages | `paccache -rk3` | Keeps 3 versions of each package; asks for your password |
| Orphan packages | `pacman -Rns` of the current orphans | Lists everything that goes first, dependencies included; asks for your password |
| Crash dumps | Files in `/var/lib/systemd/coredump` | Warns that the diagnosis is lost; asks for your password |
| Journal | `journalctl --rotate --vacuum-size=50M` | Trims to 50 MB, whole files, oldest first; asks for your password |

**Choose** opens the caches with one switch per program of 100 MB or more, and
**Others** for the smaller ones, each with what deleting it costs. Marks are
remembered in your settings, and a new folder starts unmarked. The outer **Clean**
removes what is marked, and isn't available with nothing marked. Loose files in
`~/.cache`, like the Proton logs, stay.

"In use" means open, running or as the working directory of one of your processes,
and what can't be checked counts as in use. Other users' processes and protected
ones of your own can't be checked, which is one reason for the 24 hours. Links are
never followed. Nothing of the plugin runs as root: the password only authorizes
those system commands with fixed arguments, and package names come from `pacman`
at that moment, never from the page. Cleaning can't stop files coming back: if a
program keeps leaving files in `/tmp`, that is for that program to fix.

### Network per adapter

Under **Omarchy › Extras**, lets you pick the adapter (Ethernet or Wi-Fi) when
changing its IP or DNS from the Omarchy menu:

- **Setup › Network › IP** › *adapter*: **DHCP** gets the address and gateway
  from the router again; **Custom** opens a floating terminal that asks for the
  address with its prefix (`192.168.1.20/24`) and the gateway, Enter keeping
  the current value shown in brackets.
- **Setup › Network › DNS** › *adapter*: **DHCP**, **Cloudflare**, **Google** or
  **Custom** (servers separated by spaces, IPv4 or IPv6) for that adapter only.
  Omarchy's own four choices stay above them and still apply to every adapter.

There is one entry per wired or Wi-Fi adapter, shown only while it is
connected: settings belong to the connection active on it (for Wi-Fi, the
network you are on). A ✓ marks the current choice. Input is checked first
(valid IPv4, prefix 1–32, gateway in the same subnet, no network or broadcast
address, valid DNS servers); on any error nothing changes.

Changes go through `nmcli` as the session user: NetworkManager already lets a
local session change connections, so there is no password prompt and nothing
to install. Errors from the menu show as a notification.

Omarchy's DNS choice for every adapter (Cloudflare, Google or Custom) is a
NetworkManager global setting that overrides each adapter's own, so DNS per
adapter is refused with a message until Omarchy's DNS is back on **DHCP**.

A static address gets no DNS from the router. If the adapter has no DNS of its
own, **Custom** IP keeps the servers in use at that moment, and **DHCP** removes
exactly those later, unless they were changed in between. With a static IP,
**DHCP** DNS is refused, since the router would give none.

The module page lists each adapter with its IP and DNS and, with a static IP,
a **Back to DHCP** button. Turning the module off or uninstalling removes the
menu entries and the helper copy in `~/.local/share/omarchy-tool/`; the
network keeps whatever was last chosen.

### Plugins

Turns your installed Omarchy plugins on and off from the panel, with one switch
each. The list comes from `omarchy plugin list`, so plugins you add later show
up by themselves; built-in plugins and Omarchy Tool itself are left out. It
uses Omarchy's own `omarchy plugin enable|disable`: no password, and nothing is
written outside the plugin's settings. When a bar icon is turned off its place
(section and position) is remembered, and it goes back there when turned on.
It changes nothing by itself, so it has no switch of its own in the panel list.
A full bar plugin is listed without a switch: Omarchy can't turn a bar off,
only swap it with `omarchy bar use`.

## Command line

The panel only calls `bin/omarchy-tool`, which you can also use by hand. It is
not on your `PATH`; add an alias first:

```bash
alias omarchy-tool=~/.config/omarchy/plugins/io.github.gsus67.omarchy-tool/bin/omarchy-tool
omarchy-tool status                          # state of every module (JSON)
omarchy-tool uninstall                       # remove every trace outside the plugin
omarchy-tool self-update                     # update now if there is a new version
omarchy-tool windows-disks enable|disable
omarchy-tool windows-disks add /mnt/data [Name]
omarchy-tool windows-disks remove /mnt/data
omarchy-tool windows-disks letter /mnt/data X    # or "next"
omarchy-tool web-devices enable|disable
omarchy-tool web-devices add 1b1c:2b0d            # vendor:product (lsusb)
omarchy-tool web-devices remove 1b1c:2b0d
omarchy-tool exe-icons enable|disable
omarchy-tool exe-proton enable|disable
omarchy-tool exe-proton saves-list                # JSON: what a copy would hold, and the copies
omarchy-tool exe-proton saves-preview NAME        # JSON: what a copy contains
omarchy-tool exe-proton saves-save
omarchy-tool exe-proton saves-load NAME
omarchy-tool exe-proton saves-folder /mnt/datos   # "" goes back to the default
omarchy-tool exe-proton saves-auto on|off
omarchy-tool cleanup list                         # JSON: what can be cleaned
omarchy-tool cleanup cache-mark '["uv"]' on|off
omarchy-tool cleanup clean tmp|paccache|coredumps|journal
omarchy-tool cleanup clean cache '["uv"]'         # only folders already marked
omarchy-tool cleanup clean orphans REVISION       # the revision from cleanup list
omarchy-tool network-ip enable|disable
omarchy-tool network-ip dhcp enp6s0              # adapter back to DHCP
omarchy-tool usb-windows enable|disable
omarchy-tool usb-windows add 093a:822a            # vendor:product (lsusb)
omarchy-tool usb-windows remove 093a:822a
omarchy-tool usb-windows move linux|windows 093a:822a  # with Windows open
omarchy-tool usb-windows move linux --all            # same as SUPER+ALT+U
omarchy-tool plugins on|off io.github.gsus67.omarchy-taskbar
```

## Adding a module

1. `bin/modules/<name>.sh` with `<name>_<action>` functions. It must have
   `<name>_enable`, `<name>_disable`, `<name>_status` (JSON with `enabled`) and
   `<name>_apply`. When disabled, `apply` must delete everything the module
   wrote; if it touches anything outside its folder, add its cleanup to
   `bin/uninstall.sh`.
2. `modules/<Name>.qml`: the module page. It receives `status` and calls
   `tool.run([...])`.
3. Add it to the `modules` list in `ToolPanel.qml`, with its `group`, next to
   the others in its group. The panel shows it under the group title, with its
   name and its switch. For an Extras sub-module, use `parent: "extras"`
   instead of `group`; both levels reuse the same row component.

## Tests

```bash
bash tests/run.sh
bash tests/i18n.sh
omarchy plugin validate .
```

## License

[MIT](LICENSE)
