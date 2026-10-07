#!/bin/zsh
# Prepare updates without replacing the running executable. Install only on quit.
set -eu
mode=$1
app_path=$2
source_root=$3
cache_root=$4
mkdir -p "$cache_root"
ready="$cache_root/ready.app"
plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true; }
if [[ "$mode" == install ]]; then
  [[ -d "$ready" ]] || exit 0
  /usr/bin/codesign --verify --deep --strict "$ready"
  [[ "$(plist_value "$ready" CFBundleIdentifier)" == studio.repository-launcher ]] || exit 1
  # Copy to the same filesystem before swapping; retain the old app if the swap fails.
  replacement=$(mktemp -d "${app_path:h}/.launcher-update.XXXXXX")
  trap 'rm -rf "$replacement"' EXIT
  /usr/bin/ditto "$ready" "$replacement/new.app"
  /usr/bin/codesign --verify --deep --strict "$replacement/new.app"
  mv "$app_path" "$replacement/old.app"
  if ! mv "$replacement/new.app" "$app_path"; then
    mv "$replacement/old.app" "$app_path"
    exit 1
  fi
  rm -rf "$ready"
  exit 0
fi
[[ "$mode" == prepare ]] || exit 1
work=$(mktemp -d "$cache_root/check.XXXXXX")
trap 'rm -rf "$work"' EXIT
installed=$(plist_value "$app_path" LauncherSourceFingerprint)
if [[ -f "$source_root/scripts/source-fingerprint.sh" ]]; then
  current=$(/bin/zsh "$source_root/scripts/source-fingerprint.sh" "$source_root")
  if [[ "$current" != "$installed" ]]; then
    if [[ -d "$ready" && "$(plist_value "$ready" LauncherSourceFingerprint)" == "$current" ]]; then exit 0; fi
    /bin/zsh "$source_root/build-app.sh" "$work/new.app"
    # Do not publish a build if files changed during compilation.
    [[ "$current" == "$(/bin/zsh "$source_root/scripts/source-fingerprint.sh" "$source_root")" ]] || exit 0
    rm -rf "$ready"
    mv "$work/new.app" "$ready"
    exit 0
  fi
fi
# Poll the published bundle at most every fifteen minutes, without pulling or
# altering the user's repository. A failed/offline check keeps the current app.
if [[ -f "$cache_root/last-remote-check" ]]; then
  age=$(( $(date +%s) - $(stat -f %m "$cache_root/last-remote-check") ))
  (( age >= 900 )) || exit 0
fi
touch "$cache_root/last-remote-check"
catalog="$cache_root/catalog.git"
[[ -d "$catalog" ]] || /usr/bin/git init --bare "$catalog" >/dev/null
GIT_TERMINAL_PROMPT=0 /usr/bin/git --git-dir="$catalog" fetch --quiet https://github.com/pony-factor/mobli.git main:refs/heads/published
/usr/bin/git --git-dir="$catalog" archive published 'Repository Launcher.app' | /usr/bin/tar -x -C "$work"
candidate="$work/Repository Launcher.app"
revision=$(plist_value "$candidate" LauncherSourceRevision)
baseline=$(plist_value "$app_path" LauncherSourceRevision)
fingerprint=$(plist_value "$candidate" LauncherSourceFingerprint)
[[ -n "$fingerprint" && "$fingerprint" != "$installed" && -n "$baseline" && -n "$revision" ]] || exit 0
# Locally modified builds take precedence until those changes are published.
[[ "$(plist_value "$app_path" LauncherSourceClean)" == true ]] || exit 0
[[ "$revision" != "$baseline" ]] || exit 0
/usr/bin/git --git-dir="$catalog" merge-base --is-ancestor "$baseline" "$revision" || exit 0
/usr/bin/codesign --verify --deep --strict "$candidate"
[[ "$(plist_value "$candidate" CFBundleIdentifier)" == studio.repository-launcher ]] || exit 1
rm -rf "$ready"
mv "$candidate" "$ready"
