'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');

function sweetiebotModule(extensions = path.join(os.homedir(), '.vscode', 'extensions')) {
  const versions = fs.readdirSync(extensions)
    .filter(name => name.startsWith('pony-factor.sweetiebot-scm-'))
    .sort((a, b) => b.localeCompare(a, 'en', { numeric: true }));
  for (const version of versions) {
    for (const relativePath of ['branches/new-workspace.js', 'new_workspace.js']) {
      const modulePath = path.join(extensions, version, relativePath);
      if (fs.existsSync(modulePath)) return modulePath;
    }
  }
  throw new Error('Install Sweetiebot to open independent workspaces.');
}

async function openWorkspace(code, folder, name, {
  create,
  extensions,
  run = promisify(execFile)
} = {}) {
  const uri = location => ({ scheme: 'file', fsPath: location });
  let launchAttempted = false;
  try {
    create ??= require(sweetiebotModule(extensions)).openIndependentWorkspace;
    return await create({
      workspace: { workspaceFolders: [{ uri: uri(folder), name }] },
      Uri: { file: uri },
      commands: {
        async executeCommand(command, target, options) {
          if (command !== 'vscode.openFolder' || options?.forceNewWindow !== true) {
            throw new Error('Unsupported Sweetiebot launch command.');
          }
          launchAttempted = true;
          await run(code, ['--new-window', target.fsPath]);
        }
      }
    });
  } catch (error) {
    // Once VS Code has been invoked, preserve its result instead of opening
    // a second window on a different checkout.
    if (launchAttempted) throw error;
    await run(code, ['--new-window', folder]);
    return { target: folder };
  }
}

if (require.main === module) {
  const [code, folder, name] = process.argv.slice(2);
  if (!code || !folder || !name) process.exitCode = 1;
  else openWorkspace(code, folder, name).catch(() => { process.exitCode = 1; });
}

module.exports = { sweetiebotModule, openWorkspace };
