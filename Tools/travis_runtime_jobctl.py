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
  d=json.loads(JOBS.read_text());return d if isinstance(d,dict) and isinstance(d.get("jobs"),list) else {"version":5,"jobs":[]}
 except Exception:return {"version":5,"jobs":[]}
def save(d):
 d["version"]=5;t=JOBS.with_suffix(".json.tmp");t.write_text(json.dumps(d,sort_keys=True));os.replace(t,JOBS)
def find(d,key):
 m=[j for j in d["jobs"] if str(j.get("id","")).lower().startswith(key.lower())];return m[0] if len(m)==1 else None
def new_job(title,kind,cadence,payload):
 now=time.time();return {"id":str(uuid.uuid4()),"title":title,"kind":kind,"state":"scheduled","createdAt":now,"updatedAt":now,"nextRunAt":now,"cadenceSeconds":cadence,"payload":payload,"enabled":True,"failures":0,"recoveryCount":0,"lastError":None,"lease":None,"checkpoint":None}
def default_plan():return [{"order":1,"title":"Collect runtime identity","capability":"runtime.identity"},{"order":2,"title":"Collect system health","capability":"runtime.health"},{"order":3,"title":"Verify safety envelope","capability":"runtime.safety"},{"order":4,"title":"Synthesize final report","capability":"report.synthesize"}]
def repo_plan(path):return [{"order":1,"title":"Collect runtime identity","capability":"runtime.identity"},{"order":2,"title":"Inspect repository","capability":"repository.snapshot","arguments":{"path":path}},{"order":3,"title":"Verify safety envelope","capability":"runtime.safety"},{"order":4,"title":"Synthesize final report","capability":"report.synthesize"}]
def usage():raise SystemExit("usage: jobctl.py list|status|show <id>|journal [n]|add-probe|add-system-watcher [seconds]|add-http-watcher <url> [seconds]|add-repo-snapshot <path>|add-file-inventory <path>|add-headless-mission [goal]|add-repo-mission <path> [goal]|pause|resume|retry|delete <id-prefix>")
args=sys.argv[1:];cmd=args[0] if args else "list"
if cmd=="status":
 try:
  h=json.loads(HEARTBEAT.read_text());h["heartbeatAgeSeconds"]=round(time.time()-float(h.get("lastBeatAt",0)),2);print(json.dumps(h,indent=2,sort_keys=True))
 except Exception:print("worker heartbeat unavailable")
 sys.exit(0)
if cmd=="journal":
 n=max(1,min(500,int(args[1]))) if len(args)>1 else 30
 try:
  for line in JOURNAL.read_text().splitlines()[-n:]:print(line)
 except FileNotFoundError:print("journal unavailable")
 sys.exit(0)
with locked():
 d=load()
 if cmd=="list":
  if not d["jobs"]:print("No service jobs.")
  for j in d["jobs"]:
   done=len((j.get("missionState") or {}).get("completedSteps") or []);total=len((j.get("payload") or {}).get("plan") or []);progress=f" progress={done}/{total}" if total else "";alert=" ALERT" if bool((j.get("lastResult") or {}).get("alert",False)) else ""
   print(j.get("id"),j.get("state"),j.get("kind"),j.get("title"),"next=",j.get("nextRunAt"),"failures=",j.get("failures",0),progress,alert)
  sys.exit(0)
 if cmd=="add-probe":j=new_job("TRAVIS Runtime Probe","heartbeatProbe",None,"runtime self-test");d["jobs"].append(j);save(d);print(j["id"]);sys.exit(0)
 if cmd=="add-system-watcher":
  cadence=max(10,int(args[1])) if len(args)>1 else 60;j=new_job("TRAVIS System Health Watcher","systemWatcher",cadence,{"minDiskFreePercent":10});d["jobs"].append(j);save(d);print(j["id"]);sys.exit(0)
 if cmd=="add-http-watcher":
  if len(args)<2:usage()
  cadence=max(10,int(args[2])) if len(args)>2 else 60;j=new_job("HTTP Availability Watcher","httpWatcher",cadence,{"url":args[1],"timeout":10});d["jobs"].append(j);save(d);print(j["id"]);sys.exit(0)
 if cmd=="add-repo-snapshot":
  if len(args)<2:usage()
  j=new_job("Repository Snapshot","repositorySnapshot",None,{"path":args[1]});d["jobs"].append(j);save(d);print(j["id"]);sys.exit(0)
 if cmd=="add-file-inventory":
  if len(args)<2:usage()
  j=new_job("File Inventory","fileInventory",None,{"path":args[1]});d["jobs"].append(j);save(d);print(j["id"]);sys.exit(0)
 if cmd=="add-headless-mission":
  goal=" ".join(args[1:]).strip() or "Generate a TRAVIS runtime health and safety report";j=new_job("Headless Runtime Mission","headlessMission",None,{"goal":goal,"plan":default_plan()});d["jobs"].append(j);save(d);print(j["id"]);sys.exit(0)
 if cmd=="add-repo-mission":
  if len(args)<2:usage()
  path=args[1];goal=" ".join(args[2:]).strip() or f"Inspect repository at {path} and generate a safe runtime report";j=new_job("Headless Repository Mission","headlessMission",None,{"goal":goal,"plan":repo_plan(path)});d["jobs"].append(j);save(d);print(j["id"]);sys.exit(0)
 if len(args)<2:usage()
 j=find(d,args[1])
 if not j:raise SystemExit("job not found or prefix ambiguous")
 if cmd=="show":print(json.dumps(j,indent=2,sort_keys=True));sys.exit(0)
 if cmd=="pause":j.update(enabled=False,state="paused",lease=None)
 elif cmd in ("resume","retry"):j.update(enabled=True,state="scheduled",nextRunAt=time.time(),lease=None,lastError=None)
 elif cmd=="delete":d["jobs"].remove(j)
 else:usage()
 if cmd!="delete":j["updatedAt"]=time.time()
 save(d);print("ok")
