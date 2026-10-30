"""Proton save copies: inventory, archive safety, saving and loading, all in a temporary prefix."""
import importlib.util
from datetime import datetime
import io
import os
from pathlib import Path
import random
import shutil
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("exe_proton_saves", ROOT / "bin/exe-proton-saves.py")
saves = importlib.util.module_from_spec(spec)
spec.loader.exec_module(saves)


class ProtonSaves(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="proton-saves-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.prefix = self.root / "prefix"
        self.user = self.prefix / "drive_c/users/steamuser"
        self.copies = self.root / "copies"
        self.user.mkdir(parents=True)
        self.environment = patch.dict(os.environ, {
            "HOME": str(self.root / "home"),
            "WINEPREFIX": str(self.prefix),
            "OMARCHY_TOOL_PROTON_SAVES_DIR": str(self.copies),
            "OMARCHY_TOOL_CONFIG_DIR": str(self.root / "config"),
            "OMARCHY_TOOL_STATE_DIR": str(self.root / "state"),
            "OMARCHY_TOOL_WINESERVER_PID": "",
        })
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def put(self, relative, data=b"x"):
        path = self.user / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def tree(self, root):
        if not root.exists():
            return {}
        return {str(path.relative_to(root)): path.read_bytes()
                for path in sorted(root.rglob("*")) if path.is_file() and not path.is_symlink()}

    def groups(self):
        return {(group["area"], group["name"]): group["bytes"] for group in saves.list_saves()["groups"]}


class Inventory(ProtonSaves):
    def test_groups_first_level_folders_and_sums_appdata_areas(self):
        self.put("Saved Games/God of War/slot.sav", b"123")
        self.put("Documents/Juego ñ/slot.sav", b"12")
        self.put("AppData/Local/TunnelForge.exe/a", b"12")
        self.put("AppData/Roaming/TunnelForge.exe/b", b"345")
        self.assertEqual(self.groups(), {
            ("Saved Games", "God of War"): 3,
            ("Documents", "Juego ñ"): 2,
            ("AppData", "TunnelForge.exe"): 5,
        })

    def test_linked_roots_and_descendants_are_not_followed(self):
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "secret").write_bytes(b"secret")
        (self.user / "Documents").symlink_to(outside)
        (self.user / "Saved Games").mkdir()
        (self.user / "Saved Games/linked").symlink_to(outside)
        self.assertEqual(saves.scan_prefix(self.prefix), [])
        self.assertEqual(self.tree(outside), {"secret": b"secret"})

    def test_loose_files_and_markup_names_stay_literal(self):
        self.put("Documents/readme.txt", b"x")
        self.put("Saved Games/<img src=x>/slot", b"12")
        groups = self.groups()
        self.assertEqual(groups[("Documents", "Documents")], 1)
        self.assertEqual(groups[("Saved Games", "<img src=x>")], 2)

    def test_empty_folders_are_kept_but_not_listed(self):
        (self.user / "Documents/Music").mkdir(parents=True)
        self.assertIn(("Documents/Music", 0), saves.scan_prefix(self.prefix))
        self.assertEqual(self.groups(), {})

    def test_group_bytes_are_file_size_not_disk_usage(self):
        path = self.put("Saved Games/God of War/game.sav", b"")
        os.truncate(path, 33554400)  # Sparse: occupies almost nothing on disk.
        self.assertEqual(self.groups()[("Saved Games", "God of War")], 33554400)

    def test_exclusions_are_exact(self):
        excluded = ["AppData/Local/dxvk/a", "AppData/Local/Temp/a", "AppData/Local/Microsoft/a",
                    "AppData/Local/Programs/a", "AppData/Local/openvr/a", "AppData/Roaming/Microsoft/a"]
        for relative in excluded + ["AppData/Local/My Game/slot", "AppData/Local/dxvk2/a",
                                    "AppData/LocalLow/Microsoft/a", "Documents/Temp/a"]:
            self.put(relative)
        names = {name for name, _ in saves.scan_prefix(self.prefix)}
        self.assertEqual(names & set(excluded), set())
        self.assertLessEqual({"AppData/Local/My Game/slot", "AppData/Local/dxvk2/a",
                              "AppData/LocalLow/Microsoft/a", "Documents/Temp/a"}, names)

    def test_missing_prefix_and_missing_copies_are_read_only(self):
        with patch.dict(os.environ, {"WINEPREFIX": str(self.root / "missing")}):
            result = saves.list_saves()
        self.assertFalse(result["prefixExists"])
        self.assertEqual(result["groups"], [])
        self.assertEqual(result["copies"], [])
        self.assertFalse(self.copies.exists())
        self.assertFalse((self.root / "missing").exists())

    def test_copy_metadata_ignores_links_and_unfinished_files(self):
        self.copies.mkdir()
        manual = self.copies / "partidas-20261030-084500.tar.zst"
        safety = self.copies / "antes-de-cargar-20261030-084501.tar.zst"
        automatic = self.copies / "automatica-20261030-084502.tar.zst"
        for path in (manual, safety, automatic):
            path.write_bytes(b"123")
        (self.copies / ".partidas-unfinished.tmp").write_bytes(b"x")
        (self.copies / "partidas-20261030-084503.tar.zst").symlink_to(manual)
        (self.copies / "otra.tar.zst").write_bytes(b"x")
        os.utime(manual, (100, 100))
        os.utime(safety, (200, 200))
        os.utime(automatic, (300, 300))
        copies = saves.list_saves()["copies"]
        self.assertEqual([copy["name"] for copy in copies], [automatic.name, safety.name, manual.name])
        self.assertEqual([copy["kind"] for copy in copies], ["automatica", "antes-de-cargar", "partidas"])
        self.assertEqual(copies[0]["bytes"], 3)
        self.assertEqual(copies[0]["timestamp"], 300)

    def test_default_paths_and_empty_overrides_match_runner(self):
        fake_home = self.root / "home"
        with patch.dict(os.environ, {"WINEPREFIX": "", "OMARCHY_TOOL_PROTON_SAVES_DIR": ""}):
            prefix, copies = saves.locations()
        self.assertEqual(prefix, fake_home / ".local/share/umu/default")
        self.assertEqual(copies, fake_home / "Documents/Partidas Proton")

    def test_copies_inside_the_prefix_or_behind_a_link_are_refused(self):
        with patch.dict(os.environ, {"OMARCHY_TOOL_PROTON_SAVES_DIR": str(self.user / "Documents/copias")}):
            with self.assertRaises(saves.SavesError):
                saves.list_saves()
        target = self.root / "target"
        target.mkdir()
        self.copies.symlink_to(target)
        with self.assertRaises(saves.SavesError):
            saves.list_saves()

    def test_unreadable_folder_is_an_error_not_a_short_list(self):
        self.put("Saved Games/Game/slot")
        with patch.object(saves.os, "scandir", side_effect=PermissionError("denied")):
            with self.assertRaises(saves.SavesError):
                saves.list_saves()


