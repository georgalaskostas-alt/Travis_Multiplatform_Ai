#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}";PY="$(command -v python3)";WORKER="$ROOT/Tools/travis_runtime_worker_v3.py";MARKET="$ROOT/Tools/travis_market_engine.py";AI="$ROOT/Tools/travis_headless_ai.py"
"$PY" -m py_compile "$WORKER" "$MARKET" "$AI"
TMP="$(mktemp -d)";trap '[[ -n "${PID:-}" ]] && kill "$PID" 2>/dev/null || true; rm -rf "$TMP"' EXIT
export HOME="$TMP/home";BIN="$HOME/Library/Application Support/TRAVIS/Runtime/bin";STATE="$HOME/Library/Application Support/TRAVIS/AlwaysOn";mkdir -p "$BIN" "$STATE";cp "$MARKET" "$BIN/travis_market_engine.py";cp "$AI" "$BIN/travis_headless_ai.py";cp "$WORKER" "$BIN/travis_runtime_worker.py"
"$PY" "$BIN/travis_runtime_worker.py" >"$TMP/out.log" 2>"$TMP/err.log" & PID=$!
for _ in {1..50};do [[ -f "$STATE/worker-heartbeat.json" ]] && break;sleep .1;done
[[ -f "$STATE/worker-heartbeat.json" ]] || { cat "$TMP/err.log";echo "FAIL: heartbeat missing";exit 1; }
VER="$($PY -c 'import json,os; p=os.path.expanduser("~/Library/Application Support/TRAVIS/AlwaysOn/worker-heartbeat.json"); print(json.load(open(p))["version"])')";[[ "$VER" == "9" ]] || { echo "FAIL: heartbeat version $VER";exit 1; }
# Durable CREATE command + idempotency.
$PY - <<'PY'
import json,os,time,uuid
p=os.path.expanduser('~/Library/Application Support/TRAVIS/AlwaysOn/worker-command-queue.json');jid='11111111-1111-4111-8111-111111111111';cmd={'action':'create','nonce':'create-once','createdAt':time.time(),'job':{'id':jid,'title':'acceptance probe','kind':'heartbeatProbe','state':'scheduled','createdAt':time.time(),'updatedAt':time.time(),'nextRunAt':time.time(),'payload':{},'enabled':True,'failures':0,'recoveryCount':0}}
json.dump({'version':2,'commands':[cmd,cmd]},open(p,'w'))
PY
sleep 3
COUNT="$($PY -c 'import json,os;d=json.load(open(os.path.expanduser("~/Library/Application Support/TRAVIS/AlwaysOn/service-jobs-v1.json")));print(sum(1 for j in d["jobs"] if j["id"].startswith("11111111")))')";[[ "$COUNT" == "1" ]] || { echo "FAIL: create idempotency count=$COUNT";exit 1; }
STATEVAL="$($PY -c 'import json,os;d=json.load(open(os.path.expanduser("~/Library/Application Support/TRAVIS/AlwaysOn/service-jobs-v1.json")));print(next(j["state"] for j in d["jobs"] if j["id"].startswith("11111111")))')";[[ "$STATEVAL" == "stopped" ]] || { echo "FAIL: probe state=$STATEVAL";exit 1; }
# Mission result with sourceStepID for reconciliation.
$PY - <<'PY'
import json,os,time
p=os.path.expanduser('~/Library/Application Support/TRAVIS/AlwaysOn/worker-command-queue.json');job={'id':'22222222-2222-4222-8222-222222222222','title':'mission acceptance','kind':'headlessMission','state':'scheduled','createdAt':time.time(),'updatedAt':time.time(),'nextRunAt':time.time(),'enabled':True,'failures':0,'recoveryCount':0,'payload':{'goal':'runtime report','sourceTaskID':'33333333-3333-4333-8333-333333333333','sourcePlanVersion':1,'executionMode':'full','plan':[{'order':1,'sourceStepID':'44444444-4444-4444-8444-444444444444','title':'identity','capability':'runtime.identity'},{'order':2,'sourceStepID':'55555555-5555-4555-8555-555555555555','title':'report','capability':'report.synthesize'}]}};json.dump({'version':2,'commands':[{'action':'create','nonce':'mission-create','createdAt':time.time(),'job':job}]},open(p,'w'))
PY
sleep 4
$PY - <<'PY'
import json,os,sys
p=os.path.expanduser('~/Library/Application Support/TRAVIS/AlwaysOn/service-jobs-v1.json');d=json.load(open(p));j=next(x for x in d['jobs'] if x['id'].startswith('22222222'));assert j['state']=='stopped',j;assert j['lastResult']['completedSteps']==2,j;assert j['lastResult']['steps'][0]['sourceStepID'].startswith('44444444'),j
print('PASS: mission source identity + terminal result')
PY
# Queue ack ledger exists and consumed commands are removed.
$PY - <<'PY'
import json,os
root=os.path.expanduser('~/Library/Application Support/TRAVIS/AlwaysOn');a=json.load(open(root+'/worker-command-acks-v1.json'));assert any(x.get('nonce')=='mission-create' and x.get('status')=='applied' for x in a['nonces']);q=json.load(open(root+'/worker-command-queue.json'));assert not q.get('commands');print('PASS: durable command acknowledgement')
PY
echo "PASS: TRAVIS worker v3 acceptance suite"
