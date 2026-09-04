#!/bin/zsh
set -euo pipefail
LABEL="com.travis.runtime.worker"
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
xml_escape(){ printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"; }
PY_XML="$(xml_escape "$PYTHON")"; WORKER_XML="$(xml_escape "$WORKER")"; OUT_XML="$(xml_escape "$LOGDIR/runtime-worker.log")"; ERR_XML="$(xml_escape "$LOGDIR/runtime-worker-error.log")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>$LABEL</string><key>ProgramArguments</key><array><string>$PY_XML</string><string>$WORKER_XML</string></array><key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ProcessType</key><string>Background</string><key>StandardOutPath</key><string>$OUT_XML</string><key>StandardErrorPath</key><string>$ERR_XML</string><key>ThrottleInterval</key><integer>5</integer></dict></plist>
EOF
plutil -lint "$PLIST" >/dev/null
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST";launchctl enable "gui/$(id -u)/$LABEL";launchctl kickstart -k "gui/$(id -u)/$LABEL"
echo "TRAVIS runtime worker installed: $LABEL"
echo "Interpreter: $PYTHON"
echo "Stable worker: $WORKER"
