#!/usr/bin/env python3
"""Install/remove only our Nautilus extension and our bookmark; no root or daemon."""
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

NAME = "omarchy-tool-disk-tiles.py"


def locations():
    home = Path.home()
    data = Path(os.environ.get("XDG_DATA_HOME", home / ".local/share"))
    config = Path(os.environ.get("XDG_CONFIG_HOME", home / ".config"))
    if not data.is_absolute() or not config.is_absolute():
        raise ValueError("XDG paths must be absolute")
    return data / "nautilus-python/extensions" / NAME, config / "gtk-3.0/bookmarks"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def atomic(path, data):
    # Do not follow a replacement symlink, including for the temporary file.
    import tempfile
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(prefix=".disk-tiles-", dir=path.parent)
    try:
        if path.exists() and not path.is_symlink():
            os.fchmod(descriptor, path.stat().st_mode & 0o777)
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


def probe():
    if os.geteuid() == 0:
        raise ValueError("Run as your desktop user, never root")
    extension, _ = locations()
    candidates = [extension.parent, Path("/usr/share/nautilus-python/extensions")]
    for directory in candidates:
        if any(directory.glob("*my*computer*")) or (directory / "nautilus_my_computer").exists():
            raise ValueError("Another Computer view is installed; disable it first")
    if not shutil.which("nautilus"):
        raise ValueError("Nautilus is required")
    # Nautilus initializes GTK and its tag database even for --version. Read
    # Arch's package metadata instead, without opening the user's application.
    result = subprocess.run(["pacman", "-Q", "nautilus", "nautilus-python"], capture_output=True, text=True, timeout=5)
    if result.returncode:
        raise ValueError("Nautilus and nautilus-python are required")
    import re
    version = re.search(r"\b(\d+)\.", result.stdout)
    if result.returncode or not version or not 50 <= int(version[1]) <= 51:
        raise ValueError("Discos en mosaicos supports Nautilus 50 and 51")
    # No display initialization and no installer: just check the shipped bindings.
    subprocess.run([sys.executable, "-B", "-c",
                    "import gi; gi.require_version('Nautilus','4.1'); "
                    "gi.require_version('Gtk','4.0'); gi.require_version('Adw','1'); "
                    "from gi.repository import Nautilus, Gtk, Adw"], check=True, timeout=5)


def enable(state, source):
    extension, bookmark = locations()
    record = state / "owned.json"
    if record.exists():
        owned = json.loads(record.read_text())
        if owned["extension"] != str(extension) or owned["bookmark"] != str(bookmark):
            raise ValueError("XDG locations changed; disable using the previous locations first")
        if extension.is_symlink() or (extension.exists() and digest(extension.read_bytes()) != owned["hash"]):
            raise ValueError("Our extension was edited; refusing to overwrite it")
    else:
        if extension.exists() or extension.is_symlink():
            raise ValueError("Extension path already exists; refusing to overwrite it")
        if bookmark.is_symlink():
            raise ValueError("Bookmark file is a symlink; refusing to modify it")
        before = bookmark.read_bytes() if bookmark.exists() else b""
        has_computer = any(line.split(maxsplit=1)[0] == b"computer:///"
                           for line in before.splitlines() if line.strip())
        spanish = (os.environ.get("LC_ALL") or os.environ.get("LC_MESSAGES")
                   or os.environ.get("LANG", "en")).lower().startswith("es")
        line = ("computer:/// " + ("Este equipo" if spanish else "This PC") + "\n").encode()
        owned = {"extension": str(extension), "bookmark": str(bookmark),
                 "bookmark_existed": bookmark.exists(),
                 "before": base64.b64encode(before).decode(),
                 "line": line.decode(), "added": not has_computer,
                 "directories": []}
        # Remember only directories created here; rmdir never removes user content.
        for parent in (extension.parent, bookmark.parent):
            missing = []
            while not parent.exists():
                missing.append(str(parent)); parent = parent.parent
            owned["directories"] += missing
    data = source.read_text().replace("STATE_DIRECTORY = None", f"STATE_DIRECTORY = {str(state)!r}").encode()
    # Persist ownership before the first mutation, including on a partial install.
    owned["hash"] = digest(data)
    state.mkdir(parents=True, exist_ok=True)
    atomic(record, json.dumps(owned).encode())
    if owned["added"]:
        before = base64.b64decode(owned["before"])
        current = bookmark.read_bytes() if bookmark.exists() else b""
        line = owned["line"].encode()
        if line not in current.splitlines(keepends=True):
            atomic(bookmark, current + (b"\n" if current and not current.endswith(b"\n") else b"") + line)
    atomic(state / "enabled", b"1\n")
    atomic(extension, data)


def disable(state):
    record = state / "owned.json"
    if not record.exists():
        # A failed prerequisite check may have copied only manage.py.
        (state / "manage.py").unlink(missing_ok=True)
        if state.exists(): state.rmdir()
        return
    owned = json.loads(record.read_text())
    extension, bookmark = Path(owned["extension"]), Path(owned["bookmark"])
    if extension.is_symlink() or (extension.exists() and digest(extension.read_bytes()) != owned["hash"]):
        raise ValueError("Our extension was replaced or edited; keep state for manual review")
    (state / "enabled").unlink(missing_ok=True)
    extension.unlink(missing_ok=True)
    cache = extension.parent / "__pycache__"
    if cache.is_dir() and not cache.is_symlink():
        for compiled in cache.glob("omarchy-tool-disk-tiles.*.pyc"):
            compiled.unlink()
        try: cache.rmdir()
        except OSError: pass
    if owned["added"] and bookmark.exists():
        if bookmark.is_symlink():
            raise ValueError("Bookmark file was replaced by a symlink; cleanup can be retried")
        current = bookmark.read_bytes()
        before = base64.b64decode(owned["before"])
        expected = before + (b"\n" if before and not before.endswith(b"\n") else b"") + owned["line"].encode()
        if current == expected:
            if owned["bookmark_existed"]:
                atomic(bookmark, before)
            else:
                bookmark.unlink()
        else:
            # Keep other edits made while enabled, removing just our exact row.
            new = b"".join(line for line in current.splitlines(keepends=True)
                           if line != owned["line"].encode())
            if new != current: atomic(bookmark, new)
    for directory in owned["directories"]:
        try: Path(directory).rmdir()
        except OSError: pass
    for name in ("owned.json", "manage.py"):
        (state / name).unlink(missing_ok=True)
    state.rmdir()


def main():
    action, directory, *extra = sys.argv[1:]
    state = Path(directory).absolute()
    if action == "probe": probe()
    elif action == "enable": enable(state, Path(extra[0]))
    elif action == "disable": disable(state)
    elif action == "check":
        try:
            owned = json.loads((state / "owned.json").read_text())
            return 0 if (state / "enabled").exists() and digest(Path(owned["extension"]).read_bytes()) == owned["hash"] else 1
        except (OSError, ValueError, KeyError): return 1
    else: raise ValueError("Unknown operation")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Discos en mosaicos: {error}", file=sys.stderr)
        sys.exit(1)
