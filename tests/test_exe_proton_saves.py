"""Proton save copies: inventory, archive safety, saving and loading, all in a temporary prefix."""
import importlib.util
from compression import zstd
from datetime import datetime
import io
import json
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


class Loading(ArchiveSafety):
    def saved_state(self):
        self.put("Saved Games/Game/slot", b"old")
        self.put("Documents/Game/slot", b"old")
        self.put("AppData/Local/Game/slot", b"old")
        self.put("AppData/LocalLow/Game/slot", b"old")
        self.put("AppData/Roaming/Game/slot", b"old")
        return saves.save_copy()["name"]

    def assert_nothing_changed(self, before_prefix, before_copies):
        self.assertEqual(self.tree(self.prefix), before_prefix)
        self.assertEqual(self.tree(self.copies), before_copies)
        self.assertEqual([path.name for path in self.user.parent.iterdir()], ["steamuser"])

    def test_load_overlays_all_areas_and_preserves_later_slots(self):
        name = self.saved_state()
        for relative in ("Saved Games/Game/slot", "Documents/Game/slot", "AppData/Local/Game/slot",
                         "AppData/LocalLow/Game/slot", "AppData/Roaming/Game/slot"):
            self.put(relative, b"new")
        self.put("Saved Games/Game/later.sav", b"later")
        changed = self.tree(self.user)
        with patch.object(saves, "datetime", wraps=saves.datetime) as clock:
            clock.now.return_value = datetime(2030, 1, 1)
            result = saves.load_copy(name)
        self.assertEqual(self.tree(self.user), {
            "Saved Games/Game/slot": b"old", "Saved Games/Game/later.sav": b"later", "Documents/Game/slot": b"old",
            "AppData/Local/Game/slot": b"old", "AppData/LocalLow/Game/slot": b"old",
            "AppData/Roaming/Game/slot": b"old"})
        self.assertEqual(result["name"], name)
        self.assertRegex(result["safetyCopy"], r"^antes-de-cargar-\d{8}-\d{6}\.tar\.zst$")
        with tarfile.open(self.copies / result["safetyCopy"], "r:zst") as archive:
            safety = {member.name: archive.extractfile(member).read() for member in archive if member.isfile()}
        self.assertEqual(safety, changed)
        self.assertIn(result["safetyCopy"], [copy["name"] for copy in saves.list_saves()["copies"]])
        self.assertEqual([path.name for path in self.user.parent.iterdir()], ["steamuser"])

    def test_load_recreates_missing_folders(self):
        name = self.saved_state()
        shutil.rmtree(self.user / "Saved Games")
        saves.load_copy(name)
        self.assertEqual((self.user / "Saved Games/Game/slot").read_bytes(), b"old")

    def test_failed_safety_copy_leaves_prefix_unchanged(self):
        name = self.saved_state()
        self.put("Saved Games/Game/slot", b"new")
        before = self.tree(self.prefix)
        with patch.object(saves, "write_copy", side_effect=saves.SavesError("no se pudo guardar la copia")):
            with self.assertRaises(saves.SavesError):
                saves.load_copy(name)
        self.assertEqual(self.tree(self.prefix), before)

    def test_destination_link_is_refused_and_hard_link_is_not_written_through(self):
        name = self.saved_state()
        outside = self.root / "outside-file"
        outside.write_bytes(b"outside")
        destination = self.user / "Saved Games/Game/slot"
        destination.unlink()
        destination.symlink_to(outside)
        with self.assertRaises(saves.SavesError):
            saves.load_copy(name)
        self.assertEqual(outside.read_bytes(), b"outside")
        destination.unlink()
        os.link(outside, destination)
        saves.load_copy(name)
        self.assertEqual(outside.read_bytes(), b"outside")
        self.assertEqual(destination.read_bytes(), b"old")

    def test_linked_folder_in_the_path_is_refused(self):
        name = self.saved_state()
        outside = self.root / "outside-folder"
        outside.mkdir()
        shutil.rmtree(self.user / "Saved Games/Game")
        (self.user / "Saved Games/Game").symlink_to(outside)
        with self.assertRaises(saves.SavesError):
            saves.load_copy(name)
        self.assertEqual(self.tree(outside), {})

    def test_bad_late_member_changes_nothing(self):
        name = self.make_copy([regular("Saved Games/Game/slot", b"archived"), regular("../outside")])
        self.put("Saved Games/Game/slot", b"current")
        prefix_before, copies_before = self.tree(self.prefix), self.tree(self.copies)
        with self.assertRaises(saves.SavesError):
            saves.load_copy(name)
        self.assert_nothing_changed(prefix_before, copies_before)

    def test_truncated_late_payload_changes_nothing(self):
        payload = random.Random(1).randbytes(1 << 20)
        name = self.make_copy([regular("Saved Games/Game/slot", b"archived"), regular("Saved Games/Game/big", payload)])
        path = self.copies / name
        path.write_bytes(path.read_bytes()[:-(1 << 19)])
        self.put("Saved Games/Game/slot", b"current")
        prefix_before, copies_before = self.tree(self.prefix), self.tree(self.copies)
        with self.assertRaises(saves.SavesError):
            saves.load_copy(name)
        self.assert_nothing_changed(prefix_before, copies_before)

    def test_open_proton_refuses_load(self):
        name = self.saved_state()
        prefix_before, copies_before = self.tree(self.prefix), self.tree(self.copies)
        with patch.dict(os.environ, {"OMARCHY_TOOL_WINESERVER_PID": "4242"}):
            with self.assertRaises(saves.SavesError):
                saves.load_copy(name)
        self.assert_nothing_changed(prefix_before, copies_before)

    def test_extraction_uses_data_filter(self):
        name = self.saved_state()
        real = tarfile.TarFile.extractall
        with patch.object(tarfile.TarFile, "extractall", autospec=True, side_effect=real) as extractall:
            saves.load_copy(name)
        self.assertEqual(extractall.call_args.kwargs["filter"], "data")

    def test_destination_type_conflict_is_rejected_before_backup(self):
        name = self.saved_state()
        shutil.rmtree(self.user / "Saved Games/Game")
        self.put("Saved Games/Game", b"a file now")
        prefix_before, copies_before = self.tree(self.prefix), self.tree(self.copies)
        with self.assertRaises(saves.SavesError):
            saves.load_copy(name)
        self.assert_nothing_changed(prefix_before, copies_before)

    def test_proton_starting_during_safety_copy_prevents_overlay(self):
        name = self.saved_state()
        self.put("Saved Games/Game/slot", b"current")
        real = saves.write_copy

        def proton_starts(*args):
            result = real(*args)
            os.environ["OMARCHY_TOOL_WINESERVER_PID"] = "4242"
            return result

        with patch.object(saves, "write_copy", side_effect=proton_starts):
            with self.assertRaises(saves.SavesError):
                saves.load_copy(name)
        self.assertEqual((self.user / "Saved Games/Game/slot").read_bytes(), b"current")
        self.assertEqual(len([copy for copy in saves.list_saves()["copies"] if copy["kind"] == "antes-de-cargar"]), 1)
        self.assertEqual([path.name for path in self.user.parent.iterdir()], ["steamuser"])


