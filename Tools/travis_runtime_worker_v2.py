#!/usr/bin/env python3
"""TRAVIS headless worker v2: claim/execute/commit leases, durable commands, crash recovery."""
import fcntl,json,os,platform,signal,time,uuid,urllib.request,urllib.error
from contextlib import contextmanager
from pathlib import Path
ROOT=Path.home()/"Library/Application Support/TRAVIS/AlwaysOn";ROOT.mkdir(parents=True,exist_ok=True)
JOBS=ROOT/"service-jobs-v1.json";LOCK=ROOT/"service-jobs.lock";JOURNAL=ROOT/"service-journal-v1.jsonl";HB=ROOT/"worker-heartbeat.json";CONTROL=ROOT/"worker-control.json";QUEUE=ROOT/"worker-command-queue.json";LEGACY=ROOT/"worker-command.json"
RUN=True;PID=os.getpid();START=time.time();GEN=str(uuid.uuid4());LEASE_TTL=45.0;ALLOWED={"heartbeatProbe","systemWatcher","headlessMission","watcher","repositorySnapshot","fileInventory","httpWatcher"}
def stop(*_):
 global RUN;RUN=False
signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
@contextmanager
def locked():
 with LOCK.open("a+") as f:fcntl.flock(f,fcntl.LOCK_EX);yield;fcntl.flock(f,fcntl.LOCK_UN)
def atomic(path,obj):
 t=path.with_suffix(path.suffix+".tmp");t.write_text(json.dumps(obj,sort_keys=True),encoding="utf-8");os.replace(t,path)
def read(path,default):
 try:return json.loads(path.read_text(encoding="utf-8"))
 except Exception:return default
def doc():
 d=read(JOBS,{"version":8,"jobs":[]});return d if isinstance(d,dict) and isinstance(d.get("jobs"),list) else {"version":8,"jobs":[]}
def log(event,**kw):
 r={"at":time.time(),"event":event,"workerPID":PID,"generation":GEN,**kw}
 with (ROOT/"service-journal.lock").open("a+") as l:
  fcntl.flock(l,fcntl.LOCK_EX)
  with JOURNAL.open("a") as f:f.write(json.dumps(r,sort_keys=True)+"\n")
  fcntl.flock(l,fcntl.LOCK_UN)
def killed():return bool(read(CONTROL,{"killSwitch":False}).get("killSwitch",False))
def resolve(jobs,key):
 k=str(key or "").lower();m=[j for j in jobs if str(j.get("id","")).lower().startswith(k)];return m[0] if len(m)==1 else None
def commands():
 q=read(QUEUE,{"commands":[]}).get("commands",[]) if QUEUE.exists() else []
 if LEGACY.exists():q.append(read(LEGACY,{}));LEGACY.unlink(missing_ok=True)
 if QUEUE.exists():atomic(QUEUE,{"version":1,"commands":[]})
 return [x for x in q if isinstance(x,dict)]
def apply_commands():
 cmds=commands()
 if not cmds:return
 with locked():
  d=doc();jobs=d["jobs"]
  for c in cmds:
   action=str(c.get("action","")).lower();j=resolve(jobs,c.get("jobID"));nonce=c.get("nonce")
   if not j:log("remote_command_rejected",action=action,jobID=c.get("jobID"),nonce=nonce,reason="not-found-or-ambiguous");continue
   if action=="pause":j.update(enabled=False,state="paused",cancelRequested=True,updatedAt=time.time())
   elif action in ("resume","retry"):j.update(enabled=True,state="scheduled",nextRunAt=time.time(),lease=None,cancelRequested=False,lastError=None,updatedAt=time.time())
   elif action=="delete":
    if j.get("state")=="running":j.update(enabled=False,cancelRequested=True,deleteAfterRun=True,updatedAt=time.time())
    else:jobs.remove(j)
   else:log("remote_command_rejected",action=action,jobID=j.get("id"),nonce=nonce,reason="unsupported");continue
   log("remote_command_applied",action=action,jobID=j.get("id"),nonce=nonce)
  d["version"]=8;atomic(JOBS,d)
def recover():
 with locked():
  d=doc();now=time.time();changed=False
  for j in d["jobs"]:
   l=j.get("lease") or {}
   if j.get("state")=="running" and float(l.get("expiresAt",0))<now:
    j.update(state="scheduled",nextRunAt=now,lease=None,lastError="Recovered expired execution lease",updatedAt=now,recoveryCount=int(j.get("recoveryCount",0))+1);changed=True;log("job_recovered",jobID=j.get("id"),checkpoint=j.get("checkpoint"))
  if changed:d["version"]=8;atomic(JOBS,d)
def claim():
 if killed():return None
 with locked():
  d=doc();now=time.time()
  for j in d["jobs"]:
   if not j.get("enabled",False) or j.get("state") in ("paused","stopped","running"):continue
   if float(j.get("nextRunAt") or j.get("createdAt") or now)>now:continue
   if j.get("kind") not in ALLOWED:
    j.update(state="failed",lastError="Job kind is not allowlisted",updatedAt=now);atomic(JOBS,d);continue
   token=str(uuid.uuid4());j.update(state="running",lease={"owner":f"worker:{PID}","generation":GEN,"token":token,"acquiredAt":now,"renewedAt":now,"expiresAt":now+LEASE_TTL},lastRunID=token,updatedAt=now,cancelRequested=False);d["version"]=8;atomic(JOBS,d);log("job_claimed",jobID=j.get("id"),kind=j.get("kind"),runID=token);return str(j.get("id")),token,json.loads(json.dumps(j))
 return None
