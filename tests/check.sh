#!/bin/zsh
set -eu
repo_dir=${0:A:h:h}
check_dir=$(mktemp -d /tmp/mobli-checks.XXXXXX)
trap 'rm -f "$check_dir/Owner.swift" "$check_dir/Inbox.swift" "$check_dir/checks"; rmdir "$check_dir"' EXIT
python3 - "$repo_dir" "$check_dir" <<'PY'
from pathlib import Path
import sys
repo, out = map(Path, sys.argv[1:])
source = (repo / 'RepoLauncher.swift').read_text()
(out / 'Owner.swift').write_text('import Foundation\n' + source[source.index('struct OwnerProfile:'):source.index('actor OwnerCache {')])
source = (repo / 'Notifications.swift').read_text()
(out / 'Inbox.swift').write_text(source[:source.index('@MainActor final class Inbox:')])
PY
xcrun swiftc -parse-as-library "$check_dir/Owner.swift" "$check_dir/Inbox.swift" "$repo_dir/tests/InboxChecks.swift" -o "$check_dir/checks" -framework AppKit
"$check_dir/checks"
