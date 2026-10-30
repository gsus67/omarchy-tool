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
        (self.proc / "self").mkdir()
        (self.proc / "self/mountinfo").write_text("")
        self.now = os.stat(self.root).st_ctime + 2 * DAY

    def write(self, path, data=b"x" * 8192):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def process(self, pid="100", fds=None, cwd=None, exe=None, maps="", comm="programa"):
        """A synthetic /proc entry owned by this user."""
        directory = self.proc / pid
        (directory / "fd").mkdir(parents=True)
        (directory / "comm").write_text(comm + "\n")
        for number, target in enumerate(fds or []):
            (directory / "fd" / str(number)).symlink_to(target)
        (directory / "cwd").symlink_to(cwd or "/")
        (directory / "exe").symlink_to(exe or "/usr/bin/true")
        (directory / "maps").write_text(maps)
        return directory

    def deep_tree(self, path):
        """Deeper than Python's recursion limit, lowered so no runner's open file limit matters."""
        limit = sys.getrecursionlimit()
        sys.setrecursionlimit(120)
        self.addCleanup(sys.setrecursionlimit, limit)
        path.mkdir()
        for _ in range(180):
            path = path / "d"
            path.mkdir()

    def cli(self, *args, stdin=None):
        return subprocess.run([sys.executable, "-B", str(HELPER), *args], input=stdin, capture_output=True,
                              text=True, timeout=10, check=False)


