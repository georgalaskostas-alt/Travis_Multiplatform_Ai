#!/usr/bin/env python3
"""Safe local control utility for TRAVIS service jobs."""
import json,os,sys,time,uuid
from pathlib import Path
ROOT=Path.home()/"Library/Application Support/TRAVIS/AlwaysOn";ROOT.mkdir(parents=True,exist_ok=True);JOBS=ROOT/"service-jobs-v1.json"
def load():
    try:return json.loads(JOBS.read_text())
    except Exception:return {"version":1,"jobs":[]}
def save(d):
    t=JOBS.with_suffix(".json.tmp");t.write_text(json.dumps(d,sort_keys=True));os.replace(t,JOBS)
def find(d,key):
    m=[j for j in d["jobs"] if str(j.get("id","")).startswith(key)];return m[0] if len(m)==1 else None
args=sys.argv[1:];cmd=args[0] if args else "list";d=load()
if cmd=="list":
    for j in d["jobs"]:print(j.get("id"),j.get("state"),j.get("kind"),j.get("title"));sys.exit(0)
if cmd=="add-probe":
    now=time.time();j={"id":str(uuid.uuid4()),"title":"TRAVIS Runtime Probe","kind":"heartbeatProbe","state":"scheduled","createdAt":now,"updatedAt":now,"nextRunAt":now,"cadenceSeconds":None,"payload":"runtime self-test","enabled":True,"failures":0,"lastError":None,"lease":None};d["jobs"].append(j);save(d);print(j["id"]);sys.exit(0)
if len(args)<2:raise SystemExit("usage: jobctl.py list|add-probe|pause|resume|delete <id-prefix>")
j=find(d,args[1]);
if not j:raise SystemExit("job not found or prefix ambiguous")
if cmd=="pause":j["enabled"]=False;j["state"]="paused"
elif cmd=="resume":j["enabled"]=True;j["state"]="scheduled";j["nextRunAt"]=time.time()
elif cmd=="delete":d["jobs"].remove(j)
else:raise SystemExit("unknown command")
if cmd!="delete":j["updatedAt"]=time.time()
save(d);print("ok")
