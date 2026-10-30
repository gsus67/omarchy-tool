"""Execute the panel's actual JS functions through delayed/failing operations."""
from pathlib import Path
import re
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


def function(source, name):
    match = re.search(r"function " + name + r"\([^)]*\)\s*\{", source)
    start, depth = match.start(), 1
    position = match.end()
    while depth:
        char = source[position]
        depth += (char == "{") - (char == "}")
        position += 1
    # QML methods resolve unqualified properties against their owning object.
    return "root." + name + " = (function() { with(root) { return " + source[start:position] + "; } })();"


@unittest.skipUnless(shutil.which("node"), "Node is required to execute QML JavaScript (installed in CI)")
class OperationFeedback(unittest.TestCase):
    def test_actual_panel_functions_wait_for_status_and_never_claim_false_success(self):
        source = (ROOT / "ToolPanel.qml").read_text()
        program = r'''
const assert = require('node:assert/strict');
const tasks = [];
const Qt = {callLater: callback => tasks.push(callback)};
const root = {t:s=>s, toolPath:'/fake/tool', modules:[{id:'disk-tiles',title:'Discos en mosaicos'}],
  status:{modules:{}}, queue:[], pendingFeedback:null, activeAction:[], feedback:'', error:'', busy:false};
const actionProc = {running:false,command:[]};
const statusProc = {running:false};
'''
        for name in ("moduleStatus", "actionTitle", "isSwitch", "diskTilesMessage", "completeFeedback", "refresh", "pump"):
            program += function(source, name) + "\n"
        program += r'''
root.queue.push(['disk-tiles','enable']);
root.pump();
assert.equal(root.busy,true);
assert.match(root.feedback,/Preparando y activando/);
assert.deepEqual(actionProc.command,['/fake/tool','disk-tiles','enable']);
actionProc.running=false;
root.pendingFeedback={args:['disk-tiles','enable'],exitCode:0};
root.queue.push(['disk-tiles','disable']);
root.pump();
assert.equal(root.queue.length,1,'next mutation waits for the completion status');
root.status.modules['disk-tiles']={enabled:true,applied:true,restartRequired:true,ready:false};
root.completeFeedback(true);
assert.equal(root.busy,false);
assert.match(root.feedback,/Cierra Archivos/);
assert.doesNotMatch(root.feedback,/Vista lista/);
assert.equal(root.pendingFeedback,null);

root.status.modules['disk-tiles'].ready=true;
assert.match(root.diskTilesMessage(),/Vista lista/);
root.status.modules['disk-tiles']={enabled:true,applied:true,restartRequired:false,ready:false};
assert.match(root.diskTilesMessage(),/Abre Archivos/);

for (const [exitCode,readable,applied] of [[7,true,true],[0,false,true],[0,true,false]]) {
  root.busy=true; root.error='';
  root.status.modules['disk-tiles']={enabled:true,applied};
  root.pendingFeedback={args:['disk-tiles','enable'],exitCode};
  root.completeFeedback(readable);
  assert.match(root.feedback,/No se pudo completar/);
  assert.notEqual(root.error,'');
  assert.equal(root.busy,false);
}

root.error='';
root.status.modules['disk-tiles']={enabled:false,applied:true};
root.pendingFeedback={args:['disk-tiles','disable'],exitCode:0};
root.completeFeedback(true);
assert.match(root.feedback,/Limpieza terminada/);
assert.equal(root.isSwitch(['apply']),false,'background sync is not a manual switch');
statusProc.running=true;
root.refreshPending=false;
root.refresh();
assert.equal(root.refreshPending,true,'an in-flight status must be refreshed again after the operation');
'''
        result = subprocess.run([shutil.which("node"), "-e", program], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__": unittest.main()
