# Proton saves Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add manual, complete Proton save copies, with content previews and a safety copy before loading.

**Architecture:** A standard-library Python helper owns inventory, archive validation, saving, and loading; Bash exposes its commands through the existing module dispatcher. Save/load retain the dispatcher lock and send completion notifications, while listing/preview bypass that lock. The QML page collects read results through its own Quickshell process and submits mutations through `tool.run`.

**Tech Stack:** Bash, Python 3.14 `tarfile` with native Zstandard, QtQuick/QML, Quickshell.Io, existing i18n catalog, Bash regression tests, Python `unittest`, existing Node-based QML JavaScript tests.

**Spec:** `docs/superpowers/specs/2026-10-30-proton-saves-design.md`

## Global Constraints

- “Un archivo por copia; se guarda y se carga completo.”
- “Elegir juegos sueltos (opción B, descartada).”
- “Prefijos de Steam en `steamapps/compatdata`: hoy solo existe el `0`.”
- “Copias programadas por horario, copia incremental, NAS o nube.”
- “`Documents`, `Saved Games` y `AppData/{Local,LocalLow,Roaming}`.”
- “`AppData/Local/{dxvk,Temp,Microsoft,Programs,openvr}` y `AppData/Roaming/Microsoft`.”
- “Los enlaces simbólicos no se siguen.”
- “`~/Documents/Partidas Proton/`”, “`partidas-AAAAMMDD-HHMMSS.tar.zst`”, “Carpeta `0700` y archivos `0600`”.
- “Cargar no borra: sobrescribe lo que está en la copia y deja lo demás.”
- “Antes de cargar se crea una copia `antes-de-cargar-….tar.zst`, que aparece en la misma lista.”
- “Si no se puede crear, no se carga.”
- “se conservan las 5 automáticas más recientes y se borran las anteriores. Las manuales y las `antes-de-cargar` nunca se borran.”
- “Con Proton abierto (hay un `wineserver` en marcha) se rechaza tanto guardar como cargar”.
- “solo rutas relativas bajo las carpetas de arriba, sin `..`, enlaces ni dispositivos.”
- “Si algo falla, se rechaza la copia entera.”
- “visible si el prefijo existe aunque el módulo esté desactivado”.
- “Cargar solo se ofrece después de «Ver».”
- “Al terminar llega una notificación, porque el panel puede haberse cerrado.”
- “Todo texto con `Text.PlainText`”.
- “No va en `exe_proton_status`, que se ejecuta muy a menudo.”
- “Textos en `i18n/messages.json`; documentación en `README.md` y `README.es.md`.”
- “`bin/uninstall.sh` no toca las copias.”

Additional execution constraints: no new dependencies, root operations, polling, or version bump. Use feature branch `feat/proton-saves`, conventional commits, and a PR referring to `#3` without closing it. Incremental copies and NAS support remain outside this change.

## Review Focus

1. **Wine folders linked to host folders:** skip linked roots and descendants without reading their targets or copying the copies directory recursively. Tests: Tasks 1 and 3.
2. **Full disk, interrupted archive write, or same-second filename collision:** publish no partial archive, overwrite no existing copy, and abort loading if its safety copy fails. Tests: Tasks 3 and 4.
3. **Late preview responses after cancellation, another selection, or a mutation:** discard stale results; Cargar remains unavailable until the selected copy has a successful current preview. Tests: Task 7.
4. **Existing destination symlinks or hardlinks:** reject symlink destinations before changes; replace regular files without modifying another pathname sharing their inode. Tests: Task 4.
5. **Corruption after valid archive members:** reject truncated payloads before changing the prefix or creating a safety copy; never restore only the valid beginning. Tests: Tasks 2 and 4.

---

### Task 1: Inventory the prefix and existing copies

**Files:**

- Create: `bin/exe-proton-saves.py`
- Create/Test: `tests/test_exe_proton_saves.py`
- Modify: `i18n/messages.json`

**Interfaces:**

- Consumes: `${WINEPREFIX:-$HOME/.local/share/umu/default}`.
- Produces: `OMARCHY_TOOL_PROTON_SAVES_DIR`, defaulting to `$HOME/Documents/Partidas Proton`; empty values use the default.
- Produces these JSON records:
  - `Group`: `{name: str, area: "Saved Games"|"Documents"|"AppData", bytes: int}`; `bytes >= 0`, uncompressed.
  - `Copy`: `{name: str, timestamp: int, bytes: int, kind: "partidas"|"automatica"|"antes-de-cargar"}`; basename, Unix seconds from file mtime, compressed file size, kind from the filename.
  - `Listing`: `{prefixExists: bool, groups: list[Group], copies: list[Copy]}`.
  - `ErrorResult`: `{error: str}`; `error` is a Spanish catalog source string.
- Produces in `bin/exe-proton-saves.py`:
  - `SavesError(source: str)`, exposing `source: str`.
  - `locations() -> tuple[Path, Path]`: canonical prefix and copies directory.
  - `scan_prefix(prefix: Path) -> list[tuple[str, int]]`: relative POSIX member names and sizes; directory sizes are zero.
  - `group_entries(entries: Iterable[tuple[str, int]]) -> list[Group]`.
  - `list_saves() -> Listing`.
  - `main(argv: list[str]) -> int`; initially accepts `list`.
