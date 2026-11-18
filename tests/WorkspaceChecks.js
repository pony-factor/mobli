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
    const fallbackCalls = [];
    const options = { extensions, run: async (...args) => fallbackCalls.push(args) };
    const folder = '/normal/repo with spaces';
    assert.deepEqual(await openWorkspace('code', folder, 'Repo', options), { target: folder });
    // Also cover a missing extensions directory on a plain VS Code install.
    await openWorkspace('code', folder, 'Repo', { ...options, extensions: path.join(extensions, 'missing') });
    fs.writeFileSync(legacy, 'module.exports = {};');
    await openWorkspace('code', folder, 'Repo', options);
    await openWorkspace('code', folder, 'Repo', {
      ...options, create: async () => { throw new Error('No local main branch'); }
    });
    assert.deepEqual(fallbackCalls, Array.from({ length: 4 }, () => ['code', ['--new-window', folder]]));
    await assert.rejects(openWorkspace('code', folder, 'Repo', {
      extensions: path.join(extensions, 'missing'),
      run: async () => { throw new Error('VS Code unavailable'); }
    }), /VS Code unavailable/);
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
  let failedLaunches = 0;
  await assert.rejects(openWorkspace('code', '/source/repo with spaces', 'Repo', {
    create, run: async () => { failedLaunches++; throw new Error('launch failed'); }
  }), /launch failed/);
  assert.equal(failedLaunches, 1, 'Do not retry a failed VS Code launch on another checkout');
  console.log('PASS: Sweetiebot launch, plain-folder fallback, and launch failure propagation');
})().catch(error => { console.error(error); process.exitCode = 1; });
