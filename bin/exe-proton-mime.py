#!/usr/bin/env python3
"""Own the user desktop handler and remember/restore each Windows MIME default."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

MIMES = (
    "application/x-ms-dos-executable",
    "application/vnd.microsoft.portable-executable",
    "application/x-msdownload",
    "application/x-msi",
    "application/x-ms-installer",
)
DESKTOP = "omarchy-tool-run-exe.desktop"
LEGACY_HASH = "b6c77d4cffcf24a3160909ccd6d99ccbc129af65dc120b2d1f6b80a81ea5e6fb"
HOME = Path.home()
DATA = Path(os.environ.get("XDG_DATA_HOME", HOME / ".local/share"))
CONFIG = Path(os.environ.get("XDG_CONFIG_HOME", HOME / ".config"))
APPS = Path(os.environ.get("OMARCHY_TOOL_APPLICATIONS_DIR", DATA / "applications"))
LEGACY_SCRIPT = HOME / ".local/bin/run-exe"
LEGACY_ENTRY = DATA / "applications/run-exe.desktop"


def adoptable():
    if not LEGACY_SCRIPT.is_file() or not LEGACY_ENTRY.is_file():
        return False
    return (hashlib.sha256(LEGACY_SCRIPT.read_bytes()).hexdigest() == LEGACY_HASH
            and f"Exec={LEGACY_SCRIPT} %f" in LEGACY_ENTRY.read_text().splitlines())


def xdg(*args):
    return subprocess.run(["xdg-mime", *args], check=True, text=True,
                          stdout=subprocess.PIPE).stdout.strip()


def desktop_quote(path):
    # Desktop Exec quoting has two escaping layers (entry value, then argv).
    value = str(path).replace("%", "%%")
    for char in ("\\", '"', '`', '$'):
        value = value.replace(char, "\\" + char)
    return '"' + value.replace("\\", "\\\\") + '"'


def forget_handler(handler):
    # xdg-mime has no unset operation. Remove just this handler's tokens from
    # user mimeapps files, preserving unrelated defaults, comments and groups.
    files = set(CONFIG.glob("*mimeapps.list")) | set((DATA / "applications").glob("*mimeapps.list"))
    files |= {DATA / "applications/defaults.list"}
    for path in files:
        if not path.is_file():
            continue
        lines, group = [], ""
        for line in path.read_text().splitlines(keepends=True):
            if line.strip().startswith("["):
                group = line.strip()
            key, sep, value = line.partition("=")
            if (group in ("[Default Applications]", "[Added Associations]", "[Removed Associations]")
                    and sep and key.strip() in MIMES):
                tokens = [token for token in value.strip().split(";") if token]
                if handler in tokens:
                    tokens = [token for token in tokens if token != handler]
                    if not tokens:
                        continue
                    line = key + "=" + ";".join(tokens) + ";\n"
            lines.append(line)
        new = "".join(lines)
        if new != path.read_text():
            path.write_text(new)


def apply(state):
    record = state / "defaults.json"
    adopt = adoptable()
    # Save all types before the first mutation, never overwrite on reapply.
    if not record.exists():
        previous = {mime: xdg("query", "default", mime) for mime in MIMES}
        if adopt:
            previous = {mime: "" if value == "run-exe.desktop" else value
                        for mime, value in previous.items()}
        tmp = state / "defaults.json.tmp"
        tmp.write_text(json.dumps(previous) + "\n")
        tmp.replace(record)
    if adopt:
        LEGACY_ENTRY.unlink()
        LEGACY_SCRIPT.unlink()
        forget_handler("run-exe.desktop")
    APPS.mkdir(parents=True, exist_ok=True)
    (APPS / DESKTOP).write_text(
        "[Desktop Entry]\nType=Application\nName=Ejecutar con Proton\n"
        "Name[en]=Run with Proton\n"
        f"Exec=/usr/bin/bash {desktop_quote(state / 'run-exe')} %f\n"
        "Icon=wine\nNoDisplay=true\nTerminal=false\n"
        f"MimeType={';'.join(MIMES)};\n")
    for mime in MIMES:
        xdg("default", DESKTOP, mime)


def remove(state):
    record = state / "defaults.json"
    if not record.exists():
        return
    previous = json.loads(record.read_text())
    forget_handler(DESKTOP)
    for mime in MIMES:
        if previous.get(mime):
            xdg("default", previous[mime], mime)


if __name__ == "__main__":
    action, directory = sys.argv[1:]
    if action == "adoptable":
        sys.exit(0 if adoptable() else 1)
    if action == "apply":
        apply(Path(directory))
    elif action == "remove":
        remove(Path(directory))
    else:
        sys.exit(1)
