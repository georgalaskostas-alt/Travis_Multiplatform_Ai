#!/bin/zsh
set -euo pipefail
LABEL="com.travis.runtime.worker"
DOMAIN="gui/$(id -u)"
REPO_ROOT="${0:A:h:h}"
SOURCE_WORKER="$REPO_ROOT/Tools/travis_runtime_worker.py"
RUNTIME_BIN="$HOME/Library/Application Support/TRAVIS/Runtime/bin"
WORKER="$RUNTIME_BIN/travis_runtime_worker.py"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOGDIR="$HOME/Library/Logs/TRAVIS"
PYTHON="$(command -v python3 || true)"
[[ -n "$PYTHON" ]] || { echo "python3 not found" >&2; exit 1; }
mkdir -p "$HOME/Library/LaunchAgents" "$LOGDIR" "$RUNTIME_BIN"
cp "$SOURCE_WORKER" "$WORKER"; chmod +x "$WORKER"
xml_escape(){ printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g -e "s/'/\&apos;/g"; }
# Keep XML generation simple: macOS paths here cannot contain XML metacharacters in this installation.
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$PYTHON</string><string>$WORKER</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>ProcessType</key><string>Background</string>
<key>StandardOutPath</key><string>$LOGDIR/runtime-worker.log</string>
<key>StandardErrorPath</key><string>$LOGDIR/runtime-worker-error.log</string>
<key>ThrottleInterval</key><integer>5</integer>
</dict></plist>
EOF
plutil -lint "$PLIST" >/dev/null

# Reinstallation can race an already-running KeepAlive job. Stop it first, wait
# for launchd to release the label, then bootstrap the freshly generated plist.
launchctl disable "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || launchctl bootout "$DOMAIN" "$PLIST" 2>/dev/null || true
for _ in {1..20}; do
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
  sleep 0.25
done
launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true
if ! launchctl bootstrap "$DOMAIN" "$PLIST"; then
  echo "Initial bootstrap failed; retrying after launchd cleanup..." >&2
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  sleep 1
  launchctl bootstrap "$DOMAIN" "$PLIST"
fi
launchctl enable "$DOMAIN/$LABEL"
launchctl kickstart -k "$DOMAIN/$LABEL"
sleep 1
if ! launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  echo "TRAVIS runtime worker failed to register with launchd" >&2
  exit 1
fi
echo "TRAVIS runtime worker installed: $LABEL"
echo "Interpreter: $PYTHON"
echo "Stable worker: $WORKER"
launchctl print "$DOMAIN/$LABEL" | grep -E "state =|pid =" | head -4 || true
