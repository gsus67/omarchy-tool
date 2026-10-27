"""Lifecycle tests: exact restoration, user edits, partial failure and lost checkout."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("disk_tiles_manage", ROOT / "bin/disk-tiles.py")
manage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manage)


class DiskTilesLifecycle(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="disk-tiles-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.environment = patch.dict(os.environ, {"XDG_DATA_HOME": str(self.root / "data"),
                                                  "XDG_CONFIG_HOME": str(self.root / "config")})
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.state = self.root / "state/disk-tiles"
        self.source = ROOT / "nautilus/disk_tiles.py"
        self.extension, self.bookmark = manage.locations()

    def enable(self):
        manage.enable(self.state, self.source)

    def write_bookmarks(self, data):
        self.bookmark.parent.mkdir(parents=True, exist_ok=True)
        self.bookmark.write_bytes(data)

    def test_new_install_returns_filesystem_to_original(self):
        self.enable()
        self.assertTrue(self.extension.is_file())
        self.assertIn("STATE_DIRECTORY = " + repr(str(self.state)), self.extension.read_text())
        self.assertTrue((self.state / "enabled").exists())
        manage.disable(self.state)
        self.assertFalse(self.extension.exists())
        self.assertFalse(self.bookmark.exists())
        self.assertFalse(self.state.exists())
        self.assertFalse((self.root / "data").exists())
        self.assertFalse((self.root / "config").exists())
        manage.disable(self.state)  # Idempotent, including after checkout deletion.

    def test_existing_bookmarks_restored_byte_for_byte_and_mode(self):
        before = b"file:///tmp user folder\n# comment without final newline"
        self.write_bookmarks(before)
        self.bookmark.chmod(0o640)
        self.enable()
        self.enable()
        self.assertEqual(self.bookmark.read_bytes().count(b"computer:///"), 1)
        manage.disable(self.state)
        self.assertEqual(self.bookmark.read_bytes(), before)
        self.assertEqual(self.bookmark.stat().st_mode & 0o777, 0o640)

    def test_existing_computer_bookmark_is_never_owned(self):
        before = b"computer:/// Custom name\nfile:///tmp My folder\n"
        self.write_bookmarks(before)
        self.enable()
        manage.disable(self.state)
        self.assertEqual(self.bookmark.read_bytes(), before)

    def test_user_edits_while_enabled_are_kept(self):
        self.write_bookmarks(b"file:///tmp Original\n")
        self.enable()
        self.bookmark.write_bytes(self.bookmark.read_bytes() + b"file:///mnt/data Added later\n")
        manage.disable(self.state)
        self.assertEqual(self.bookmark.read_bytes(), b"file:///tmp Original\nfile:///mnt/data Added later\n")

    def test_user_renamed_computer_bookmark_is_kept(self):
        self.enable()
        self.bookmark.write_bytes(b"computer:/// User renamed this\n")
        manage.disable(self.state)
        self.assertEqual(self.bookmark.read_bytes(), b"computer:/// User renamed this\n")

    def test_foreign_extension_never_overwritten(self):
        self.extension.parent.mkdir(parents=True)
        self.extension.write_text("preexisting")
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.enable()
        self.assertEqual(self.extension.read_text(), "preexisting")

    def test_edited_extension_blocks_cleanup_and_retains_ledger(self):
        self.enable()
        original = self.extension.read_bytes()
        self.extension.write_bytes(original + b"\n# user changed this\n")
        with self.assertRaisesRegex(ValueError, "edited"):
            manage.disable(self.state)
        self.assertTrue((self.state / "owned.json").exists())
        self.extension.write_bytes(original)
        manage.disable(self.state)
        self.assertFalse(self.state.exists())

    def test_bookmark_replacement_by_symlink_is_not_followed(self):
        self.enable()
        self.bookmark.unlink()
        outside = self.root / "outside"
        outside.write_text("private file")
        self.bookmark.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "symlink"):
            manage.disable(self.state)
        self.assertEqual(outside.read_text(), "private file")
        self.assertTrue((self.state / "owned.json").exists())
        self.bookmark.unlink()
        manage.disable(self.state)

    def test_partial_install_can_be_cleaned(self):
        real_atomic = manage.atomic
        def fail_extension(path, data):
            if path == self.extension: raise OSError("disk full")
            return real_atomic(path, data)
        with patch.object(manage, "atomic", side_effect=fail_extension):
            with self.assertRaises(OSError): self.enable()
        self.assertTrue((self.state / "owned.json").exists())
        manage.disable(self.state)
        self.assertFalse(self.bookmark.exists())
        self.assertFalse(self.state.exists())

    def test_ledger_keeps_original_across_source_update(self):
        self.write_bookmarks(b"file:///tmp Original\n")
        self.enable()
        updated = self.root / "update.py"
        updated.write_text(self.source.read_text() + "\n# update\n")
        manage.enable(self.state, updated)
        self.assertTrue(self.extension.read_text().endswith("# update\n"))
        manage.disable(self.state)
        self.assertEqual(self.bookmark.read_bytes(), b"file:///tmp Original\n")

    def test_cleanup_copy_works_after_plugin_checkout_is_gone(self):
        import subprocess
        self.enable()
        copied = self.state / "manage.py"
        copied.write_bytes((ROOT / "bin/disk-tiles.py").read_bytes())
        result = subprocess.run(["python3", "-B", str(copied), "disable", str(self.state)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.state.exists())

    def test_changed_xdg_location_requires_restoration_first(self):
        self.enable()
        with patch.dict(os.environ, {"XDG_DATA_HOME": str(self.root / "different")}):
            with self.assertRaisesRegex(ValueError, "XDG locations changed"):
                self.enable()
            # Cleanup uses the recorded paths, even when the environment changed.
            manage.disable(self.state)
        self.assertFalse(self.extension.exists())

    def test_only_owned_bytecode_is_removed(self):
        self.enable()
        cache = self.extension.parent / "__pycache__"
        cache.mkdir()
        own = cache / "omarchy-tool-disk-tiles.cpython-314.pyc"
        other = cache / "another-extension.cpython-314.pyc"
        own.write_bytes(b"ours")
        other.write_bytes(b"user's extension")
        manage.disable(self.state)
        self.assertFalse(own.exists())
        self.assertEqual(other.read_bytes(), b"user's extension")

    def test_runtime_distinguishes_installed_from_loaded_and_rejects_stale_marker(self):
        self.enable()
        proc_root = self.root / "proc"
        proc = proc_root / "456"
        proc.mkdir(parents=True)
        (proc / "comm").write_text("nautilus\n")
        (proc / "environ").write_bytes(("XDG_DATA_HOME=" + os.environ["XDG_DATA_HOME"] + "\0XDG_CONFIG_HOME="
                                       + os.environ["XDG_CONFIG_HOME"] + "\0").encode())
        (proc / "stat").write_text("456 (nautilus) " + " ".join(["S"] + ["0"] * 18 + ["1234"]))
        self.assertEqual(manage.runtime(self.state, proc_root),
                         {"ready": False, "restartRequired": True, "nautilusRunning": True})
        marker = self.state / "loaded-456.json"
        valid = {"pid": 456, "start": "1234", "hash": json.loads((self.state / "owned.json").read_text())["hash"]}
        marker.write_text(json.dumps(valid))
        self.assertTrue(manage.runtime(self.state, proc_root)["ready"])
        for wrong in ({"start": "old-process"}, {"hash": "old-source"}, {"pid": 457}):
            marker.write_text(json.dumps(valid | wrong))
            self.assertFalse(manage.runtime(self.state, proc_root)["ready"])
            self.assertTrue(manage.runtime(self.state, proc_root)["restartRequired"])
        (proc / "environ").write_bytes(b"XDG_DATA_HOME=/another-profile\0XDG_CONFIG_HOME=/another-profile\0")
        self.assertFalse(manage.runtime(self.state, proc_root)["nautilusRunning"])
        manage.disable(self.state)
        self.assertFalse(self.state.exists())

    def test_installed_without_running_nautilus_waits_for_open_not_restart(self):
        self.enable()
        proc_root = self.root / "empty-proc"
        proc_root.mkdir()
        self.assertEqual(manage.runtime(self.state, proc_root),
                         {"ready": False, "restartRequired": False, "nautilusRunning": False})

    def test_cleanup_removes_interrupted_runtime_marker_temporary(self):
        self.enable()
        (self.state / ".loaded-interrupted").write_text("partial")
        manage.disable(self.state)
        self.assertFalse(self.state.exists())

    def test_uninstaller_keeps_state_if_privileged_cleanup_fails(self):
        import subprocess
        for kind in ("compose", "webhid"):
            with self.subTest(kind=kind):
                state = self.root / kind
                state.mkdir()
                helper = state / ("compose-edit.sh" if kind == "compose" else "udev-webhid.sh")
                helper.write_text("#!/bin/bash\nexit 23\n")
                rules = self.root / "fake-udev.rules"
                rules.touch()
                if kind == "compose": (state / "compose.applied").write_text("1\n")
                env = dict(os.environ, OMARCHY_TOOL_STATE_DIR=str(state),
                           OMARCHY_TOOL_CONFIG_DIR=str(self.root / "tool-config"),
                           OMARCHY_TOOL_PRIV="", OMARCHY_TOOL_UDEV_RULES=str(rules))
                result = subprocess.run(["bash", str(ROOT / "bin/uninstall.sh")], env=env,
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertTrue(helper.exists(), "failed cleanup must retain its helper for retry")

    def test_tool_switch_and_external_uninstaller_full_lifecycle(self):
        import shlex
        import subprocess
        import sys
        commands = self.root / "fake-bin"
        commands.mkdir()
        notice_log = self.root / "notices.log"
        # Probe package versions and bindings without requiring GTK in unit CI.
        for name, script in {
            "nautilus": "#!/bin/sh\nexit 0\n",
            "pacman": '#!/bin/sh\n[ "${DISK_TILES_TEST_PROBE_FAIL:-0}" != 1 ] || exit 1\nprintf "nautilus 51.1-1\\nnautilus-python 4.2.0-1\\n"\n',
            "python3": "#!/bin/sh\nif [ \"$1\" = -B ] && [ \"$2\" = -c ]; then exit 0; fi\nexec " + shlex.quote(sys.executable) + ' "$@"\n',
            "omarchy-notification-send": '#!/bin/sh\nprintf "%s\\n" "$*" >> "$DISK_TILES_TEST_NOTICES"\n',
        }.items():
            file = commands / name
            file.write_text(script)
            file.chmod(0o755)
        runtime = self.root / "runtime"
        runtime.mkdir()
        state = self.root / "tool-state"
        config = self.root / "tool-config"
        env = dict(os.environ, PATH=str(commands) + ":" + os.environ["PATH"], LC_ALL="C.UTF-8",
                   DISK_TILES_TEST_NOTICES=str(notice_log),
                   XDG_RUNTIME_DIR=str(runtime), OMARCHY_TOOL_STATE_DIR=str(state),
                   OMARCHY_TOOL_CONFIG_DIR=str(config), OMARCHY_TOOL_WINDOWS_SHARED=str(self.root / "shared"),
                   OMARCHY_TOOL_APPLICATIONS_DIR=str(self.root / "applications"),
                   OMARCHY_TOOL_MENU_FILE=str(self.root / "menu.jsonc"),
                   OMARCHY_TOOL_HYPR_DIR=str(self.root / "hypr"),
                   OMARCHY_TOOL_UDEV_RULES=str(self.root / "rules"),
                   OMARCHY_TOOL_EXE_BIN_DIR=str(self.root / "system-bin"),
                   OMARCHY_TOOL_THUMBNAILERS_DIR=str(self.root / "thumbnailers"))
        def tool(*arguments):
            result = subprocess.run([str(ROOT / "bin/omarchy-tool"), *arguments], env=env,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            return result
        tool("disk-tiles", "enable")
        notices = notice_log.read_text().splitlines()
        self.assertEqual(len(notices), 2)
        self.assertIn("Preparing and enabling Disk tiles", notices[0])
        self.assertIn("Installation finished", notices[1])
        self.assertTrue(json.loads(tool("disk-tiles", "status").stdout)["applied"])
        self.assertTrue(self.extension.is_file())
        tool("disk-tiles", "disable")
        self.assertIn("Cleanup finished", notice_log.read_text().splitlines()[-1])
        self.assertFalse(self.extension.exists())
        self.assertFalse((state / "disk-tiles").exists())
        tool("disk-tiles", "enable")
        copied = state / "uninstall.sh"
        result = subprocess.run(["bash", str(copied)], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.extension.exists())
        self.assertFalse(self.bookmark.exists())
        self.assertFalse(state.exists())
        self.assertFalse(config.exists())
        notice_log.write_text("")
        failed = subprocess.run([str(ROOT / "bin/omarchy-tool"), "disk-tiles", "enable"],
                                env=env | {"DISK_TILES_TEST_PROBE_FAIL": "1"}, capture_output=True, text=True)
        self.assertNotEqual(failed.returncode, 0)
        notices = notice_log.read_text().splitlines()
        self.assertEqual(len(notices), 2)
        self.assertIn("Preparing and enabling", notices[0])
        self.assertIn("-u critical", notices[1])
        self.assertIn("Could not complete", notices[1])
        self.assertFalse(self.extension.exists())


if __name__ == "__main__": unittest.main()
