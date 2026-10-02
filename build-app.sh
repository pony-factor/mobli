#!/bin/zsh
set -eu
source_dir=${0:A:h}
destination=${1:-"$source_dir/Repository Launcher.app"}
mkdir -p "$destination/Contents/MacOS" "$destination/Contents/Resources"
xcrun swiftc -O -parse-as-library "$source_dir/RepoLauncher.swift" "$source_dir/Notifications.swift" "$source_dir/Activity.swift" -o "$destination/Contents/MacOS/RepositoryLauncher" -framework SwiftUI -framework AppKit
icon_dir=$(mktemp -d /tmp/mobli-icon.XXXXXX)
trap 'rm -rf "$icon_dir"' EXIT
mkdir "$icon_dir/AppIcon.iconset"
xcrun swift "$source_dir/AppIcon.swift" "$icon_dir/AppIcon.iconset"
iconutil -c icns "$icon_dir/AppIcon.iconset" -o "$destination/Contents/Resources/AppIcon.icns"
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
codesign --force --sign - "$destination"
print "Built $destination"