class ChosenFolderAndAutomatic(ProtonSaves):
    def setUp(self):
        super().setUp()
        self.chosen = self.root / "disco"
        self.chosen.mkdir()
        self.put("Saved Games/Game/slot", b"1")

    def configure(self, **module):
        config = self.root / "config"
        config.mkdir(exist_ok=True)
        (config / "config.json").write_text(json.dumps({"modules": {"exe-proton": module}}))

    def use_config_only(self):
        environment = patch.dict(os.environ, {"OMARCHY_TOOL_PROTON_SAVES_DIR": ""})
        environment.start()
        self.addCleanup(environment.stop)

    def test_chosen_folder_holds_copies_in_its_subfolder(self):
        self.use_config_only()
        self.configure(savesFolder=str(self.chosen))
        saves.choose_folder(str(self.chosen))
        self.assertEqual(saves.locations()[1], self.chosen / "Partidas Proton")
        name = saves.save_copy()["name"]
        self.assertTrue((self.chosen / "Partidas Proton" / name).is_file())
        result = saves.list_saves()
        self.assertEqual(result["folder"], str(self.chosen))
        self.assertTrue(result["folderAvailable"])

    def test_missing_subfolder_means_disk_gone_and_is_never_recreated(self):
        self.use_config_only()
        self.configure(savesFolder=str(self.chosen))
        with self.assertRaises(saves.SavesError) as caught:
            saves.save_copy()
        self.assertEqual(caught.exception.source, "la carpeta de copias no está disponible; comprueba que el disco esté conectado")
        self.assertFalse((self.chosen / "Partidas Proton").exists())
        self.assertFalse(saves.list_saves()["folderAvailable"])

    def test_default_folder_is_created_on_demand(self):
        self.use_config_only()
        saves.save_copy()
        self.assertEqual(len(list((self.root / "home/Documents/Partidas Proton").iterdir())), 1)
        self.assertTrue(saves.list_saves()["folderAvailable"])

    def test_choosing_refuses_missing_relative_and_prefix_folders(self):
        self.use_config_only()
        for path in (str(self.root / "missing"), "relativa", str(self.user), str(self.prefix)):
            with self.subTest(path=path):
                with self.assertRaises(saves.SavesError):
                    saves.choose_folder(path)

    def test_choosing_returns_the_real_path_and_empty_means_default(self):
        self.use_config_only()
        link = self.root / "enlace"
        link.symlink_to(self.chosen)
        self.assertEqual(saves.choose_folder(str(link)), {"folder": str(self.chosen)})
        self.assertTrue((self.chosen / "Partidas Proton").is_dir())
        self.assertEqual(saves.choose_folder(""), {"folder": ""})

    def test_chmod_refused_by_the_disk_does_not_fail_saving(self):
        with patch.object(saves.os, "chmod", side_effect=PermissionError(1, "not permitted")):
            self.assertRegex(saves.save_copy()["name"], r"^partidas-")

    def test_saving_nothing_is_refused(self):
        shutil.rmtree(self.user / "Saved Games")
        with self.assertRaises(saves.SavesError) as caught:
            saves.save_copy()
        self.assertEqual(caught.exception.source, "no hay nada que guardar")

    def test_load_into_an_empty_prefix_keeps_a_viewable_previous_copy(self):
        name = saves.save_copy()["name"]
        shutil.rmtree(self.user / "Saved Games")
        safety = saves.load_copy(name)["safetyCopy"]
        self.assertEqual(saves.preview_copy(safety)["groups"], [])

    def test_auto_off_makes_no_copy(self):
        self.assertIsNone(saves.auto_copy()["name"])
        self.assertFalse(self.copies.exists())

    def test_auto_skips_when_nothing_changed(self):
        self.configure(savesAuto=True)
        self.assertRegex(saves.auto_copy()["name"], r"^automatica-")
        self.assertIsNone(saves.auto_copy()["name"])

    def test_auto_copies_again_when_data_changed(self):
        self.configure(savesAuto=True)
        fixed = [datetime(2026, 10, 30, 8, 0, 0), datetime(2026, 10, 30, 8, 0, 1)]
        with patch.object(saves, "datetime", wraps=saves.datetime) as clock:
            clock.now.side_effect = fixed
            saves.auto_copy()
            self.put("Saved Games/Game/slot", b"12")
            self.assertIsNotNone(saves.auto_copy()["name"])

    def test_auto_copies_again_when_the_folder_changed_or_its_copies_are_gone(self):
        self.configure(savesAuto=True)
        first = saves.auto_copy()["name"]
        (self.copies / first).unlink()
        fixed = datetime(2026, 10, 30, 8, 0, 1)
        with patch.object(saves, "datetime", wraps=saves.datetime) as clock:
            clock.now.return_value = fixed
            self.assertIsNotNone(saves.auto_copy()["name"])

    def test_auto_with_open_proton_makes_no_copy_and_no_error(self):
        self.configure(savesAuto=True)
        with patch.dict(os.environ, {"OMARCHY_TOOL_WINESERVER_PID": "4242"}):
            self.assertIsNone(saves.auto_copy()["name"])
        self.assertFalse(self.copies.exists())

    def test_auto_with_the_disk_gone_is_an_error(self):
        self.use_config_only()
        self.configure(savesAuto=True, savesFolder=str(self.chosen))
        with self.assertRaises(saves.SavesError):
            saves.auto_copy()

    def test_auto_with_nothing_to_save_makes_no_copy(self):
        self.configure(savesAuto=True)
        shutil.rmtree(self.user / "Saved Games")
        self.assertIsNone(saves.auto_copy()["name"])
        self.assertFalse(self.copies.exists())

    def test_failed_auto_copy_keeps_the_old_fingerprint_so_it_retries(self):
        self.configure(savesAuto=True)
        with patch.object(saves, "write_copy", side_effect=saves.SavesError("no se pudo guardar la copia")):
            with self.assertRaises(saves.SavesError):
                saves.auto_copy()
        self.assertIsNotNone(saves.auto_copy()["name"])

    def test_prune_keeps_five_newest_automatic_and_every_other_kind(self):
        self.copies.mkdir()
        for minute in range(8):
            path = self.copies / f"automatica-20261030-08{minute:02d}00.tar.zst"
            path.write_bytes(b"x")
            os.utime(path, (1000 + minute, 1000 + minute))
        manual = self.copies / "partidas-20200101-000000.tar.zst"
        safety = self.copies / "antes-de-cargar-20200101-000000.tar.zst"
        manual.write_bytes(b"x")
        safety.write_bytes(b"x")
        saves.prune_automatic(self.copies, "automatica-20261030-080700.tar.zst")
        self.assertEqual(sorted(path.name for path in self.copies.glob("automatica-*")),
                         [f"automatica-20261030-08{minute:02d}00.tar.zst" for minute in range(3, 8)])
        self.assertTrue(manual.exists())
        self.assertTrue(safety.exists())