def mutate_owned(jobid,token,fn):
 with locked():
  d=doc();j=next((x for x in d["jobs"] if str(x.get("id"))==jobid),None)
  if not j:return False
  l=j.get("lease") or {}
  if l.get("token")!=token or l.get("generation")!=GEN:return False
  fn(j);j["updatedAt"]=time.time();d["version"]=8;atomic(JOBS,d);return True
def pulse(jobid,token,checkpoint=None):
 def f(j):
  l=j.get("lease") or {};now=time.time();l.update(renewedAt=now,expiresAt=now+LEASE_TTL);j["lease"]=l
  if checkpoint is not None:j["checkpoint"]=checkpoint
 if not mutate_owned(jobid,token,f):raise RuntimeError("Execution lease lost")
 with locked():
  j=next((x for x in doc()["jobs"] if str(x.get("id"))==jobid),None)
  if not j or j.get("cancelRequested") or not j.get("enabled",False):raise RuntimeError("Execution cancelled")
 if killed():raise RuntimeError("Emergency kill switch active")
def safe_path(raw):
 p=Path(str(raw or "")).expanduser().resolve();h=Path.home().resolve()
 if p!=h and h not in p.parents:raise RuntimeError("Path outside user home scope")
 return p
def health():
 load=os.getloadavg();v=os.statvfs(str(Path.home()));return {"host":platform.node(),"load1":round(load[0],2),"load5":round(load[1],2),"diskFreePercent":round(v.f_bavail/v.f_blocks*100,1) if v.f_blocks else 0,"pid":PID,"generation":GEN}
def inventory(raw):
 p=safe_path(raw);n=d=b=0;ext={}
 if not p.exists():raise RuntimeError("Path does not exist")
 for root,ds,fs in os.walk(p):
  d+=len(ds)
  for name in fs:
   n+=1
   if n>2000:break
   q=Path(root)/name
   try:b+=q.stat().st_size
   except:pass
   ext[q.suffix.lower()]=ext.get(q.suffix.lower(),0)+1
  if n>2000:break
 return {"root":str(p),"files":min(n,2000),"directories":d,"bytes":b,"truncated":n>2000,"extensions":dict(sorted(ext.items(),key=lambda x:-x[1])[:25])}
def repo(raw):
 p=safe_path(raw);g=p/".git";branch=head=None
 if not p.is_dir():raise RuntimeError("Repository path invalid")
 try:
  h=(g/"HEAD").read_text().strip();branch=h.split("/",2)[-1] if h.startswith("ref: ") else None;ref=g/h[5:] if h.startswith("ref: ") else None;head=ref.read_text().strip() if ref and ref.exists() else h
 except:pass
 return {"path":str(p),"isGitRepository":g.exists(),"branch":branch,"head":head,"inventory":inventory(str(p))}
def http(url):
 u=str(url or "");
 if not u.startswith(("http://","https://")):raise RuntimeError("Only HTTP(S) allowed")
 st=time.time()
 try:
  with urllib.request.urlopen(urllib.request.Request(u,headers={"User-Agent":"TRAVIS-Worker/2"}),timeout=15) as r:r.read(4096);return {"url":u,"status":r.status,"latencyMs":int((time.time()-st)*1000),"ok":200<=r.status<400}
 except urllib.error.HTTPError as e:return {"url":u,"status":e.code,"latencyMs":int((time.time()-st)*1000),"ok":False}
def capability(cap,args,ctx):
 if cap=="runtime.identity":return {"host":platform.node(),"workerPID":PID,"generation":GEN}
 if cap=="runtime.health":return health()
 if cap=="runtime.safety":return {"killSwitch":killed(),"arbitraryShell":False,"liveTrading":False,"withdrawals":False,"credentials":False}
 if cap=="filesystem.inventory":return inventory(args.get("path"))
 if cap=="repository.snapshot":return repo(args.get("path"))
 if cap=="network.http_probe":return http(args.get("url"))
 if cap=="report.synthesize":return {"report":"Always-On mission completed with %d verified steps."%len([x for x in ctx if x.get("result")])}
 raise RuntimeError("Unsupported mission capability: "+cap)
