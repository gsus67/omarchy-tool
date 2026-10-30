"""A reversible, read-only Computer view for Nautilus 50/51.

Nautilus has no public custom-view API. Like nautilus-my-computer (MIT,
Yann Masoch), attach a sibling to each settled slot's Gtk.Stack, never
reparent Nautilus's widgets. See docs/DISK_TILES.md for that compatibility
boundary. No native-code injection, shell commands, mounting or disk writes.
"""
import os
import hashlib
import json
import tempfile
from pathlib import Path
from xml.etree import ElementTree

import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
gi.require_version("Nautilus", "4.1")
from gi.repository import Adw, Gdk, Gio, GLib, GObject, Gtk, Nautilus, Pango

STATE_DIRECTORY = None  # Replaced with a quoted absolute path by manage.py.
COMPUTER = "computer:///"
LOCAL_TYPES = {"ext2", "ext3", "ext4", "btrfs", "xfs", "f2fs", "bcachefs",
               "ntfs", "ntfs3", "exfat", "vfat", "zfs", "fuseblk", "iso9660", "udf"}


def text(english, spanish):
    locale = os.environ.get("LC_ALL") or os.environ.get("LC_MESSAGES") or os.environ.get("LANG", "en")
    return spanish if locale.lower().startswith("es") else english


def unescape(value):
    # mountinfo escapes backslash last: a literal '\\040' must stay literal.
    for old, new in (("\\040", " "), ("\\011", "\t"), ("\\012", "\n"), ("\\134", "\\")):
        value = value.replace(old, new)
    return value


def local_mounts(contents):
    """One row per filesystem, including root, excluding virtual/boot mounts."""
    rows, seen = [], set()
    for line in contents.splitlines():
        fields = line.split()
        try:
            separator = fields.index("-")
            filesystem, device, path = fields[separator + 1], fields[2], unescape(fields[4])
        except (ValueError, IndexError):
            continue
        if (filesystem not in LOCAL_TYPES and not (path == "/" and filesystem == "overlay")) or device in seen:
            continue
        if path == "/boot" or path.startswith("/boot/"):
            continue
        seen.add(device)
        rows.append((path, text("System", "Sistema") if path == "/" else Path(path).name))
    return rows


def widgets(widget):
    yield widget
    child = widget.get_first_child()
    while child:
        following = child.get_next_sibling()
        yield from widgets(child)
        child = following


def supported_runtime():
    # Read the running binary's embedded metadata, not the possibly upgraded
    # package on disk, and never start a second Nautilus from its own main loop.
    try:
        data = Gio.resources_lookup_data("/org/gnome/nautilus/appdata", Gio.ResourceLookupFlags.NONE)
        release = ElementTree.fromstring(data.get_data()).find("releases/release")
        return int(release.get("version").split(".")[0]) in (50, 51)
    except (GLib.Error, ValueError, AttributeError, ElementTree.ParseError):
        return False