- CLI contract: `python3 bin/exe-proton-saves.py list`; one JSON object on stdout, exit `0` on success; `ErrorResult` and exit `1` on failure.
- Produces test fixture `ProtonSaves`: temporary `self.root`, `self.prefix`, `self.user`, `self.copies`; `put(relative: str, data: bytes) -> Path`; `tree(root: Path) -> dict[str, bytes]`.

- [ ] **Write failing inventory tests.**

  Use `importlib.util` and `TemporaryDirectory`, following `tests/test_disk_tiles.py`. Set temporary `HOME`, `WINEPREFIX`, and `OMARCHY_TOOL_PROTON_SAVES_DIR`; no real desktop or prefix access.

  ```python
  def test_groups_first_level_folders_and_sums_appdata_areas(self):
      self.put("Saved Games/God of War/slot.sav", b"123")
      self.put("Documents/Juego ñ/slot.sav", b"12")
      self.put("AppData/Local/TunnelForge.exe/a", b"12")
      self.put("AppData/Roaming/TunnelForge.exe/b", b"345")
      groups = {(g["area"], g["name"]): g["bytes"]
                for g in saves.list_saves()["groups"]}
      self.assertEqual(groups, {
          ("Saved Games", "God of War"): 3,
          ("Documents", "Juego ñ"): 2,
          ("AppData", "TunnelForge.exe"): 5,
      })

  def test_linked_roots_and_descendants_are_not_followed(self):
      # Create linked Documents and a linked child under Saved Games,
      # both targeting self.root / "outside".
      self.assertEqual(saves.scan_prefix(self.prefix), [])
      self.assertEqual(self.tree(self.root / "outside"), outside_before)

  def test_loose_files_empty_directories_and_markup_names(self):
      self.put("Documents/readme.txt", b"x")
      self.put("Saved Games/<img src=x>/slot", b"12")
      # Also create an empty Saved Games/Empty directory.
      groups = {(g["area"], g["name"]): g["bytes"]
                for g in saves.list_saves()["groups"]}
      self.assertEqual(groups[("Documents", "Documents")], 1)
      self.assertEqual(groups[("Saved Games", "<img src=x>")], 2)
      self.assertNotIn(("Saved Games", "Empty"), groups)
  ```

  Add named tests asserting:

  ```python
  # test_group_bytes_are_file_size_not_disk_usage (sparse file, st_size 33 MiB):
  self.assertEqual(groups[("Saved Games", "God of War")], 33554400)

  # test_exclusions_are_exact:
  self.assertEqual(excluded_member_names, set())
  self.assertIn("AppData/Local/My Game/slot", member_names)

  # test_missing_prefix_and_missing_copies_are_read_only:
  self.assertFalse(result["prefixExists"])
  self.assertEqual(result["groups"], [])
  self.assertEqual(result["copies"], [])
  self.assertFalse(self.copies.exists())

  # test_copy_metadata_ignores_links_and_unfinished_files:
  self.assertEqual({c["name"] for c in result["copies"]}, expected_basenames)
  self.assertEqual(safety_copy["kind"], "antes-de-cargar")
  self.assertIsInstance(safety_copy["timestamp"], int)

  # test_default_paths_and_empty_overrides_match_runner:
  self.assertEqual(prefix, fake_home / ".local/share/umu/default")
  self.assertEqual(copies, fake_home / "Documents/Partidas Proton")
  ```

- [ ] **Run the tests and confirm failure.**

  ```bash
  python3 -B -m unittest discover -s tests -p 'test_exe_proton_saves.py' -v
  ```

  Expected: failure because `bin/exe-proton-saves.py` does not exist.

- [ ] **Implement the declared inventory interfaces in `bin/exe-proton-saves.py`.**

  Walk with `lstat`, including only regular files and directories. Skip missing source roots, every source symlink below the canonical prefix, special files, and the exact excluded subtrees. Unreadable existing content is an error rather than a silently incomplete inventory.

  Group Documents/Saved Games by their first-level folder; group AppData by the folder immediately below Local/LocalLow/Roaming, combining identical names under area `AppData`. Loose files aggregate under their area name. Sizes are `st_size`, never disk usage: on this btrfs machine a 33 MB save occupies 16 KB. Groups totalling zero bytes are not listed (the prefix ships empty `Documents/{Downloads,Music,Pictures,Templates,Videos}`), though empty directories are still archived. Sort groups by area and name, and copies newest first with basename as a tie-breaker.

  List only regular, non-symlink files matching the two generated filename patterns. Listing creates no directories and opens no archives. Reject a copies directory inside the canonical prefix; reject a symlink used as the copies directory.

  Add Spanish error source keys with English translations to `.en` in `i18n/messages.json`; retain the existing Spanish source fallback. Keep byte values numeric: **QML owns size formatting**.

- [ ] **Run the inventory tests; expect every test to pass.**

  ```bash
  python3 -B -m unittest discover -s tests -p 'test_exe_proton_saves.py' -v
  ```

- [ ] **Commit on the feature branch.**

  At execution time, create `feat/proton-saves` before modifying files; preserve the existing untracked spec.

  ```bash
  git add bin/exe-proton-saves.py tests/test_exe_proton_saves.py i18n/messages.json
  git commit -m "feat: list Proton save data"
  ```

### Task 2: Validate and preview archives

**Files:**

- Modify: `bin/exe-proton-saves.py`
- Modify/Test: `tests/test_exe_proton_saves.py`
- Modify: `i18n/messages.json`

**Interfaces:**

