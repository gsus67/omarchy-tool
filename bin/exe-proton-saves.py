#!/usr/bin/env python3
"""Whole copies of what Windows programs keep in the Proton prefix.

Usage: exe-proton-saves.py list | preview NAME | save | load NAME | auto | folder PATH
Prints one JSON object. Errors print {"error": <Spanish catalog source>} and
exit 1, so the shell side can translate them.
"""
from compression import zstd
from datetime import datetime
import errno
import hashlib
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
COPIES_SUBFOLDER = "Partidas Proton"
FSTAB_FILE = Path("/etc/fstab")
AUTO_KEEP = 5


class SavesError(Exception):
    """A failure the user reads; source is its Spanish catalog key."""

    def __init__(self, source):
        super().__init__(source)
        self.source = source


def config_directory():
    home = Path.home()
    return Path(os.environ.get("OMARCHY_TOOL_CONFIG_DIR") or Path(os.environ.get("XDG_CONFIG_HOME") or home / ".config") / "omarchy-tool")


def module_config():
    try:
        config = json.loads((config_directory() / "config.json").read_text())
        return config["modules"]["exe-proton"]
    except (OSError, ValueError, KeyError, TypeError):
        return {}


def locations():
    """The canonical prefix and the copies directory (last component unresolved, to spot a link)."""
    home = Path.home()
    prefix = Path(os.environ.get("WINEPREFIX") or home / ".local/share/umu/default").resolve()
    override = os.environ.get("OMARCHY_TOOL_PROTON_SAVES_DIR")
    copies = Path(override) if override else Path(module_config().get("savesFolder") or home / "Documents") / COPIES_SUBFOLDER
    copies = copies.parent.resolve() / copies.name
    if copies == prefix or prefix in copies.parents:
        raise SavesError("la carpeta de copias no puede estar dentro del prefijo de Proton")
    if copies.is_symlink():
        raise SavesError("la carpeta de copias no puede ser un enlace")
    return prefix, copies


def excluded(name):
    return any(name == path or name.startswith(path + "/") for path in EXCLUDED)


def require_real_user_directory(prefix):
    """The prefix is canonical, so a link below it could only lead outside."""
    path = prefix
    for part in USER_DIRECTORY.split("/"):
        path = path / part
        if path.is_symlink():
            raise SavesError("el prefijo de Proton apunta fuera de su carpeta")


def scan_prefix(prefix):
    """Relative names and sizes of what a copy holds; links and special files never count."""
    require_real_user_directory(prefix)
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


def unmounted_disk(path):
    """Whether path lies on a disk fstab knows about and that isn't mounted now."""
    try:
        lines = FSTAB_FILE.read_text(errors="replace").splitlines()
    except OSError:
        return False
    for line in lines:
        fields = line.split()
        if len(fields) < 2 or fields[0].startswith("#") or not fields[1].startswith("/"):
            continue
        target = Path(fields[1].replace("\\040", " "))
        if (target == path or target in path.parents) and not os.path.ismount(target):
            return True
    return False


def folder_available(copies):
    """A chosen folder keeps its subfolder: without it the disk is probably not mounted,
    and creating it would write to the system disk. The default folder is made on demand."""
    chosen = module_config().get("savesFolder") and not os.environ.get("OMARCHY_TOOL_PROTON_SAVES_DIR")
    return not chosen or (copies.is_dir() and not unmounted_disk(copies))


def list_saves():
    prefix, copies = locations()
    exists = (prefix / USER_DIRECTORY).is_dir()
    return {"prefixExists": exists,
            "groups": group_entries(scan_prefix(prefix)) if exists else [],
            "copies": list_copies(copies),
            "folder": str(copies.parent),
            "folderAvailable": folder_available(copies),
            "folderChosen": bool(module_config().get("savesFolder")),
            "auto": module_config().get("savesAuto") is True}


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
        # tarfile reads a bad header as the end of the archive: check it really is,
        # then read on so the compressed stream's own end and checksum are verified.
        stream = archive.fileobj
        stream.seek(archive.offset)
        end = stream.read(tarfile.BLOCKSIZE)
        if len(end) != tarfile.BLOCKSIZE or any(end):
            raise SavesError("la copia está dañada")
        while chunk := stream.read(1 << 20):
            if any(chunk):
                raise SavesError("la copia está dañada")
    except (tarfile.TarError, EOFError, OSError, ValueError, zstd.ZstdError) as error:
        raise SavesError("la copia está dañada") from error
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
            with tarfile.open(fileobj=output, mode="w:zst", options={zstd.CompressionParameter.checksum_flag: 1}) as archive:
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


