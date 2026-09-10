#!/bin/zsh
set -euo pipefail
LABEL="com.travis.runtime.worker";DOMAIN="gui/$(id -u)";REPO_ROOT="${0:A:h:h}"
SOURCE_WORKER="$REPO_ROOT/Tools/travis_runtime_worker_v3.py";SOURCE_MARKET="$REPO_ROOT/Tools/travis_market_engine.py";RUNTIME_BIN="$HOME/Library/Application Support/TRAVIS/Runtime/bin";WORKER="$RUNTIME_BIN/travis_runtime_worker.py";MARKET="$RUNTIME_BIN/travis_market_engine.py";PLIST="$HOME/Library/LaunchAgents/$LABEL.plist";LOGDIR="$HOME/Library/Logs/TRAVIS";PYTHON="$(command -v python3 || true)"
[[ -n "$PYTHON" ]] || { echo "python3 not found" >&2; exit 1; };[[ -f "$SOURCE_WORKER" ]] || { echo "worker v3 missing" >&2; exit 1; };[[ -f "$SOURCE_MARKET" ]] || { echo "market engine missing" >&2; exit 1; }
mkdir -p "$HOME/Library/LaunchAgents" "$LOGDIR" "$RUNTIME_BIN"
"$PYTHON" -m py_compile "$SOURCE_WORKER" "$SOURCE_MARKET"
cp "$SOURCE_MARKET" "$MARKET.tmp";mv "$MARKET.tmp" "$MARKET";chmod +x "$MARKET"
cp "$SOURCE_WORKER" "$WORKER.tmp";mv "$WORKER.tmp" "$WORKER";chmod +x "$WORKER"
rm -f "$PLIST";/usr/libexec/PlistBuddy -c "Add :Label string $LABEL" "$PLIST";/usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$PLIST";/usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $PYTHON" "$PLIST";/usr/libexec/PlistBuddy -c "Add :ProgramArguments:1 string $WORKER" "$PLIST";/usr/libexec/PlistBuddy -c "Add :RunAtLoad bool true" "$PLIST";/usr/libexec/PlistBuddy -c "Add :KeepAlive bool true" "$PLIST";/usr/libexec/PlistBuddy -c "Add :ProcessType string Background" "$PLIST";/usr/libexec/PlistBuddy -c "Add :StandardOutPath string $LOGDIR/runtime-worker.log" "$PLIST";/usr/libexec/PlistBuddy -c "Add :StandardErrorPath string $LOGDIR/runtime-worker-error.log" "$PLIST";/usr/libexec/PlistBuddy -c "Add :ThrottleInterval integer 5" "$PLIST";plutil -convert xml1 "$PLIST";plutil -lint "$PLIST" >/dev/null
launchctl disable "$DOMAIN/$LABEL" 2>/dev/null || true;launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || launchctl bootout "$DOMAIN" "$PLIST" 2>/dev/null || true
for _ in {1..20};do launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break;sleep .25;done
launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true
if ! launchctl bootstrap "$DOMAIN" "$PLIST";then echo "Initial bootstrap failed; retrying..." >&2;launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true;sleep 1;launchctl bootstrap "$DOMAIN" "$PLIST";fi
launchctl enable "$DOMAIN/$LABEL";launchctl kickstart -k "$DOMAIN/$LABEL";sleep 1;launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || { echo "TRAVIS worker failed to register" >&2;exit 1; }
echo "TRAVIS Always-On worker v3 installed: $LABEL";echo "Interpreter: $PYTHON";echo "Worker: $WORKER";echo "Market engine: $MARKET";launchctl print "$DOMAIN/$LABEL" | grep -E "state =|pid =" | head -4 || true
