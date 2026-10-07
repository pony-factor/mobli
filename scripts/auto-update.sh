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
  if [[ -f "$source_root/scripts/source-fingerprint.sh" ]]; then
    /bin/zsh "$source_root/scripts/source-fingerprint.sh" "$source_root" > "$replacement/source-fingerprint"
  fi
  mv "$app_path" "$replacement/old.app"
  if ! mv "$replacement/new.app" "$app_path"; then
    mv "$replacement/old.app" "$app_path"
    exit 1
  fi
  if [[ -f "$replacement/source-fingerprint" ]]; then
    mv "$replacement/source-fingerprint" "$cache_root/installed-local-fingerprint"
  fi
  rm -rf "$ready"
  rm -f "$cache_root/ready-local-fingerprint"
  exit 0
fi
[[ "$mode" == prepare ]] || exit 1
work=$(mktemp -d "$cache_root/check.XXXXXX")
trap 'rm -rf "$work"' EXIT
installed=$(plist_value "$app_path" LauncherSourceFingerprint)
if [[ -f "$source_root/scripts/source-fingerprint.sh" ]]; then
  current=$(/bin/zsh "$source_root/scripts/source-fingerprint.sh" "$source_root")
  observed="$installed"
  if [[ -f "$cache_root/installed-local-fingerprint" ]]; then
    observed=$(<"$cache_root/installed-local-fingerprint")
  fi
  if [[ -f "$cache_root/ready-local-fingerprint" && "$(<"$cache_root/ready-local-fingerprint")" != "$current" ]]; then
    rm -rf "$ready"
    rm -f "$cache_root/ready-local-fingerprint"
  fi
  if [[ "$current" != "$installed" && "$current" != "$observed" ]]; then
    if [[ -d "$ready" && "$(plist_value "$ready" LauncherSourceFingerprint)" == "$current" ]]; then exit 0; fi
    /bin/zsh "$source_root/build-app.sh" "$work/new.app"
    # Do not publish a build if files changed during compilation.
    [[ "$current" == "$(/bin/zsh "$source_root/scripts/source-fingerprint.sh" "$source_root")" ]] || exit 0
    rm -rf "$ready"
    mv "$work/new.app" "$ready"
    print -r -- "$current" > "$cache_root/ready-local-fingerprint"
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
GIT_TERMINAL_PROMPT=0 /usr/bin/git -c http.lowSpeedLimit=1 -c http.lowSpeedTime=30 --git-dir="$catalog" fetch --quiet https://github.com/pony-factor/mobli.git main:refs/heads/published
/usr/bin/git --git-dir="$catalog" archive published 'Repository Launcher.app' | /usr/bin/tar -x -C "$work"
candidate="$work/Repository Launcher.app"
revision=$(plist_value "$candidate" LauncherSourceRevision)
baseline=$(plist_value "$app_path" LauncherSourceRevision)
fingerprint=$(plist_value "$candidate" LauncherSourceFingerprint)
[[ -n "$fingerprint" && "$fingerprint" != "$installed" && -n "$baseline" && -n "$revision" ]] || exit 0
# Locally modified builds take precedence until those changes are published.
if [[ "$(plist_value "$app_path" LauncherSourceClean)" != true ]]; then
  # Once local edits have been committed, their commit becomes the baseline;
  # only a published descendant may replace that development build.
  [[ "${current:-}" == "$installed" ]] || exit 0
  /usr/bin/git -C "$source_root" diff --quiet HEAD -- Sources AppIcon.icns build-app.sh scripts || exit 0
  [[ -z "$(/usr/bin/git -C "$source_root" ls-files --others --exclude-standard -- Sources scripts)" ]] || exit 0
  baseline=$(/usr/bin/git -C "$source_root" rev-parse HEAD)
fi
[[ "$revision" != "$baseline" ]] || exit 0
/usr/bin/git --git-dir="$catalog" merge-base --is-ancestor "$baseline" "$revision" || exit 0
/usr/bin/codesign --verify --deep --strict "$candidate"
[[ "$(plist_value "$candidate" CFBundleIdentifier)" == studio.repository-launcher ]] || exit 1
rm -rf "$ready"
mv "$candidate" "$ready"
rm -f "$cache_root/ready-local-fingerprint"
