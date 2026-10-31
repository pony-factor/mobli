#!/bin/zsh
set -eu
repo_dir=${0:A:h:h}
node "$repo_dir/tests/WorkspaceChecks.js"
# Validate branch discovery and recent-first selection separately from SwiftUI.
xcrun swiftc -parse-as-library "$repo_dir/Sources/RecentBranches.swift" "$repo_dir/tests/RecentBranchChecks.swift" -o /tmp/mobli-recent-branches-$
/tmp/mobli-recent-branches-$
rm -f /tmp/mobli-recent-branches-$
check_dir=$(mktemp -d /tmp/mobli-checks.XXXXXX)
trap 'rm -f "$check_dir/AgendaAPI.swift" "$check_dir/agenda-api-checks" "$check_dir/PinPlacement.swift" "$check_dir/pin-placement-checks" "$check_dir/Activity.swift" "$check_dir/activity-checks" "$check_dir/StreamModel.swift" "$check_dir/stream-checks" "$check_dir/Owner.swift" "$check_dir/Inbox.swift" "$check_dir/checks" "$check_dir/Discovery.swift" "$check_dir/discovery-checks" "$check_dir/OwnerOrder.swift" "$check_dir/owner-order-checks" "$check_dir/Agenda.swift" "$check_dir/agenda-checks"; rmdir "$check_dir"' EXIT
# Regression guard: delegate independent clones to Sweetiebot without raising existing windows.
python3 - "$repo_dir/Sources/RepoLauncher.swift" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
launch = source.split('private func openInVSCode(', 1)[1].split('\nenum Palette', 1)[0]
assert 'forResource: "open-workspace", withExtension: "js"' in launch, "Use the bundled Sweetiebot bridge"
assert 'url.path, displayName]' in launch, "Pass the selected checkout to Sweetiebot"
assert '.activateAllWindows' not in launch, "Do not raise every existing VS Code window"
assert 'vsCode.activate(' not in launch and 'yieldActivation(' not in launch, "Leave window focus to the VS Code CLI"
print("VS Code selected-window launch checks passed")
PY
# Regression guard: the unified branch menu opens existing checkouts rather than cloning
# another workspace or inventing a different Git branch.
python3 - "$repo_dir/Sources/RepoLauncher.swift" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
menu = source.split('private struct RecentBranchMenu:', 1)[1].split('struct RepositoryRow: View', 1)[0]
branch_open = source.split('    func openBranch(_ branch: RecentBranch)', 1)[1].split('    func openFolder(', 1)[0]
assert 'Task.sleep(for: .seconds(1))' in menu, "Delay hover menu by one second"
assert 'ForEach(branches.indices' in menu and 'openBranch(branch)' in menu, "Every listed branch must be clickable"
assert '.accessibilityLabel("Open branch \\(branch.name)")' in menu, "Branch rows need accessible launch actions"
assert 'Text("Recent")' in menu and 'index == 0' in menu, "Only the first branch gets the recent pill"
assert 'worktree' not in menu.lower(), "Do not separate or badge worktrees in the branch menu"
assert 'RecentBranches.active(at: branch.url, named: branch.name)' in branch_open, "Validate stale checkout paths"
assert 'openInVSCode(branch.url, displayName: branch.name, independent: false)' in branch_open, "Open the existing checkout, not a new main clone"
print("Unified clickable branch picker checks passed")
PY
# Regression guard: activating Mobli follows the current macOS Space, even if
# its existing window is still visible on a different Space.
python3 - "$repo_dir/Sources/RepoLauncher.swift" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
delegate = source.split('@MainActor final class LauncherAppDelegate:', 1)[1].split('@main struct RepoLauncherApp:', 1)[0]
setup, reopen = delegate.split('    func applicationShouldHandleReopen(', 1)
assert 'forName: NSWindow.didBecomeKeyNotification' in setup, "Observe all new launcher windows"
assert setup.count('window.collectionBehavior.insert(.moveToActiveSpace)') >= 2, "Configure each window before subsequent activation"
assert 'removeObserver(launcherWindowObserver)' not in setup, "Observe future windows after the first one"
assert 'hasVisibleWindows _: Bool' in reopen, "Handle Dock reopening even with visible windows"
assert 'guard !flag' not in reopen, "Do not defer to macOS for windows on other Spaces"
assert 'frontWindow.collectionBehavior.insert(.moveToActiveSpace)' in reopen, "Move the chosen window to the active Space"
assert 'frontWindow.makeKeyAndOrderFront(nil)' in reopen, "Raise the chosen window"
assert 'if frontWindow.isMiniaturized' in reopen, "Restore minimized windows"
assert 'for window in windows' not in reopen, "Do not raise every window"
print("Mobli current-desktop activation checks passed")
PY
python3 - "$repo_dir" "$check_dir" <<'PY'
from pathlib import Path
import sys
repo, out = map(Path, sys.argv[1:])
source = (repo / 'Sources' / 'RepoLauncher.swift').read_text()
(out / 'Discovery.swift').write_text('import Foundation\n' + source[source.index('struct Repository:'):source.index('struct OwnerProfile:')])
(out / 'Owner.swift').write_text('import Foundation\n' + source[source.index('struct OwnerProfile:'):source.index('actor OwnerCache {')])
(out / 'OwnerOrder.swift').write_text('import Foundation\n' + source[source.index('enum OwnerOrdering {'):source.index('@MainActor final class OwnerOrderPreferences:')])
(out / 'PinPlacement.swift').write_text('import Foundation\nimport Combine\n' + source[source.index('struct Repository:'):source.index('struct OwnerProfile:')] + source[source.index('@MainActor final class RepositoryUsageStore:'):source.index('@MainActor final class Library:')])
source = (repo / 'Sources' / 'Notifications.swift').read_text()
(out / 'Inbox.swift').write_text(source[:source.index('@MainActor final class Inbox:')])
source = (repo / 'Sources' / 'Activity.swift').read_text()
(out / 'Activity.swift').write_text(source[:source.index('@MainActor final class ActivityFeed:')])
source = (repo / 'Sources' / 'Stream.swift').read_text()
(out / 'StreamModel.swift').write_text('import Foundation\n' + source[source.index('struct StreamEvent:'):source.index('// MARK: - macOS Keychain-backed API keys')])
source = (repo / 'Sources' / 'Agenda.swift').read_text()
(out / 'Agenda.swift').write_text('import Foundation\n' + source[source.index('struct AgendaProject:'):source.index('enum AgendaFailure:')])
(out / 'AgendaAPI.swift').write_text('import Foundation\nimport AppKit\nenum GitHubInbox { static let executable: String? = nil }\n' + source[source.index('struct AgendaProject:'):source.index('@MainActor final class Agenda:')])
PY
xcrun swiftc -parse-as-library "$check_dir/Owner.swift" "$check_dir/Inbox.swift" "$repo_dir/tests/InboxChecks.swift" -o "$check_dir/checks" -framework AppKit
"$check_dir/checks"