class Measuring(CleanupCase):
    def test_sparse_usage_counts_allocated_blocks(self):
        sparse = self.write(self.temp / "sparse", b"")
        os.truncate(sparse, 50 * 1024 * 1024)
        self.assertEqual(cleanup.allocated_bytes(sparse), sparse.lstat().st_blocks * 512)
        self.assertLess(cleanup.allocated_bytes(sparse), sparse.lstat().st_size)

    def test_hard_links_are_not_counted_twice(self):
        one = self.write(self.temp / "folder/one", b"x" * 8192)
        os.link(one, self.temp / "folder/two")
        size = one.lstat().st_blocks * 512
        self.assertEqual(cleanup.allocated_bytes(self.temp / "folder"),
                         size + (self.temp / "folder").lstat().st_blocks * 512)

    def test_a_very_deep_folder_is_not_a_crash(self):
        self.deep_tree(self.temp / "deep")
        self.assertGreaterEqual(cleanup.allocated_bytes(self.temp / "deep"), 0)

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

    def test_the_session_managers_being_unreadable_blocks_nothing(self):
        for pid, name in (("100", "systemd"), ("101", "(sd-pam)")):
            self.process(pid=pid, comm=name)
        real = os.listdir

        def denied(path):
            if str(path).endswith(("/100/fd", "/101/fd")):
                raise PermissionError(13, "denied")
            return real(path)

        with patch.object(cleanup.os, "listdir", side_effect=denied):
            self.assertFalse(cleanup.is_in_use(self.entry, self.proc))

    def test_a_process_ending_while_read_does_not_block(self):
        self.process()
        real = os.listdir

        def ended(path):
            if str(path).endswith("/100/fd"):
                raise ProcessLookupError(3, "ended")
            return real(path)

        with patch.object(cleanup.os, "listdir", side_effect=ended):
            self.assertFalse(cleanup.is_in_use(self.entry, self.proc))

    def test_a_mount_inside_counts_as_in_use(self):
        (self.proc / "self/mountinfo").write_text(f"36 35 98:0 / {self.entry}/remote rw,noatime - fuse.sshfs host rw\n")
        self.assertTrue(cleanup.is_in_use(self.entry, self.proc))

    def test_a_mount_with_a_space_in_its_path_counts(self):
        spaced = self.temp / "con espacio"
        spaced.mkdir()
        (self.proc / "self/mountinfo").write_text(f"36 35 98:0 / {self.temp}/con\\040espacio rw - fuse.x y rw\n")
        self.assertTrue(cleanup.is_in_use(spaced, self.proc))

    def test_unreadable_mounts_count_as_in_use(self):
        (self.proc / "self/mountinfo").unlink()
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
        # Made first, so the file system can't hand the link the folder's old inode.
        link = self.temp / "new-link"
        link.symlink_to(outside.parent)
        (entry / "file").unlink()
        entry.rmdir()
        os.replace(link, entry)
        descriptor = os.open(self.temp, os.O_RDONLY | os.O_DIRECTORY)
        self.addCleanup(os.close, descriptor)
        with self.assertRaises(OSError):
            cleanup.remove_entry(descriptor, "old", identity)
        self.assertEqual(outside.read_bytes(), b"keep")

    def test_another_disk_inside_an_entry_is_never_entered(self):
        entry = self.old_entry()
        inner = self.write(entry / "remote/file", b"keep")
        real_scandir = os.scandir

        class Foreign:
            def __init__(self, item):
                self.item = item
                self.name = item.name
                self.path = item.path

            def stat(self, follow_symlinks=True):
                values = list(self.item.stat(follow_symlinks=follow_symlinks))
                values[2] += 1
                return os.stat_result(values)

        class Listing:
            def __init__(self, listing):
                self.listing = listing

            def __enter__(self):
                return [Foreign(item) if item.name == "remote" else item for item in self.listing]

            def __exit__(self, *details):
                self.listing.close()

        with patch.object(cleanup.os, "scandir", side_effect=lambda path: Listing(real_scandir(path))):
            self.assertIsNone(cleanup.scan_temp(now=self.now))
            result = cleanup.clean_temp(now=self.now)
        self.assertEqual(inner.read_bytes(), b"keep")
        self.assertEqual(result["skippedNames"], ["old"])

    def test_removing_refuses_to_cross_into_another_disk(self):
        entry = self.old_entry()
        inner = self.write(entry / "remote/file", b"keep")
        real_scandir = os.scandir

        class Foreign:
            def __init__(self, item):
                self.item = item
                self.name = item.name
                self.path = item.path

            def stat(self, follow_symlinks=True):
                values = list(self.item.stat(follow_symlinks=follow_symlinks))
                values[2] += 1
                return os.stat_result(values)

        class Listing:
            def __init__(self, listing):
                self.listing = listing

            def __enter__(self):
                return [Foreign(item) if item.name == "remote" else item for item in self.listing]

            def __exit__(self, *details):
                self.listing.close()

        status = entry.lstat()
        descriptor = os.open(self.temp, os.O_RDONLY | os.O_DIRECTORY)
        self.addCleanup(os.close, descriptor)
        with patch.object(cleanup.os, "scandir", side_effect=lambda path: Listing(real_scandir(path))):
            with self.assertRaises(OSError):
                cleanup.remove_entry(descriptor, "old", (status.st_dev, status.st_ino))
        self.assertEqual(inner.read_bytes(), b"keep")

    def test_lock_files_are_left_alone(self):
        self.write(self.temp / ".X0-lock")
        self.write(self.temp / "uv-123.lock")
        self.assertIsNone(cleanup.scan_temp(now=self.now))
        result = cleanup.clean_temp(now=self.now)
        self.assertTrue((self.temp / ".X0-lock").exists())
        self.assertTrue((self.temp / "uv-123.lock").exists())
        self.assertEqual(result["skippedCount"], 0)

    def test_a_very_deep_entry_is_skipped_not_a_crash(self):
        self.deep_tree(self.temp / "deep")
        self.assertIsNone(cleanup.scan_temp(now=self.now))
        self.assertEqual(cleanup.clean_temp(now=self.now)["skippedNames"], ["deep"])

    def test_an_entry_that_changed_during_the_run_stays(self):
        first = self.old_entry("a")
        second = self.old_entry("b")
        real = cleanup.remove_entry
        fresh = self.now

        def touch_b_after_a(directory, name, identity):
            freed = real(directory, name, identity)
            os.utime(second / "file", (fresh, fresh))
            return freed

        with patch.object(cleanup, "remove_entry", side_effect=touch_b_after_a):
            cleanup.clean_temp(now=self.now)
        self.assertFalse(first.exists())
        self.assertTrue(second.exists())

    def test_processes_are_not_walked_once_per_entry(self):
        for number in range(30):
            self.old_entry(f"e{number}")
        with patch.object(cleanup, "open_targets", wraps=cleanup.open_targets) as walk:
            cleanup.clean_temp(now=self.now)
        self.assertLess(walk.call_count, 5)

    def test_nothing_to_clean_omits_the_category(self):
        self.assertIsNone(cleanup.scan_temp(now=self.now))


