#!/usr/bin/env python3
"""What the Limpieza page can clean, and cleaning what needs no password.

Usage: cleanup.py list | validate-cache NAMES_JSON | clean tmp | clean cache NAMES_JSON
Prints one JSON object. Errors print {"error": <Spanish catalog source>} and
exit 1, so the shell side can translate them.
"""
import errno
import json
import os
from pathlib import Path
import stat
import sys
import time

MINIMUM_AGE = 86400
GROUP_BELOW = 100 * 1024 * 1024
DELETED_SUFFIX = " (deleted)"

ERROR_ACTION = "acción de limpieza no válida"
ERROR_GENERIC = "no se pudo completar la limpieza"
ERROR_TEMP = "no se pudo abrir la carpeta de temporales"
TEMP_TITLE = "Temporales (en RAM)"
TEMP_SUMMARY = "Archivos de programas que ya terminaron. Limpiarlos libera memoria."
ERROR_CACHE = "carpeta de caché no válida"
CACHE_TITLE = "Caché de programas"
CACHE_SUMMARY = "Datos que los programas vuelven a crear cuando los necesitan."
OTHER_TITLE = "Otras"
OTHER_SUMMARY = "Carpetas menores de 100 MB"
CACHE_FALLBACK = "Datos que este programa guardó para ir más rápido; los vuelve a crear."
CACHE_SUMMARIES = {
    "chromium": "Se regenera al navegar; la primera carga va más lenta.",
    "google-chrome": "Se regenera al navegar; la primera carga va más lenta.",
    "codex-runtimes": "Entornos de Codex; se descargan otra vez al usarlo.",
    "uv": "Paquetes de Python; se descargan otra vez.",
    "mise": "Descargas de herramientas; se bajan otra vez si hacen falta.",
    "ms-playwright": "Navegadores de prueba; hay que reinstalarlos para usar Playwright.",
    "mesa_shader_cache": "Shaders de juegos y programas; se recompilan y pueden dar tirones al principio.",
    "pnpm": "Paquetes de Node; se descargan otra vez.",
    "node-gyp": "Cabeceras de Node; se descargan otra vez al compilar.",
    "electron": "Descargas de Electron; se bajan otra vez si hacen falta.",
    "yay": "Paquetes compilados de AUR; se recompilan si se reinstalan.",
    "thumbnails": "Miniaturas de archivos; se crean otra vez al abrir carpetas.",
}
CATALOG_SOURCES = [ERROR_ACTION, ERROR_GENERIC, ERROR_TEMP, TEMP_TITLE, TEMP_SUMMARY, ERROR_CACHE, CACHE_TITLE,
                   CACHE_SUMMARY, OTHER_TITLE, OTHER_SUMMARY, CACHE_FALLBACK, *CACHE_SUMMARIES.values()]


class CleanupError(Exception):
    """A failure the user reads; source is its Spanish catalog key."""

    def __init__(self, source):
        super().__init__(source)
        self.source = source


def locations():
    """Where each category lives; tests point these at temporary folders."""
    def place(variable, default):
        return Path(os.environ.get(variable) or default)

    home = Path.home()
    return {
        "temp": place("OMARCHY_TOOL_CLEANUP_TEMP_DIR", "/tmp"),
        "cache": place("OMARCHY_TOOL_CLEANUP_CACHE_DIR", os.environ.get("XDG_CACHE_HOME") or home / ".cache"),
        "proc": place("OMARCHY_TOOL_CLEANUP_PROC_DIR", "/proc"),
        "coredumps": place("OMARCHY_TOOL_CLEANUP_COREDUMP_DIR", "/var/lib/systemd/coredump"),
        "journal": place("OMARCHY_TOOL_CLEANUP_JOURNAL_DIR", "/var/log/journal"),
        "runtime-journal": place("OMARCHY_TOOL_CLEANUP_RUNTIME_JOURNAL_DIR", "/run/log/journal"),
    }


def blocks(status):
    return status.st_blocks * 512


def allocated_bytes(path):
    """Space really occupied, without following links. What can't be read counts as nothing."""
    try:
        status = os.lstat(path)
    except OSError:
        return 0
    total = blocks(status)
    if stat.S_ISDIR(status.st_mode):
        try:
            with os.scandir(path) as listing:
                children = list(listing)
        except OSError:
            return total
        for child in children:
            total += allocated_bytes(child.path)
    return total


