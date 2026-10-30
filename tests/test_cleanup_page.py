"""The cleanup page's own logic, run with the real QML functions."""
from pathlib import Path
import shutil
import subprocess
import unittest

from test_operation_feedback import function

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "modules/Cleanup.qml").read_text()
FUNCTIONS = ("requestRead", "pumpRead", "collectRead", "exitRead", "completeRead", "finishRead", "validListing",
             "busyChanged", "findCategory", "openCache", "closeCache", "setMarked", "selectedFolders", "selectedBytes",
             "beginClean", "cancelClean", "confirmClean", "formatBytes")
PREAMBLE = """
const assert = require('node:assert/strict');
const mutations = [];
const readProc = {running: false, command: []};
const Qt = {callLater: f => f()};
const tool = {toolPath: '/fake/tool', busy: false, language: 'es', t: s => s, run: a => mutations.push(a)};
const root = {tool, t: s => s, readProc, listing: {categories: []}, listed: false, readError: '', readGeneration: 0,
  activeRead: null, pendingRead: false, readOutput: null, readExit: null, cacheView: false, confirmation: null};
const folder = (name, bytes, marked) => ({name, bytes, marked});
const cache = {id: 'cache', title: 'Caché', summary: 's', warning: '', bytes: 600, count: 3, requiresPassword: false,
  names: [], revision: '', rows: [
    {id: 'folder:uv', title: 'uv', summary: 's', bytes: 200, folders: [folder('uv', 200, true)]},
    {id: 'folder:otras', title: 'otras', summary: 's', bytes: 300, folders: [folder('otras', 300, false)]},
    {id: 'otras', title: 'Otras', summary: 's', bytes: 100, folders: [folder('a', 60, true), folder('b', 40, false)]}]};
const tmp = {id: 'tmp', title: 'T', summary: 's', warning: '', bytes: 10, count: 1, requiresPassword: false, names: [],
  revision: '', rows: []};
const orphans = {id: 'orphans', title: 'O', summary: 's', warning: '', bytes: 20, count: 2, requiresPassword: true,
  names: ['app', 'lib'], revision: 'abc', rows: []};
const core = {id: 'coredumps', title: 'C', summary: 's', warning: 'se pierde', bytes: 30, count: 1, requiresPassword: true,
  names: [], revision: '', rows: []};
const listingJSON = JSON.stringify({categories: [tmp, cache, orphans, core]});
const finishActive = (output, code = 0) => {
  readProc.running = false; root.collectRead(output); root.exitRead(code);
};
const finishListing = () => { root.requestRead(); finishActive(listingJSON); };
"""