class Cache(CleanupCase):
    MB = 1024 * 1024

    def folder(self, name, data=b"x" * 8192):
        self.write(self.cache / name / "data", data)
        return self.cache / name

    def mark(self, *names):
        config = self.root / "config"
        config.mkdir(exist_ok=True)
        (config / "config.json").write_text(json.dumps({"modules": {"cleanup": {"cacheMarked": list(names)}}}))

    def sized(self, **sizes):
        """Pretend folder sizes, so the suite doesn't allocate hundreds of megabytes."""
        real = cleanup.allocated_bytes

        def fake(path):
            name = os.path.basename(path)
            return sizes[name] if name in sizes else real(path)

        return patch.object(cleanup, "allocated_bytes", side_effect=fake)

    def rows(self):
        return {row["id"]: row for row in cleanup.scan_cache()["rows"]}

    def test_the_boundary_is_100_mb_and_a_real_folder_called_otras_stays_distinct(self):
        for name in ("uv", "otras", "small"):
            self.folder(name)
        with self.sized(uv=100 * self.MB, otras=200 * self.MB, small=100 * self.MB - 1):
            rows = self.rows()
        self.assertEqual(set(rows), {"folder:uv", "folder:otras", "otras"})
        self.assertEqual(rows["folder:uv"]["bytes"], 100 * self.MB)
        self.assertEqual([folder["name"] for folder in rows["otras"]["folders"]], ["small"])
        self.assertEqual(rows["folder:otras"]["title"], "otras")
        self.assertEqual(rows["otras"]["title"], "Otras")

    def test_a_new_small_folder_does_not_inherit_the_group_marks(self):
        self.folder("marked-small")
        self.folder("new-small")
        self.mark("marked-small")
        folders = {folder["name"]: folder["marked"] for folder in self.rows()["otras"]["folders"]}
        self.assertEqual(folders, {"marked-small": True, "new-small": False})

    def test_a_folder_keeps_its_mark_when_it_grows_out_of_the_group(self):
        self.folder("uv")
        self.mark("uv")
        with self.sized(uv=100 * self.MB):
            self.assertTrue(self.rows()["folder:uv"]["folders"][0]["marked"])

    def test_invalid_marks_in_the_config_mean_none(self):
        self.folder("uv")
        config = self.root / "config"
        config.mkdir()
        for content in ("not json", '{"modules":{"cleanup":{"cacheMarked":"uv"}}}', '{"modules":[]}'):
            (config / "config.json").write_text(content)
            self.assertEqual(cleanup.marked_names(), set())

    def test_known_summaries_and_unknown_fallback(self):
        self.folder("uv")
        self.folder("rara")
        with self.sized(uv=100 * self.MB, rara=100 * self.MB):
            rows = self.rows()
        self.assertEqual(rows["folder:uv"]["summary"], cleanup.CACHE_SUMMARIES["uv"])
        self.assertEqual(rows["folder:rara"]["summary"], cleanup.CACHE_FALLBACK)

    def test_known_folders_are_the_ones_in_the_design(self):
        self.assertEqual(set(cleanup.CACHE_SUMMARIES), {
            "chromium", "google-chrome", "codex-runtimes", "uv", "mise", "ms-playwright", "mesa_shader_cache",
            "pnpm", "node-gyp", "electron", "yay", "thumbnails"})

    def test_loose_files_and_links_are_not_folders(self):
        self.write(self.cache / "run-exe.log")
        outside = self.write(self.root / "outside/keep", b"keep").parent
        (self.cache / "linked").symlink_to(outside)
        self.assertIsNone(cleanup.scan_cache())

    def test_a_linked_cache_root_is_not_scanned(self):
        real = self.root / "real-cache"
        self.write(real / "uv/data")
        link = self.root / "cache-link"
        link.symlink_to(real)
        with patch.dict(os.environ, {"OMARCHY_TOOL_CLEANUP_CACHE_DIR": str(link)}):
            self.assertIsNone(cleanup.scan_cache())
            with self.assertRaises(cleanup.CleanupError):
                cleanup.clean_cache(["uv"])
        self.assertTrue((real / "uv/data").exists())

    def test_names_reject_the_entire_invalid_request(self):
        keep = self.folder("uv")
        outside = self.write(self.root / "outside/keep", b"keep").parent
        (self.cache / "linked").symlink_to(outside)
        self.write(self.cache / "loose")
        for names in (["../outside"], ["a/b"], [".."], [""], ["."], ["\0"], ["linked"], ["loose"], ["missing"],
                      ["uv", "uv"], ["uv", "../outside"], [], [1], "uv", {"uv": 1}, None):
            with self.subTest(names=names), self.assertRaises(cleanup.CleanupError):
                cleanup.cache_names(json.dumps(names))
        with self.assertRaises(cleanup.CleanupError):
            cleanup.cache_names("not json")
        self.assertTrue(keep.exists())

    def test_names_with_markup_quotes_and_spaces_are_valid(self):
        names = ["<b>x", 'a"b', "con espacio", "ñ", "a..b"]
        for name in names:
            self.folder(name)
        self.assertEqual(cleanup.cache_names(json.dumps(names)), names)

    def test_open_folders_are_skipped_and_loose_files_stay(self):
        free = self.folder("uv")
        busy = self.folder("busy")
        loose = self.write(self.cache / "run-exe.log")
        self.process(fds=[str(busy / "data")])
        expected = cleanup.allocated_bytes(free)
        result = cleanup.clean_cache(["uv", "busy"])
        self.assertFalse(free.exists())
        self.assertTrue(busy.exists())
        self.assertTrue(loose.exists())
        self.assertEqual(result, {"freedBytes": expected, "skippedCount": 1, "skippedNames": ["busy"]})

    def test_a_vanished_folder_is_skipped_not_a_refusal(self):
        free = self.folder("uv")
        result = self.cli("clean", "cache", '["uv", "gone"]')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertFalse(free.exists())
        self.assertEqual(json.loads(result.stdout)["skippedNames"], ["gone"])

    def test_a_stale_mark_can_be_dropped(self):
        self.assertEqual(json.loads(self.cli("validate-names", '["gone"]').stdout), {"names": ["gone"]})
        self.assertEqual(self.cli("validate-names", '["../x"]').returncode, 1)

    def test_a_folder_with_a_socket_or_fifo_inside_is_skipped(self):
        with_socket = self.folder("daemon")
        with_fifo = self.folder("pipe")
        os.mkfifo(with_fifo / "fifo")
        with socket.socket(socket.AF_UNIX) as server:
            server.bind(str(with_socket / "s"))
            result = cleanup.clean_cache(["daemon", "pipe"])
        self.assertTrue(with_socket.exists())
        self.assertTrue(with_fifo.exists())
        self.assertEqual(result["skippedNames"], ["daemon", "pipe"])

    def test_a_mount_inside_a_marked_folder_is_skipped(self):
        folder = self.folder("uv")
        (self.proc / "self/mountinfo").write_text(f"36 35 98:0 / {folder}/remote rw - fuse.sshfs h rw\n")
        result = cleanup.clean_cache(["uv"])
        self.assertTrue(folder.exists())
        self.assertEqual(result["skippedNames"], ["uv"])

    def test_undecodable_names_are_not_offered(self):
        self.folder("uv")
        bad = os.fsencode(str(self.cache)) + b"/bad\xff"
        try:
            os.mkdir(bad)
        except OSError:
            self.skipTest("this filesystem refuses such names")
        self.assertEqual(cleanup.cache_folders(self.cache), ["uv"])

    def test_a_folder_replaced_by_a_link_is_skipped_and_its_target_stays(self):
        outside = self.write(self.root / "outside/keep", b"keep")
        (self.cache / "swapped").symlink_to(outside.parent)
        result = cleanup.clean_cache(["swapped"])
        self.assertEqual(outside.read_bytes(), b"keep")
        self.assertTrue((self.cache / "swapped").is_symlink())
        self.assertEqual(result["skippedNames"], ["swapped"])

    def test_a_link_inside_a_folder_goes_without_touching_its_target(self):
        outside = self.write(self.root / "outside/keep", b"keep")
        folder = self.folder("uv")
        (folder / "link").symlink_to(outside.parent)
        cleanup.clean_cache(["uv"])
        self.assertFalse(folder.exists())
        self.assertEqual(outside.read_bytes(), b"keep")

    def test_read_only_folders_can_be_cleaned(self):
        folder = self.folder("go")
        os.chmod(folder, 0o500)
        cleanup.clean_cache(["go"])
        self.assertFalse(folder.exists())

    def test_a_failure_after_another_folder_went_reports_both(self):
        first = self.folder("a")
        second = self.folder("b")
        expected = cleanup.allocated_bytes(first)
        real = cleanup.remove_entry

        def fail_on_b(directory, name, identity):
            if name == "b":
                raise PermissionError(13, "denied")
            return real(directory, name, identity)

        with patch.object(cleanup, "remove_entry", side_effect=fail_on_b):
            result = cleanup.clean_cache(["a", "b"])
        self.assertFalse(first.exists())
        self.assertTrue(second.exists())
        self.assertEqual(result, {"freedBytes": expected, "skippedCount": 1, "skippedNames": ["b"]})

    def test_the_category_adds_everything_up(self):
        one = self.folder("uv")
        two = self.folder("mise")
        category = cleanup.scan_cache()
        self.assertEqual(category["id"], "cache")
        self.assertEqual(category["count"], 2)
        self.assertEqual(category["bytes"], cleanup.allocated_bytes(one) + cleanup.allocated_bytes(two))

    def test_cli_validates_and_cleans(self):
        folder = self.folder("uv")
        checked = self.cli("validate-cache", '["uv"]')
        self.assertEqual(json.loads(checked.stdout), {"names": ["uv"]})
        refused = self.cli("clean", "cache", '["../x"]')
        self.assertEqual(refused.returncode, 1)
        self.assertEqual(json.loads(refused.stdout), {"error": "carpeta de caché no válida"})
        self.assertTrue(folder.exists())
        cleaned = self.cli("clean", "cache", '["uv"]')
        self.assertEqual(cleaned.returncode, 0, cleaned.stderr)
        self.assertFalse(folder.exists())