def open_targets(proc):
    """Every path the user's processes hold open, run or sit in; None if one can't be checked.

    Other users' processes are skipped: their fd lists are always unreadable, so
    counting them as unknown would make nothing cleanable.
    """
    targets = set()
    try:
        processes = [entry for entry in os.listdir(proc) if entry.isdigit()]
    except OSError:
        return None
    uid = os.getuid()
    for pid in processes:
        base = os.path.join(proc, pid)
        try:
            if os.stat(base).st_uid != uid:
                continue
            links = [os.path.join(base, "cwd"), os.path.join(base, "exe")]
            try:
                links += [os.path.join(base, "fd", number) for number in os.listdir(os.path.join(base, "fd"))]
            except FileNotFoundError:
                pass
            for link in links:
                try:
                    targets.add(os.readlink(link))
                except FileNotFoundError:
                    pass
            try:
                with open(os.path.join(base, "maps"), encoding="utf-8", errors="surrogateescape") as maps:
                    for line in maps:
                        fields = line.rstrip("\n").split(None, 5)
                        if len(fields) == 6 and fields[5].startswith("/"):
                            targets.add(fields[5])
            except FileNotFoundError:
                pass
        except FileNotFoundError:
            continue  # It ended while looking.
        except OSError:
            return None
    return {target.removesuffix(DELETED_SUFFIX) for target in targets}


def holds(targets, path):
    if targets is None:
        return True
    path = os.path.join(os.path.realpath(os.path.dirname(path)), os.path.basename(path))
    prefix = path + "/"
    return any(target == path or target.startswith(prefix) for target in targets)


def is_in_use(path, proc):
    return holds(open_targets(proc), str(path))


def remove_tree(parent, name, identity):
    """Delete one folder by descriptors: a swapped path can never lead outside it."""
    descriptor = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent)
    freed = 0
    try:
        status = os.fstat(descriptor)
        if (status.st_dev, status.st_ino) != identity:
            raise OSError(errno.ESTALE, "changed while cleaning", name)
        if status.st_uid == os.getuid():
            # Read-only folders, like Go's module cache, can't be emptied otherwise.
            os.fchmod(descriptor, 0o700)
        with os.scandir(descriptor) as listing:
            children = list(listing)
        for child in children:
            info = child.stat(follow_symlinks=False)
            if stat.S_ISDIR(info.st_mode):
                freed += remove_tree(descriptor, child.name, (info.st_dev, info.st_ino))
            else:
                os.unlink(child.name, dir_fd=descriptor)
                freed += blocks(info)
    finally:
        os.close(descriptor)
    os.rmdir(name, dir_fd=parent)
    return freed + blocks(status)


def remove_entry(directory, name, identity):
    """Delete a direct entry of an open folder if it is still what was checked."""
    status = os.lstat(name, dir_fd=directory)
    if (status.st_dev, status.st_ino) != identity:
        raise OSError(errno.ESTALE, "changed while cleaning", name)
    if stat.S_ISDIR(status.st_mode):
        return remove_tree(directory, name, identity)
    os.unlink(name, dir_fd=directory)
    return blocks(status)


def remove_counted(directory, root, name, identity, result):
    """Remove one entry; if it stops midway, what did go still counts as freed."""
    path = os.path.join(root, name)
    before = allocated_bytes(path)
    try:
        result["freedBytes"] += remove_entry(directory, name, identity)
    except OSError:
        result["freedBytes"] += max(0, before - allocated_bytes(path))
        result["skippedCount"] += 1
        result["skippedNames"].append(name)


def new_result():
    return {"freedBytes": 0, "skippedCount": 0, "skippedNames": []}


def category(identifier, title, summary, size, count, warning="", password=False, names=None, revision="", rows=None):
    return {"id": identifier, "title": title, "summary": summary, "warning": warning, "bytes": size, "count": count,
            "requiresPassword": password, "names": names or [], "revision": revision, "rows": rows or []}


def temp_state(path, status, now):
    """"old": can go. "recent": changed lately, not a candidate. "skip": can't be cleaned, say so."""
    uid = os.getuid()
    if status.st_uid != uid or stat.S_ISLNK(status.st_mode):
        return "ignore"
    if not (stat.S_ISDIR(status.st_mode) or stat.S_ISREG(status.st_mode)):
        return "skip"
    state = "old"
    if now - status.st_mtime < MINIMUM_AGE or now - status.st_ctime < MINIMUM_AGE:
        state = "recent"
    if stat.S_ISDIR(status.st_mode):
        try:
            with os.scandir(path) as listing:
                children = list(listing)
            for child in children:
                info = child.stat(follow_symlinks=False)
                if stat.S_ISLNK(info.st_mode):
                    if now - info.st_mtime < MINIMUM_AGE or now - info.st_ctime < MINIMUM_AGE:
                        state = "recent"
                    continue
                inner = temp_state(child.path, info, now)
                if inner in ("skip", "ignore"):
                    return "skip"
                if inner == "recent":
                    state = "recent"
        except OSError:
            return "skip"
    return state


def temp_entries(temp, now):
    """Direct entries of the temp folder, with what state each is in."""
    try:
        with os.scandir(temp) as listing:
            names = sorted(entry.name for entry in listing)
    except OSError as error:
        raise CleanupError(ERROR_TEMP) from error
    entries = []
    for name in names:
        path = os.path.join(temp, name)
        try:
            status = os.lstat(path)
        except OSError:
            continue
        state = temp_state(path, status, now)
        if state != "ignore":
            entries.append((name, path, status, state))
    return entries


