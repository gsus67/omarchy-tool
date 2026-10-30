#!/usr/bin/env python3
"""Whole copies of what Windows programs keep in the Proton prefix.

Usage: exe-proton-saves.py list | preview NAME
Prints one JSON object. Errors print {"error": <Spanish catalog source>} and
exit 1, so the shell side can translate them.
"""
from compression import zstd
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys
import tarfile

USER_DIRECTORY = "drive_c/users/steamuser"
ROOTS = ("Documents", "Saved Games", "AppData/Local", "AppData/LocalLow", "AppData/Roaming")
# Caches and Windows' own folders, relative to the user directory.
EXCLUDED = ("AppData/Local/dxvk", "AppData/Local/Temp", "AppData/Local/Microsoft",
            "AppData/Local/Programs", "AppData/Local/openvr", "AppData/Roaming/Microsoft")
COPY_NAME = re.compile(r"^(partidas|automatica|antes-de-cargar)-\d{8}-\d{6}\.tar\.zst$")


class SavesError(Exception):
    """A failure the user reads; source is its Spanish catalog key."""

    def __init__(self, source):
        super().__init__(source)
        self.source = source


def locations():
    """The canonical prefix and the copies directory (last component unresolved, to spot a link)."""
    home = Path.home()
    prefix = Path(os.environ.get("WINEPREFIX") or home / ".local/share/umu/default").resolve()
    copies = Path(os.environ.get("OMARCHY_TOOL_PROTON_SAVES_DIR") or home / "Documents/Partidas Proton")
    copies = copies.parent.resolve() / copies.name
    if copies == prefix or prefix in copies.parents:
        raise SavesError("la carpeta de copias no puede estar dentro del prefijo de Proton")
    if copies.is_symlink():
        raise SavesError("la carpeta de copias no puede ser un enlace")
    return prefix, copies


def excluded(name):
    return any(name == path or name.startswith(path + "/") for path in EXCLUDED)


def scan_prefix(prefix):
    """Relative names and sizes of what a copy holds; links and special files never count."""
    user = prefix / USER_DIRECTORY
    entries = []

    def walk(relative):
        try:
            with os.scandir(user / relative) as listing:
                children = sorted(listing, key=lambda child: child.name)
        except FileNotFoundError:
            return
        except OSError as error:
            raise SavesError("no se pudieron leer los datos de Proton") from error
        for child in children:
            name = f"{relative}/{child.name}"
            if excluded(name):
                continue
            try:
                mode = child.stat(follow_symlinks=False)
            except FileNotFoundError:
                continue
            except OSError as error:
                raise SavesError("no se pudieron leer los datos de Proton") from error
            if stat.S_ISDIR(mode.st_mode):
                entries.append((name, 0))
                walk(name)
            elif stat.S_ISREG(mode.st_mode):
                entries.append((name, mode.st_size))

    for root in ROOTS:
        # A root that is itself a link is not ours to copy: its target is outside.
        if not (user / root).is_symlink() and not (user / root).parent.is_symlink():
            walk(root)
    return entries


def group_entries(entries):
    """What the page shows: one row per first-level folder, without empty ones."""
    totals = {}
    for name, size in entries:
        parts = name.split("/")
        if parts[0] == "AppData":
            area, rest = "AppData", parts[2:]
        else:
            area, rest = parts[0], parts[1:]
        group = rest[0] if len(rest) > 1 or size == 0 else area
        totals[(area, group)] = totals.get((area, group), 0) + size
    return [{"name": name, "area": area, "bytes": size}
            for (area, name), size in sorted(totals.items()) if size > 0]


def list_copies(copies):
    found = []
    try:
        with os.scandir(copies) as listing:
            for entry in listing:
                match = COPY_NAME.match(entry.name)
                if match and entry.is_file(follow_symlinks=False):
                    info = entry.stat(follow_symlinks=False)
                    found.append({"name": entry.name, "timestamp": int(info.st_mtime),
                                  "bytes": info.st_size, "kind": match.group(1)})
    except FileNotFoundError:
        return []
    except OSError as error:
        raise SavesError("no se pudo leer la carpeta de copias") from error
    return sorted(found, key=lambda copy: (-copy["timestamp"], copy["name"]))


def list_saves():
    prefix, copies = locations()
    exists = (prefix / USER_DIRECTORY).is_dir()
    return {"prefixExists": exists,
            "groups": group_entries(scan_prefix(prefix)) if exists else [],
            "copies": list_copies(copies)}


def open_copy(name):
    """The named copy, opened without following a link. Only generated names are accepted."""
    if not COPY_NAME.match(name):
        raise SavesError("nombre de copia no válido")
    _, copies = locations()
    try:
        descriptor = os.open(copies / name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError as error:
        raise SavesError("no se pudo abrir la copia") from error
    copy = os.fdopen(descriptor, "rb")
    if not stat.S_ISREG(os.fstat(copy.fileno()).st_mode):
        copy.close()
        raise SavesError("no se pudo abrir la copia")
    return copy


def allowed_member(member):
    """Whether a member may exist in a copy: same rules as what scan_prefix produces."""
    name = member.name
    if PurePosixPath(name).as_posix() != name or name.startswith("/") or ".." in name.split("/"):
        return False
    if member.type == tarfile.DIRTYPE and (name == "AppData" or name in ROOTS):
        return True
    if member.type not in (tarfile.REGTYPE, tarfile.AREGTYPE, tarfile.DIRTYPE):
        return False
    return any(name.startswith(root + "/") for root in ROOTS) and not excluded(name)


def validated_members(archive):
    """Every member, once all were checked and all payloads read to the end, or SavesError."""
    members, seen, files = [], set(), set()
    try:
        for member in archive:
            if not allowed_member(member) or member.name in seen:
                raise SavesError("la copia contiene rutas no permitidas")
            seen.add(member.name)
            if member.type != tarfile.DIRTYPE:
                files.add(member.name)
                payload = archive.extractfile(member)
                remaining = member.size
                while chunk := payload.read(1 << 20):
                    remaining -= len(chunk)
                if remaining:
                    raise SavesError("la copia está dañada")
            members.append(member)
    except (tarfile.TarError, EOFError, OSError, ValueError, zstd.ZstdError) as error:
        raise SavesError("la copia está dañada") from error
    if not members:
        raise SavesError("la copia está dañada")
    for name in seen:
        if any(str(parent) in files for parent in PurePosixPath(name).parents):
            raise SavesError("la copia contiene rutas no permitidas")
    return members


def open_archive(copy):
    try:
        return tarfile.open(fileobj=copy, mode="r:zst")
    except (tarfile.TarError, EOFError, OSError, ValueError, zstd.ZstdError) as error:
        raise SavesError("la copia está dañada") from error


def preview_copy(name):
    with open_copy(name) as copy, open_archive(copy) as archive:
        members = validated_members(archive)
    return {"name": name, "groups": group_entries((member.name, member.size) for member in members)}


def main(argv):
    try:
        if argv == ["list"]:
            result = list_saves()
        elif len(argv) == 2 and argv[0] == "preview":
            result = preview_copy(argv[1])
        else:
            raise SavesError("acción de copias no válida")
    except SavesError as error:
        print(json.dumps({"error": error.source}))
        return 1
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
