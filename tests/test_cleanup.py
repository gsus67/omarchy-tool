"""System cleanup helper: what it finds and what it deletes, all in temporary folders."""
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "bin/cleanup.py"
spec = importlib.util.spec_from_file_location("cleanup_helper", HELPER)
cleanup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cleanup)
DAY = 86400


class CleanupCase(unittest.TestCase):
    def setUp(self):
        previous = os.umask(0o077)
        self.addCleanup(os.umask, previous)
        self.temporary = tempfile.TemporaryDirectory(prefix="cleanup-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.temp = self.root / "tmp"
        self.cache = self.root / "cache"
        self.proc = self.root / "proc"
        self.core = self.root / "coredump"
        self.journal = self.root / "journal"
        self.runtime_journal = self.root / "run-journal"
        self.bin = self.root / "bin"
        for path in (self.temp, self.cache, self.proc, self.core, self.journal, self.runtime_journal, self.bin):
            path.mkdir()
        self.environment = patch.dict(os.environ, {
            "HOME": str(self.root / "home"),
            "OMARCHY_TOOL_CONFIG_DIR": str(self.root / "config"),
            "OMARCHY_TOOL_CLEANUP_TEMP_DIR": str(self.temp),
            "OMARCHY_TOOL_CLEANUP_CACHE_DIR": str(self.cache),
            "OMARCHY_TOOL_CLEANUP_PROC_DIR": str(self.proc),
            "OMARCHY_TOOL_CLEANUP_COREDUMP_DIR": str(self.core),
            "OMARCHY_TOOL_CLEANUP_JOURNAL_DIR": str(self.journal),
            "OMARCHY_TOOL_CLEANUP_RUNTIME_JOURNAL_DIR": str(self.runtime_journal),
            "PATH": str(self.bin),
        })
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.now = os.stat(self.root).st_ctime + 2 * DAY

    def write(self, path, data=b"x" * 8192):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def process(self, pid="100", fds=None, cwd=None, exe=None, maps=""):
        """A synthetic /proc entry owned by this user."""
        directory = self.proc / pid
        (directory / "fd").mkdir(parents=True)
        for number, target in enumerate(fds or []):
            (directory / "fd" / str(number)).symlink_to(target)
        (directory / "cwd").symlink_to(cwd or "/")
        (directory / "exe").symlink_to(exe or "/usr/bin/true")
        (directory / "maps").write_text(maps)
        return directory

    def cli(self, *args, stdin=None):
        return subprocess.run([sys.executable, "-B", str(HELPER), *args], input=stdin, capture_output=True,
                              text=True, timeout=10, check=False)


class Measuring(CleanupCase):
    def test_sparse_usage_counts_allocated_blocks(self):
        sparse = self.write(self.temp / "sparse", b"")
        os.truncate(sparse, 50 * 1024 * 1024)
        self.assertEqual(cleanup.allocated_bytes(sparse), sparse.lstat().st_blocks * 512)
        self.assertLess(cleanup.allocated_bytes(sparse), sparse.lstat().st_size)

    def test_usage_of_a_folder_does_not_follow_links(self):
        outside = self.write(self.root / "outside/big", b"x" * 65536)
        folder = self.temp / "folder"
        self.write(folder / "own", b"x" * 8192)
        (folder / "link").symlink_to(outside.parent)
        self.assertLess(cleanup.allocated_bytes(folder), 65536)


class InUse(CleanupCase):
    def setUp(self):
        super().setUp()
        self.entry = self.temp / "entry"
        self.inner = self.write(self.entry / "inner")

    def test_nothing_open_means_free(self):
        self.process(fds=["/somewhere/else"])
        self.assertFalse(cleanup.is_in_use(self.entry, self.proc))

    def test_a_similar_name_is_not_the_same_entry(self):
        self.process(fds=[str(self.temp / "entry-2/file")])
        self.assertFalse(cleanup.is_in_use(self.entry, self.proc))

    def test_open_file_inside_counts(self):
        self.process(fds=[str(self.inner)])
        self.assertTrue(cleanup.is_in_use(self.entry, self.proc))

    def test_working_directory_inside_counts(self):
        self.process(cwd=str(self.entry))
        self.assertTrue(cleanup.is_in_use(self.entry, self.proc))

    def test_running_program_and_loaded_library_count(self):
        self.process(pid="100", exe=str(self.inner))
        self.assertTrue(cleanup.is_in_use(self.entry, self.proc))
        (self.proc / "100/exe").unlink()
        (self.proc / "100/exe").symlink_to("/usr/bin/true")
        (self.proc / "100/maps").write_text(f"7f00-7f10 r-xp 00000000 08:01 42   {self.inner}\n")
        self.assertTrue(cleanup.is_in_use(self.entry, self.proc))

    def test_deleted_open_target_counts(self):
        self.process(fds=[f"{self.inner} (deleted)"])
        self.assertTrue(cleanup.is_in_use(self.entry, self.proc))

    def test_uninspectable_own_process_counts(self):
        self.process()
        real = os.listdir

        def denied(path):
            if str(path).endswith("/100/fd"):
                raise PermissionError(13, "denied")
            return real(path)

        with patch.object(cleanup.os, "listdir", side_effect=denied):
            self.assertTrue(cleanup.is_in_use(self.entry, self.proc))

    def test_processes_of_other_users_are_not_inspected(self):
        self.process(fds=[str(self.inner)])
        real = os.stat

        def foreign(path, *args, **kwargs):
            result = real(path, *args, **kwargs)
            if str(path).endswith("/proc/100"):
                values = list(result)
                values[4] = os.getuid() + 1
                return os.stat_result(values)
            return result

        with patch.object(cleanup.os, "stat", side_effect=foreign):
            self.assertFalse(cleanup.is_in_use(self.entry, self.proc))

    def test_a_process_that_ended_does_not_count(self):
        self.process()
        real = os.listdir

        def gone(path):
            if str(path).endswith("/100/fd"):
                raise FileNotFoundError(2, "gone")
            return real(path)

        with patch.object(cleanup.os, "listdir", side_effect=gone):
            (self.proc / "100/cwd").unlink()
            (self.proc / "100/exe").unlink()
            (self.proc / "100/maps").unlink()
            self.assertFalse(cleanup.is_in_use(self.entry, self.proc))

    def test_unreadable_proc_root_counts_as_in_use(self):
        self.assertTrue(cleanup.is_in_use(self.entry, self.root / "no-proc"))


class Temporales(CleanupCase):
    def old_entry(self, name="old", data=b"x" * 8192):
        return self.write(self.temp / name / "file", data).parent

    def test_old_unused_entries_are_listed_and_removed(self):
        old = self.old_entry()
        loose = self.write(self.temp / "loose")
        category = cleanup.scan_temp(now=self.now)
        self.assertEqual(category["id"], "tmp")
        self.assertEqual(category["count"], 2)
        self.assertEqual(category["bytes"], cleanup.allocated_bytes(old) + cleanup.allocated_bytes(loose))
        result = cleanup.clean_temp(now=self.now)
        self.assertFalse(old.exists())
        self.assertFalse(loose.exists())
        self.assertEqual(result["freedBytes"], category["bytes"])
        self.assertEqual(result["skippedCount"], 0)

    def test_a_recent_file_inside_keeps_the_whole_entry(self):
        recent = self.old_entry("recent")
        self.assertIsNone(cleanup.scan_temp(now=os.stat(recent).st_ctime + 3600))
        cleanup.clean_temp(now=os.stat(recent).st_ctime + 3600)
        self.assertTrue(recent.exists())

    def test_touching_mtime_back_does_not_make_an_entry_old(self):
        entry = self.old_entry("touched")
        os.utime(entry / "file", (0, 0))
        os.utime(entry, (0, 0))
        self.assertIsNone(cleanup.scan_temp(now=os.stat(entry / "file").st_ctime + 3600))

    def test_entries_of_other_users_are_left_alone(self):
        foreign = self.old_entry("foreign")
        real = os.lstat

        def not_mine(path, *args, **kwargs):
            result = real(path, *args, **kwargs)
            if str(path).endswith("/foreign"):
                values = list(result)
                values[4] = os.getuid() + 1
                return os.stat_result(values)
            return result

        with patch.object(cleanup.os, "lstat", side_effect=not_mine):
            cleanup.clean_temp(now=self.now)
        self.assertTrue(foreign.exists())

    def test_a_link_at_the_top_is_never_followed(self):
        outside = self.write(self.root / "outside/keep", b"keep")
        (self.temp / "link").symlink_to(outside.parent)
        self.assertIsNone(cleanup.scan_temp(now=self.now))
        cleanup.clean_temp(now=self.now)
        self.assertEqual(outside.read_bytes(), b"keep")
        self.assertTrue((self.temp / "link").is_symlink())

    def test_a_link_inside_is_removed_without_touching_its_target(self):
        outside = self.write(self.root / "outside/keep", b"keep")
        entry = self.old_entry()
        (entry / "link").symlink_to(outside.parent)
        cleanup.clean_temp(now=self.now)
        self.assertFalse(entry.exists())
        self.assertEqual(outside.read_bytes(), b"keep")

    def test_sockets_are_skipped_by_name(self):
        path = str(self.temp / "s")
        with socket.socket(socket.AF_UNIX) as server:
            server.bind(path)
            self.old_entry()
            result = cleanup.clean_temp(now=self.now)
        self.assertTrue(os.path.lexists(path))
        self.assertIn("s", result["skippedNames"])

    def test_a_socket_inside_keeps_the_whole_entry(self):
        entry = self.temp / "with-socket"
        entry.mkdir()
        with socket.socket(socket.AF_UNIX) as server:
            server.bind(str(entry / "s"))
            result = cleanup.clean_temp(now=self.now)
        self.assertTrue(entry.exists())
        self.assertEqual(result["skippedNames"], ["with-socket"])

    def test_an_unreadable_folder_is_skipped_by_name(self):
        entry = self.old_entry("locked")
        real = os.scandir

        def denied(path):
            if isinstance(path, (str, os.PathLike)) and str(path).endswith("/locked"):
                raise PermissionError(13, "denied")
            return real(path)

        with patch.object(cleanup.os, "scandir", side_effect=denied):
            result = cleanup.clean_temp(now=self.now)
        self.assertTrue(entry.exists())
        self.assertEqual(result["skippedNames"], ["locked"])

    def test_an_entry_that_became_active_after_the_listing_stays(self):
        entry = self.old_entry()
        self.assertEqual(cleanup.scan_temp(now=self.now)["count"], 1)
        self.process(fds=[str(entry / "file")])
        result = cleanup.clean_temp(now=self.now)
        self.assertTrue(entry.exists())
        self.assertEqual(result, {"freedBytes": 0, "skippedCount": 1, "skippedNames": ["old"]})

    def test_a_failure_midway_keeps_accurate_totals(self):
        first = self.old_entry("a")
        second = self.old_entry("b")
        expected = cleanup.allocated_bytes(first)
        real = cleanup.remove_entry

        def fail_on_b(directory, name, identity):
            if name == "b":
                raise PermissionError(13, "denied")
            return real(directory, name, identity)

        with patch.object(cleanup, "remove_entry", side_effect=fail_on_b):
            result = cleanup.clean_temp(now=self.now)
        self.assertFalse(first.exists())
        self.assertTrue(second.exists())
        self.assertEqual(result, {"freedBytes": expected, "skippedCount": 1, "skippedNames": ["b"]})

    def test_replacing_a_folder_with_a_link_before_deleting_touches_nothing_outside(self):
        outside = self.write(self.root / "outside/keep", b"keep")
        entry = self.old_entry()
        identity = (entry.lstat().st_dev, entry.lstat().st_ino)
        (entry / "file").unlink()
        entry.rmdir()
        entry.symlink_to(outside.parent)
        descriptor = os.open(self.temp, os.O_RDONLY | os.O_DIRECTORY)
        self.addCleanup(os.close, descriptor)
        with self.assertRaises(OSError):
            cleanup.remove_entry(descriptor, "old", identity)
        self.assertEqual(outside.read_bytes(), b"keep")

    def test_nothing_to_clean_omits_the_category(self):
        self.assertIsNone(cleanup.scan_temp(now=self.now))


class Protocol(CleanupCase):
    def test_failure_is_one_json_object(self):
        result = self.cli("unknown")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(result.stdout.splitlines()), 1)
        self.assertEqual(json.loads(result.stdout), {"error": "acción de limpieza no válida"})

    def test_listing_is_one_json_object(self):
        self.write(self.temp / "fresh")
        result = self.cli("list")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"categories": []})

    def test_every_category_field_exists(self):
        self.write(self.temp / "old")
        with patch.object(cleanup.time, "time", return_value=self.now):
            category = cleanup.scan_temp()
        self.assertEqual(set(category), {"id", "title", "summary", "warning", "bytes", "count", "requiresPassword",
                                         "names", "revision", "rows"})

    def test_defaults_follow_the_system(self):
        with patch.dict(os.environ, {"OMARCHY_TOOL_CLEANUP_TEMP_DIR": "", "OMARCHY_TOOL_CLEANUP_CACHE_DIR": "",
                                     "OMARCHY_TOOL_CLEANUP_PROC_DIR": "", "XDG_CACHE_HOME": ""}):
            places = cleanup.locations()
        self.assertEqual(places["temp"], Path("/tmp"))
        self.assertEqual(places["cache"], self.root / "home/.cache")
        self.assertEqual(places["proc"], Path("/proc"))

    def test_catalog_has_every_source_in_english(self):
        catalog = json.loads((ROOT / "i18n/messages.json").read_text())["en"]
        for source in cleanup.CATALOG_SOURCES:
            with self.subTest(source=source):
                self.assertIn(source, catalog)


if __name__ == "__main__":
    unittest.main()