- Consumes: Task 1 paths, grouping, error protocol, and test fixture.
- Produces:
  - `Preview`: `{name: str, groups: list[Group]}`.
  - `open_copy(name: str) -> BinaryIO`.
  - `validated_members(archive: tarfile.TarFile) -> list[tarfile.TarInfo]`.
  - `preview_copy(name: str) -> Preview`.
  - Helper CLI `preview NAME`, returning `Preview` or `ErrorResult`.
  - Test fixture method `make_copy(entries: list[tuple[tarfile.TarInfo, bytes]]) -> str`, writing `partidas-20261030-084500.tar.zst` inside `self.copies`.

- [ ] **Write failing archive-preview tests.**

  Build fixtures using native `tarfile.open(..., "w:zst")`.

  ```python
  def test_preview_matches_grouping_without_extracting(self):
      result = saves.preview_copy(name)
      self.assertEqual(result["name"], name)
      self.assertEqual(result["groups"], expected_groups)
      self.assertEqual(self.tree(self.prefix), prefix_before)
      self.assertEqual(self.tree(self.root / "outside"), {})

  def test_unsafe_members_reject_the_whole_archive(self):
      # Each bad member follows a valid Saved Games/Game/slot member.
      for bad_name in (
          "../outside", "/tmp/outside", "Documents/../outside",
          "Documents2/slot", "AppData/Other/slot",
          "AppData/Local/Temp/slot", "AppData/Roaming/Microsoft/slot",
      ):
          with self.subTest(name=bad_name):
              # Rebuild the fixture with bad_name.
              with self.assertRaises(saves.SavesError):
                  saves.preview_copy(name)
              self.assertEqual(self.tree(self.prefix), prefix_before)

  def test_truncated_late_payload_is_rejected(self):
      # First member is valid; truncate inside a later large random payload.
      with self.assertRaises(saves.SavesError):
          saves.preview_copy(name)
      self.assertEqual(self.tree(self.prefix), prefix_before)
  ```

  Add parameterized tests for symlink, hardlink, FIFO, character/block device, duplicate member names, and file/child conflicts. Add basename tests:

  ```python
  # test_copy_name_cannot_escape_or_follow_a_link:
  for name in ("../partidas-20261030-084500.tar.zst",
               "/tmp/partidas-20261030-084500.tar.zst",
               linked_copy_name):
      with self.subTest(name=name):
          with self.assertRaises(saves.SavesError):
              saves.preview_copy(name)
  ```

- [ ] **Run the tests and confirm failure.**

  ```bash
  python3 -B -m unittest discover -s tests -p 'test_exe_proton_saves.py' -v
  ```

  Expected: missing `preview_copy`/archive-validation interfaces.

- [ ] **Implement the declared preview interfaces in `bin/exe-proton-saves.py`.**

  `open_copy` accepts only generated basenames, opens relative to the configured copies directory without following the archive symlink, and verifies a regular file. Keep that descriptor open throughout each operation.

  Open archives with `"r:zst"`. Validate every effective member name and type, including PAX-resolved names: relative canonical paths, no `..`, only the allowed roots, no excluded subtree, only regular files/directories, no duplicate destinations or file/child conflicts. Allow a structural `AppData` directory entry, but no files directly under it.

  Read every regular-file payload during validation so a truncated late payload cannot pass a header-only preview. Preview performs no extraction or prefix writes. Add catalog entries for invalid name, unsafe archive, unreadable archive, and corrupt archive errors.

- [ ] **Run the tests; expect all inventory and preview tests to pass.**

  ```bash
  python3 -B -m unittest discover -s tests -p 'test_exe_proton_saves.py' -v
  ```

- [ ] **Commit.**

  ```bash
  git add bin/exe-proton-saves.py tests/test_exe_proton_saves.py i18n/messages.json
  git commit -m "feat: validate and preview Proton save copies"
  ```

### Task 3: Save complete, private copies

**Files:**

- Modify: `bin/exe-proton-saves.py`
- Modify/Test: `tests/test_exe_proton_saves.py`
- Modify: `i18n/messages.json`

**Interfaces:**

- Consumes: Task 1 inventory and Task 2 archive contract.
- Produces:
  - `Saved`: `{name: str}`.
  - `proton_open() -> bool`.
  - `write_copy(prefix: Path, copies: Path, kind: Literal["partidas", "antes-de-cargar"], now: datetime | None = None) -> str`.
  - `save_copy() -> Saved`.
  - Helper CLI `save`, returning `Saved` or `ErrorResult`.
  - Probe override `OMARCHY_TOOL_WINESERVER_PID`: present and empty means closed; present and nonempty means open; absent uses the real probe.