def execute(jobid,token,j):
 kind=j.get("kind");p=j.get("payload") or {};pulse(jobid,token)
 if kind=="heartbeatProbe":return {"ok":True,"summary":"Headless runtime probe completed"}
 if kind=="systemWatcher":return {"ok":True,"summary":"System watcher cycle completed","observation":health()}
 if kind=="repositorySnapshot":return {"ok":True,"summary":"Repository snapshot completed","repository":repo(p.get("path"))}
 if kind=="fileInventory":return {"ok":True,"summary":"File inventory completed","inventory":inventory(p.get("path"))}
 if kind=="httpWatcher":
  o=http(p.get("url"));return {"ok":True,"summary":"HTTP watcher cycle completed","observation":o,"alert":not o.get("ok")}
 if kind=="watcher":return {"ok":True,"summary":"Local watcher cycle recorded"}
 if kind!="headlessMission":raise RuntimeError("Unsupported kind")
 goal=str(p.get("goal") or "TRAVIS mission")[:1000];plan=p.get("plan") or [{"order":1,"title":"Identity","capability":"runtime.identity"},{"order":2,"title":"Health","capability":"runtime.health"},{"order":3,"title":"Safety","capability":"runtime.safety"},{"order":4,"title":"Report","capability":"report.synthesize"}]
 completed=list((j.get("missionState") or {}).get("completedSteps") or []);done={int(x.get("order",0)) for x in completed};ctx=[{"goal":goal}]+completed
 for s in sorted(plan,key=lambda x:int(x.get("order",0))):
  order=int(s.get("order",0));
  if order in done:continue
  cp={"order":order,"title":str(s.get("title") or order),"capability":str(s.get("capability") or ""),"status":"running","at":time.time()};pulse(jobid,token,cp);log("mission_step_started",jobID=jobid,runID=token,**cp)
  r=capability(cp["capability"],s.get("arguments") or {},ctx);rec={**cp,"status":"completed","result":r,"completedAt":time.time()};completed.append(rec);ctx.append(rec)
  def save(x):x["missionState"]={"completedSteps":completed,"totalSteps":len(plan)};x["checkpoint"]={**cp,"status":"completed","at":time.time()};(x.get("lease") or {}).update(expiresAt=time.time()+LEASE_TTL,renewedAt=time.time())
  if not mutate_owned(jobid,token,save):raise RuntimeError("Execution lease lost");log("mission_step_completed",jobID=jobid,runID=token,order=order,title=cp["title"],capability=cp["capability"])
 report=next((x.get("result",{}).get("report") for x in reversed(completed) if x.get("capability")=="report.synthesize"),None) or "Mission completed: "+goal
 return {"ok":True,"summary":"Headless mission completed","goal":goal,"completedSteps":len(completed),"totalSteps":len(plan),"steps":completed,"finalReport":report}
def commit(jobid,token,result=None,error=None):
 def f(j):
  if j.get("deleteAfterRun"):j["_delete"] = True;return
  if error:
   fails=int(j.get("failures",0))+1;j.update(state="failed",failures=fails,lastError=error,nextRunAt=time.time()+min((2**fails)*5,300),lease=None)
  else:
   cadence=float(j.get("cadenceSeconds") or 0);j.update(lastResult=result,lastError=None,failures=0,lastCompletedAt=time.time(),missionState=None,checkpoint=None,lease=None,state="sleeping" if cadence>0 else "stopped",enabled=True if cadence>0 else False,nextRunAt=time.time()+cadence if cadence>0 else None)
 ok=mutate_owned(jobid,token,f)
 if ok:
  with locked():
   d=doc();before=len(d["jobs"]);d["jobs"]=[x for x in d["jobs"] if not x.get("_delete")];
   if len(d["jobs"])!=before:atomic(JOBS,d)
  log("job_failed" if error else "job_completed",jobID=jobid,runID=token,error=error,summary=(result or {}).get("summary"))
def public():
 with locked():jobs=doc()["jobs"]
 out=[]
 for j in jobs[-50:]:
  r=j.get("lastResult") or {};m=j.get("missionState") or {};out.append({"id":j.get("id"),"title":j.get("title"),"kind":j.get("kind"),"state":j.get("state"),"nextRunAt":j.get("nextRunAt"),"failures":int(j.get("failures",0)),"recoveryCount":int(j.get("recoveryCount",0)),"lastError":j.get("lastError"),"enabled":bool(j.get("enabled",False)),"lastCompletedAt":j.get("lastCompletedAt"),"summary":r.get("summary"),"finalReport":r.get("finalReport"),"completedSteps":int(r.get("completedSteps",len(m.get("completedSteps") or []))),"totalSteps":int(r.get("totalSteps",len((j.get("payload") or {}).get("plan") or []))),"checkpoint":j.get("checkpoint")})
 return out
log("worker_started",workerVersion=8);recover()
while RUN:
 try:
  apply_commands();c=claim()
  if c:
   jid,tok,j=c
   try:r=execute(jid,tok,j);commit(jid,tok,result=r)
   except Exception as e:commit(jid,tok,error=str(e))
  jobs=public();atomic(HB,{"version":8,"generation":GEN,"pid":PID,"startedAt":START,"lastBeatAt":time.time(),"killSwitch":killed(),"state":"safe-stop" if killed() else "ready","activeServiceJobs":sum(1 for j in jobs if j["enabled"] and j["state"] not in ("paused","stopped")),"failedServiceJobs":sum(1 for j in jobs if j["state"]=="failed"),"serviceJobs":jobs})
 except Exception as e:log("worker_loop_error",error=str(e))
 time.sleep(1)
log("worker_stopped");HB.unlink(missing_ok=True)
