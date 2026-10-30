"""Proton save copies: inventory, archive safety, saving and loading, all in a temporary prefix."""
import importlib.util
import os
from pathlib import Path
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


if __name__ == "__main__":
    unittest.main()