class ReviewFindings(ArchiveSafety):
    def corrupt_second_header(self, name):
        """Recompress the copy with a bad checksum in its second member's header."""
        path = self.copies / name
        raw = bytearray(zstd.decompress(path.read_bytes()))
        second = 512 + 512  # First member: one header block, one data block.
        raw[second + 148:second + 156] = b"0000000\0"
        path.write_bytes(zstd.compress(bytes(raw)))

    def test_bad_header_after_valid_members_is_not_read_as_the_end(self):
        name = self.make_copy([regular("Saved Games/Game/a", b"first"), regular("Saved Games/Game/b", b"second")])
        self.corrupt_second_header(name)
        self.assert_refused(name)
        self.put("Saved Games/Game/a", b"current")
        prefix_before, copies_before = self.tree(self.prefix), self.tree(self.copies)
        with self.assertRaises(saves.SavesError):
            saves.load_copy(name)
        self.assertEqual(self.tree(self.prefix), prefix_before)
        self.assertEqual(self.tree(self.copies), copies_before)

    def test_missing_end_of_archive_is_rejected(self):
        name = self.make_copy([regular("Saved Games/Game/a", b"first")])
        path = self.copies / name
        raw = zstd.decompress(path.read_bytes())
        path.write_bytes(zstd.compress(raw[:1024]))
        self.assert_refused(name)

    def test_saved_copy_with_a_cut_trailer_is_rejected(self):
        self.put("Saved Games/Game/slot", b"x" * 4096)
        name = saves.save_copy()["name"]
        path = self.copies / name
        self.assertEqual(saves.preview_copy(name)["name"], name)
        path.write_bytes(path.read_bytes()[:-2])
        self.assert_refused(name)

    def test_linked_folders_above_the_user_directory_are_refused(self):
        outside = self.root / "outside-users"
        (outside / "steamuser/Documents/Game").mkdir(parents=True)
        victim = outside / "steamuser/Documents/Game/slot"
        victim.write_bytes(b"outside")
        name = self.make_copy([regular("Documents/Game/slot", b"archived")])
        shutil.rmtree(self.prefix / "drive_c/users")
        (self.prefix / "drive_c/users").symlink_to(outside)
        with self.assertRaises(saves.SavesError):
            saves.scan_prefix(self.prefix)
        with self.assertRaises(saves.SavesError):
            saves.save_copy()
        with self.assertRaises(saves.SavesError):
            saves.load_copy(name)
        self.assertEqual(victim.read_bytes(), b"outside")

    def test_retention_never_deletes_the_copy_just_made(self):
        self.copies.mkdir()
        future = 4000000000
        for minute in range(5):
            path = self.copies / f"automatica-20300101-00{minute:02d}00.tar.zst"
            path.write_bytes(b"x")
            os.utime(path, (future + minute, future + minute))
        new = self.copies / "automatica-20261030-080000.tar.zst"
        new.write_bytes(b"x")
        saves.prune_automatic(self.copies, new.name)
        self.assertTrue(new.exists())
        self.assertEqual(len(list(self.copies.glob("automatica-*"))), 5)

    def test_choosing_refuses_folders_that_cleanup_deletes(self):
        for inside in (self.root / "state", self.root / "state/exe-proton", self.root / "config", ROOT / "bin"):
            with self.subTest(folder=inside):
                inside.mkdir(parents=True, exist_ok=True)
                with self.assertRaises(saves.SavesError) as caught:
                    saves.choose_folder(str(inside))
                self.assertEqual(caught.exception.source, "esa carpeta se borra al desinstalar; elige otra")
        self.assertFalse((ROOT / "bin/Partidas Proton").exists())

    def test_folder_on_an_unmounted_fstab_disk_is_not_available(self):
        disk = self.root / "disco"
        (disk / "Partidas Proton").mkdir(parents=True)
        fstab = self.root / "fstab"
        fstab.write_text(f"# comentario\nUUID=1 / btrfs defaults 0 0\nUUID=2 {disk} ntfs3 rw 0 0\nUUID=3 none swap sw 0 0\n")
        environment = patch.dict(os.environ, {"OMARCHY_TOOL_PROTON_SAVES_DIR": ""})
        environment.start()
        self.addCleanup(environment.stop)
        config = self.root / "config"
        config.mkdir()
        (config / "config.json").write_text(json.dumps(
            {"modules": {"exe-proton": {"savesFolder": str(disk), "savesAuto": True}}}))
        self.put("Saved Games/Game/slot")
        with patch.object(saves, "FSTAB_FILE", fstab):
            self.assertFalse(saves.list_saves()["folderAvailable"])
            with self.assertRaises(saves.SavesError):
                saves.save_copy()
            with self.assertRaises(saves.SavesError):
                saves.auto_copy()
            with self.assertRaises(saves.SavesError) as caught:
                saves.choose_folder(str(disk))
            self.assertEqual(caught.exception.source, "ese disco no está montado")
            self.assertEqual(list((disk / "Partidas Proton").iterdir()), [])
            with patch.object(saves.os.path, "ismount", return_value=True):
                self.assertTrue(saves.list_saves()["folderAvailable"])
                self.assertRegex(saves.save_copy()["name"], r"^partidas-")


if __name__ == "__main__":
    unittest.main()