@unittest.skipUnless(shutil.which("node"), "Node is required to execute QML JavaScript (installed in CI)")
class CleanupPage(unittest.TestCase):
    def run_page(self, body):
        functions = "\n".join(function(SOURCE, name) for name in FUNCTIONS)
        result = subprocess.run([shutil.which("node"), "-e", PREAMBLE + functions + body], capture_output=True,
                                text=True, timeout=10, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_reads_use_their_own_process_and_changes_use_the_queue(self):
        self.run_page("""
          root.requestRead();
          assert.deepEqual(readProc.command, ['/fake/tool', 'cleanup', 'list']);
          assert.equal(readProc.running, true);
          assert.deepEqual(mutations, []);
          finishActive(listingJSON);
          assert.equal(root.listed, true);
          root.beginClean('tmp');
          assert.deepEqual(mutations, [], 'Limpiar alone deletes nothing');
          root.confirmClean();
          assert.deepEqual(mutations, [['cleanup', 'clean', 'tmp', '']]);
        """)

    def test_both_orders_of_output_and_exit_count(self):
        self.run_page("""
          root.requestRead();
          readProc.running = false;
          root.exitRead(0);
          assert.equal(root.listed, false, 'still waiting for the output');
          root.collectRead(listingJSON);
          assert.equal(root.listed, true);

          root.requestRead();
          readProc.running = false;
          root.collectRead('not json');
          assert.equal(root.readError, '', 'still waiting for the exit');
          root.exitRead(0);
          assert.notEqual(root.readError, '');
          assert.equal(root.listed, false);
        """)

    def test_cancel_never_submits_a_clean(self):
        self.run_page("""
          finishListing();
          root.beginClean('tmp');
          root.cancelClean();
          assert.equal(root.confirmation, null);
          root.confirmClean();
          assert.deepEqual(mutations, []);
        """)

    def test_confirming_twice_submits_once(self):
        self.run_page("""
          finishListing();
          root.beginClean('tmp');
          root.confirmClean();
          root.confirmClean();
          assert.equal(mutations.length, 1);
        """)

    def test_a_stale_read_cannot_enable_cleaning(self):
        self.run_page("""
          root.requestRead();
          tool.busy = true;
          root.busyChanged();
          finishActive(listingJSON);
          assert.equal(root.listed, false);
          root.beginClean('tmp');
          assert.equal(root.confirmation, null);
          root.confirmClean();
          assert.deepEqual(mutations, []);
        """)

    def test_bad_answers_hide_everything(self):
        self.run_page("""
          const bad = ['not json', '', 'null', '[]', '{}', '{"categories":"x"}', '{"categories":[{"id":1}]}',
            '{"categories":[{"id":"tmp","bytes":"10"}]}', '{"error":"no se pudo completar la limpieza"}'];
          for (const output of bad) {
            finishListing();
            assert.equal(root.listed, true);
            root.requestRead();
            finishActive(output);
            assert.equal(root.listed, false, output);
            assert.notEqual(root.readError, '', output);
            assert.deepEqual(root.listing.categories, [], output);
            root.beginClean('tmp');
            assert.equal(root.confirmation, null, output);
          }
        """)

    def test_valid_json_with_a_failed_exit_is_a_failure(self):
        self.run_page("""
          root.requestRead();
          finishActive(listingJSON, 1);
          assert.equal(root.listed, false);
          assert.notEqual(root.readError, '');
        """)

    def test_a_translated_error_comes_through(self):
        self.run_page("""
          tool.t = s => 'EN:' + s;
          root.t = tool.t;
          root.requestRead();
          finishActive('{"error":"no se pudo completar la limpieza"}', 1);
          assert.equal(root.readError, 'EN:no se pudo completar la limpieza');
        """)

    def test_a_change_from_elsewhere_clears_the_confirmation_and_rereads_after(self):
        self.run_page("""
          finishListing();
          root.beginClean('tmp');
          tool.busy = true;
          root.busyChanged();
          assert.equal(root.confirmation, null);
          tool.busy = false;
          root.busyChanged();
          assert.equal(readProc.running, true);
        """)

    def test_nothing_can_start_while_busy_or_reading(self):
        self.run_page("""
          finishListing();
          tool.busy = true;
          root.beginClean('tmp');
          assert.equal(root.confirmation, null);
          root.setMarked(cache.rows[0], false);
          assert.deepEqual(mutations, []);
          tool.busy = false;
          root.requestRead();
          root.beginClean('tmp');
          assert.equal(root.confirmation, null, 'still reading');
        """)

    def test_a_category_that_disappeared_cannot_be_cleaned(self):
        self.run_page("""
          finishListing();
          root.requestRead();
          finishActive(JSON.stringify({categories: [tmp]}));
          root.beginClean('coredumps');
          assert.equal(root.confirmation, null);
        """)

    def test_the_cache_confirmation_uses_only_marked_folders(self):
        self.run_page("""
          finishListing();
          root.beginClean('cache');
          assert.deepEqual(root.confirmation.names, ['uv', 'a']);
          assert.equal(root.confirmation.bytes, 260);
          root.confirmClean();
          assert.deepEqual(mutations, [['cleanup', 'clean', 'cache', '["uv","a"]']]);
        """)

    def test_nothing_marked_means_no_cache_clean(self):
        self.run_page("""
          const none = JSON.parse(JSON.stringify(cache));
          for (const row of none.rows) for (const item of row.folders) item.marked = false;
          root.requestRead();
          finishActive(JSON.stringify({categories: [none]}));
          assert.deepEqual(root.selectedFolders(), []);
          assert.equal(root.selectedBytes(), 0);
          root.beginClean('cache');
          assert.equal(root.confirmation, null);
        """)

    def test_a_group_switch_sends_its_real_folders_and_a_real_otras_stays_apart(self):
        self.run_page("""
          finishListing();
          root.setMarked(cache.rows[2], true);
          root.setMarked(cache.rows[1], true);
          assert.deepEqual(mutations, [['cleanup', 'cache-mark', '["a","b"]', 'on'],
            ['cleanup', 'cache-mark', '["otras"]', 'on']]);
        """)

    def test_orphans_show_everything_that_goes_and_send_only_the_revision(self):
        self.run_page("""
          finishListing();
          root.beginClean('orphans');
          assert.deepEqual(root.confirmation.names, ['app', 'lib']);
          root.confirmClean();
          assert.deepEqual(mutations, [['cleanup', 'clean', 'orphans', 'abc']]);
        """)

    def test_a_warning_reaches_the_confirmation(self):
        self.run_page("""
          finishListing();
          root.beginClean('coredumps');
          assert.equal(root.confirmation.warning, 'se pierde');
        """)

    def test_the_cache_view_closes_when_the_cache_is_gone(self):
        self.run_page("""
          finishListing();
          root.openCache();
          assert.equal(root.cacheView, true);
          root.requestRead();
          finishActive(JSON.stringify({categories: [tmp]}));
          assert.equal(root.cacheView, false);
        """)

    def test_sizes_follow_the_proton_saves_format(self):
        self.run_page("""
          assert.equal(root.formatBytes(0), '0 B');
          assert.equal(root.formatBytes(1536), '1,5 KB');
          assert.equal(root.formatBytes(33554400), '32 MB');
          tool.language = 'en';
          assert.equal(root.formatBytes(1536), '1.5 KB');
        """)

    def test_the_page_is_an_entry_without_a_switch_that_reads_by_itself(self):
        panel = (ROOT / "ToolPanel.qml").read_text()
        self.assertRegex(panel, r'id: "cleanup", parent: "extras", title: root\.t\("Limpieza"\), '
                                r'source: "modules/Cleanup\.qml", switchable: false')
        self.assertIn("ToggleSwitch", SOURCE)
        self.assertIn("StdioCollector", SOURCE)
        self.assertNotIn("Timer {", SOURCE)
        self.assertNotIn("status.enabled", SOURCE)
        self.assertNotIn("execDetached", SOURCE)


if __name__ == "__main__":
    unittest.main()
