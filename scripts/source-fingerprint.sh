#!/bin/zsh
set -eu
cd "$1"
for input in Sources/*.swift AppIcon.icns build-app.sh scripts/*.sh; do
  print -r -- "$input"
  /usr/bin/shasum -a 256 "$input"
done | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