COPY = "partidas-20261030-084500.tar.zst"


def regular(name, data=b"x"):
    info = tarfile.TarInfo(name)
    info.size = len(data)
    return info, data


def special(name, kind, linkname=""):
    info = tarfile.TarInfo(name)
    info.type = kind
    info.linkname = linkname
    return info, b""


class ArchiveSafety(ProtonSaves):
    def make_copy(self, entries, name=COPY):
        self.copies.mkdir(exist_ok=True)
        with tarfile.open(self.copies / name, "w:zst") as archive:
            for info, data in entries:
                archive.addfile(info, io.BytesIO(data))
        return name

    def assert_refused(self, name):
        before = self.tree(self.prefix)
        with self.assertRaises(saves.SavesError):
            saves.preview_copy(name)
        self.assertEqual(self.tree(self.prefix), before)
        self.assertEqual(self.tree(self.root / "outside"), {})

    def test_preview_matches_grouping_without_extracting(self):
        name = self.make_copy([regular("Saved Games/God of War/slot", b"123"),
                               regular("AppData/Local/Tool/a", b"12"), regular("AppData/Roaming/Tool/b", b"1")])
        before = self.tree(self.prefix)
        result = saves.preview_copy(name)
        self.assertEqual(result["name"], name)
        self.assertEqual(result["groups"], [{"name": "Tool", "area": "AppData", "bytes": 3},
                                            {"name": "God of War", "area": "Saved Games", "bytes": 3}])
        self.assertEqual(self.tree(self.prefix), before)

    def test_unsafe_names_reject_the_whole_archive(self):
        for bad_name in ("../outside", "/tmp/outside", "Documents/../outside", "Documents2/slot",
                         "AppData/Other/slot", "AppData/slot", "AppData/Local/Temp/slot",
                         "AppData/Roaming/Microsoft/slot", "Documents", "./Documents/slot"):
            with self.subTest(name=bad_name):
                self.assert_refused(self.make_copy([regular("Saved Games/Game/slot"), regular(bad_name)]))

    def test_links_and_devices_reject_the_whole_archive(self):
        kinds = {"symlink": (tarfile.SYMTYPE, "/etc/passwd"), "hardlink": (tarfile.LNKTYPE, "Saved Games/Game/slot"),
                 "fifo": (tarfile.FIFOTYPE, ""), "char": (tarfile.CHRTYPE, ""), "block": (tarfile.BLKTYPE, "")}
        for label, (kind, target) in kinds.items():
            with self.subTest(kind=label):
                self.assert_refused(self.make_copy([regular("Saved Games/Game/slot"),
                                                    special("Documents/bad", kind, target)]))

    def test_duplicates_and_file_child_conflicts_reject_the_whole_archive(self):
        self.assert_refused(self.make_copy([regular("Documents/a"), regular("Documents/a")]))
        self.assert_refused(self.make_copy([regular("Documents/a"), regular("Documents/a/b")]))
        self.assert_refused(self.make_copy([regular("Documents/a/b"), regular("Documents/a")]))

    def test_truncated_late_payload_is_rejected(self):
        payload = random.Random(1).randbytes(1 << 20)
        name = self.make_copy([regular("Saved Games/Game/first", b"ok"), regular("Saved Games/Game/big", payload)])
        path = self.copies / name
        path.write_bytes(path.read_bytes()[:-(1 << 19)])
        self.assert_refused(name)

    def test_garbage_is_rejected(self):
        self.copies.mkdir()
        (self.copies / COPY).write_bytes(b"not an archive")
        self.assert_refused(COPY)

    def test_copy_name_cannot_escape_or_follow_a_link(self):
        real = self.make_copy([regular("Documents/a")])
        linked = "partidas-20261030-084501.tar.zst"
        (self.copies / linked).symlink_to(self.copies / real)
        for name in ("../" + real, "/tmp/" + real, linked, "nada.tar.zst"):
            with self.subTest(name=name):
                with self.assertRaises(saves.SavesError):
                    saves.preview_copy(name)


