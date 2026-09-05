#!/usr/bin/env python3
"""TRAVIS durable headless runtime supervisor.
Safe deterministic service scheduler: no shell execution, credentials or trading.
"""
import fcntl,json,os,platform,signal,time,uuid
from contextlib import contextmanager
from pathlib import Path
ROOT=Path.home()/"Library/Application Support/TRAVIS/AlwaysOn";ROOT.mkdir(parents=True,exist_ok=True)
HEARTBEAT=ROOT/"worker-heartbeat.json";CONTROL=ROOT/"worker-control.json";JOBS=ROOT/"service-jobs-v1.json";JOURNAL=ROOT/"service-journal-v1.jsonl";LOCK=ROOT/"service-jobs.lock"
RUN=True;PID=os.getpid();STARTED=time.time();LEASE_TTL=30.0;GEN=str(uuid.uuid4())
def stop(*_):
 global RUN;RUN=False
signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
@contextmanager
def locked():
 with LOCK.open("a+") as f:fcntl.flock(f,fcntl.LOCK_EX);yield;fcntl.flock(f,fcntl.LOCK_UN)
def atomic_json(path,payload):
 tmp=path.with_suffix(path.suffix+".tmp");tmp.write_text(json.dumps(payload,sort_keys=True),encoding="utf-8");os.replace(tmp,path)
def read_json(path,default):
 try:return json.loads(path.read_text(encoding="utf-8"))
 except Exception:return default
def journal(event,**fields):
 rec={"at":time.time(),"event":event,"workerPID":PID,"generation":GEN,**fields}
 with (ROOT/"service-journal.lock").open("a+") as lk:
  fcntl.flock(lk,fcntl.LOCK_EX)
  with JOURNAL.open("a",encoding="utf-8") as f:f.write(json.dumps(rec,sort_keys=True)+"\n")
  fcntl.flock(lk,fcntl.LOCK_UN)
def control():return read_json(CONTROL,{"killSwitch":False})
def load_jobs():
 raw=read_json(JOBS,{"version":2,"jobs":[]});return raw if isinstance(raw,dict) and isinstance(raw.get("jobs",[]),list) else {"version":2,"jobs":[]}
def recover(doc):
 now=time.time()
 for j in doc["jobs"]:
  lease=j.get("lease") or {}
  if j.get("state")=="running" and float(lease.get("expiresAt",0))<now:
   j.update(state="scheduled",nextRunAt=now,lastError="Recovered stale worker lease",lease=None,updatedAt=now);journal("job_recovered",jobID=j.get("id"))
 return doc
def execute_safe(job):
 kind=job.get("kind");payload=job.get("payload") or {}
 if kind=="heartbeatProbe":return {"ok":True,"summary":"Headless runtime probe completed"}
 if kind=="systemWatcher":
  load=os.getloadavg();disk=os.statvfs(str(Path.home()));free=disk.f_bavail*disk.f_frsize;total=disk.f_blocks*disk.f_frsize;free_pct=(free/total*100) if total else 0
  obs={"host":platform.node(),"load1":round(load[0],2),"load5":round(load[1],2),"diskFreePercent":round(free_pct,1)}
  threshold=float(payload.get("minDiskFreePercent",10)) if isinstance(payload,dict) else 10
  obs["alert"]=free_pct<threshold
  return {"ok":True,"summary":"System watcher cycle completed","observation":obs}
 if kind=="watcher":return {"ok":True,"summary":"Local watcher cycle recorded","payload":str(payload)[:500]}
 raise RuntimeError(f"Unsupported headless job kind: {kind}")
def tick_jobs(killed):
 with locked():
  doc=recover(load_jobs());jobs=doc["jobs"];now=time.time()
  if killed:return len([j for j in jobs if j.get("enabled")])
  for j in jobs:
   if not j.get("enabled",False) or j.get("state") in ("paused","stopped"):continue
   if float(j.get("nextRunAt") or j.get("createdAt") or now)>now:continue
   run_id=str(uuid.uuid4());j.update(state="running",lease={"owner":f"worker:{PID}","token":run_id,"acquiredAt":now,"expiresAt":now+LEASE_TTL},updatedAt=now,lastRunID=run_id);atomic_json(JOBS,doc);journal("job_started",jobID=j.get("id"),kind=j.get("kind"),runID=run_id)
   try:
    result=execute_safe(j);previous=j.get("lastResult");j.update(lastResult=result,lastError=None,failures=0,lastCompletedAt=time.time())
    cadence=float(j.get("cadenceSeconds") or 0)
    if cadence>0:j.update(state="sleeping",nextRunAt=time.time()+cadence)
    else:j.update(state="stopped",enabled=False,nextRunAt=None)
    journal("job_completed",jobID=j.get("id"),runID=run_id,summary=result.get("summary"),changed=previous!=result)
   except Exception as e:
    failures=int(j.get("failures",0))+1;j.update(failures=failures,lastError=str(e),state="failed",nextRunAt=time.time()+min((2**failures)*5,300));journal("job_failed",jobID=j.get("id"),runID=run_id,error=str(e))
   j.update(lease=None,updatedAt=time.time());atomic_json(JOBS,doc)
  return len([j for j in jobs if j.get("enabled")])
journal("worker_started")
while RUN:
 try:
  c=control();killed=bool(c.get("killSwitch",False));active=tick_jobs(killed);atomic_json(HEARTBEAT,{"version":3,"generation":GEN,"pid":PID,"startedAt":STARTED,"lastBeatAt":time.time(),"killSwitch":killed,"state":"safe-stop" if killed else "ready","activeServiceJobs":active,"journal":str(JOURNAL)})
 except Exception as e:journal("worker_loop_error",error=str(e))
 time.sleep(2)
journal("worker_stopped")
try:HEARTBEAT.unlink()
except FileNotFoundError:pass
