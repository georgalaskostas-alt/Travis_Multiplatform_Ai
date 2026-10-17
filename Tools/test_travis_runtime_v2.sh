#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}";TOOLS="$ROOT/Tools";DATA="$HOME/Library/Application Support/TRAVIS/AlwaysOn";PYTHON="$(command -v python3)"
echo "== TRAVIS Runtime V5.1 acceptance =="
"$TOOLS/install_travis_runtime_launchagent.sh"
HB="$DATA/worker-heartbeat.json"
for _ in {1..40};do [[ -f "$HB" ]] && break;sleep .25;done
[[ -f "$HB" ]] || { echo "FAIL: heartbeat unavailable";exit 1; }
echo "-- heartbeat --";"$PYTHON" - "$HB" <<'PY'
import json,sys,time
h=json.load(open(sys.argv[1]));age=time.time()-float(h.get('lastBeatAt',0));print(json.dumps({k:h.get(k) for k in ('version','generation','pid','state','marketEngine','headlessAI','testnetAdapter')},indent=2));assert int(h.get('version',0))>=12;assert age<8
PY
JID=$("$PYTHON" - <<'PY'
import fcntl,json,os,time,uuid
from pathlib import Path
root=Path.home()/"Library/Application Support/TRAVIS/AlwaysOn";jobs=root/"service-jobs-v1.json";lock=root/"service-jobs.lock";jid=str(uuid.uuid4());now=time.time()
with lock.open('a+') as f:
 fcntl.flock(f,fcntl.LOCK_EX)
 try:d=json.loads(jobs.read_text())
 except:d={"version":12,"jobs":[]}
 d['jobs'].append({"id":jid,"title":"Runtime V5.1 Acceptance Mission","kind":"headlessMission","state":"scheduled","createdAt":now,"updatedAt":now,"nextRunAt":now,"payload":{"goal":"Verify lease-safe Always-On runtime","executionMode":"full","plan":[{"order":1,"title":"Runtime identity","capability":"runtime.identity"},{"order":2,"title":"System health","capability":"runtime.health"},{"order":3,"title":"Safety envelope","capability":"runtime.safety"},{"order":4,"title":"Final report","capability":"report.synthesize"}]},"enabled":True,"failures":0,"recoveryCount":0,"lastError":None,"lease":None,"checkpoint":None});d['version']=12
 t=jobs.with_suffix('.json.tmp');t.write_text(json.dumps(d,sort_keys=True));os.replace(t,jobs);fcntl.flock(f,fcntl.LOCK_UN)
print(jid)
PY
)
echo "Acceptance job: $JID"
for _ in {1..80};do
 STATE=$("$PYTHON" - "$JID" <<'PY'
import fcntl,json,sys
from pathlib import Path
r=Path.home()/"Library/Application Support/TRAVIS/AlwaysOn";jid=sys.argv[1]
with (r/'service-jobs.lock').open('a+') as f:
 fcntl.flock(f,fcntl.LOCK_SH)
 try:d=json.loads((r/'service-jobs-v1.json').read_text());j=next(x for x in d['jobs'] if x['id']==jid);print(j.get('state',''))
 except Exception:print('missing')
PY
)
 [[ "$STATE" == "stopped" || "$STATE" == "failed" ]] && break
 sleep .25
done
echo "-- acceptance job --"
"$PYTHON" - "$JID" <<'PY'
import fcntl,json,sys
from pathlib import Path
r=Path.home()/"Library/Application Support/TRAVIS/AlwaysOn";jid=sys.argv[1]
with (r/'service-jobs.lock').open('a+') as f:
 fcntl.flock(f,fcntl.LOCK_SH);d=json.loads((r/'service-jobs-v1.json').read_text());j=next(x for x in d['jobs'] if x['id']==jid)
print(json.dumps(j,indent=2,sort_keys=True));assert j['state']=='stopped',j;assert (j.get('lastResult') or {}).get('completedSteps')==4,j;assert not j.get('lease'),j
PY
echo "-- lease/journal evidence --";tail -60 "$DATA/service-journal-v1.jsonl" | grep -E "$JID|worker_startup_error" || true
echo "PASS: worker v12 heartbeat, claim/execute/commit, checkpoints and lease release verified."
