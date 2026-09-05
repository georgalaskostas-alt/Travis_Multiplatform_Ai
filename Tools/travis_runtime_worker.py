#!/usr/bin/env python3
"""TRAVIS durable headless runtime supervisor.
Allowlisted deterministic execution only. No arbitrary shell, credentials, withdrawals or live trading.
"""
import fcntl,json,os,platform,signal,time,uuid
from contextlib import contextmanager
from pathlib import Path
ROOT=Path.home()/"Library/Application Support/TRAVIS/AlwaysOn";ROOT.mkdir(parents=True,exist_ok=True)
HEARTBEAT=ROOT/"worker-heartbeat.json";CONTROL=ROOT/"worker-control.json";COMMAND=ROOT/"worker-command.json";JOBS=ROOT/"service-jobs-v1.json";JOURNAL=ROOT/"service-journal-v1.jsonl";LOCK=ROOT/"service-jobs.lock"
RUN=True;PID=os.getpid();STARTED=time.time();LEASE_TTL=30.0;GEN=str(uuid.uuid4());ALLOWED_KINDS={"heartbeatProbe","systemWatcher","headlessMission","watcher"}
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
 raw=read_json(JOBS,{"version":4,"jobs":[]});return raw if isinstance(raw,dict) and isinstance(raw.get("jobs",[]),list) else {"version":4,"jobs":[]}
def resolve(jobs,key):
 key=str(key or "").lower();matches=[j for j in jobs if str(j.get("id","")).lower().startswith(key)];return matches[0] if len(matches)==1 else None
def validate_job(j):
 if j.get("kind") not in ALLOWED_KINDS:raise RuntimeError("Job kind is not allowlisted")
 if not str(j.get("id","")).strip():raise RuntimeError("Job id missing")
 if float(j.get("cadenceSeconds") or 0)<0:raise RuntimeError("Invalid cadence")
def apply_remote_command():
 if not COMMAND.exists():return
 try:cmd=read_json(COMMAND,{});COMMAND.unlink(missing_ok=True)
 except Exception:return
 action=str(cmd.get("action","")).lower();key=cmd.get("jobID")
 with locked():
  doc=load_jobs();job=resolve(doc["jobs"],key)
  if not job:journal("remote_command_rejected",action=action,jobID=key,reason="not-found-or-ambiguous");return
  if action=="pause":job.update(enabled=False,state="paused",lease=None,updatedAt=time.time())
  elif action in ("resume","retry"):job.update(enabled=True,state="scheduled",nextRunAt=time.time(),lease=None,lastError=None,updatedAt=time.time())
  elif action=="delete":doc["jobs"].remove(job)
  else:journal("remote_command_rejected",action=action,jobID=key,reason="unsupported");return
  doc["version"]=4;atomic_json(JOBS,doc);journal("remote_command_applied",action=action,jobID=job.get("id"))
def recover(doc):
 now=time.time()
 for j in doc["jobs"]:
  lease=j.get("lease") or {}
  if j.get("state")=="running" and float(lease.get("expiresAt",0))<now:
   j.update(state="scheduled",nextRunAt=now,lastError="Recovered stale worker lease",lease=None,updatedAt=now,recoveryCount=int(j.get("recoveryCount",0))+1);journal("job_recovered",jobID=j.get("id"),checkpoint=j.get("checkpoint"))
 return doc
def host_observation():
 load=os.getloadavg();disk=os.statvfs(str(Path.home()));free=disk.f_bavail*disk.f_frsize;total=disk.f_blocks*disk.f_frsize
 return {"host":platform.node(),"platform":platform.platform(),"load1":round(load[0],2),"load5":round(load[1],2),"diskFreePercent":round((free/total*100) if total else 0,1),"pid":PID,"generation":GEN}
def default_plan(goal):
 return [{"order":1,"title":"Collect runtime identity","capability":"runtime.identity"},{"order":2,"title":"Collect system health","capability":"runtime.health"},{"order":3,"title":"Verify safety envelope","capability":"runtime.safety"},{"order":4,"title":"Synthesize final report","capability":"report.synthesize"}]
def execute_capability(capability,context):
 if capability=="runtime.identity":return {"host":platform.node(),"workerPID":PID,"generation":GEN}
 if capability=="runtime.health":return host_observation()
 if capability=="runtime.safety":return {"killSwitch":bool(control().get("killSwitch",False)),"arbitraryShell":False,"liveTrading":False,"withdrawals":False,"credentials":False}
 if capability=="report.synthesize":
  health=next((x.get("result") for x in context if x.get("capability")=="runtime.health"),{}) or {};goal=context[0].get("goal","") if context else ""
  return {"report":f"Goal: {goal}\nWorker {PID} on {health.get('host',platform.node())} is operational. Load1={health.get('load1','n/a')}, disk free={health.get('diskFreePercent','n/a')}%. Safety envelope verified."}
 raise RuntimeError(f"Unsupported mission capability: {capability}")
