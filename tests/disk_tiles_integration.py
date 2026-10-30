#!/usr/bin/env python3
"""Real Nautilus in a private D-Bus/Broadway session, never the desktop instance.

Requires Nautilus 50/51, nautilus-python, GTK4 (gtk4-broadwayd) and libadwaita.
No browser, package changes or administrator privileges are required.
"""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]

PROBE = r'''
import gc, json, os, subprocess, sys, traceback
from pathlib import Path
import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Nautilus", "4.1")
from gi.repository import Gio, GLib, GObject, Gtk, Nautilus

class DiskTilesProbe(GObject.GObject, Nautilus.MenuProvider):
    def __init__(self):
        super().__init__()
        self.phase = 0
        self.ticks = 0
        self.checks = []
        GLib.timeout_add(100, self.step)

    def step(self):
        self.ticks += 1
        try:
            assert self.ticks < 400, "integration timed out at phase " + str(self.phase)
            ext = next((o for o in gc.get_objects() if type(o).__name__ == "DiskTilesExtension"), None)
            if ext is None: return True
            if self.phase == 0:
                visible = [(s, d) for s, d in ext.slots.items() if d["panel"].get_mapped() and d["cards"]]
                if not visible: return True
                self.slot, data = visible[0]
                if not all(" free of " in c[2].get_label() for c in data["cards"].values()): return True
                self.win = data["window"]
                self.checks.append({"start_on_computer": self.slot.get_property("location").get_uri(),
                                    "capacities": [c[2].get_label() for c in data["cards"].values()]})
                assert self.slot.get_property("location").get_uri() == "computer:///"
                runtime = subprocess.run([sys.executable, "-B", os.environ["DISK_TILES_TEST_MANAGER"], "runtime",
                                          os.environ["DISK_TILES_TEST_STATE"]], check=True, capture_output=True, text=True)
                assert json.loads(runtime.stdout)["ready"], "installed view must confirm it loaded into Nautilus"
                self.checks.append("loaded view confirmed by PID, start time and source hash")
                assert ext.action(self.slot, "open-location", GLib.Variant("s", Gio.File.new_for_path(os.environ["DISK_TILES_TEST_FOLDER"]).get_uri()))
                self.phase = 1
            elif self.phase == 1:
                data = ext.slots[self.slot]
                if self.slot.get_property("location").get_path() != os.environ["DISK_TILES_TEST_FOLDER"]: return True
                assert data["stack"].get_visible_child() is not data["panel"]
                self.checks.append("folder navigation restores native view")
                assert ext.action(self.slot, "back")
                self.phase = 2
            elif self.phase == 2:
                data = ext.slots[self.slot]
                if data["stack"].get_visible_child() is not data["panel"]: return True
                self.checks.append("back returns to disk tiles")
                Gio.ActionGroup.activate_action(self.win, "new-tab", None)
                self.phase = 3
            elif self.phase == 3:
                if len(ext.slots) < 2: return True
                self.checks.append("new tab has its own panel")
                # This client calls back into this very GTK main loop over
                # D-Bus, so waiting synchronously here would deadlock the test.
                self.launch = subprocess.Popen(["nautilus", "--new-window", os.environ["DISK_TILES_TEST_FOLDER"]])
                self.phase = 4
            elif self.phase == 4:
                if self.launch.poll() is None: return True
                assert self.launch.returncode == 0
                other = [d for s, d in ext.slots.items() if d["window"] is not self.win
                         and s.get_property("location").get_path() == os.environ["DISK_TILES_TEST_FOLDER"]]
                if not other: return True
                assert all(d["stack"].get_visible_child() is not d["panel"] for d in other)
                self.checks.append("explicit folder in new window is preserved")
                subprocess.run([sys.executable, "-B", os.environ["DISK_TILES_TEST_MANAGER"], "disable",
                                os.environ["DISK_TILES_TEST_STATE"]], check=True)
                self.phase = 5
            elif self.phase == 5:
                if ext.active or ext.slots: return True
                assert not ext.sources and not ext.queries and not ext.handlers
                self.checks.append("disable removes all panels, timers, queries and app hooks")
                subprocess.run([sys.executable, "-B", os.environ["DISK_TILES_TEST_REPO_MANAGER"], "enable",
                                os.environ["DISK_TILES_TEST_STATE"], os.environ["DISK_TILES_TEST_SOURCE"]], check=True)
                self.phase = 6
            elif self.phase == 6:
                if not ext.active or not ext.slots: return True
                self.checks.append("re-enable works in the same Nautilus process")
                bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
                for name in ("org.freedesktop.Tracker3.Miner.Files", "org.freedesktop.LocalSearch3"):
                    reply = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus",
                                          "org.freedesktop.DBus", "NameHasOwner", GLib.Variant("(s)", (name,)),
                                          GLib.VariantType.new("(b)"), Gio.DBusCallFlags.NONE, 1000, None)
                    assert not reply.unpack()[0], "test must not start the search indexer"
                self.checks.append("search indexer was not activated on the test bus")
                Path(os.environ["DISK_TILES_TEST_RESULT"]).write_text(json.dumps({"ok": True, "checks": self.checks}))
                return False
        except Exception:
            Path(os.environ["DISK_TILES_TEST_RESULT"]).write_text(json.dumps({"ok": False, "checks": self.checks,
                                                                             "error": traceback.format_exc()}))
            return False
        return True

    def get_file_items(self, *args): return []
    def get_background_items(self, *args): return []
'''


