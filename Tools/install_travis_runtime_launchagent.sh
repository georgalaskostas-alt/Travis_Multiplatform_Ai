#!/bin/zsh
set -euo pipefail
LABEL="com.travis.runtime.worker"
REPO_ROOT="${0:A:h:h}"
WORKER="$REPO_ROOT/Tools/travis_runtime_worker.py"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOGDIR="$HOME/Library/Logs/TRAVIS"
mkdir -p "$HOME/Library/LaunchAgents" "$LOGDIR"
chmod +x "$WORKER"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>/usr/bin/python3</string><string>$WORKER</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>ProcessType</key><string>Background</string>
<key>StandardOutPath</key><string>$LOGDIR/runtime-worker.log</string>
<key>StandardErrorPath</key><string>$LOGDIR/runtime-worker-error.log</string>
<key>ThrottleInterval</key><integer>5</integer>
</dict></plist>
EOF
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl enable "gui/$(id -u)/$LABEL"
launchctl kickstart -k "gui/$(id -u)/$LABEL"
echo "TRAVIS runtime worker installed: $LABEL"