def run_headless_mission(job,payload,persist):
 goal=str(payload.get("goal") or "Generate TRAVIS runtime health report")[:1000];plan=payload.get("plan") if isinstance(payload.get("plan"),list) else default_plan(goal)
 if not plan or len(plan)>20:raise RuntimeError("Mission plan must contain 1...20 steps")
 completed=list((job.get("missionState") or {}).get("completedSteps") or []);completed_orders={int(s.get("order",0)) for s in completed};context=[{"goal":goal}]+completed
 for raw in sorted(plan,key=lambda x:int(x.get("order",0))):
  order=int(raw.get("order",0));title=str(raw.get("title") or f"Step {order}")[:200];cap=str(raw.get("capability") or "")
  if order<1 or not cap:raise RuntimeError("Malformed mission step")
  if order in completed_orders:continue
  if bool(control().get("killSwitch",False)):raise RuntimeError("Emergency kill switch active")
  checkpoint={"order":order,"title":title,"capability":cap,"at":time.time()};job["checkpoint"]=checkpoint;persist();journal("mission_step_started",jobID=job.get("id"),order=order,title=title,capability=cap)
  result=execute_capability(cap,context);record={"order":order,"title":title,"capability":cap,"status":"completed","result":result,"completedAt":time.time()};completed.append(record);context.append(record);job["missionState"]={"completedSteps":completed,"totalSteps":len(plan)};job["checkpoint"]={"order":order,"title":title,"status":"completed","at":time.time()};persist();journal("mission_step_completed",jobID=job.get("id"),order=order,title=title,capability=cap)
 report=next((s.get("result",{}).get("report") for s in reversed(completed) if s.get("capability")=="report.synthesize"),None) or f"Mission completed: {goal}"
 return {"ok":True,"summary":"Headless mission completed","goal":goal,"completedSteps":len(completed),"totalSteps":len(plan),"steps":completed,"finalReport":report}
def execute_safe(job,persist):
 validate_job(job);kind=job.get("kind");payload=job.get("payload") or {}
 if kind=="heartbeatProbe":return {"ok":True,"summary":"Headless runtime probe completed"}
 if kind=="systemWatcher":
  obs=host_observation();threshold=float(payload.get("minDiskFreePercent",10)) if isinstance(payload,dict) else 10;obs["alert"]=obs["diskFreePercent"]<threshold;return {"ok":True,"summary":"System watcher cycle completed","observation":obs}
 if kind=="headlessMission":return run_headless_mission(job,payload if isinstance(payload,dict) else {},persist)
 if kind=="watcher":return {"ok":True,"summary":"Local watcher cycle recorded","payload":str(payload)[:500]}
 raise RuntimeError(f"Unsupported headless job kind: {kind}")
def public_jobs(jobs):
 return [{"id":j.get("id"),"title":j.get("title"),"kind":j.get("kind"),"state":j.get("state"),"nextRunAt":j.get("nextRunAt"),"failures":int(j.get("failures",0)),"recoveryCount":int(j.get("recoveryCount",0)),"lastError":j.get("lastError"),"enabled":bool(j.get("enabled",False)),"lastCompletedAt":j.get("lastCompletedAt"),"summary":(j.get("lastResult") or {}).get("summary"),"finalReport":(j.get("lastResult") or {}).get("finalReport"),"completedSteps":int((j.get("lastResult") or {}).get("completedSteps",len((j.get("missionState") or {}).get("completedSteps") or []))),"totalSteps":int((j.get("lastResult") or {}).get("totalSteps",len((j.get("payload") or {}).get("plan") or []))),"checkpoint":j.get("checkpoint")} for j in jobs][-50:]
def tick_jobs(killed):
 with locked():
  doc=recover(load_jobs());jobs=doc["jobs"];now=time.time()
  if killed:return jobs
  for j in jobs:
   if not j.get("enabled",False) or j.get("state") in ("paused","stopped"):continue
   if float(j.get("nextRunAt") or j.get("createdAt") or now)>now:continue
   run_id=str(uuid.uuid4());j.update(state="running",lease={"owner":f"worker:{PID}","token":run_id,"acquiredAt":now,"expiresAt":now+LEASE_TTL},updatedAt=now,lastRunID=run_id);doc["version"]=4;atomic_json(JOBS,doc);journal("job_started",jobID=j.get("id"),kind=j.get("kind"),runID=run_id)
   def persist():doc["version"]=4;atomic_json(JOBS,doc)
   try:
    result=execute_safe(j,persist);previous=j.get("lastResult");j.update(lastResult=result,lastError=None,failures=0,lastCompletedAt=time.time(),missionState=None,checkpoint=None);cadence=float(j.get("cadenceSeconds") or 0)
    if cadence>0:j.update(state="sleeping",nextRunAt=time.time()+cadence)
    else:j.update(state="stopped",enabled=False,nextRunAt=None)
    journal("job_completed",jobID=j.get("id"),runID=run_id,summary=result.get("summary"),changed=previous!=result)
   except Exception as e:
    failures=int(j.get("failures",0))+1;j.update(failures=failures,lastError=str(e),state="failed",nextRunAt=time.time()+min((2**failures)*5,300));journal("job_failed",jobID=j.get("id"),runID=run_id,error=str(e),checkpoint=j.get("checkpoint"))
   j.update(lease=None,updatedAt=time.time());persist()
  return jobs
journal("worker_started")
while RUN:
 try:
  apply_remote_command();c=control();killed=bool(c.get("killSwitch",False));jobs=tick_jobs(killed);active=sum(1 for j in jobs if j.get("enabled") and j.get("state") not in ("paused","stopped"));failed=sum(1 for j in jobs if j.get("state")=="failed");atomic_json(HEARTBEAT,{"version":6,"generation":GEN,"pid":PID,"startedAt":STARTED,"lastBeatAt":time.time(),"killSwitch":killed,"state":"safe-stop" if killed else "ready","activeServiceJobs":active,"failedServiceJobs":failed,"serviceJobs":public_jobs(jobs),"journal":str(JOURNAL)})
 except Exception as e:journal("worker_loop_error",error=str(e))
 time.sleep(2)
journal("worker_stopped")
try:HEARTBEAT.unlink()
except FileNotFoundError:pass
