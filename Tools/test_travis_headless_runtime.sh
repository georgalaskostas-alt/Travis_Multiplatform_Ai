#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JOBCTL="$SCRIPT_DIR/travis_runtime_jobctl.py"
INSTALLER="$SCRIPT_DIR/install_travis_runtime_launchagent.sh"

echo "=== TRAVIS HEADLESS ACCEPTANCE TEST ==="
"$INSTALLER"
MISSION_ID="$($JOBCTL add-headless-mission 'Verify persistent headless mission execution and produce a runtime safety report')"
WATCHER_ID="$($JOBCTL add-system-watcher 15)"
echo "Mission: $MISSION_ID"
echo "Watcher: $WATCHER_ID"
echo "Waiting for independent worker execution..."
sleep 22

echo "\n=== WORKER STATUS ==="
"$JOBCTL" status

echo "\n=== SERVICE JOBS ==="
"$JOBCTL" list

echo "\n=== HEADLESS MISSION ==="
"$JOBCTL" show "${MISSION_ID:0:8}"

echo "\n=== RECENT JOURNAL ==="
"$JOBCTL" journal 40

echo "\nAcceptance criteria: headlessMission=stopped with finalReport, systemWatcher=sleeping, worker heartbeat healthy."
