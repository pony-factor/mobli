# Repository Launcher

A simple desktop launcher for repositories in `~/GitHub`. Repositories are grouped by their current GitHub origin owner, falling back to the local folder for other remotes. Each owner gets a column with its GitHub display name and logo above a vertical list of repositories ranked by activity and launcher usage, with pinned repositories first. Repository columns stay 260 points wide and notification columns stay 320 points wide, with larger list and header text. Columns scroll horizontally when they exceed the window width, and each repository list scrolls independently. Click a repository to open a separate VS Code window.

Public organization and personal owner profiles come from GitHub. Names and logos are cached together for seven days in `~/Library/Caches/studio.repository-launcher/owners`. Fresh cache entries avoid network requests; expired entries refresh automatically when the app opens or becomes active. Previously cached profiles remain available offline. Opening Settings refreshes repositories and notifications and bypasses the seven-day cache to reload owner names and images. Owners without a GitHub display name fall back to their login.

Settings includes saved toggles for repository counts in category headers and GitHub owner slugs beneath display names, plus controls for organization order. Hide owner slugs to show just the organization or personal display name on both tabs; owners without a cached display name still show their login. Drag an organization header by its grip onto the left or right half of another column to place it before or after that organization, or use the ordering arrows in Settings. The order is shared by Repositories and Notifications and persists between launches. Click the pin beside any repository to keep it at the top of its category; click it again to unpin. Pins also persist between launches.

The repository list persists in `~/Library/Application Support/studio.repository-launcher/repositories.json`. On launch, the saved list and cached owner names and logos appear immediately, while repository discovery refreshes in the background. Local changes appear before GitHub requests finish, and a failed GitHub refresh keeps the previous remote list available. Successful GitHub repository results are reused for five minutes; opening Settings forces a refresh.

Repository discovery also refreshes in the background when the app becomes active. It checks `.git` directories and worktree marker files and asks Git for the origin URL without reading repository contents or credential files.

The compiled `Repository Launcher.app` lives in this repository and supports both Apple Silicon and Intel Macs. Drag that app to the Dock once. GitHub Actions tests and rebuilds it after changes reach `main`, then commits the new app back to `main`. After the workflow finishes, pull the repository, quit the launcher, and reopen it from the same Dock shortcut. The shortcut continues to point to the same app path. Source edits alone do not change a running app, and GitHub does not pull updates onto your Mac automatically.

For an optional stable link in your Applications folder, run this from the repository root before adding that link to the Dock:

```sh
mkdir -p "$HOME/Applications"
ln -s "$PWD/Repository Launcher.app" "$HOME/Applications/Repository Launcher.app"
```

If that Applications path already contains an installed copy, move it aside first. Keep the clone at the same path so the link remains valid.

To rebuild immediately after local source edits, quit the app and run `zsh build-app.sh`. This replaces the repository app with a build for your Mac's architecture; an optional first argument selects a different destination. Building locally requires Swift command-line tools. Running the app requires macOS 14 or later and Visual Studio Code in `/Applications` or `~/Applications`.

The build bundles a Dock icon generated with AppKit. Cached public profiles stay outside this checkout. The apps are ad-hoc signed and are not notarized.

Pull requests run the tests, build both architectures, and verify a universal app without publishing changes. On `main`, the workflow commits only the compiled app, skips publication if newer source changes have arrived, and uses GitHub's workflow token so its generated commit does not start another build. You can also start **Build app** manually on `main`. Workflow runs and optional downloads are available at https://github.com/pony-factor/mobli/actions/workflows/build-app.yml; downloads remain available for 30 days.

## Notifications

The Notifications tab shows unread GitHub threads in owner columns, including repositories that are not cloned locally. Click a title to open its discussion on GitHub, or click its checkmark to mark the thread as read. The inbox loads all pages and refreshes while the tab is open, respecting GitHub’s polling interval and conditional responses. Notifications stay in memory; only public owner names and logos use the seven-day disk cache.

Install GitHub CLI to connect an account. An existing GitHub CLI sign-in works automatically. **Connect GitHub** opens GitHub CLI’s browser authorization in Terminal, where the one-time code appears. Complete authorization and return to the launcher. GitHub CLI manages credentials; the launcher never reads credential files or extracts tokens.

The ChatGPT repository extension currently uses personal tokens rather than a GitHub App sign-in. GitHub’s notifications API does not support GitHub App tokens or fine-grained personal tokens, so this launcher uses GitHub CLI’s OAuth connection with the notifications scope. API reference: https://docs.github.com/en/rest/activity/notifications

Run focused notification model and HTTP parsing checks with `zsh tests/check.sh`.