- [ ] **Write failing save tests.**

  ```python
  def test_save_uses_native_zstandard_and_private_modes(self):
      result = saves.save_copy()
      self.assertRegex(result["name"], r"^partidas-\d{8}-\d{6}\.tar\.zst$")
      self.assertEqual(self.copies.stat().st_mode & 0o777, 0o700)
      self.assertEqual((self.copies / result["name"]).stat().st_mode & 0o777, 0o600)
      self.assertEqual(saves.preview_copy(result["name"])["groups"],
                       saves.list_saves()["groups"])

  def test_open_proton_refuses_save_without_creating_copies(self):
      with patch.dict(os.environ, {"OMARCHY_TOOL_WINESERVER_PID": "4242"}):
          with self.assertRaises(saves.SavesError):
              saves.save_copy()
      self.assertFalse(self.copies.exists())

  def test_failed_write_publishes_no_partial_archive(self):
      with patch.object(tarfile.TarFile, "addfile",
                        side_effect=OSError("disk full")):
          with self.assertRaises(saves.SavesError):
              saves.save_copy()
      self.assertEqual(list(self.copies.iterdir()), [])
      self.assertEqual(self.tree(self.prefix), prefix_before)

  def test_same_second_never_overwrites_an_existing_copy(self):
      name = saves.write_copy(self.prefix, self.copies, "partidas", fixed_time)
      before = (self.copies / name).read_bytes()
      with self.assertRaises(saves.SavesError):
          saves.write_copy(self.prefix, self.copies, "partidas", fixed_time)
      self.assertEqual((self.copies / name).read_bytes(), before)
  ```

  Also assert that saved members exactly match the permitted inventory, symlink targets never appear, hardlinked source files become regular archive members, and an already-existing permissive copies directory becomes `0700`.

  Test the real probe by mocking `/proc` reads for `wineserver`, `wineserver64`, unrelated processes, and a process disappearing during the scan. A failure to inspect the process directory must prevent mutation.

- [ ] **Run the tests and confirm failure.**

  ```bash
  python3 -B -m unittest discover -s tests -p 'test_exe_proton_saves.py' -v
  ```

  Expected: missing `save_copy`, `write_copy`, and `proton_open`.

- [ ] **Implement the declared save interfaces in `bin/exe-proton-saves.py`.**

  Without the override, inspect `/proc/<pid>/comm` for `wineserver` or `wineserver64`; do not poll or spawn a process. Check before saving, and reject a missing prefix.

  Write `"w:zst"` archives to a private temporary file in the copies directory. Emit regular-file/directory members from the inventory without recursive `tarfile.add` traversal or link records. Recheck source types before opening files; do not follow source links.

  Close and flush the archive before publishing its exact timestamped name. Use publication that fails if the final name already exists; remove only this operation’s unfinished temporary file on failure. Do not retry with sleeps, suffixes, or overwritten archives.

  Add catalog entries including `cierra Proton antes de guardar o cargar` and `ya existe una copia de este segundo; inténtalo de nuevo`.

- [ ] **Run the tests; expect every inventory, preview, and save test to pass.**

  ```bash
  python3 -B -m unittest discover -s tests -p 'test_exe_proton_saves.py' -v
  ```

- [ ] **Commit.**

  ```bash
  git add bin/exe-proton-saves.py tests/test_exe_proton_saves.py i18n/messages.json
  git commit -m "feat: save Proton data in private archives"
  ```

### Task 4: Load with a safety copy and preserve newer data

**Files:**

- Modify: `bin/exe-proton-saves.py`
- Modify/Test: `tests/test_exe_proton_saves.py`
- Modify: `i18n/messages.json`

**Interfaces:**

- Consumes: `open_copy`, `validated_members`, `proton_open`, `write_copy`, and previous JSON/error records.
- Produces:
  - `Loaded`: `{name: str, safetyCopy: str}`.
  - `validate_destinations(prefix: Path, members: list[tarfile.TarInfo]) -> None`.
  - `load_copy(name: str) -> Loaded`.
  - Helper CLI `load NAME`, returning `Loaded` or `ErrorResult`.

- [ ] **Write failing restore tests.**

  ```python
  def test_load_overlays_all_areas_and_preserves_later_slots(self):
      # Save old contents in all five included roots, then change them
      # and add Saved Games/Game/later.sav.
      result = saves.load_copy(name)
      self.assertEqual(self.tree(self.user), expected_overlay)
      self.assertEqual((self.user / "Saved Games/Game/later.sav").read_bytes(),
                       b"later")
      self.assertRegex(result["safetyCopy"],
                       r"^antes-de-cargar-\d{8}-\d{6}\.tar\.zst$")
      # Read its members with tarfile: the changed pre-load bytes must exist.
      self.assertEqual(safety_contents, before_load)
      self.assertIn(result["safetyCopy"],
                    [c["name"] for c in saves.list_saves()["copies"]])

  def test_failed_safety_copy_leaves_prefix_unchanged(self):
      with patch.object(saves, "write_copy",
                        side_effect=saves.SavesError("no se pudo guardar la copia")):
          with self.assertRaises(saves.SavesError):
              saves.load_copy(name)
      self.assertEqual(self.tree(self.prefix), prefix_before)

  def test_destination_links_cannot_modify_another_path(self):
      # First use an existing destination symlink, then a hardlinked file.
      with self.assertRaises(saves.SavesError):
          saves.load_copy(name)
      self.assertEqual(outside.read_bytes(), b"outside")
      # Rebuild destination as a hardlink and load.
      saves.load_copy(name)
      self.assertEqual(outside.read_bytes(), b"outside")
      self.assertEqual(destination.read_bytes(), b"archived")

  def test_bad_late_member_or_payload_changes_nothing(self):
      # Exercise both a late unsafe member and a truncated late payload.
      with self.assertRaises(saves.SavesError):
          saves.load_copy(name)
      self.assertEqual(self.tree(self.prefix), prefix_before)
      self.assertEqual(self.tree(self.copies), copies_before)
  ```

  Add tests asserting:

  ```python
  # test_open_proton_refuses_load:
  self.assertEqual(self.tree(self.prefix), prefix_before)
  self.assertEqual(self.tree(self.copies), copies_before)

  # test_extraction_uses_data_filter:
  self.assertEqual(extractall_call.kwargs["filter"], "data")

  # test_destination_type_conflict_is_rejected_before_backup:
  self.assertEqual(self.tree(self.prefix), prefix_before)
  self.assertEqual(self.tree(self.copies), copies_before)

  # test_proton_starting_during_safety_copy_prevents_overlay:
  self.assertEqual(self.tree(self.prefix), prefix_before)
  self.assertTrue(safety_archive.exists())
  ```

