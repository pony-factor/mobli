#!/bin/zsh
set -eu
repo_dir=${0:A:h:h}
installed_app=$1
fixture=$(mktemp -d /tmp/mobli-update-checks.XXXXXX)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/source" "$fixture/cache"
for input in Sources scripts AppIcon.icns build-app.sh; do
  ditto "$repo_dir/$input" "$fixture/source/$input"
done
app="$fixture/Installed.app"
ditto "$installed_app" "$app"
touch "$fixture/cache/last-remote-check"
run_update() { /bin/zsh "$repo_dir/scripts/auto-update.sh" "$1" "$app" "$fixture/source" "$fixture/cache"; }
fingerprint() { /usr/libexec/PlistBuddy -c 'Print :LauncherSourceFingerprint' "$1/Contents/Info.plist"; }
original=$(fingerprint "$app")
run_update prepare
[[ ! -d "$fixture/cache/ready.app" ]]
print '\n// Automatic update fixture.' >> "$fixture/source/Sources/Activity.swift"
run_update prepare
[[ -d "$fixture/cache/ready.app" ]]
[[ "$(fingerprint "$app")" == "$original" ]]
updated=$(fingerprint "$fixture/cache/ready.app")
[[ "$updated" != "$original" ]]
run_update install
[[ ! -d "$fixture/cache/ready.app" ]]
[[ "$(fingerprint "$app")" == "$updated" ]]
codesign --verify --deep --strict "$app"
# Simulate an older checkout beside a newly installed published app. It must
# stay unchanged until the local source actually changes again.
ditto "$repo_dir/Sources/Activity.swift" "$fixture/source/Sources/Activity.swift"
/bin/zsh "$repo_dir/scripts/source-fingerprint.sh" "$fixture/source" > "$fixture/cache/installed-local-fingerprint"
run_update prepare
[[ ! -d "$fixture/cache/ready.app" ]]
[[ "$(fingerprint "$app")" == "$updated" ]]
# Reject an incomplete/corrupted candidate and preserve the installed bundle.
ditto "$app" "$fixture/cache/ready.app"
print 'corruption' >> "$fixture/cache/ready.app/Contents/MacOS/RepositoryLauncher"
if run_update install; then
  print 'Corrupted update was accepted' >&2
  exit 1
fi
[[ "$(fingerprint "$app")" == "$updated" ]]
codesign --verify --deep --strict "$app"
print 'Automatic update preparation, quit installation, downgrade protection, and failed-update preservation passed'
