#!/usr/bin/env python3
"""Remove only GNOME failed thumbnails whose Thumb::URI is an EXE/MSI/DLL."""
from pathlib import Path
import struct
import sys
import zlib


def windows_failure(path):
    """GNOME stores thumbnail metadata in PNG tEXt chunks, not image pixels."""
    with path.open("rb") as png:
        if png.read(8) != b"\x89PNG\r\n\x1a\n":
            return False
        while header := png.read(8):
            if len(header) != 8:
                return False
            size, kind = struct.unpack(">I4s", header)
            # Failed thumbnails are tiny; leave corrupt or oversized files alone.
            if size > 1024 * 1024:
                return False
            data, crc = png.read(size), png.read(4)
            if len(data) != size or len(crc) != 4:
                return False
            if zlib.crc32(kind + data) != struct.unpack(">I", crc)[0]:
                return False
            if kind == b"tEXt":
                key, sep, value = data.partition(b"\0")
                if sep and key == b"Thumb::URI":
                    return value.lower().endswith((b".exe", b".msi", b".dll"))
            if kind == b"IEND":
                return False
    return False


def clean(directory):
    if not directory.is_dir():
        return
    for path in directory.glob("*.png"):
        try:
            if not path.is_symlink() and path.is_file() and windows_failure(path):
                path.unlink()
        except OSError:
            # Cache entries can disappear while Files updates them.
            continue


if __name__ == "__main__":
    clean(Path(sys.argv[1]))