- [ ] **Run the tests and confirm failure.**

  ```bash
  python3 -B -m unittest discover -s tests -p 'test_exe_proton_saves.py' -v
  ```

  Expected: missing `load_copy` and `validate_destinations`.

- [ ] **Implement the declared restore interfaces in `bin/exe-proton-saves.py`.**

  Apply this order:

  1. Reject open Proton or a missing prefix.
  2. Open the selected archive once; validate all members and payloads.
  3. Validate existing destination components below the canonical prefix: reject symlinks, special files, and file/directory conflicts.
  4. Extract the validated archive into a private temporary staging directory inside the copies directory (not `/tmp`, which may be a small tmpfs) using `filter="data"`.
  5. Create `write_copy(prefix, copies, "antes-de-cargar")`; abort if it fails.
  6. Recheck Proton and destination components before applying staged contents.
  7. Merge directories and replace each regular destination through a temporary file in its destination directory. Never truncate an existing inode or delete unrelated files.

  Temporary staging is removed on every exit; the safety archive is retained on success or a subsequent failure. Do not restore archive ownership metadata. Add localized errors distinguishing failure before a safety copy from failure after one was retained.

- [ ] **Run the helper suite; expect every test to pass.**

  ```bash
  python3 -B -m unittest discover -s tests -p 'test_exe_proton_saves.py' -v
  ```

- [ ] **Commit.**

  ```bash
  git add bin/exe-proton-saves.py tests/test_exe_proton_saves.py i18n/messages.json
  git commit -m "feat: restore Proton data with safety copies"
  ```

### Task 5: Expose dispatcher actions, notifications, and retention guarantees

**Files:**

- Modify: `bin/modules/exe-proton.sh`
- Modify: `bin/omarchy-tool`
- Modify: `bin/uninstall.sh`
- Modify/Test: `tests/exe-proton.sh`
- Modify/Test: `tests/i18n.sh`
- Modify: `i18n/messages.json`
- Modify: `README.md`
- Modify: `README.es.md`

**Interfaces:**

- Consumes: helper CLI `list`, `preview NAME`, `save`, `load NAME`; `ErrorResult`; existing `tool_text`, `fail`, and `operation_notice`.
- Produces normal dispatcher actions:
  - `omarchy-tool exe-proton saves-list` → `Listing` or `ErrorResult`.
  - `omarchy-tool exe-proton saves-preview NAME` → `Preview` or `ErrorResult`.
  - `omarchy-tool exe-proton saves-save` → exit status; no success stdout.
  - `omarchy-tool exe-proton saves-load NAME` → exit status; no success stdout.
- Produces Bash functions:
  - `exe_proton_saves_list`
  - `exe_proton_saves_preview NAME`
  - `exe_proton_saves_save`
  - `exe_proton_saves_load NAME`
  - `exe_proton_saves_change <save|load> [NAME]`
- Only the exact `(exe-proton, saves-list)` and `(exe-proton, saves-preview)` pairs bypass main’s flock. Save/load retain serialization.

- [ ] **Write failing dispatcher and retention tests using `check`.**

  Extend the existing temporary environment and fake notification executable. Set `OMARCHY_TOOL_WINESERVER_PID=""` so the host session cannot influence tests.

  ```bash
  check "saves listing works while Proton module is disabled" \
    '"$tool" exe-proton saves-list >"$work/saves-list.json" &&
     jq -e ".prefixExists and (.groups | type == \"array\")" "$work/saves-list.json" >/dev/null'

  check "save sends completion notification without switch feedback" \
    '"$tool" exe-proton saves-save &&
     grep -qF "Partidas y datos guardados." "$work/notify-all.log"'

  check "open Proton refuses save and sends failure notification" \
    '! OMARCHY_TOOL_WINESERVER_PID=4242 "$tool" exe-proton saves-save 2>"$work/saves-error" &&
     grep -qF "cierra Proton antes de guardar o cargar" "$work/saves-error"'

  check "status keeps its existing lightweight Proton shape" \
    '"$tool" status | jq -e ".modules[\"exe-proton\"] | keys == [\"applied\",\"enabled\",\"summary\"]" >/dev/null'
  ```

  Hold the real runtime lock with a child process, with readiness signaled through a fixture file and release through a pipe. Assert:

  ```bash
  check "listing bypasses a held mutation lock" \
    'timeout 2 "$tool" exe-proton saves-list >/dev/null'

  check "preview bypasses a held mutation lock" \
    'timeout 2 "$tool" exe-proton saves-preview "$saves_name" >/dev/null'

  check "saving still waits for the mutation lock" \
    'timeout 0.2 "$tool" exe-proton saves-save; [[ $? == 124 ]]'

  check "loading still waits for the mutation lock" \
    'timeout 0.2 "$tool" exe-proton saves-load "$saves_name"; [[ $? == 124 ]]'
  ```

  Release/wait for the child even on test failure. Product code gains no waiting loop.

  Before existing disable and copied-uninstaller calls, create copies in both the default and overridden copies directories and record their hashes. Add checks asserting their bytes remain unchanged after disable and uninstall, including when the original plugin directory is unavailable. Verify an explicit `WINEPREFIX` selects the alternate temporary prefix and saves request no privilege.

  Extend `tests/i18n.sh` with temporary copies and the fake process override. Assert English failure text under `LC_ALL=C.UTF-8`, Spanish under `LANG=es`, and unchanged user folder names.

