#!/bin/zsh
set -eu
repo_dir=${0:A:h:h}
check_dir=$(mktemp -d /tmp/mobli-checks.XXXXXX)
trap 'rm -f "$check_dir/AgendaAPI.swift" "$check_dir/agenda-api-checks" "$check_dir/PinPlacement.swift" "$check_dir/pin-placement-checks" "$check_dir/Activity.swift" "$check_dir/activity-checks" "$check_dir/Owner.swift" "$check_dir/Inbox.swift" "$check_dir/checks" "$check_dir/Discovery.swift" "$check_dir/discovery-checks" "$check_dir/OwnerOrder.swift" "$check_dir/owner-order-checks" "$check_dir/Agenda.swift" "$check_dir/agenda-checks"; rmdir "$check_dir"' EXIT
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
source = (repo / 'Sources' / 'Agenda.swift').read_text()
(out / 'Agenda.swift').write_text('import Foundation\n' + source[source.index('struct AgendaProject:'):source.index('enum AgendaFailure:')])
(out / 'AgendaAPI.swift').write_text('import Foundation\nimport AppKit\nenum GitHubInbox { static let executable: String? = nil }\n' + source[source.index('struct AgendaProject:'):source.index('@MainActor final class Agenda:')])
PY
xcrun swiftc -parse-as-library "$check_dir/Owner.swift" "$check_dir/Inbox.swift" "$repo_dir/tests/InboxChecks.swift" -o "$check_dir/checks" -framework AppKit
"$check_dir/checks"

xcrun swiftc -parse-as-library "$check_dir/Activity.swift" "$repo_dir/tests/ActivityChecks.swift" -o "$check_dir/activity-checks" -framework AppKit -framework SwiftUI
"$check_dir/activity-checks"

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