class DiskTilesExtension(GObject.GObject, Nautilus.MenuProvider):
    def __init__(self):
        super().__init__()
        self.active = False
        self.compatible = supported_runtime()
        self.windows = {}
        self.slots = {}
        self.handlers = []
        self.sources = set()
        self.queries = set()
        self.refresh_source = 0
        self.style = None
        self.monitor = Gio.VolumeMonitor.get()
        self.state = Path(STATE_DIRECTORY) if STATE_DIRECTORY else None
        self.source_hash = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        self.loaded_marker = self.state / ("loaded-" + str(os.getpid()) + ".json") if self.state else None
        # Watching the installed directory allows on/off/on in the same process.
        # No polling, daemon, retained settings or persistent cache is needed.
        self.file_monitor = Gio.File.new_for_path(str(Path(__file__).parent)).monitor_directory(
            Gio.FileMonitorFlags.NONE, None)
        self.file_monitor.connect("changed", self.changed)
        self.changed()

    def later(self, milliseconds, callback):
        identity = [0]
        def run():
            self.sources.discard(identity[0])
            if self.active: callback()
            return GLib.SOURCE_REMOVE
        identity[0] = GLib.timeout_add(milliseconds, run, priority=GLib.PRIORITY_LOW)
        self.sources.add(identity[0])
        return identity[0]

    def connect(self, obj, signal, callback, bucket=None):
        identity = obj.connect(signal, callback)
        (self.handlers if bucket is None else bucket).append((obj, identity))

    @staticmethod
    def disconnect(bucket):
        for obj, identity in bucket:
            if GObject.signal_handler_is_connected(obj, identity): obj.disconnect(identity)
        bucket.clear()

    def changed(self, *_args):
        enabled = self.compatible and self.state is not None and (self.state / "enabled").is_file() and Path(__file__).is_file()
        if enabled and not self.active:
            self.active = True
            self.start()
        elif not enabled and self.active:
            self.stop()

    def start(self, attempt=0):
        app = Gtk.Application.get_default()
        if app is None:
            if attempt < 50: self.later(40, lambda: self.start(attempt + 1))
            return
        self.style = Gtk.CssProvider()
        self.style.load_from_string(
            "levelbar.omarchy-tool-capacity block.filled { background-color: @accent_bg_color; }"
            "levelbar.omarchy-tool-capacity.critical block.filled { background-color: @error_bg_color; }")
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), self.style,
                                                 Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        self.connect(app, "window-added", lambda _app, win: self.window(win))
        self.connect(app, "shutdown", lambda *_args: self.forget_ready())
        for signal in ("mount-added", "mount-removed", "mount-changed", "volume-added", "volume-removed"):
            self.connect(self.monitor, signal, lambda *_args: self.refresh())
        for win in app.get_windows(): self.window(win)

    def window(self, win, attempt=0):
        # Never modify GTK file pickers, dialogs, desktop windows or other apps.
        if GObject.type_name(type(win)) != "NautilusWindow" or win in self.windows:
            return
        tabs = next((w for w in widgets(win) if isinstance(w, Adw.TabView)), None)
        if tabs is None:
            if attempt < 100: self.later(20, lambda: self.window(win, attempt + 1))
            return
        bucket = self.windows[win] = []
        first = [True]
        def attach(page):
            initial = first[0]
            first[0] = False
            self.slot(win, page.get_child(), initial=initial)
        self.connect(tabs, "page-attached", lambda _tabs, page, _i: attach(page), bucket)
        self.connect(tabs, "page-detached", lambda _tabs, page, _i: self.drop_slot(page.get_child())
                     if page.get_child() in self.slots else None, bucket)
        self.connect(win, "destroy", lambda *_args: self.drop_window(win), bucket)
        for index in range(tabs.get_n_pages()):
            attach(tabs.get_nth_page(index))

    def slot(self, win, slot, initial=False, attempt=0):
        if slot in self.slots or not self.active or win not in self.windows:
            return
        if GObject.type_name(type(slot)) != "NautilusWindowSlot": return
        location = slot.get_property("location")
        if location is None or slot.get_property("allow-stop"):
            if attempt < 100: self.later(20, lambda: self.slot(win, slot, initial, attempt + 1))
            return  # Unsupported or stalled native loads remain untouched.
        stack = next((w for w in widgets(slot) if isinstance(w, Gtk.Stack)), None)
        if stack is None or stack.get_child_by_name("mc-computer") is not None: return
        panel = Gtk.ScrolledWindow(hexpand=True, vexpand=True)
        column = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=20,
                         margin_top=24, margin_bottom=24, margin_start=24, margin_end=24)
        title = Gtk.Label(label=text("This PC", "Este equipo"), xalign=0)
        title.add_css_class("title-1")
        column.append(title)
        subtitle = Gtk.Label(label=text("Devices and drives", "Dispositivos y unidades"), xalign=0)
        subtitle.add_css_class("heading")
        column.append(subtitle)
        flow = Gtk.FlowBox(selection_mode=Gtk.SelectionMode.NONE, homogeneous=True,
                           column_spacing=16, row_spacing=16, min_children_per_line=1, max_children_per_line=4)
        column.append(flow)
        panel.set_child(column)
        stack.add_named(panel, "omarchy-tool-disk-tiles")
        state = self.slots[slot] = {"window": win, "stack": stack, "panel": panel,
                                   "flow": flow, "native": stack.get_visible_child(), "handlers": [], "cards": {}}
        self.connect(slot, "notify::location", lambda *_args: self.navigation(slot), state["handlers"])
        self.connect(stack, "notify::visible-child", lambda *_args: self.navigation(slot), state["handlers"])
        self.connect(panel, "map", lambda *_args: self.refresh(), state["handlers"])
        self.connect(panel, "unmap", lambda *_args: self.schedule_refresh(), state["handlers"])
        # Only default new windows (Home) go to This PC. Explicit other folders,
        # additional tabs, open/save dialogs and existing navigation are preserved.
        if initial and location.equal(Gio.File.new_for_path(str(Path.home()))):
            self.start_location(slot)
        self.navigation(slot)
        self.mark_ready()

    def mark_ready(self):
        if self.loaded_marker is None or not self.active or not (self.state / "enabled").is_file(): return
        temporary = None
        try:
            start = Path("/proc/self/stat").read_text().rsplit(")", 1)[1].split()[19]
            descriptor, temporary = tempfile.mkstemp(prefix=".loaded-", dir=self.state)
            with os.fdopen(descriptor, "w") as output:
                json.dump({"pid": os.getpid(), "start": start, "hash": self.source_hash}, output)
            os.replace(temporary, self.loaded_marker)
        except (OSError, IndexError): pass  # Disabling can remove the directory concurrently.
        finally:
            if temporary is not None: Path(temporary).unlink(missing_ok=True)

    def forget_ready(self):
        if self.loaded_marker is not None: self.loaded_marker.unlink(missing_ok=True)

    def action(self, slot, name, parameter=None):
        if slot.activate_action("slot." + name, parameter): return True
        state = self.slots.get(slot)
        # Modern Nautilus exports the active slot action group on the window.
        # Never let a background tab accidentally navigate the selected tab.
        if state is not None and slot.get_property("active"):
            return state["window"].activate_action("slot." + name, parameter)
        return False

    def start_location(self, slot, attempt=0):
        if slot not in self.slots: return
        location = slot.get_property("location")
        if location is None or not location.equal(Gio.File.new_for_path(str(Path.home()))): return
        self.action(slot, "open-location", GLib.Variant("s", COMPUTER))
        if attempt < 25: self.later(60, lambda: self.start_location(slot, attempt + 1))

    def navigation(self, slot):
        state = self.slots.get(slot)
        if state is None: return
        location = slot.get_property("location")
        at_computer = self.active and location is not None and location.get_uri() == COMPUTER
        stack, panel = state["stack"], state["panel"]
        if at_computer and stack.get_visible_child() is not panel:
            state["native"] = stack.get_visible_child()
            stack.set_visible_child(panel)
            self.refresh()
        elif not at_computer and stack.get_visible_child() is panel:
            if state["native"] is not None: stack.set_visible_child(state["native"])

    def mounts(self):
        rows = {}
        try:
            for path, label in local_mounts(Path("/proc/self/mountinfo").read_text()):
                file = Gio.File.new_for_path(path)
                rows[file.get_uri()] = (label, Gio.ThemedIcon.new("drive-harddisk-symbolic"))
        except OSError: pass
        for mount in self.monitor.get_mounts():
            root = mount.get_root()
            path = root.get_path()
            # Keep real user volumes (incl. remote shares), not GVfs virtual roots.
            if root.get_uri().startswith(("computer:", "network:", "recent:", "trash:")): continue
            if path and (path == "/boot" or path.startswith(("/boot/", "/proc/", "/sys/", "/dev/"))): continue
            rows[root.get_uri()] = (mount.get_name(), mount.get_symbolic_icon())
        return rows

    def refresh(self):
        visible = [(slot, s) for slot, s in self.slots.items() if s["panel"].get_mapped()]
        if not visible: return
        rows = self.mounts()
        for slot, state in visible:
            cards = state["cards"]
            for uri in set(cards) - rows.keys():
                state["flow"].remove(cards.pop(uri)[0])
            for uri, (name, icon) in rows.items():
                if uri not in cards:
                    cards[uri] = self.card(slot, state["flow"], uri, name, icon)
                self.usage(uri, cards[uri])
        self.schedule_refresh()

    def schedule_refresh(self):
        if self.refresh_source:
            GLib.source_remove(self.refresh_source)
            self.sources.discard(self.refresh_source)
            self.refresh_source = 0
        if self.active and any(s["panel"].get_mapped() for s in self.slots.values()):
            self.refresh_source = self.later(10000, self.tick)

    def tick(self):
        self.refresh_source = 0
        self.refresh()

    def card(self, slot, flow, uri, name, icon):
        button = Gtk.Button(tooltip_text=uri)
        button.add_css_class("card")
        row = Gtk.Box(spacing=14, margin_top=14, margin_bottom=14, margin_start=14, margin_end=14)
        image = Gtk.Image.new_from_gicon(icon)
        image.set_pixel_size(40)
        row.append(image)
        column = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=7, hexpand=True)
        label = Gtk.Label(label=name, xalign=0, ellipsize=Pango.EllipsizeMode.END, max_width_chars=28)
        label.add_css_class("heading")
        column.append(label)
        bar = Gtk.LevelBar(min_value=0, max_value=1, value=0)
        bar.add_css_class("omarchy-tool-capacity")
        column.append(bar)
        capacity = Gtk.Label(label=text("Reading capacity…", "Leyendo capacidad…"), xalign=0,
                             ellipsize=Pango.EllipsizeMode.END, max_width_chars=38)
        capacity.add_css_class("dim-label")
        column.append(capacity)
        row.append(column)
        button.set_child(row)
        button.connect("clicked", lambda *_args: self.action(slot, "open-location", GLib.Variant("s", uri)))
        flow.append(button)
        # FlowBox wraps each card in a FlowBoxChild, which is what remove expects.
        return button.get_parent(), bar, capacity

    def usage(self, uri, card):
        cancellable = Gio.Cancellable()
        self.queries.add(cancellable)
        def cancel():
            cancellable.cancel()
            card[2].set_label(text("Capacity unavailable", "Capacidad no disponible"))
        deadline = self.later(2500, cancel)
        def ready(file, result):
            self.queries.discard(cancellable)
            if deadline in self.sources:
                GLib.source_remove(deadline)
                self.sources.discard(deadline)
            if not self.active or cancellable.is_cancelled(): return
            try:
                info = file.query_filesystem_info_finish(result)
                total = info.get_attribute_uint64("filesystem::size")
                free = info.get_attribute_uint64("filesystem::free")
                if not total: raise ValueError("unknown capacity")
                card[1].set_value(max(0, min(1, 1 - free / total)))
                if free / total < .1: card[1].add_css_class("critical")
                else: card[1].remove_css_class("critical")
                pattern = text("{free} free of {total}", "{free} libres de {total}")
                card[2].set_label(pattern.format(free=GLib.format_size(free), total=GLib.format_size(total)))
            except (GLib.Error, ValueError):
                card[2].set_label(text("Capacity unavailable", "Capacidad no disponible"))
        Gio.File.new_for_uri(uri).query_filesystem_info_async(
            "filesystem::size,filesystem::free", GLib.PRIORITY_DEFAULT, cancellable, ready)

    def drop_window(self, win):
        for slot, state in list(self.slots.items()):
            if state["window"] is win: self.drop_slot(slot, restore=not self.active)
        self.disconnect(self.windows.pop(win, []))

    def drop_slot(self, slot, restore=False):
        state = self.slots[slot]
        self.disconnect(state["handlers"])
        stack, panel = state["stack"], state["panel"]
        if stack.get_visible_child() is panel and state["native"] is not None:
            stack.set_visible_child(state["native"])
        stack.remove(panel)
        if restore and slot.get_property("location") is not None and slot.get_property("location").get_uri() == COMPUTER:
            self.action(slot, "open-location", GLib.Variant("s", Gio.File.new_for_path(str(Path.home())).get_uri()))
        self.slots.pop(slot)

    def stop(self):
        self.active = False
        self.forget_ready()
        for query in self.queries: query.cancel()
        self.queries.clear()
        for identity in self.sources: GLib.source_remove(identity)
        self.sources.clear()
        self.refresh_source = 0
        for win in list(self.windows): self.drop_window(win)
        self.disconnect(self.handlers)
        if self.style is not None:
            Gtk.StyleContext.remove_provider_for_display(Gdk.Display.get_default(), self.style)
            self.style = None

    # Nautilus loads the provider through its public menu-extension interface;
    # the feature contributes no context menus and never interprets file names.
    def get_file_items(self, *_args): return []

    def get_background_items(self, *_args): return []