- [ ] **Run the tests and confirm failure.**

  ```bash
  bash tests/run.sh
  bash tests/i18n.sh
  ```

  Expected: unknown `saves-*` actions; new retention assertions may already pass.

- [ ] **Implement the Bash interfaces and exact lock exemptions.**

  Listing/preview invoke the helper directly, preserving its JSON and status. `exe_proton_saves_change` captures mutation results, translates `ErrorResult.error`, sends exactly one terminal `operation_notice`, then calls `fail` on failure. Treat unexpected helper output as a localized failure.

  Success messages:

  - `Partidas y datos guardados.`
  - `Partidas y datos cargados. Se conservó una copia previa.`

  Add the two read exemptions before main’s existing flock path without exempting other module actions. Leave `exe_proton_status` unchanged.

  Add a retention comment beside Proton cleanup in `bin/uninstall.sh`; add no copies path to cleanup inventory.

  Update both READMEs together: included/excluded folders, full-copy semantics, `WINEPREFIX`, copies override/default location, permissions, open-Proton refusal, merge behavior, safety copies, CLI commands, and retention after disable/uninstall. Update the existing cleanup exception lists to include Proton copies.

- [ ] **Run both suites; expect all tests to pass.**

  ```bash
  bash tests/run.sh
  bash tests/i18n.sh
  ```

- [ ] **Commit.**

  ```bash
  git add bin/modules/exe-proton.sh bin/omarchy-tool bin/uninstall.sh tests/exe-proton.sh tests/i18n.sh i18n/messages.json README.md README.es.md
  git commit -m "feat: expose Proton save actions through dispatcher"
  ```

### Task 6: Chosen folder and automatic copy at startup

**Files:**

- Modify: `bin/exe-proton-saves.py`, `bin/modules/exe-proton.sh`, `bin/omarchy-tool`, `i18n/messages.json`, `README.md`, `README.es.md`
- Modify/Test: `tests/test_exe_proton_saves.py`, `tests/exe-proton.sh`

**Interfaces:**

- Consumes: Tasks 1-5 helper and dispatcher.
- Config keys, read by the helper from `${OMARCHY_TOOL_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/omarchy-tool}/config.json`: `.modules["exe-proton"].savesFolder: str` and `.modules["exe-proton"].savesAuto: bool` (default `false`).
- Changes `locations()`: `OMARCHY_TOOL_PROTON_SAVES_DIR` still wins and is the exact copies directory; otherwise copies are `<savesFolder or $HOME/Documents>/Partidas Proton`.
- Adds to `Listing`: `folder: str`, `auto: bool`.
- Produces helper CLI `auto` → exit `0` with `{name: str|null}`; `null` means nothing changed. Failures use `ErrorResult`.
- Produces dispatcher actions `omarchy-tool exe-proton saves-folder PATH` and `saves-auto on|off`.
- Produces `auto_copy() -> dict`, `prune_automatic(copies: Path, keep: int = 5) -> None`, `fingerprint(entries) -> str`; constant `AUTO_KEEP = 5`.
- Produces Bash `exe_proton_startup` and a generic `<module>_startup` hook called from `cmd_apply` only.

- [ ] **Write failing tests.**

  ```python
  # test_default_folder_creates_subfolder_but_chosen_folder_must_keep_it:
  self.assertEqual(saves.locations()[1], chosen / "Partidas Proton")
  shutil.rmtree(chosen / "Partidas Proton")
  with self.assertRaises(saves.SavesError):
      saves.save_copy()
  self.assertFalse((chosen / "Partidas Proton").exists())

  # test_chmod_failure_on_ntfs_does_not_fail_save (os.chmod raises PermissionError):
  self.assertRegex(saves.save_copy()["name"], r"^partidas-")

  # test_auto_skips_when_nothing_changed:
  self.assertIsNotNone(saves.auto_copy()["name"])
  self.assertIsNone(saves.auto_copy()["name"])

  # test_prune_keeps_five_newest_automatic_and_every_other_kind:
  self.assertEqual(automatic_left, newest_five)
  self.assertTrue(manual.exists()); self.assertTrue(safety.exists())

  # test_auto_with_open_proton_makes_no_copy_and_no_error:
  self.assertIsNone(saves.auto_copy()["name"])
  self.assertEqual(copies_after, copies_before)

  # test_auto_off_makes_no_copy:
  self.assertIsNone(saves.auto_copy()["name"])
  ```

  Replace Task 3's assertion on a permissive existing copies directory: it still becomes `0700` when chmod is permitted. Add the file name pattern `automatica-…` and `kind` to Task 1's copy tests.

  ```bash
  check "apply makes no automatic copy while off" '"$tool" apply && [[ -z $(find "$saves_dir" -name "automatica-*" 2>/dev/null) ]]'
  check "apply copies once when on, then skips unchanged data" '"$tool" exe-proton saves-auto on && "$tool" apply && "$tool" apply && [[ $(find "$saves_dir" -name "automatica-*" | wc -l) == 1 ]]'
  check "enable and disable never trigger the startup copy" '[[ $(find "$saves_dir" -name "automatica-*" | wc -l) == 1 ]]'
  check "unavailable folder notifies without failing apply" '"$tool" apply && grep -qF "no se pudo crear la copia automática" "$work/notify-all.log"'
  check "folder action refuses missing paths and the prefix" '! "$tool" exe-proton saves-folder "$work/missing" 2>/dev/null && ! "$tool" exe-proton saves-folder "$WINEPREFIX/drive_c" 2>/dev/null'
  check "disable keeps copies" '[[ -n $(find "$saves_dir" -name "automatica-*") ]]'
  ```

