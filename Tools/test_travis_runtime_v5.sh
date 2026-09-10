#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}";PY="$(command -v python3)";WORKER="$ROOT/Tools/travis_runtime_worker_v5.py";MARKET="$ROOT/Tools/travis_market_engine.py";AI="$ROOT/Tools/travis_headless_ai.py";TESTNET="$ROOT/Tools/travis_binance_testnet.py"
"$PY" -m py_compile "$WORKER" "$MARKET" "$AI" "$TESTNET"
TMP="$(mktemp -d)";trap '[[ -n "${WPID:-}" ]] && kill "$WPID" 2>/dev/null || true; rm -rf "$TMP"' EXIT
export HOME="$TMP/home";BIN="$HOME/Library/Application Support/TRAVIS/Runtime/bin";STATE="$HOME/Library/Application Support/TRAVIS/AlwaysOn";mkdir -p "$BIN" "$STATE";cp "$MARKET" "$BIN/travis_market_engine.py";cp "$AI" "$BIN/travis_headless_ai.py";cp "$TESTNET" "$BIN/travis_binance_testnet.py";cp "$WORKER" "$BIN/travis_runtime_worker.py"
# Seed a legacy malformed running lease. Worker v4 could crash here before creating heartbeat.
"$PY" - <<'PY'
import json,os,time
p=os.path.expanduser('~/Library/Application Support/TRAVIS/AlwaysOn/service-jobs-v1.json')
job={'id':'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','title':'legacy lease migration','kind':'heartbeatProbe','state':'running','createdAt':time.time()-60,'updatedAt':time.time()-60,'nextRunAt':time.time()-60,'payload':{},'enabled':True,'failures':0,'recoveryCount':0,'lease':'legacy-string-lease','checkpoint':'legacy checkpoint'}
json.dump({'version':5,'jobs':[job]},open(p,'w'))
PY
"$PY" "$BIN/travis_runtime_worker.py" >"$TMP/out.log" 2>"$TMP/err.log" & WPID=$!
for _ in {1..80};do [[ -f "$STATE/worker-heartbeat.json" ]] && break;sleep .1;done
[[ -f "$STATE/worker-heartbeat.json" ]] || { cat "$TMP/err.log";echo "FAIL: heartbeat missing after legacy migration";exit 1; }
VER="$($PY -c 'import json,os;print(json.load(open(os.path.expanduser("~/Library/Application Support/TRAVIS/AlwaysOn/worker-heartbeat.json")))["version"])')";[[ "$VER" == "11" ]] || { echo "FAIL: heartbeat version $VER";exit 1; }
sleep 2
"$PY" - <<'PY'
import json,os
p=os.path.expanduser('~/Library/Application Support/TRAVIS/AlwaysOn/service-jobs-v1.json');j=json.load(open(p))['jobs'][0];assert j['state']=='stopped',j;assert j.get('lease') is None,j;assert j.get('recoveryCount',0)>=1,j
print('PASS: legacy lease migrated and recovered')
PY
# Queue duplicate create command; must produce exactly one job and one acknowledgement identity.
"$PY" - <<'PY'
import json,os,time
q=os.path.expanduser('~/Library/Application Support/TRAVIS/AlwaysOn/worker-command-queue.json');job={'id':'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','title':'idempotent create','kind':'headlessMission','state':'scheduled','createdAt':time.time(),'updatedAt':time.time(),'nextRunAt':time.time(),'payload':{'goal':'acceptance','sourceTaskID':'cccccccc-cccc-4ccc-8ccc-cccccccccccc','sourcePlanVersion':7,'executionMode':'full','plan':[{'order':1,'sourceStepID':'dddddddd-dddd-4ddd-8ddd-dddddddddddd','title':'identity','capability':'runtime.identity'},{'order':2,'sourceStepID':'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','title':'health','capability':'runtime.health'},{'order':3,'sourceStepID':'ffffffff-ffff-4fff-8fff-ffffffffffff','title':'report','capability':'report.synthesize'}]},'enabled':True,'failures':0,'recoveryCount':0};cmd={'action':'create','nonce':'v5-create-once','createdAt':time.time(),'job':job};json.dump({'version':2,'commands':[cmd,cmd]},open(q,'w'))
PY
sleep 4
"$PY" - <<'PY'
import json,os,time
root=os.path.expanduser('~/Library/Application Support/TRAVIS/AlwaysOn');d=json.load(open(root+'/service-jobs-v1.json'));jobs=[j for j in d['jobs'] if j['id'].startswith('bbbbbbbb')];assert len(jobs)==1,jobs;j=jobs[0];assert j['state']=='stopped',j;assert j['lastResult']['completedSteps']==3,j;assert j['lastResult']['steps'][0]['sourceStepID'].startswith('dddddddd'),j;assert j['payload']['sourceTaskID'].startswith('cccccccc'),j;assert j['payload']['sourcePlanVersion']==7,j
acks=json.load(open(root+'/worker-command-acks-v1.json'))['nonces'];assert any(a.get('nonce')=='v5-create-once' and a.get('status')=='applied' for a in acks),acks
hb=json.load(open(root+'/worker-heartbeat.json'));assert time.time()-hb['lastBeatAt']<4,hb
print('PASS: command idempotency + Mission V2 source identity + terminal result + fresh heartbeat')
PY
echo "PASS: TRAVIS worker v5 isolated acceptance suite"
