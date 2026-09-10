#!/bin/zsh
set -euo pipefail
LABEL="com.travis.runtime.worker";DOMAIN="gui/$(id -u)";REPO_ROOT="${0:A:h:h}";RUNTIME_BIN="$HOME/Library/Application Support/TRAVIS/Runtime/bin";PLIST="$HOME/Library/LaunchAgents/$LABEL.plist";LOGDIR="$HOME/Library/Logs/TRAVIS";PYTHON="$(command -v python3 || true)"
SOURCE_WORKER="$REPO_ROOT/Tools/travis_runtime_worker_v5.py";SOURCE_MARKET="$REPO_ROOT/Tools/travis_market_engine.py";SOURCE_AI="$REPO_ROOT/Tools/travis_headless_ai.py";SOURCE_TESTNET="$REPO_ROOT/Tools/travis_binance_testnet.py"
WORKER="$RUNTIME_BIN/travis_runtime_worker.py";MARKET="$RUNTIME_BIN/travis_market_engine.py";AI="$RUNTIME_BIN/travis_headless_ai.py";TESTNET="$RUNTIME_BIN/travis_binance_testnet.py"
HB="$HOME/Library/Application Support/TRAVIS/AlwaysOn/worker-heartbeat.json"
[[ -n "$PYTHON" ]] || { echo "python3 not found" >&2; exit 1; }
for f in "$SOURCE_WORKER" "$SOURCE_MARKET" "$SOURCE_AI" "$SOURCE_TESTNET";do [[ -f "$f" ]] || { echo "runtime component missing: $f" >&2;exit 1; };done
mkdir -p "$HOME/Library/LaunchAgents" "$LOGDIR" "$RUNTIME_BIN"
"$PYTHON" -m py_compile "$SOURCE_WORKER" "$SOURCE_MARKET" "$SOURCE_AI" "$SOURCE_TESTNET"
for pair in "$SOURCE_MARKET:$MARKET" "$SOURCE_AI:$AI" "$SOURCE_TESTNET:$TESTNET" "$SOURCE_WORKER:$WORKER";do src="${pair%%:*}";dst="${pair#*:}";cp "$src" "$dst.tmp";mv "$dst.tmp" "$dst";chmod +x "$dst";done
rm -f "$PLIST";/usr/libexec/PlistBuddy -c "Add :Label string $LABEL" "$PLIST";/usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$PLIST";/usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $PYTHON" "$PLIST";/usr/libexec/PlistBuddy -c "Add :ProgramArguments:1 string $WORKER" "$PLIST";/usr/libexec/PlistBuddy -c "Add :RunAtLoad bool true" "$PLIST";/usr/libexec/PlistBuddy -c "Add :KeepAlive bool true" "$PLIST";/usr/libexec/PlistBuddy -c "Add :ProcessType string Background" "$PLIST";/usr/libexec/PlistBuddy -c "Add :StandardOutPath string $LOGDIR/runtime-worker.log" "$PLIST";/usr/libexec/PlistBuddy -c "Add :StandardErrorPath string $LOGDIR/runtime-worker-error.log" "$PLIST";/usr/libexec/PlistBuddy -c "Add :ThrottleInterval integer 5" "$PLIST";plutil -convert xml1 "$PLIST";plutil -lint "$PLIST" >/dev/null
launchctl disable "$DOMAIN/$LABEL" 2>/dev/null || true;launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || launchctl bootout "$DOMAIN" "$PLIST" 2>/dev/null || true
for _ in {1..20};do launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break;sleep .25;done
launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true
if ! launchctl bootstrap "$DOMAIN" "$PLIST";then echo "Initial bootstrap failed; retrying..." >&2;launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true;sleep 1;launchctl bootstrap "$DOMAIN" "$PLIST";fi
launchctl enable "$DOMAIN/$LABEL";launchctl kickstart -k "$DOMAIN/$LABEL"
for _ in {1..30};do
  if [[ -f "$HB" ]] && "$PYTHON" - "$HB" <<'PY' >/dev/null 2>&1
import json,sys,time
h=json.load(open(sys.argv[1]));assert int(h.get('version',0))>=11;assert time.time()-float(h.get('lastBeatAt',0))<8
PY
  then break;fi
  sleep .25
done
if ! launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1;then echo "TRAVIS worker failed to register" >&2;exit 1;fi
if [[ ! -f "$HB" ]];then
  echo "TRAVIS worker registered but heartbeat was not created." >&2
  echo "--- launchd ---" >&2;launchctl print "$DOMAIN/$LABEL" | grep -E "state =|pid =|last exit code" | head -8 >&2 || true
  echo "--- stderr ---" >&2;tail -80 "$LOGDIR/runtime-worker-error.log" >&2 2>/dev/null || true
  echo "--- journal ---" >&2;tail -40 "$HOME/Library/Application Support/TRAVIS/AlwaysOn/service-journal-v1.jsonl" >&2 2>/dev/null || true
  exit 1
fi
"$PYTHON" - "$HB" <<'PY'
import json,sys,time
h=json.load(open(sys.argv[1]));age=time.time()-float(h.get('lastBeatAt',0));assert int(h.get('version',0))>=11,("unexpected heartbeat version",h);assert age<8,("stale heartbeat",age,h)
print(f"Heartbeat v{h.get('version')} healthy; pid={h.get('pid')} age={age:.2f}s state={h.get('state')}")
PY
echo "TRAVIS Always-On intelligence worker v5 installed: $LABEL";echo "Interpreter: $PYTHON";echo "Runtime components: worker + market + headless AI + Binance testnet";launchctl print "$DOMAIN/$LABEL" | grep -E "state =|pid =" | head -4 || true