- [ ] **Run both suites and confirm failure.** `python3 -B -m unittest discover -s tests -p 'test_exe_proton_saves.py' -v` and `bash tests/run.sh`; expected: missing `auto_copy` and unknown `saves-folder`.

- [ ] **Implement.**

  `cmd_apply` calls each module's `<module>_startup` after its apply loop; `exe_proton_enable`/`disable` do not. `exe_proton_startup` runs the helper's `auto` from `$TOOL_DIR`, never fails `apply`, stays silent on success or skip, and sends one `operation_notice critical` on failure. No runner change, systemd unit, timer, or resident process.

  `auto_copy` returns `{name: null}` when `savesAuto` is off or `proton_open()` is true. It compares `fingerprint` (names, sizes, mtimes) with `$STATE_DIR/exe-proton-saves.fingerprint`, kept outside the module state so disable does not reset it; it writes the fingerprint only after a published copy and prunes only after publication. `apply` holds main's lock, so no second lock is needed. `uninstall.sh` removes the fingerprint file, not the copies.

  `chmod` failures are ignored only for `EPERM`/`ENOTSUP`. `saves-folder` resolves the path, requires an existing directory outside the prefix, creates `Partidas Proton`, then writes config with `config_update`; an empty path restores the default. No migration of existing copies.

  Add catalog strings and update both READMEs with the folder, unmounted-disk behavior, startup timing, using Guardar before a reinstall, retention of five, and NTFS note.

- [ ] **Run both suites; expect all to pass.** Same commands, plus `bash tests/i18n.sh`.

- [ ] **Commit.**

  ```bash
  git add bin/exe-proton-saves.py bin/modules/exe-proton.sh bin/omarchy-tool bin/uninstall.sh tests/test_exe_proton_saves.py tests/exe-proton.sh i18n/messages.json README.md README.es.md
  git commit -m "feat: choose the copies folder and copy automatically at startup"
  ```

### Task 7: Build the page workflow and complete full verification

**Files:**

- Modify: `modules/ExeProton.qml`
- Create/Test: `tests/test_proton_saves_page.py`
- Test: `tests/test_qml_security.py`
- Test: `tests/test_operation_feedback.py`
- Modify: `i18n/messages.json`
- Modify: `README.md`
- Modify: `README.es.md`

**Interfaces:**

- Consumes: Task 5 dispatcher actions; `Listing`, `Preview`, `ErrorResult`; existing `tool.toolPath`, `tool.run(args)`, `tool.busy`, `tool.t(source)`, and `tool.status.language`.
- Produces QML state:
  - `listing`: `Listing`, initially `{prefixExists:false, groups:[], copies:[]}`.
  - `selectedCopy: string`, initially `""`.
  - `preview: Preview|null`, initially `null`.
  - `readError: string`, initially `""`.
  - `readGeneration: int`, initially `0`.
  - `activeRead` and `pendingRead`: `null` or `{args: string[], generation: int}`.
  - `loading: bool`, initially `false`.
- Produces QML functions:
  - `requestRead(args: string[]) -> void`
  - `pumpRead() -> void`
  - `finishRead(request: object, output: string, exitCode: int) -> void`
  - `viewCopy(name: string) -> void`
  - `cancelView() -> void`
  - `saveData() -> void`
  - `loadData() -> void`
  - `formatBytes(bytes: number) -> string`
  - `areaLabel(area: string) -> string`
- Read commands use `[tool.toolPath, "exe-proton", ...args]`; mutations use `tool.run(["exe-proton", "saves-save"])` or `tool.run(["exe-proton", "saves-load", selectedCopy])`.