def require_ready(prefix, copies):
    if not folder_available(copies):
        raise SavesError("la carpeta de copias no está disponible; comprueba que el disco esté conectado")
    if proton_open():
        raise SavesError("cierra Proton antes de guardar o cargar")
    if not (prefix / USER_DIRECTORY).is_dir():
        raise SavesError("todavía no existe el prefijo de Proton; abre antes un programa con Proton")


def save_copy():
    prefix, copies = locations()
    require_ready(prefix, copies)
    if not group_entries(scan_prefix(prefix)):
        raise SavesError("no hay nada que guardar")
    return {"name": write_copy(prefix, copies, "partidas")}


def fingerprint(prefix, copies, entries):
    """Changes when a file or the destination does, without reading any contents."""
    user = prefix / USER_DIRECTORY
    digest = hashlib.sha256(str(copies).encode())
    for name, _ in entries:
        status = os.lstat(user / name)
        digest.update(f"\0{name}\0{status.st_size}\0{status.st_mtime_ns}".encode(errors="surrogateescape"))
    return digest.hexdigest()


def prune_automatic(copies, newest, keep=AUTO_KEEP):
    """Only automatic copies are ever deleted, the oldest first, and never the one just
    made: a corrected clock can make older copies look newer."""
    others = [copy for copy in list_copies(copies) if copy["kind"] == "automatica" and copy["name"] != newest]
    for copy in others[keep - 1:]:
        try:
            (copies / copy["name"]).unlink()
        except OSError:
            pass  # Retried at the next automatic copy.


def state_directory():
    home = Path.home()
    return Path(os.environ.get("OMARCHY_TOOL_STATE_DIR") or Path(os.environ.get("XDG_DATA_HOME") or home / ".local/share") / "omarchy-tool")


def fingerprint_file():
    return state_directory() / "exe-proton-saves.fingerprint"


def auto_copy():
    """The startup copy: nothing to do is not a failure, a missing disk is."""
    if module_config().get("savesAuto") is not True:
        return {"name": None}
    prefix, copies = locations()
    if not (prefix / USER_DIRECTORY).is_dir() or proton_open():
        return {"name": None}
    if not folder_available(copies):
        raise SavesError("la carpeta de copias no está disponible; comprueba que el disco esté conectado")
    entries = scan_prefix(prefix)
    if not group_entries(entries):
        return {"name": None}
    try:
        current = fingerprint(prefix, copies, entries)
        record = fingerprint_file()
        has_automatic = any(copy["kind"] == "automatica" for copy in list_copies(copies))
        if has_automatic and record.is_file() and record.read_text() == current:
            return {"name": None}
        name = write_copy(prefix, copies, "automatica")
        record.parent.mkdir(parents=True, exist_ok=True)
        record.write_text(current)
    except OSError as error:
        raise SavesError("no se pudo guardar la copia") from error
    prune_automatic(copies, name)
    return {"name": name}


def choose_folder(path):
    """Check a folder the user typed and make its subfolder; "" goes back to the default."""
    if not path:
        return {"folder": ""}
    folder = Path(path).expanduser()
    if not folder.is_absolute():
        raise SavesError("escribe la ruta completa de la carpeta")
    folder = folder.resolve()
    if not folder.is_dir():
        raise SavesError("esa carpeta no existe")
    prefix = Path(os.environ.get("WINEPREFIX") or Path.home() / ".local/share/umu/default").resolve()
    if folder == prefix or prefix in folder.parents:
        raise SavesError("la carpeta de copias no puede estar dentro del prefijo de Proton")
    for removed in (state_directory(), config_directory(), Path(__file__).resolve().parents[1]):
        removed = removed.resolve()
        if folder == removed or removed in folder.parents:
            raise SavesError("esa carpeta se borra al desinstalar; elige otra")
    if unmounted_disk(folder):
        raise SavesError("ese disco no está montado")
    copies = folder / COPIES_SUBFOLDER
    if copies.is_symlink():
        raise SavesError("la carpeta de copias no puede ser un enlace")
    try:
        private_directory(copies)
    except OSError as error:
        raise SavesError("no se pudo usar esa carpeta") from error
    return {"folder": str(folder)}


def validate_destinations(prefix, members):
    """Refuse a load that would go through a link or change what a path is."""
    require_real_user_directory(prefix)
    user = prefix / USER_DIRECTORY
    if not user.is_dir():
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
    require_ready(prefix, copies)
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
        elif argv == ["auto"]:
            result = auto_copy()
        elif len(argv) == 2 and argv[0] == "folder":
            result = choose_folder(argv[1])
        else:
            raise SavesError("acción de copias no válida")
    except SavesError as error:
        print(json.dumps({"error": error.source}))
        return 1
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