def terminate(process):
    if process is None: return
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=5)
    except (ProcessLookupError, subprocess.TimeoutExpired):
        try: os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError: pass


def run():
    with tempfile.TemporaryDirectory(prefix="disk-tiles-nautilus-") as temporary:
        work = Path(temporary)
        runtime = work / "runtime"
        runtime.mkdir(mode=0o700)
        folder = work / "explicit-folder"
        folder.mkdir()
        state = work / "state/disk-tiles"
        state.mkdir(parents=True)
        manager = state / "manage.py"
        shutil.copyfile(ROOT / "bin/disk-tiles.py", manager)
        result = work / "result.json"
        env = dict(os.environ, XDG_DATA_HOME=str(work / "data"), XDG_CONFIG_HOME=str(work / "config"),
                   XDG_CACHE_HOME=str(work / "cache"), XDG_STATE_HOME=str(work / "state"),
                   XDG_RUNTIME_DIR=str(runtime), GDK_BACKEND="broadway", BROADWAY_DISPLAY=":47",
                   XDG_SESSION_TYPE="x11", GTK_A11Y="none", GVFS_DISABLE_FUSE="1",
                   LC_ALL="C.UTF-8", PYTHONDONTWRITEBYTECODE="1",
                   DISK_TILES_TEST_FOLDER=str(folder), DISK_TILES_TEST_MANAGER=str(manager),
                   DISK_TILES_TEST_STATE=str(state), DISK_TILES_TEST_RESULT=str(result),
                   DISK_TILES_TEST_REPO_MANAGER=str(ROOT / "bin/disk-tiles.py"),
                   DISK_TILES_TEST_SOURCE=str(ROOT / "nautilus/disk_tiles.py"))
        subprocess.run([sys.executable, "-B", str(manager), "enable", str(state),
                        str(ROOT / "nautilus/disk_tiles.py")], env=env, check=True)
        extensions = work / "data/nautilus-python/extensions"
        (extensions / "zz_disk_tiles_probe.py").write_text(PROBE)
        # Storage/navigation tests do not need a search index. Override activation
        # only on this private bus, so it cannot start an indexer over the real
        # Home tree or race another test's temporary index database.
        services = work / "data/dbus-1/services"
        services.mkdir(parents=True)
        for name in ("org.freedesktop.Tracker3.Miner.Files", "org.freedesktop.LocalSearch3"):
            (services / (name + ".service")).write_text(
                "[D-BUS Service]\nName=" + name + "\nExec=/usr/bin/false\n")
        broadway = app = None
        with (work / "broadway.log").open("w") as display_log, (work / "nautilus.log").open("w") as app_log:
            try:
                broadway = subprocess.Popen(["gtk4-broadwayd", ":47", "--address=127.0.0.1", "--port=18447"],
                                            env=env, stdout=display_log, stderr=display_log, start_new_session=True)
                time.sleep(.3)
                app = subprocess.Popen(["dbus-run-session", "--", "nautilus", "--new-window"],
                                       env=env, stdout=app_log, stderr=app_log, start_new_session=True)
                deadline = time.monotonic() + 45
                while not result.exists() and time.monotonic() < deadline and app.poll() is None:
                    time.sleep(.1)
                if not result.exists():
                    raise AssertionError("No integration result\n" + (work / "nautilus.log").read_text()[-7000:])
                report = json.loads(result.read_text())
                if not report["ok"]: raise AssertionError(json.dumps(report, indent=2))
                print(json.dumps(report, indent=2))
            finally:
                terminate(app)
                terminate(broadway)
                # Session-activated GVfs/metadata helpers exit after the bus;
                # let their last atomic writes settle before removing the XDG tree.
                time.sleep(1)


if __name__ == "__main__": run()