- [ ] **Write failing page tests.**

  Follow `tests/test_operation_feedback.py`: extract actual QML JavaScript functions with its existing `function(source, name)` utility and execute them with the existing Node test dependency. Stub the process, tool, and queued callbacks.

  ```javascript
  // test_reads_use_binary_path_and_mutations_use_queue
  root.requestRead(['saves-list']);
  assert.deepEqual(readProc.command,
    ['/fake/tool', 'exe-proton', 'saves-list']);
  assert.deepEqual(mutations, []);

  // test_load_requires_successful_selected_preview
  root.selectedCopy = copyA;
  root.loadData();
  assert.deepEqual(mutations, []);
  // Deliver a current valid Preview for copyA.
  root.loadData();
  assert.deepEqual(mutations,
    [['exe-proton', 'saves-load', copyA]]);

  // test_stale_preview_after_cancel_or_other_selection_is_discarded
  root.viewCopy(copyA);
  const oldRequest = root.activeRead;
  root.cancelView();
  root.finishRead(oldRequest, JSON.stringify(previewA), 0);
  assert.equal(root.preview, null);
  root.loadData();
  assert.deepEqual(mutations, []);

  // Repeat after selecting copyB, and after invalidating on a mutation.

  // test_failed_or_malformed_read_clears_previous_preview
  root.finishRead(currentRequest, '{"error":"archivo no válido"}', 1);
  assert.equal(root.preview, null);
  assert.notEqual(root.readError, '');
  root.loadData();
  assert.deepEqual(mutations, []);
  ```

  Add assertions that busy/loading prevents mutation, save submits exactly one queued action, and cancellation submits none. Check listing/preview sizes use numeric byte fields, and an HTML-like game name remains unchanged.

  Add source guards:

  ```python
  self.assertIn("import Quickshell.Io", source)
  self.assertIn("StdioCollector", source)
  self.assertNotIn("Timer {", source)
  self.assertNotIn("status.enabled", source)
  ```

  Existing `test_qml_security.py` must cover every new `Text`.

- [ ] **Run the tests and confirm failure.**

  ```bash
  python3 -B -m unittest discover -s tests -p 'test_proton_saves_page.py' -v
  ```

  Expected: the required QML methods and process are absent.

- [ ] **Implement the declared page interfaces in `modules/ExeProton.qml`.**

  Keep the existing introduction and use the spacing, colors, separators, and buttons from `modules/NetworkIp.qml`. Show the saves section from `listing.prefixExists`, independently of module enablement.

  Add its own `Process` and `StdioCollector`. Start listing after `tool` is assigned by the Loader; refresh after `tool.busy` becomes false. Invalidate previews and outstanding generations when a mutation starts. Use one active read and one latest pending request; reject responses whose generation or selected basename no longer matches.

  Render:

  - `Partidas y datos`, `Guardar incluirá:`, grouped contents, and Guardar.
  - `Copias:`, each copy’s localized date and compressed size, the label `Copia previa a cargar` or `Automática` by `kind`, and Ver.
  - `Carpeta de copias` (TextField showing `listing.folder`, setting `tool.typing` on focus like `modules/NetworkIp.qml`, Aplicar → `saves-folder`) and a `Copia automática al encender` button with `active: listing.auto` → `saves-auto on|off`.
  - After a successful current preview only: its grouped contents, Cargar, and Cancelar.
  - Localized empty, loading, and read-failure states.

  `saveData`/`loadData` enforce the same guards as their buttons. Disable mutations during page reads or `tool.busy`. A successful preview is cleared on cancellation, refresh, selection change, or mutation.

  Format sizes in QML using powers of `1024`, localized numerals, and catalog templates `%1 B`, `%1 KB`, `%1 MB`, `%1 GB`, `%1 TB`. Translate area labels through Spanish sources `Partidas guardadas`, `Documentos`, and `AppData`. Every `Text` sets `textFormat: Text.PlainText`; external names remain literal data.

  Add all page strings to the catalog. Update both README sections together with the Ver → Cargar workflow and its availability while the module is disabled.

- [ ] **Run the page tests; expect all to pass.**

  ```bash
  python3 -B -m unittest discover -s tests -p 'test_proton_saves_page.py' -v
  /usr/lib/qt6/bin/qmlformat modules/ExeProton.qml >/dev/null
  ```

- [ ] **Run full verification and scanners.**

  ```bash
  bash tests/run.sh
  bash tests/i18n.sh
  python3 -B -m unittest discover -s tests -v
  /usr/lib/qt6/bin/qmlformat modules/ExeProton.qml >/dev/null
  shellcheck -f gcc --shell=bash bin/omarchy-tool bin/modules/exe-proton.sh bin/uninstall.sh tests/exe-proton.sh tests/i18n.sh
  ruff check --no-cache --select S --output-format concise bin/exe-proton-saves.py tests/test_exe_proton_saves.py tests/test_proton_saves_page.py
  gitleaks detect --no-banner --redact --source .
  osv-scanner scan --recursive .
  rg --files -g 'Dockerfile*' -g '*.Dockerfile' -0 | xargs -0 -r hadolint
  git diff --check
  git diff --exit-code -- manifest.json
  ```

  Expected: all applicable tests/checks pass; manifest is unchanged. Record OSV as inapplicable if it finds no supported dependency manifests, and Hadolint as inapplicable when there are no Dockerfiles. Report scanner findings by location and rule without secret values. Fix feature-related findings and rerun affected checks; do not install tools or dependencies.

- [ ] **Self-check coverage and interface consistency.**

  Confirm all five review-focus cases have their named regression tests; the helper has no subprocess tar; extraction uses `filter="data"`; both read actions bypass flock; both mutations remain locked and notify on completion; status performs no inventory work; cleanup preserves copies; documentation stays bilingual; no incremental, NAS, version, or release changes entered the diff.

- [ ] **Commit.**

  ```bash
  git add modules/ExeProton.qml tests/test_proton_saves_page.py i18n/messages.json README.md README.es.md
  git commit -m "feat: add Proton save and load page"
  ```

- [ ] **Prepare the feature PR after verification.**

  Title: `feat: add manual Proton save copies`

  Describe the full-copy workflow, validation, safety copy, retention, and verification results. Include `Related to #3`; do not use a closing reference. Leave version changes, tagging, and release publication for the separately approved release step.
