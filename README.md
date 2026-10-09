# Repository Launcher

A simple desktop launcher for repositories in `~/GitHub`. Repositories are grouped by their current GitHub origin owner, falling back to the local folder for other remotes. Each owner gets a column with its GitHub display name and logo above a vertical list of repositories. Pins come first, followed by cloned repositories ordered by their most recent launcher use, then cloud-only repositories. Open counts break ties in recent use, with commit activity and name as fallbacks for projects you have not opened. Opening a repository through Folders also updates its launcher usage. Repository columns stay 260 points wide and notification columns stay 320 points wide, with larger list and header text. Columns scroll horizontally when they exceed the window width, and each repository list scrolls independently. Click a repository to open a separate VS Code window; Mobli leaves that window's focus to VS Code instead of raising every existing editor window.

Public organization and personal owner profiles come from GitHub. Names and logos are cached together for seven days in `~/Library/Caches/studio.repository-launcher/owners`. Fresh cache entries avoid network requests; expired entries refresh automatically when the app opens or becomes active. Previously cached profiles remain available offline. Opening Settings refreshes repositories and notifications and bypasses the seven-day cache to reload owner names and images. Owners without a GitHub display name fall back to their login.

Settings includes saved toggles for repository counts in category headers and GitHub owner slugs beneath display names, plus controls for organization order. Hide owner slugs to show just the organization or personal display name on both tabs; owners without a cached display name still show their login. The organization-order list also includes organizations from the connected GitHub account even when they do not currently contribute a repository or notification row. Drag an organization row in Settings to reorder it directly, drag an organization header by its grip onto the left or right half of another column, or use the ordering arrows. The order is shared by Repositories and Notifications and persists between launches. Click the pin beside any repository to keep it at the top of its category; click it again to unpin. Pins also persist between launches.

The repository list persists in `~/Library/Application Support/studio.repository-launcher/repositories.json`. On launch, the saved list and cached owner names and logos appear immediately, while repository discovery refreshes in the background. Local changes appear before GitHub requests finish, and a failed GitHub refresh keeps the previous remote list available. Successful GitHub repository results are reused for five minutes; opening Settings forces a refresh.

Find searches local folders and the connected GitHub repository catalog by repository name or owner/name. Local repositories appear before cloud repositories, which show a cloud icon and their GitHub owner. Select a cloud result to open it on GitHub, or use its download button to clone it into `~/GitHub`. Results update when the repository catalog refreshes or a clone finishes.

Repository discovery also refreshes in the background when the app becomes active. It checks `.git` directories and worktree marker files and asks Git for the origin URL without reading repository contents or credential files.

Activating Mobli from the Dock or app switcher brings its window onto your current macOS desktop (Space) rather than returning to the desktop where it was last active. Reopening also restores a minimized or hidden launcher window on the current desktop without raising every window.

The compiled `Repository Launcher.app` lives in this repository and supports both Apple Silicon and Intel Macs. Drag that app to the Dock once. GitHub Actions tests and rebuilds it after changes reach `main`, then commits the new app back to `main`. The launcher checks for published builds every fifteen minutes and local source changes every minute. Updates prepare in the background and install at the same app path when you quit; reopen normally to use the new version. Quitting never waits for a download or build still in progress. Failed checks keep the current app. Local source changes take precedence over published builds and require Swift command-line tools to rebuild. Update checks use a separate cache and do not pull, stage, or modify your checkout. Update logs are saved under `~/Library/Application Support/studio.repository-launcher/updates`.

For an optional stable link in your Applications folder, run this from the repository root before adding that link to the Dock:

```sh
mkdir -p "$HOME/Applications"
ln -s "$PWD/Repository Launcher.app" "$HOME/Applications/Repository Launcher.app"
```

If that Applications path already contains an installed copy, move it aside first. Keep the clone at the same path so the link remains valid.

To rebuild immediately after local source edits, quit the app and run `zsh build-app.sh`. This replaces the repository app with a build for your Mac's architecture; an optional first argument selects a different destination. Building locally requires Swift command-line tools. Running the app requires macOS 14 or later and Visual Studio Code in `/Applications` or `~/Applications`.