class System(CleanupCase):
    MB = 1024 * 1024

    def setUp(self):
        super().setUp()
        self.privilege_log = self.root / "privilege.log"
        for name in ("pkexec", "sudo"):
            self.tool(name, f'echo "$*" >>"{self.privilege_log}"')

    def tool(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o700)

    def paccache(self, *paths):
        lines = ["==> Candidate packages:", *map(str, paths), "",
                 f"==> finished dry run: {len(paths)} candidates (disk space saved: 1 MiB)"]
        output = self.root / "paccache.out"
        output.write_text("\n".join(lines) + "\n")
        self.tool("paccache", f'[ "$*" = "-d -k3 -vv --nocolor" ] || exit 9; /usr/bin/cat "{output}"')

    def pacman(self, seeds, transaction=None, files=None, seed_status=0):
        transaction = seeds if transaction is None else transaction
        seed_output = "\n".join(seeds)
        trans_output = "\n".join(transaction)
        file_output = "\n".join(map(str, files or []))
        self.tool("pacman", f"""case "$1" in
  -Qdtq) printf '%s\\n' "{seed_output}"; exit {seed_status} ;;
  -Rs) shift 3; printf '%s\\n' "{trans_output}" ;;
  -Qlq) printf '%s\\n' "{file_output}" ;;
  *) exit 9 ;;
esac""")

    def sized(self, **sizes):
        real = cleanup.file_bytes

        def fake(path, status):
            return sizes.get(os.path.basename(path).replace("-", "_").replace(".", "_"), real(path, status))

        return patch.object(cleanup, "file_bytes", side_effect=fake)

    def test_listing_needs_no_privilege_and_keeps_the_order(self):
        self.write(self.temp / "old")
        self.write(self.cache / "uv/data")
        package = self.write(self.root / "pkg/a-1-x86_64.pkg.tar.zst")
        self.paccache(package)
        self.pacman(["orphan"], files=[self.write(self.root / "usr/orphan")])
        self.write(self.core / "core.1")
        self.write(self.journal / "machine/system.journal", b"x" * 8192)
        with patch.object(cleanup.time, "time", return_value=self.now), self.sized(system_journal=60 * self.MB):
            categories = cleanup.list_categories()["categories"]
        self.assertEqual([item["id"] for item in categories], ["tmp", "cache", "paccache", "orphans", "coredumps", "journal"])
        self.assertFalse(self.privilege_log.exists())
        for item in categories:
            self.assertNotIn("entries", item)
            self.assertNotIn("candidates", item)

    def test_paccache_missing_or_with_nothing_to_remove_is_omitted(self):
        self.assertIsNone(cleanup.scan_system("paccache"))
        self.tool("paccache", "echo '==> no candidate packages found for pruning'")
        self.assertIsNone(cleanup.scan_system("paccache"))

    def test_paccache_counts_packages_apart_from_signatures_and_paths_with_spaces(self):
        package = self.write(self.root / "pkg dir/a-1-x86_64.pkg.tar.zst")
        signature = self.write(self.root / "pkg dir/a-1-x86_64.pkg.tar.zst.sig")
        self.paccache(package, signature)
        plan = cleanup.system_plan("paccache")
        self.assertEqual(plan["count"], 1)
        self.assertEqual(plan["candidates"], [str(package), str(signature)])
        self.assertEqual(plan["bytes"], cleanup.allocated_bytes(package) + cleanup.allocated_bytes(signature))

    def test_unexpected_paccache_output_is_refused(self):
        self.tool("paccache", "echo 'something new here'; echo '/not/a/package'")
        with self.assertRaises(cleanup.CleanupError):
            cleanup.system_plan("paccache")
        self.assertIsNone(cleanup.scan_system("paccache"))

    def test_a_linked_package_is_not_counted(self):
        package = self.write(self.root / "pkg/a-1-x86_64.pkg.tar.zst")
        link = self.root / "pkg/b-1-x86_64.pkg.tar.zst"
        link.symlink_to(package)
        self.paccache(package, link)
        plan = cleanup.system_plan("paccache")
        self.assertEqual([entry["path"] for entry in plan["entries"]], [str(package)])

    def test_orphan_preview_includes_what_goes_with_it(self):
        one = self.write(self.root / "usr/one", b"x" * 8192)
        two = self.write(self.root / "usr/two", b"x" * 8192)
        os.link(one, self.root / "usr/same-inode")
        self.pacman(["orphan-app"], ["orphan-app", "unused-library"], [one, two, self.root / "usr/same-inode", self.root / "usr"])
        plan = cleanup.system_plan("orphans")
        self.assertEqual(plan["packages"], ["orphan-app"])
        self.assertEqual(plan["names"], ["orphan-app", "unused-library"])
        self.assertEqual(plan["count"], 2)
        self.assertEqual(plan["bytes"], one.lstat().st_blocks * 512 + two.lstat().st_blocks * 512)
        self.assertTrue(plan["revision"])

    def test_no_orphans_is_not_an_error(self):
        self.tool("pacman", "exit 1")
        self.assertIsNone(cleanup.scan_system("orphans"))

    def test_a_pacman_failure_is_an_error_but_hides_the_row(self):
        self.tool("pacman", "echo 'error: broken database' >&2; exit 1")
        with self.assertRaises(cleanup.CleanupError):
            cleanup.system_plan("orphans")
        self.assertIsNone(cleanup.scan_system("orphans"))

    def test_one_invalid_package_refuses_the_whole_plan(self):
        for name in ("--root", "bad name", "../bad", "Upper", "$(touch bad)"):
            with self.subTest(seed=name):
                self.pacman(["good", name.replace("$", "\\\\$")], ["good"])
                with self.assertRaises(cleanup.CleanupError):
                    cleanup.system_plan("orphans")
            with self.subTest(transaction=name):
                self.pacman(["good"], ["good", name.replace("$", "\\\\$")])
                with self.assertRaises(cleanup.CleanupError):
                    cleanup.system_plan("orphans")
        self.assertFalse((self.root / "bad").exists())
        self.assertFalse(self.privilege_log.exists())

    def test_a_changed_transaction_is_refused(self):
        self.pacman(["a"], ["a", "b"])
        revision = cleanup.system_plan("orphans")["revision"]
        self.assertEqual(cleanup.system_plan("orphans", revision)["revision"], revision)
        self.pacman(["a"], ["a", "b", "c"])
        with self.assertRaises(cleanup.CleanupError) as caught:
            cleanup.system_plan("orphans", revision)
        self.assertEqual(caught.exception.source, "los paquetes huérfanos cambiaron; vuelve a revisarlos")

    def test_coredumps_are_only_direct_regular_files(self):
        core = self.write(self.core / "core.1")
        self.write(self.core / "folder/inner")
        (self.core / "link").symlink_to(core)
        plan = cleanup.system_plan("coredumps")
        self.assertEqual(plan["candidates"], [str(core)])
        self.assertEqual(plan["bytes"], cleanup.allocated_bytes(core))
        self.assertTrue(cleanup.scan_system("coredumps")["warning"])

    def test_journal_under_the_limit_is_omitted(self):
        self.write(self.journal / "machine/system.journal")
        self.assertIsNone(cleanup.scan_system("journal"))

    def journals(self):
        oldest = self.write(self.journal / "machine/old.journal")
        middle = self.write(self.journal / "machine/mid.journal")
        active = self.write(self.journal / "machine/system.journal")
        os.utime(oldest, (100, 100))
        os.utime(middle, (200, 200))
        os.utime(active, (300, 300))

    def test_journal_preview_counts_whole_files_from_the_oldest(self):
        self.journals()
        with self.sized(old_journal=30 * self.MB, mid_journal=30 * self.MB, system_journal=self.MB):
            plan = cleanup.system_plan("journal")
        self.assertEqual(plan["bytes"], 30 * self.MB)

    def test_journal_with_only_active_files_can_still_be_trimmed(self):
        self.write(self.journal / "machine/system.journal")
        self.write(self.journal / "machine/user-1000.journal")
        with self.sized(system_journal=72 * self.MB, user_1000_journal=72 * self.MB):
            self.assertEqual(cleanup.system_plan("journal")["bytes"], 144 * self.MB)

    def test_journal_freed_is_measured_on_the_folder(self):
        self.journals()
        plan = cleanup.system_plan("journal")
        machine = self.journal / "machine"
        before = sum(cleanup.allocated_bytes(machine / name) for name in ("old.journal", "mid.journal", "system.journal"))
        self.assertEqual(plan["before"], before)
        # Rotation renamed everything, removed one file and started a new one.
        (machine / "old.journal").unlink()
        os.replace(machine / "system.journal", machine / "system@1.journal")
        self.write(machine / "system.journal", b"x" * 4096)
        after = sum(cleanup.allocated_bytes(machine / name) for name in ("mid.journal", "system@1.journal", "system.journal"))
        self.assertEqual(cleanup.finish_system(plan)["freedBytes"], max(0, before - after))

    def test_a_journal_file_vanishing_during_the_scan_hides_nothing_else(self):
        self.write(self.cache / "uv/data")
        with patch.object(cleanup, "journal_plan", side_effect=FileNotFoundError(2, "rotated")):
            categories = cleanup.list_categories()["categories"]
        self.assertEqual([item["id"] for item in categories], ["cache"])

    def test_finish_counts_what_went_and_what_stayed(self):
        kept = self.write(self.core / "kept", b"x" * 8192)
        gone = self.write(self.core / "gone", b"x" * 8192)
        plan = cleanup.system_plan("coredumps")
        expected = cleanup.allocated_bytes(gone)
        gone.unlink()
        result = cleanup.finish_system(plan)
        self.assertEqual(result, {"freedBytes": expected, "skippedCount": 1, "skippedNames": []})
        self.assertTrue(kept.exists())

    def test_a_replaced_file_counts_as_gone(self):
        core = self.write(self.core / "core.1", b"x" * 8192)
        plan = cleanup.system_plan("coredumps")
        expected = cleanup.allocated_bytes(core)
        replacement = self.write(self.root / "replacement", b"y")
        os.replace(replacement, core)
        self.assertEqual(cleanup.finish_system(plan)["freedBytes"], expected)

    def test_cli_prepares_and_finishes(self):
        self.write(self.core / "core.1")
        prepared = self.cli("prepare", "coredumps", "")
        self.assertEqual(prepared.returncode, 0, prepared.stderr)
        finished = self.cli("finish", stdin=prepared.stdout)
        self.assertEqual(finished.returncode, 0, finished.stderr)
        self.assertEqual(json.loads(finished.stdout)["skippedCount"], 1)
        self.assertEqual(json.loads(self.cli("prepare", "nope", "").stdout), {"error": "acción de limpieza no válida"})
        self.assertEqual(json.loads(self.cli("finish", stdin="not json").stdout), {"error": "acción de limpieza no válida"})


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
        self.assertEqual(set(category), {"id", "title", "summary", "warning", "bytes", "count", "needsRoot",
                                         "names", "revision", "rows"})

    def test_a_broken_temp_folder_hides_only_its_row(self):
        self.write(self.cache / "uv/data")
        with patch.dict(os.environ, {"OMARCHY_TOOL_CLEANUP_TEMP_DIR": str(self.root / "missing")}):
            self.assertEqual([item["id"] for item in cleanup.list_categories()["categories"]], ["cache"])

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