xcrun swiftc -parse-as-library "$check_dir/Activity.swift" "$repo_dir/tests/ActivityChecks.swift" -o "$check_dir/activity-checks" -framework AppKit -framework SwiftUI
"$check_dir/activity-checks"

xcrun swiftc -parse-as-library "$check_dir/StreamModel.swift" "$repo_dir/tests/StreamChecks.swift" -o "$check_dir/stream-checks"
"$check_dir/stream-checks"

xcrun swiftc -parse-as-library "$check_dir/Discovery.swift" "$repo_dir/tests/DiscoveryChecks.swift" -o "$check_dir/discovery-checks"
"$check_dir/discovery-checks"

xcrun swiftc -parse-as-library "$check_dir/OwnerOrder.swift" "$repo_dir/tests/OwnerOrderChecks.swift" -o "$check_dir/owner-order-checks"
"$check_dir/owner-order-checks"

xcrun swiftc -parse-as-library "$check_dir/Agenda.swift" "$repo_dir/tests/AgendaChecks.swift" -o "$check_dir/agenda-checks"
"$check_dir/agenda-checks"

xcrun swiftc -parse-as-library "$check_dir/PinPlacement.swift" "$repo_dir/tests/PinPlacementChecks.swift" -o "$check_dir/pin-placement-checks"
"$check_dir/pin-placement-checks"

xcrun swiftc -parse-as-library "$check_dir/AgendaAPI.swift" "$repo_dir/tests/AgendaWriteChecks.swift" -o "$check_dir/agenda-api-checks" -framework AppKit
"$check_dir/agenda-api-checks"
