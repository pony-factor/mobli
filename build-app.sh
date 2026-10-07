#!/bin/zsh
set -eu
source_dir=${0:A:h}
destination=${1:-"$source_dir/Repository Launcher.app"}
mkdir -p "$destination/Contents/MacOS" "$destination/Contents/Resources"
xcrun swiftc -O -parse-as-library "$source_dir/Sources/RepoLauncher.swift" "$source_dir/Sources/Notifications.swift" "$source_dir/Sources/Agenda.swift" "$source_dir/Sources/Activity.swift" -o "$destination/Contents/MacOS/RepositoryLauncher" -framework SwiftUI -framework AppKit
ditto "$source_dir/AppIcon.icns" "$destination/Contents/Resources/AppIcon.icns"
ditto "$source_dir/scripts/auto-update.sh" "$destination/Contents/Resources/auto-update.sh"
cat > "$destination/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>RepositoryLauncher</string>
<key>CFBundleIdentifier</key><string>studio.repository-launcher</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleName</key><string>Repository Launcher</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
fingerprint=$(/bin/zsh "$source_dir/scripts/source-fingerprint.sh" "$source_dir")
revision=$(/usr/bin/git -C "$source_dir" rev-parse HEAD 2>/dev/null || true)
source_clean=false
if /usr/bin/git -C "$source_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  source_clean=true
  if ! /usr/bin/git -C "$source_dir" diff --quiet HEAD -- Sources AppIcon.icns build-app.sh scripts; then
    source_clean=false
  fi
  if [[ -n "$(/usr/bin/git -C "$source_dir" ls-files --others --exclude-standard -- Sources scripts)" ]]; then
    source_clean=false
  fi
fi
plist="$destination/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LauncherSourceFingerprint string $fingerprint" "$plist"
/usr/libexec/PlistBuddy -c "Add :LauncherSourceRevision string $revision" "$plist"
/usr/libexec/PlistBuddy -c "Add :LauncherSourceClean string $source_clean" "$plist"
# Keep machine-specific paths outside Info.plist so universal builds match.
print -r -- "$source_dir" > "$destination/Contents/Resources/source-root.txt"
codesign --force --sign - "$destination"
print "Built $destination"
