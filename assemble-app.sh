#!/bin/zsh
set -eu
source_dir=${0:A:h}
arm_app=$1
intel_app=$2
destination=${3:-"$source_dir/Repository Launcher.app"}

codesign --verify --deep --strict "$arm_app"
codesign --verify --deep --strict "$intel_app"
cmp "$arm_app/Contents/Info.plist" "$intel_app/Contents/Info.plist"
cmp "$arm_app/Contents/Resources/AppIcon.icns" "$intel_app/Contents/Resources/AppIcon.icns"

assembly_dir=$(mktemp -d /tmp/mobli-universal.XXXXXX)
trap 'rm -rf "$assembly_dir"' EXIT
ditto "$arm_app" "$assembly_dir/Repository Launcher.app"
binary_path="$assembly_dir/Repository Launcher.app/Contents/MacOS/RepositoryLauncher"
lipo -create "$arm_app/Contents/MacOS/RepositoryLauncher" "$intel_app/Contents/MacOS/RepositoryLauncher" -output "$assembly_dir/RepositoryLauncher"
mv "$assembly_dir/RepositoryLauncher" "$binary_path"
chmod +x "$binary_path"
for architecture in arm64 x86_64; do
  lipo "$binary_path" -verify_arch "$architecture"
done
codesign --force --sign - "$assembly_dir/Repository Launcher.app"
codesign --verify --deep --strict "$assembly_dir/Repository Launcher.app"
ditto "$assembly_dir/Repository Launcher.app" "$destination"
print "Built universal app at $destination"
