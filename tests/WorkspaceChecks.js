'use strict';
const assert = require('node:assert/strict');
const { openWorkspace } = require('../scripts/open-workspace');

(async () => {
  const calls = [];
  const target = '/Library/Application Support/Sweetiebot/Workspaces/repo-123/repo';
  const create = async vscode => {
    assert.deepEqual(vscode.workspace.workspaceFolders, [{
      uri: { scheme: 'file', fsPath: '/source/repo with spaces' }, name: 'Repo'
    }]);
    await vscode.commands.executeCommand('vscode.openFolder', vscode.Uri.file(target), { forceNewWindow: true });
    return { target };
  };
  const result = await openWorkspace('/Code App/bin/code', '/source/repo with spaces', 'Repo', {
    create, run: async (...args) => calls.push(args)
  });
  assert.deepEqual(calls, [['/Code App/bin/code', ['--new-window', target]]]);
  assert.deepEqual(result, { target });
  await assert.rejects(openWorkspace('code', '/source/repo with spaces', 'Repo', {
    create, run: async () => { throw new Error('launch failed'); }
  }), /launch failed/);
  console.log('PASS: Sweetiebot selected folder, new-window launch, and launch failure propagation');
})().catch(error => { console.error(error); process.exitCode = 1; });
