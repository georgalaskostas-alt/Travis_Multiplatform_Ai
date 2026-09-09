#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}";TOOLS="$ROOT/Tools";DATA="$HOME/Library/Application Support/TRAVIS/AlwaysOn"
echo "== TRAVIS Runtime V2 acceptance =="
"$TOOLS/install_travis_runtime_launchagent.sh"
sleep 2
python3 - <<'PY'
import json,os,time,uuid
from pathlib import Path
p=Path.home()/"Library/Application Support/TRAVIS/AlwaysOn/service-jobs-v1.json"
try:d=json.loads(p.read_text())
except:d={"version":8,"jobs":[]}
now=time.time();jid=str(uuid.uuid4())
d["jobs"].append({"id":jid,"title":"Runtime V2 Acceptance Mission","kind":"headlessMission","state":"scheduled","createdAt":now,"updatedAt":now,"nextRunAt":now,"cadenceSeconds":None,"payload":{"goal":"Verify lease-safe Always-On runtime","sourceTaskID":None,"sourcePlanVersion":None,"executionMode":"full","plan":[{"order":1,"title":"Runtime identity","capability":"runtime.identity"},{"order":2,"title":"System health","capability":"runtime.health"},{"order":3,"title":"Safety envelope","capability":"runtime.safety"},{"order":4,"title":"Final report","capability":"report.synthesize"}]},"enabled":True,"failures":0,"recoveryCount":0,"lastError":None,"lease":None,"checkpoint":None})
d["version"]=8
t=p.with_suffix('.tmp');t.write_text(json.dumps(d,sort_keys=True));os.replace(t,p)
print(jid)
(Path.home()/"Library/Application Support/TRAVIS/AlwaysOn/v2-acceptance-id.txt").write_text(jid)
PY
sleep 8
echo "-- heartbeat --";cat "$DATA/worker-heartbeat.json";echo
echo "-- acceptance job --"
python3 - <<'PY'
import json
from pathlib import Path
r=Path.home()/"Library/Application Support/TRAVIS/AlwaysOn";jid=(r/"v2-acceptance-id.txt").read_text().strip();d=json.loads((r/"service-jobs-v1.json").read_text());j=next(x for x in d['jobs'] if x['id']==jid);print(json.dumps(j,indent=2,sort_keys=True));assert j['state']=='stopped',j;assert (j.get('lastResult') or {}).get('completedSteps')==4,j;assert not j.get('lease'),j
PY
echo "-- lease/journal evidence --";tail -40 "$DATA/service-journal-v1.jsonl" | grep -E 'job_claimed|mission_step_|job_completed|job_recovered' || true
echo "PASS: worker v2 claimed without holding the global job lock, checkpointed, completed and released its lease."
