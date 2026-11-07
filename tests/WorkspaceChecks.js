'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { sweetiebotModule, openWorkspace } = require('../scripts/open-workspace');

(async () => {
  const extensions = fs.mkdtempSync(path.join(os.tmpdir(), 'mobli-extensions-'));
  try {
    const legacy = path.join(extensions, 'pony-factor.sweetiebot-scm-0.3.9', 'new_workspace.js');
    const current = path.join(extensions, 'pony-factor.sweetiebot-scm-0.3.10', 'branches', 'new-workspace.js');
    for (const modulePath of [legacy, current]) {
      fs.mkdirSync(path.dirname(modulePath), { recursive: true });
      fs.writeFileSync(modulePath, '');
    }
    assert.equal(sweetiebotModule(extensions), current);
    fs.unlinkSync(current);
    assert.equal(sweetiebotModule(extensions), legacy);
    fs.unlinkSync(legacy);
    assert.throws(() => sweetiebotModule(extensions), /Install Sweetiebot/);
  } finally {
    fs.rmSync(extensions, { recursive: true, force: true });
  }
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
