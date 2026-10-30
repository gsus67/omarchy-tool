#!/usr/bin/env python3
"""Whole copies of what Windows programs keep in the Proton prefix.

Usage: exe-proton-saves.py list | preview NAME | save | load NAME
Prints one JSON object. Errors print {"error": <Spanish catalog source>} and
exit 1, so the shell side can translate them.
"""
from compression import zstd
from datetime import datetime
import errno
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import sys
import tarfile
import tempfile

USER_DIRECTORY = "drive_c/users/steamuser"
ROOTS = ("Documents", "Saved Games", "AppData/Local", "AppData/LocalLow", "AppData/Roaming")
# Caches and Windows' own folders, relative to the user directory.
EXCLUDED = ("AppData/Local/dxvk", "AppData/Local/Temp", "AppData/Local/Microsoft",
            "AppData/Local/Programs", "AppData/Local/openvr", "AppData/Roaming/Microsoft")
COPY_NAME = re.compile(r"^(partidas|automatica|antes-de-cargar)-\d{8}-\d{6}\.tar\.zst$")
PROC_DIRECTORY = Path("/proc")


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


def proton_open():
    """Whether any wineserver runs. Tests set the override; "" means closed."""
    override = os.environ.get("OMARCHY_TOOL_WINESERVER_PID")
    if override is not None:
        return bool(override)
    try:
        processes = [entry for entry in os.listdir(PROC_DIRECTORY) if entry.isdigit()]
    except OSError as error:
        raise SavesError("no se pudo comprobar si Proton está abierto") from error
    for pid in processes:
        try:
            command = (PROC_DIRECTORY / pid / "comm").read_text(errors="replace").strip()
        except OSError:
            continue  # It ended while looking.
        if command in ("wineserver", "wineserver64"):
            return True
    return False


def private_directory(copies):
    copies.mkdir(parents=True, mode=0o700, exist_ok=True)
    try:
        os.chmod(copies, 0o700)
    except OSError as error:
        # Disks without Unix permissions, like NTFS, can't make it private.
        if error.errno not in (errno.EPERM, errno.ENOTSUP):
            raise


def add_member(archive, user, name):
    """Add one inventory entry by what it is now, never following a link."""
    path = user / name
    info = tarfile.TarInfo(name)
    status = os.lstat(path)
    info.mtime = int(status.st_mtime)
    info.mode = stat.S_IMODE(status.st_mode)
    if stat.S_ISDIR(status.st_mode):
        info.type = tarfile.DIRTYPE
        archive.addfile(info)
    elif stat.S_ISREG(status.st_mode):
        with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC), "rb") as source:
            info.size = os.fstat(source.fileno()).st_size
            archive.addfile(info, source)


def publish(temporary, final):
    """Give the finished archive its name without ever replacing another copy."""
    try:
        os.link(temporary, final)
    except FileExistsError as error:
        raise SavesError("ya existe una copia de este segundo; inténtalo de nuevo") from error
    except OSError:
        # No hard links on this disk. The tool's lock keeps other writers out.
        if final.exists():
            raise SavesError("ya existe una copia de este segundo; inténtalo de nuevo") from None
        os.rename(temporary, final)


def write_copy(prefix, copies, kind, now=None):
    """Write a complete archive under its timestamped name, or leave nothing behind."""
    name = f"{kind}-{(now or datetime.now()).strftime('%Y%m%d-%H%M%S')}.tar.zst"
    user = prefix / USER_DIRECTORY
    temporary = None
    try:
        private_directory(copies)
        descriptor, temporary = tempfile.mkstemp(prefix=f".{kind}-", suffix=".tmp", dir=copies)
        with os.fdopen(descriptor, "wb") as output:
            with tarfile.open(fileobj=output, mode="w:zst") as archive:
                for member, _ in scan_prefix(prefix):
                    add_member(archive, user, member)
            output.flush()
            os.fsync(output.fileno())
        publish(temporary, copies / name)
    except (OSError, tarfile.TarError, zstd.ZstdError) as error:
        raise SavesError("no se pudo guardar la copia") from error
    finally:
        if temporary:
            Path(temporary).unlink(missing_ok=True)
    return name


def require_closed_prefix(prefix):
    if proton_open():
        raise SavesError("cierra Proton antes de guardar o cargar")
    if not (prefix / USER_DIRECTORY).is_dir():
        raise SavesError("todavía no existe el prefijo de Proton; abre antes un programa con Proton")


def save_copy():
    prefix, copies = locations()
    require_closed_prefix(prefix)
    return {"name": write_copy(prefix, copies, "partidas")}


def validate_destinations(prefix, members):
    """Refuse a load that would go through a link or change what a path is."""
    user = prefix / USER_DIRECTORY
    if user.is_symlink() or not user.is_dir():
        raise SavesError("la copia no encaja con lo que hay en el prefijo")
    for member in members:
        path = user
        parts = member.name.split("/")
        for index, part in enumerate(parts):
            path = path / part
            try:
                mode = os.lstat(path).st_mode
            except FileNotFoundError:
                break
            except OSError as error:
                raise SavesError("no se pudieron leer los datos de Proton") from error
            last = index == len(parts) - 1
            wanted = stat.S_ISREG(mode) if last and member.type != tarfile.DIRTYPE else stat.S_ISDIR(mode)
            if not wanted:
                raise SavesError("la copia no encaja con lo que hay en el prefijo")


def apply_staged(staging, user, members):
    """Merge folders and replace files whole; whatever the copy doesn't name stays."""
    for member in members:
        target = user / member.name
        if member.type == tarfile.DIRTYPE:
            target.mkdir(parents=True, exist_ok=True)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            os.replace(staging / member.name, target)


def load_copy(name):
    prefix, copies = locations()
    require_closed_prefix(prefix)
    user = prefix / USER_DIRECTORY
    staging = None
    with open_copy(name) as copy, open_archive(copy) as archive:
        members = validated_members(archive)
        validate_destinations(prefix, members)
        try:
            # Next to the destination: same disk, so files can be moved into place whole.
            staging = Path(tempfile.mkdtemp(prefix=".omarchy-tool-carga-", dir=user.parent))
            archive.extractall(staging, members=members, filter="data")
        except (OSError, tarfile.TarError, EOFError, zstd.ZstdError) as error:
            if staging:
                shutil.rmtree(staging, ignore_errors=True)
            raise SavesError("no se pudo preparar la carga; no cambió nada") from error
    try:
        safety = write_copy(prefix, copies, "antes-de-cargar")
        if proton_open():
            raise SavesError("cierra Proton antes de guardar o cargar")
        validate_destinations(prefix, members)
        try:
            apply_staged(staging, user, members)
        except OSError as error:
            raise SavesError("la carga quedó incompleta; se conservó la copia previa") from error
    finally:
        shutil.rmtree(staging, ignore_errors=True)
    return {"name": name, "safetyCopy": safety}


def main(argv):
    try:
        if argv == ["list"]:
            result = list_saves()
        elif len(argv) == 2 and argv[0] == "preview":
            result = preview_copy(argv[1])
        elif argv == ["save"]:
            result = save_copy()
        elif len(argv) == 2 and argv[0] == "load":
            result = load_copy(argv[1])
        else:
            raise SavesError("acción de copias no válida")
    except SavesError as error:
        print(json.dumps({"error": error.source}))
        return 1
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