class Saving(ProtonSaves):
    def members(self, name):
        with tarfile.open(self.copies / name, "r:zst") as archive:
            return {member.name: member for member in archive}

    def test_save_uses_native_zstandard_and_private_modes(self):
        self.put("Saved Games/Game/slot", b"123")
        result = saves.save_copy()
        self.assertRegex(result["name"], r"^partidas-\d{8}-\d{6}\.tar\.zst$")
        self.assertEqual(self.copies.stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.copies / result["name"]).stat().st_mode & 0o777, 0o600)
        self.assertEqual(saves.preview_copy(result["name"])["groups"], saves.list_saves()["groups"])

    def test_saved_members_are_exactly_the_inventory_without_links(self):
        slot = self.put("Saved Games/Game/slot", b"123")
        os.link(slot, self.root / "other-name")
        self.put("AppData/Local/dxvk/cache", b"cache")
        (self.user / "Documents/Empty").mkdir(parents=True)
        (self.user / "Documents/link").symlink_to(self.root)
        members = self.members(saves.save_copy()["name"])
        self.assertEqual(set(members), {"Saved Games/Game", "Saved Games/Game/slot", "Documents/Empty"})
        self.assertEqual(members["Saved Games/Game/slot"].type, tarfile.REGTYPE)
        self.assertEqual(members["Saved Games/Game/slot"].uid, 0)
        self.assertEqual(members["Saved Games/Game/slot"].uname, "")

    def test_existing_permissive_copies_directory_becomes_private(self):
        self.copies.mkdir(mode=0o755)
        os.chmod(self.copies, 0o755)
        self.put("Saved Games/Game/slot")
        saves.save_copy()
        self.assertEqual(self.copies.stat().st_mode & 0o777, 0o700)

    def test_open_proton_refuses_save_without_creating_copies(self):
        self.put("Saved Games/Game/slot")
        with patch.dict(os.environ, {"OMARCHY_TOOL_WINESERVER_PID": "4242"}):
            with self.assertRaises(saves.SavesError) as caught:
                saves.save_copy()
        self.assertEqual(caught.exception.source, "cierra Proton antes de guardar o cargar")
        self.assertFalse(self.copies.exists())

    def test_missing_prefix_refuses_save(self):
        with patch.dict(os.environ, {"WINEPREFIX": str(self.root / "missing")}):
            with self.assertRaises(saves.SavesError):
                saves.save_copy()
        self.assertFalse(self.copies.exists())

    def test_failed_write_publishes_no_partial_archive(self):
        self.put("Saved Games/Game/slot")
        before = self.tree(self.prefix)
        with patch.object(tarfile.TarFile, "addfile", side_effect=OSError("disk full")):
            with self.assertRaises(saves.SavesError):
                saves.save_copy()
        self.assertEqual(list(self.copies.iterdir()), [])
        self.assertEqual(self.tree(self.prefix), before)

    def test_same_second_never_overwrites_an_existing_copy(self):
        self.put("Saved Games/Game/slot", b"first")
        fixed = datetime(2026, 10, 30, 8, 45, 0)
        name = saves.write_copy(self.prefix, self.copies, "partidas", fixed)
        before = (self.copies / name).read_bytes()
        self.put("Saved Games/Game/slot", b"second")
        with self.assertRaises(saves.SavesError) as caught:
            saves.write_copy(self.prefix, self.copies, "partidas", fixed)
        self.assertEqual(caught.exception.source, "ya existe una copia de este segundo; inténtalo de nuevo")
        self.assertEqual((self.copies / name).read_bytes(), before)
        self.assertEqual(len(list(self.copies.iterdir())), 1)

    def test_publishing_works_where_hard_links_do_not(self):
        self.put("Saved Games/Game/slot")
        with patch.object(saves.os, "link", side_effect=OSError(1, "not permitted")):
            name = saves.save_copy()["name"]
        self.assertEqual(saves.preview_copy(name)["name"], name)

    def fake_proc(self, processes):
        proc = self.root / "proc"
        for pid, command in processes.items():
            (proc / pid).mkdir(parents=True)
            (proc / pid / "comm").write_text(command + "\n")
        (proc / "self").mkdir(parents=True, exist_ok=True)
        (proc / "99").mkdir()  # A process that vanished: no comm.
        return proc

    def test_real_probe_finds_wineserver_only(self):
        environment = {k: v for k, v in os.environ.items() if k != "OMARCHY_TOOL_WINESERVER_PID"}
        with patch.dict(os.environ, environment, clear=True):
            with patch.object(saves, "PROC_DIRECTORY", self.fake_proc({"10": "bash", "11": "wineserver-tool"})):
                self.assertFalse(saves.proton_open())
        for command in ("wineserver", "wineserver64"):
            shutil.rmtree(self.root / "proc")
            with patch.dict(os.environ, environment, clear=True):
                with patch.object(saves, "PROC_DIRECTORY", self.fake_proc({"10": command})):
                    self.assertTrue(saves.proton_open())

    def test_uninspectable_processes_prevent_saving(self):
        environment = {k: v for k, v in os.environ.items() if k != "OMARCHY_TOOL_WINESERVER_PID"}
        with patch.dict(os.environ, environment, clear=True):
            with patch.object(saves, "PROC_DIRECTORY", self.root / "no-proc"):
                with self.assertRaises(saves.SavesError):
                    saves.save_copy()
        self.assertFalse(self.copies.exists())


if __name__ == "__main__":
    unittest.main()