def scan_temp(now=None):
    now = time.time() if now is None else now
    places = locations()
    targets = open_targets(places["proc"])
    size = count = 0
    for _, path, _, state in temp_entries(places["temp"], now):
        if state == "old" and not holds(targets, path):
            size += allocated_bytes(path)
            count += 1
    return category("tmp", TEMP_TITLE, TEMP_SUMMARY, size, count) if count else None


def clean_temp(now=None):
    now = time.time() if now is None else now
    places = locations()
    result = new_result()
    try:
        directory = os.open(places["temp"], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError as error:
        raise CleanupError(ERROR_TEMP) from error
    try:
        for name, path, status, state in temp_entries(places["temp"], now):
            if state == "skip" or (state == "old" and is_in_use(path, places["proc"])):
                result["skippedCount"] += 1
                result["skippedNames"].append(name)
            elif state == "old":
                remove_counted(directory, str(places["temp"]), name, (status.st_dev, status.st_ino), result)
    finally:
        os.close(directory)
    return result


def marked_names():
    """Folders the user marked; a config that isn't what it should be means none."""
    directory = os.environ.get("OMARCHY_TOOL_CONFIG_DIR") or Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "omarchy-tool"
    try:
        marked = json.loads((Path(directory) / "config.json").read_text())["modules"]["cleanup"]["cacheMarked"]
    except (OSError, ValueError, KeyError, TypeError):
        return set()
    return {name for name in marked if isinstance(name, str)} if isinstance(marked, list) else set()


def cache_folders(cache):
    """Direct, real folders of the cache; loose files and links are not ours to clean."""
    if os.path.islink(cache):
        return []
    try:
        with os.scandir(cache) as listing:
            return sorted(entry.name for entry in listing if entry.is_dir(follow_symlinks=False))
    except OSError:
        return []


def scan_cache():
    cache = locations()["cache"]
    marked = marked_names()
    rows, small = [], []
    for name in cache_folders(cache):
        size = allocated_bytes(cache / name)
        folder = {"name": name, "bytes": size, "marked": name in marked}
        if size >= GROUP_BELOW:
            rows.append({"id": "folder:" + name, "title": name, "summary": CACHE_SUMMARIES.get(name, CACHE_FALLBACK),
                         "bytes": size, "folders": [folder]})
        else:
            small.append(folder)
    rows.sort(key=lambda row: (-row["bytes"], row["title"]))
    if small:
        rows.append({"id": "otras", "title": OTHER_TITLE, "summary": OTHER_SUMMARY,
                     "bytes": sum(folder["bytes"] for folder in small), "folders": small})
    if not rows:
        return None
    count = sum(len(row["folders"]) for row in rows)
    return category("cache", CACHE_TITLE, CACHE_SUMMARY, sum(row["bytes"] for row in rows), count, rows=rows)


def cache_names(value):
    """The names asked for, only if every one is a real direct folder of the cache."""
    try:
        names = json.loads(value)
    except ValueError as error:
        raise CleanupError(ERROR_CACHE) from error
    if not isinstance(names, list) or not names or len(set(map(str, names))) != len(names):
        raise CleanupError(ERROR_CACHE)
    existing = set(cache_folders(locations()["cache"]))
    for name in names:
        if (not isinstance(name, str) or not name or "/" in name or ".." in name or "\0" in name or name == "."
                or name not in existing):
            raise CleanupError(ERROR_CACHE)
    return names


def clean_cache(names):
    places = locations()
    cache = places["cache"]
    result = new_result()
    try:
        directory = os.open(cache, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError as error:
        raise CleanupError(ERROR_CACHE) from error
    try:
        for name in names:
            try:
                status = os.lstat(name, dir_fd=directory)
            except OSError:
                status = None
            if (status is None or not stat.S_ISDIR(status.st_mode)
                    or is_in_use(os.path.join(cache, name), places["proc"])):
                result["skippedCount"] += 1
                result["skippedNames"].append(name)
                continue
            remove_counted(directory, str(cache), name, (status.st_dev, status.st_ino), result)
    finally:
        os.close(directory)
    return result


def list_categories():
    found = [scan_temp(), scan_cache()]
    return {"categories": [item for item in found if item]}


def main(argv):
    try:
        if argv == ["list"]:
            result = list_categories()
        elif argv == ["clean", "tmp"]:
            result = clean_temp()
        elif len(argv) == 2 and argv[0] == "validate-cache":
            result = {"names": cache_names(argv[1])}
        elif len(argv) == 3 and argv[:2] == ["clean", "cache"]:
            result = clean_cache(cache_names(argv[2]))
        else:
            raise CleanupError(ERROR_ACTION)
    except CleanupError as error:
        print(json.dumps({"error": error.source}))
        return 1
    except OSError:
        print(json.dumps({"error": ERROR_GENERIC}))
        return 1
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
