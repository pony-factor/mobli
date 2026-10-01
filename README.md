# Repository Launcher

A simple desktop launcher for repositories in `~/GitHub`. Repositories are grouped by their current GitHub origin owner, falling back to the local folder for other remotes. Each owner gets a column with its GitHub display name and logo above an alphabetical vertical list of repositories. Columns scroll horizontally when needed, and each repository list scrolls independently. Click a repository to open a separate VS Code window.

Public organization and personal owner profiles come from GitHub. Names and logos are cached together for seven days in `~/Library/Caches/studio.repository-launcher/owners`. Fresh cache entries avoid network requests; expired entries refresh automatically when the app opens or becomes active. Previously cached profiles remain available offline. The refresh button bypasses the seven-day cache to reload owner names and images. Owners without a GitHub display name fall back to their login.

Repository discovery also refreshes when the app becomes active. It checks `.git` directories and worktree marker files and asks Git for the origin URL without reading repository contents or credential files.

Build and install with `zsh build-app.sh`. The default destination is `~/Applications/Repository Launcher.app`; an optional first argument changes it. Requires macOS 14 or later, Swift command-line tools, and Visual Studio Code in `/Applications` or `~/Applications`.

The build bundles a Dock icon generated with AppKit. Generated app binaries and cached profiles stay outside this checkout.

## Notifications

The Notifications tab shows unread GitHub threads in owner columns, including repositories that are not cloned locally. Click a title to open its discussion on GitHub, or click its checkmark to mark the thread as read. The inbox loads all pages and refreshes while the tab is open, respecting GitHub’s polling interval and conditional responses. Notifications stay in memory; only public owner names and logos use the seven-day disk cache.

Install GitHub CLI to connect an account. An existing GitHub CLI sign-in works automatically. **Connect GitHub** opens GitHub CLI’s browser authorization in Terminal, where the one-time code appears. Complete authorization and return to the launcher. GitHub CLI manages credentials; the launcher never reads credential files or extracts tokens.

The ChatGPT repository extension currently uses personal tokens rather than a GitHub App sign-in. GitHub’s notifications API does not support GitHub App tokens or fine-grained personal tokens, so this launcher uses GitHub CLI’s OAuth connection with the notifications scope. API reference: https://docs.github.com/en/rest/activity/notifications

Run focused notification model and HTTP parsing checks with `zsh tests/check.sh`.
