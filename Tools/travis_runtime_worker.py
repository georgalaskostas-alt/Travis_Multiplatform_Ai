#!/usr/bin/env python3
"""TRAVIS durable headless runtime supervisor.

Owns service heartbeat, durable service-job scheduling, leases, recovery and an
append-only journal. It deliberately does NOT execute arbitrary shell commands,
exchange orders, credentials, or live trading.
"""
import json, os, signal, time, uuid
from pathlib import Path

ROOT=Path.home()/"Library/Application Support/TRAVIS/AlwaysOn"
ROOT.mkdir(parents=True,exist_ok=True)
HEARTBEAT=ROOT/"worker-heartbeat.json"; CONTROL=ROOT/"worker-control.json"
JOBS=ROOT/"service-jobs-v1.json"; JOURNAL=ROOT/"service-journal-v1.jsonl"
RUN=True; PID=os.getpid(); STARTED=time.time(); LEASE_TTL=30.0

def stop(*_):
    global RUN; RUN=False
signal.signal(signal.SIGTERM,stop); signal.signal(signal.SIGINT,stop)

def atomic_json(path,payload):
    tmp=path.with_suffix(path.suffix+".tmp"); tmp.write_text(json.dumps(payload,sort_keys=True),encoding="utf-8"); os.replace(tmp,path)
def read_json(path,default):
    try:return json.loads(path.read_text(encoding="utf-8"))
    except Exception:return default
def journal(event,**fields):
    record={"at":time.time(),"event":event,"workerPID":PID,**fields}
    with JOURNAL.open("a",encoding="utf-8") as f:f.write(json.dumps(record,sort_keys=True)+"\n")
def control():return read_json(CONTROL,{"killSwitch":False})
def load_jobs():
    raw=read_json(JOBS,{"version":1,"jobs":[]}); return raw if isinstance(raw,dict) else {"version":1,"jobs":[]}
def save_jobs(doc):atomic_json(JOBS,doc)
def recover(doc):
    now=time.time(); changed=False
    for j in doc.get("jobs",[]):
        lease=j.get("lease") or {}
        if j.get("state")=="running" and float(lease.get("expiresAt",0))<now:
            j["state"]="scheduled";j["nextRunAt"]=now;j["lastError"]="Recovered stale worker lease";j["lease"]=None;changed=True;journal("job_recovered",jobID=j.get("id"))
    if changed:save_jobs(doc)
    return doc

def execute_safe(job):
    kind=job.get("kind")
    if kind=="heartbeatProbe": return {"ok":True,"summary":"Headless runtime probe completed"}
    if kind=="watcher":
        # Foundation watcher is deterministic and local only. Network/API watchers
        # will be added through explicit connector allowlists, never shell payloads.
        return {"ok":True,"summary":"Watcher cycle recorded","payload":str(job.get("payload",""))[:500]}
    raise RuntimeError(f"Unsupported headless job kind: {kind}")

def tick_jobs(killed):
    doc=recover(load_jobs()); jobs=doc.get("jobs",[]); now=time.time(); changed=False
    if killed:return len([j for j in jobs if j.get("enabled")])
    for j in jobs:
        if not j.get("enabled",False) or j.get("state") in ("paused","stopped"):continue
        if float(j.get("nextRunAt",j.get("createdAt",now)))>now:continue
        lease={"owner":f"worker:{PID}","token":str(uuid.uuid4()),"acquiredAt":now,"expiresAt":now+LEASE_TTL}
        j["state"]="running";j["lease"]=lease;j["updatedAt"]=now;save_jobs(doc);journal("job_started",jobID=j.get("id"),kind=j.get("kind"))
        try:
            result=execute_safe(j);j["lastResult"]=result;j["lastError"]=None;j["failures"]=0
            cadence=float(j.get("cadenceSeconds") or 0)
            if cadence>0:j["state"]="sleeping";j["nextRunAt"]=time.time()+cadence
            else:j["state"]="stopped";j["enabled"]=False;j["nextRunAt"]=None
            journal("job_completed",jobID=j.get("id"),summary=result.get("summary"))
        except Exception as e:
            failures=int(j.get("failures",0))+1;j["failures"]=failures;j["lastError"]=str(e);j["state"]="failed";j["nextRunAt"]=time.time()+min((2**failures)*5,300);journal("job_failed",jobID=j.get("id"),error=str(e))
        j["lease"]=None;j["updatedAt"]=time.time();changed=True;save_jobs(doc)
    return len([j for j in jobs if j.get("enabled")])

journal("worker_started")
while RUN:
    c=control(); killed=bool(c.get("killSwitch",False)); active=tick_jobs(killed)
    atomic_json(HEARTBEAT,{"version":2,"pid":PID,"startedAt":STARTED,"lastBeatAt":time.time(),"killSwitch":killed,"state":"safe-stop" if killed else "ready","activeServiceJobs":active,"journal":str(JOURNAL)})
    time.sleep(2)
journal("worker_stopped")
try:HEARTBEAT.unlink()
except FileNotFoundError:pass
