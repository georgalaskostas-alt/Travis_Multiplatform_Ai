#!/usr/bin/env python3
"""Safe administration utility for TRAVIS headless service jobs."""
import fcntl,json,os,sys,time,uuid
from contextlib import contextmanager
from pathlib import Path
ROOT=Path.home()/"Library/Application Support/TRAVIS/AlwaysOn";ROOT.mkdir(parents=True,exist_ok=True);JOBS=ROOT/"service-jobs-v1.json";LOCK=ROOT/"service-jobs.lock";HEARTBEAT=ROOT/"worker-heartbeat.json";JOURNAL=ROOT/"service-journal-v1.jsonl"
@contextmanager
def locked():
 with LOCK.open("a+") as f:fcntl.flock(f,fcntl.LOCK_EX);yield;fcntl.flock(f,fcntl.LOCK_UN)
def load():
 try:
  d=json.loads(JOBS.read_text());return d if isinstance(d,dict) and isinstance(d.get("jobs"),list) else {"version":2,"jobs":[]}
 except Exception:return {"version":2,"jobs":[]}
def save(d):
 d["version"]=2;t=JOBS.with_suffix(".json.tmp");t.write_text(json.dumps(d,sort_keys=True));os.replace(t,JOBS)
def find(d,key):
 m=[j for j in d["jobs"] if str(j.get("id","")).startswith(key)];return m[0] if len(m)==1 else None
def new_job(title,kind,cadence,payload):
 now=time.time();return {"id":str(uuid.uuid4()),"title":title,"kind":kind,"state":"scheduled","createdAt":now,"updatedAt":now,"nextRunAt":now,"cadenceSeconds":cadence,"payload":payload,"enabled":True,"failures":0,"lastError":None,"lease":None}
def usage():raise SystemExit("usage: jobctl.py list|status|journal [n]|add-probe|add-system-watcher [seconds]|pause|resume|delete <id-prefix>")
args=sys.argv[1:];cmd=args[0] if args else "list"
if cmd=="status":
 try:print(json.dumps(json.loads(HEARTBEAT.read_text()),indent=2,sort_keys=True))
 except Exception:print("worker heartbeat unavailable")
 sys.exit(0)
if cmd=="journal":
 n=int(args[1]) if len(args)>1 else 20
 try:
  for line in JOURNAL.read_text().splitlines()[-n:]:print(line)
 except FileNotFoundError:print("journal unavailable")
 sys.exit(0)
with locked():
 d=load()
 if cmd=="list":
  if not d["jobs"]:print("No service jobs.")
  for j in d["jobs"]:print(j.get("id"),j.get("state"),j.get("kind"),j.get("title"),"next=",j.get("nextRunAt"),"failures=",j.get("failures",0))
  sys.exit(0)
 if cmd=="add-probe":j=new_job("TRAVIS Runtime Probe","heartbeatProbe",None,"runtime self-test");d["jobs"].append(j);save(d);print(j["id"]);sys.exit(0)
 if cmd=="add-system-watcher":
  cadence=max(10,int(args[1])) if len(args)>1 else 60;j=new_job("TRAVIS System Health Watcher","systemWatcher",cadence,{"minDiskFreePercent":10});d["jobs"].append(j);save(d);print(j["id"]);sys.exit(0)
 if len(args)<2:usage()
 j=find(d,args[1])
 if not j:raise SystemExit("job not found or prefix ambiguous")
 if cmd=="pause":j.update(enabled=False,state="paused",lease=None)
 elif cmd=="resume":j.update(enabled=True,state="scheduled",nextRunAt=time.time(),lease=None)
 elif cmd=="delete":d["jobs"].remove(j)
 else:usage()
 if cmd!="delete":j["updatedAt"]=time.time()
 save(d);print("ok")
