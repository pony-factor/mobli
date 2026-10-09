#!/bin/zsh
set -eu
repo_dir=${0:A:h:h}
check_dir=$(mktemp -d /tmp/mobli-checks.XXXXXX)
trap 'rm -f "$check_dir/AgendaAPI.swift" "$check_dir/agenda-api-checks" "$check_dir/PinPlacement.swift" "$check_dir/pin-placement-checks" "$check_dir/Activity.swift" "$check_dir/activity-checks" "$check_dir/StreamModel.swift" "$check_dir/stream-checks" "$check_dir/Owner.swift" "$check_dir/Inbox.swift" "$check_dir/checks" "$check_dir/Discovery.swift" "$check_dir/discovery-checks" "$check_dir/OwnerOrder.swift" "$check_dir/owner-order-checks" "$check_dir/Agenda.swift" "$check_dir/agenda-checks"; rmdir "$check_dir"' EXIT
# Regression guard: launch only the requested folder; do not activate every VS Code window.
python3 - "$repo_dir/Sources/RepoLauncher.swift" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
launch = source.split('private func openInVSCode(', 1)[1].split('\nenum Palette', 1)[0]
assert 'task.arguments = ["--new-window", url.path]' in launch, "Selected folder must open in its own VS Code window"
assert '.activateAllWindows' not in launch, "Do not raise every existing VS Code window"
assert 'vsCode.activate(' not in launch and 'yieldActivation(' not in launch, "Leave window focus to the VS Code CLI"
print("VS Code selected-window launch checks passed")
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
