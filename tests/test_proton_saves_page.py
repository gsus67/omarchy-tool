"""The Proton page's own logic, run with the real QML functions."""
from pathlib import Path
import shutil
import subprocess
import unittest

from test_operation_feedback import function

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "modules/ExeProton.qml").read_text()
FUNCTIONS = ("requestRead", "pumpRead", "finishRead", "viewCopy", "cancelView", "change", "saveData", "loadData",
             "formatBytes", "areaLabel", "setFolder", "setAuto")
PREAMBLE = """
const assert = require('node:assert/strict');
const mutations = [];
const readProc = {running: false, command: []};
const Qt = {callLater: f => f()};
const tool = {toolPath: '/fake/tool', busy: false, language: 'es', t: s => s, run: a => mutations.push(a)};
const root = {tool, t: s => s, readProc, listing: {prefixExists: false, groups: [], copies: []}, selectedCopy: '', preview: null,
  readError: '', readGeneration: 0, listGeneration: 0, activeRead: null, pendingReads: []};
const copyA = 'partidas-20261030-084500.tar.zst', copyB = 'partidas-20261030-084501.tar.zst';
const previewA = {name: copyA, groups: [{name: '<b>Juego</b>', area: 'Saved Games', bytes: 3}]};
const finishActive = output => { const request = root.activeRead; readProc.running = false; root.finishRead(request, output); };
"""


@unittest.skipUnless(shutil.which("node"), "Node is required to execute QML JavaScript (installed in CI)")
class ProtonSavesPage(unittest.TestCase):
    def run_page(self, body):
        functions = "\n".join(function(SOURCE, name) for name in FUNCTIONS)
        result = subprocess.run([shutil.which("node"), "-e", PREAMBLE + functions + body],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_reads_use_binary_path_and_changes_use_the_queue(self):
        self.run_page("""
          root.requestRead(['saves-list']);
          assert.deepEqual(readProc.command, ['/fake/tool', 'exe-proton', 'saves-list']);
          assert.equal(readProc.running, true);
          assert.deepEqual(mutations, []);
          finishActive(JSON.stringify({prefixExists: true, groups: [], copies: []}));
          assert.equal(root.listing.prefixExists, true);
          root.saveData();
          assert.deepEqual(mutations, [['exe-proton', 'saves-save']]);
        """)

    def test_load_requires_successful_selected_preview(self):
        self.run_page("""
          root.selectedCopy = copyA;
          root.loadData();
          assert.deepEqual(mutations, []);
          root.viewCopy(copyA);
          root.loadData();
          assert.deepEqual(mutations, [], 'still reading');
          finishActive(JSON.stringify(previewA));
          assert.deepEqual(root.preview, previewA);
          root.loadData();
          assert.deepEqual(mutations, [['exe-proton', 'saves-load', copyA]]);
          assert.equal(root.preview, null, 'a change clears the preview');
        """)

    def test_stale_preview_after_cancel_or_other_selection_is_discarded(self):
        self.run_page("""
          root.viewCopy(copyA);
          root.cancelView();
          finishActive(JSON.stringify(previewA));
          assert.equal(root.preview, null);
          root.loadData();
          assert.deepEqual(mutations, []);

          root.viewCopy(copyA);
          root.viewCopy(copyB);
          finishActive(JSON.stringify(previewA));
          assert.equal(root.preview, null);
          assert.equal(readProc.command[3], copyB, 'the newest request runs next');
          finishActive(JSON.stringify({name: copyB, groups: []}));
          assert.equal(root.preview.name, copyB);
        """)

    def test_stale_preview_after_a_change_is_discarded(self):
        self.run_page("""
          root.viewCopy(copyA);
          root.saveData();
          finishActive(JSON.stringify(previewA));
          assert.equal(root.preview, null);
          assert.equal(root.selectedCopy, '');
        """)

    def test_listing_from_before_a_change_is_discarded(self):
        self.run_page("""
          root.requestRead(['saves-list']);
          root.saveData();
          finishActive(JSON.stringify({prefixExists: true, groups: [], copies: []}));
          assert.equal(root.listing.prefixExists, false);
        """)

    def test_opening_a_copy_does_not_lose_a_waiting_listing(self):
        self.run_page("""
          root.viewCopy(copyA);
          root.requestRead(['saves-list']);
          root.viewCopy(copyB);
          finishActive(JSON.stringify(previewA));
          assert.equal(readProc.command[2], 'saves-list');
          finishActive(JSON.stringify({prefixExists: true, groups: [], copies: []}));
          assert.equal(root.listing.prefixExists, true);
          assert.equal(readProc.command[3], copyB);
          finishActive(JSON.stringify({name: copyB, groups: []}));
          assert.equal(root.preview.name, copyB);
        """)

    def test_failed_or_malformed_read_clears_previous_preview(self):
        self.run_page("""
          for (const output of ['{"error":"la copia está dañada"}', 'not json', '']) {
            root.viewCopy(copyA);
            finishActive(JSON.stringify(previewA));
            assert.deepEqual(root.preview, previewA);
            root.viewCopy(copyA);
            finishActive(output);
            assert.equal(root.preview, null);
            assert.notEqual(root.readError, '');
            root.loadData();
            assert.deepEqual(mutations, []);
          }
        """)

    def test_busy_prevents_every_change(self):
        self.run_page("""
          root.viewCopy(copyA);
          finishActive(JSON.stringify(previewA));
          tool.busy = true;
          root.loadData();
          root.saveData();
          root.setFolder('/mnt/datos');
          root.setAuto(true);
          assert.deepEqual(mutations, []);
        """)

    def test_save_submits_one_action_and_cancel_none(self):
        self.run_page("""
          root.saveData();
          assert.deepEqual(mutations, [['exe-proton', 'saves-save']]);
          root.cancelView();
          assert.equal(mutations.length, 1);
        """)

    def test_folder_and_automatic_actions(self):
        self.run_page("""
          root.setFolder('  /mnt/datos con espacio ');
          root.setAuto(true);
          root.setAuto(false);
          assert.deepEqual(mutations, [['exe-proton', 'saves-folder', '/mnt/datos con espacio'],
            ['exe-proton', 'saves-auto', 'on'], ['exe-proton', 'saves-auto', 'off']]);
        """)

    def test_sizes_and_areas(self):
        self.run_page("""
          assert.equal(root.formatBytes(0), '0 B');
          assert.equal(root.formatBytes(1023), '1023 B');
          assert.equal(root.formatBytes(1536), '1,5 KB');
          assert.equal(root.formatBytes(33554400), '32 MB');
          tool.language = 'en';
          assert.equal(root.formatBytes(1536), '1.5 KB');
          assert.equal(root.areaLabel('Saved Games'), 'Partidas guardadas');
          assert.equal(root.areaLabel('Documents'), 'Documentos');
          assert.equal(root.areaLabel('AppData'), 'AppData');
        """)

    def test_page_reads_by_itself_without_polling_or_module_state(self):
        self.assertIn("import Quickshell.Io", SOURCE)
        self.assertIn("StdioCollector", SOURCE)
        self.assertNotIn("Timer {", SOURCE)
        self.assertNotIn("status.enabled", SOURCE)


if __name__ == "__main__":
    unittest.main()
