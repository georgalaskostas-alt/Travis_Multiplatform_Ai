#!/bin/zsh
set -euo pipefail
LABEL="com.travis.runtime.worker"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
echo "TRAVIS runtime worker removed"