The build bundles the Mayor Mare icon from `AppIcon.icns`, matching the existing GitHub Project app in Applications. The bundled icon works offline. Cached public profiles stay outside this checkout. The apps are ad-hoc signed and are not notarized.

Pull requests run the tests, build both architectures, and verify a universal app without publishing changes. On `main`, the workflow commits only the compiled app, skips publication if newer source changes have arrived, and uses GitHub's workflow token so its generated commit does not start another build. You can also start **Build app** manually on `main`. Workflow runs and optional downloads are available at https://github.com/pony-factor/mobli/actions/workflows/build-app.yml; downloads remain available for 30 days.

## Agenda

The Agenda tab sits beside Repositories on the left. It shows your GitHub project as simple vertical task lists grouped by Status, in the project's status-option order. Issues and pull requests open on GitHub; draft tasks open the project. Archived and deleted items are excluded, and the launcher loads every page of project items.

The tab defaults to your connected account and selects a project whose title contains “Agenda” when available. Choose another project from the menu, or enter an organization login to load its projects. The owner and project selection persist between launches. Use Refresh to reload items; returning to the app also refreshes the open Agenda tab.

If your GitHub CLI connection lacks project access, click **Connect GitHub Projects**, finish authorization in your browser, and refresh. This requests the `read:project` scope through GitHub CLI without reading or storing credentials in the launcher.

To edit items, click **Enable editing** and authorize the `project` scope for read and write access. Change an item’s column with **Move to** or drag it into another status column; **No status** clears its assignment. Click **Comment** on an issue or pull request to write and post a comment. Failed status updates leave the item in its original column, and failed comments keep your draft. Draft project tasks can move between columns but have no issue discussion to comment on.

## Notifications

The Notifications tab shows unread GitHub threads in owner columns, including repositories that are not cloned locally. Click a title to open its discussion on GitHub, or click its checkmark to mark the thread as read. The inbox loads all pages and refreshes while the tab is open, respecting GitHub’s polling interval and conditional responses. Notifications stay in memory; only public owner names and logos use the seven-day disk cache.

Install GitHub CLI to connect an account. An existing GitHub CLI sign-in works automatically. **Connect GitHub** opens GitHub CLI’s browser authorization in Terminal, where the one-time code appears. Complete authorization and return to the launcher. GitHub CLI manages credentials; the launcher never reads credential files or extracts tokens.

The ChatGPT repository extension currently uses personal tokens rather than a GitHub App sign-in. GitHub’s notifications API does not support GitHub App tokens or fine-grained personal tokens, so this launcher uses GitHub CLI’s OAuth connection with the notifications scope. API reference: https://docs.github.com/en/rest/activity/notifications

Run focused notification model and HTTP parsing checks with `zsh tests/check.sh`.

## GitHub event stream

The **Stream** tab displays a live-updating explorer for GitHub events. In **Settings → GitHub**, add repository sources (`owner/name`), organization sources, or user sources. Public feeds work without a key. For authenticated requests, save one or more named GitHub personal access tokens and choose a key for each watched source. Tokens go into **macOS Keychain**; preferences store only key labels, UUIDs, and watched source names. Deleting a key deletes its Keychain entry and makes any corresponding watches public.

The Stream tab combines events from all watched sources, remembers up to 500 observed events in memory while the tab is open, and checks for updates about once a minute while visible. GitHub may require a longer polling interval; the client honors the `X-Poll-Interval` response and conditional `ETag` responses. The feed is **polling, not a push/WebSocket connection**; it is not an exhaustive history or security audit trail. GitHub's organization and user events APIs expose public activity, and access to repository feeds depends on token permissions. Fine-grained PATs can use **Metadata (read)** permission for repository events. Do not grant write permissions just to view the stream.

Search by keyword across event summaries, actors, repositories, types, and raw JSON. Filter by watched source or event type. Select an event to inspect its JSON and copy the data or open it on GitHub. Export the currently filtered results as JSON or CSV for further analysis. No event payloads are saved to disk by Mobli unless you explicitly export them.
