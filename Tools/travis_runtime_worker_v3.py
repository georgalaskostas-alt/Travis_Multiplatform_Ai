#!/usr/bin/env python3
"""TRAVIS Always-On Worker v3.
Durable claim/execute/commit leases, idempotent command inbox, Mission V2 handoff,
read-only market intelligence, autonomous PAPER strategy cycles and repository audits.
Never executes arbitrary shell commands and never sends live-money orders.
"""
import fcntl,json,os,platform,signal,time,uuid,urllib.request,urllib.error,sys
from contextlib import contextmanager
from pathlib import Path
ROOT=Path.home()/"Library/Application Support/TRAVIS/AlwaysOn";ROOT.mkdir(parents=True,exist_ok=True)
JOBS=ROOT/"service-jobs-v1.json";LOCK=ROOT/"service-jobs.lock";JOURNAL=ROOT/"service-journal-v1.jsonl";HB=ROOT/"worker-heartbeat.json";CONTROL=ROOT/"worker-control.json";QUEUE=ROOT/"worker-command-queue.json";QLOCK=ROOT/"worker-command-queue.lock";ACK=ROOT/"worker-command-acks-v1.json";LEGACY=ROOT/"worker-command.json"
BIN=Path.home()/"Library/Application Support/TRAVIS/Runtime/bin";sys.path.insert(0,str(BIN))
try: import travis_market_engine as market
except Exception: market=None
RUN=True;PID=os.getpid();START=time.time();GEN=str(uuid.uuid4());LEASE_TTL=45.0
ALLOWED={"heartbeatProbe","systemWatcher","headlessMission","watcher","repositorySnapshot","fileInventory","httpWatcher","marketScan","tradingPaper","repositoryAudit"}
def stop(*_):
 global RUN;RUN=False
signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
@contextmanager
def lock(path=LOCK):
 with path.open("a+") as f: fcntl.flock(f,fcntl.LOCK_EX);yield;fcntl.flock(f,fcntl.LOCK_UN)
def atomic(path,obj):
 t=path.with_suffix(path.suffix+".tmp");t.write_text(json.dumps(obj,sort_keys=True),encoding="utf-8");os.replace(t,path)
def read(path,default):
 try:return json.loads(path.read_text(encoding="utf-8"))
 except Exception:return default
def document():
 d=read(JOBS,{"version":9,"jobs":[]});return d if isinstance(d,dict) and isinstance(d.get("jobs"),list) else {"version":9,"jobs":[]}
def log(event,**kw):
 rec={"at":time.time(),"event":event,"workerPID":PID,"generation":GEN,**kw}
 with lock(ROOT/"service-journal.lock"):
  with JOURNAL.open("a",encoding="utf-8") as f:f.write(json.dumps(rec,sort_keys=True)+"\n")
def killed():return bool(read(CONTROL,{"killSwitch":False}).get("killSwitch",False))
def resolve(jobs,key):
 k=str(key or "").lower();m=[j for j in jobs if str(j.get("id","")).lower().startswith(k)];return m[0] if len(m)==1 else None
def validate_job(j):
 if j.get("kind") not in ALLOWED:raise RuntimeError("Job kind is not allowlisted")
 if not str(j.get("id","")).strip():raise RuntimeError("Job id missing")
 if float(j.get("cadenceSeconds") or 0)<0:raise RuntimeError("Invalid cadence")
 if j.get("kind")=="tradingPaper" and not isinstance(j.get("payload"),dict):raise RuntimeError("Paper trading payload missing")
def ack_state():
 a=read(ACK,{"version":1,"nonces":[]});return a if isinstance(a,dict) else {"version":1,"nonces":[]}
def read_commands():
 with lock(QLOCK):
  q=read(QUEUE,{"commands":[]});commands=q.get("commands",[]) if isinstance(q,dict) else []
  if LEGACY.exists():
   legacy=read(LEGACY,{});LEGACY.unlink(missing_ok=True)
   if isinstance(legacy,dict) and legacy:commands.append(legacy)
  return [c for c in commands if isinstance(c,dict)]
def remove_acked_from_queue(acked):
 with lock(QLOCK):
  q=read(QUEUE,{"version":2,"commands":[]});items=q.get("commands",[]) if isinstance(q,dict) else []
  remain=[c for c in items if str(c.get("nonce", "")) not in acked];atomic(QUEUE,{"version":2,"commands":remain})
def record_ack(nonce,status,detail=None):
 if not nonce:return
 with lock(QLOCK):
  a=ack_state();items=a.get("nonces",[]);items=[x for x in items if isinstance(x,dict) and x.get("nonce")!=nonce];items.append({"nonce":nonce,"status":status,"detail":detail,"at":time.time()});a["nonces"]=items[-1000:];atomic(ACK,a)
def apply_commands():
 cmds=read_commands()
 if not cmds:return
 known={x.get("nonce") for x in ack_state().get("nonces",[]) if isinstance(x,dict)};consumed=set()
 for c in cmds:
  nonce=str(c.get("nonce") or "")
  if nonce and nonce in known:consumed.add(nonce);continue
  action=str(c.get("action","")).lower()
  try:
   with lock():
    d=document();jobs=d["jobs"]
    if action=="create":
     incoming=c.get("job")
     if not isinstance(incoming,dict):raise RuntimeError("create requires job object")
     validate_job(incoming);jid=str(incoming["id"])
     if any(str(x.get("id"))==jid for x in jobs):detail="already-exists"
     else:
      incoming=json.loads(json.dumps(incoming));incoming.setdefault("createdAt",time.time());incoming["updatedAt"]=time.time();incoming.setdefault("state","scheduled");incoming.setdefault("enabled",True);incoming.setdefault("failures",0);incoming.setdefault("recoveryCount",0);jobs.append(incoming);detail="created"
    else:
     j=resolve(jobs,c.get("jobID"));
     if not j:raise RuntimeError("job-not-found-or-ambiguous")
     if action=="pause":j.update(enabled=False,state="paused",cancelRequested=True,updatedAt=time.time());detail="paused"
     elif action in ("resume","retry"):j.update(enabled=True,state="scheduled",nextRunAt=time.time(),lease=None,cancelRequested=False,lastError=None,updatedAt=time.time());detail=action
     elif action=="delete":
      if j.get("state")=="running":j.update(enabled=False,cancelRequested=True,deleteAfterRun=True,updatedAt=time.time());detail="delete-requested"
      else:jobs.remove(j);detail="deleted"
     else:raise RuntimeError("unsupported-command")
    d["version"]=9;atomic(JOBS,d)
   record_ack(nonce,"applied",detail);consumed.add(nonce);log("remote_command_applied",action=action,nonce=nonce,detail=detail)
  except Exception as e:
   record_ack(nonce,"rejected",str(e));consumed.add(nonce);log("remote_command_rejected",action=action,nonce=nonce,error=str(e))
 remove_acked_from_queue(consumed)
def recover():
 with lock():
  d=document();now=time.time();changed=False
  for j in d["jobs"]:
   l=j.get("lease") or {}
   if j.get("state")=="running" and float(l.get("expiresAt",0))<now:
    j.update(state="scheduled",nextRunAt=now,lease=None,lastError="Recovered expired execution lease",updatedAt=now,recoveryCount=int(j.get("recoveryCount",0))+1,cancelRequested=False);changed=True;log("job_recovered",jobID=j.get("id"),checkpoint=j.get("checkpoint"))
  if changed:d["version"]=9;atomic(JOBS,d)
def claim():
 if killed():return None
 with lock():
  d=document();now=time.time()
  for j in d["jobs"]:
   if not j.get("enabled",False) or j.get("state") in ("paused","stopped","running"):continue
   if float(j.get("nextRunAt") or j.get("createdAt") or now)>now:continue
   try:validate_job(j)
   except Exception as e:j.update(state="failed",lastError=str(e),updatedAt=now);atomic(JOBS,d);continue
   token=str(uuid.uuid4());j.update(state="running",lease={"owner":f"worker:{PID}","generation":GEN,"token":token,"acquiredAt":now,"renewedAt":now,"expiresAt":now+LEASE_TTL},lastRunID=token,updatedAt=now,cancelRequested=False);d["version"]=9;atomic(JOBS,d);log("job_claimed",jobID=j.get("id"),kind=j.get("kind"),runID=token);return str(j.get("id")),token,json.loads(json.dumps(j))
 return None
def mutate_owned(jobid,token,fn):
 with lock():
  d=document();j=next((x for x in d["jobs"] if str(x.get("id"))==jobid),None)
  if not j:return False
  lease=j.get("lease") or {}
  if lease.get("token")!=token or lease.get("generation")!=GEN:return False
  fn(j);j["updatedAt"]=time.time();d["version"]=9;atomic(JOBS,d);return True
def pulse(jobid,token,checkpoint=None):
 def update(j):
  l=j.get("lease") or {};now=time.time();l.update(renewedAt=now,expiresAt=now+LEASE_TTL);j["lease"]=l
  if checkpoint is not None:j["checkpoint"]=checkpoint
 if not mutate_owned(jobid,token,update):raise RuntimeError("Execution lease lost")
 with lock():
  j=next((x for x in document()["jobs"] if str(x.get("id"))==jobid),None)
  if not j or j.get("cancelRequested") or not j.get("enabled",False):raise RuntimeError("Execution cancelled")
 if killed():raise RuntimeError("Emergency kill switch active")
def safe_path(raw):
 p=Path(str(raw or "")).expanduser().resolve();h=Path.home().resolve()
 if p!=h and h not in p.parents:raise RuntimeError("Path outside user home scope")
 return p
def health():
 load=os.getloadavg();v=os.statvfs(str(Path.home()));return {"host":platform.node(),"load1":round(load[0],2),"load5":round(load[1],2),"diskFreePercent":round(v.f_bavail/v.f_blocks*100,1) if v.f_blocks else 0,"pid":PID,"generation":GEN,"marketEngine":market is not None}
def inventory(raw,max_items=2000):
 p=safe_path(raw);n=d=b=0;ext={}
 if not p.exists():raise RuntimeError("Path does not exist")
 for root,ds,fs in os.walk(p):
  d+=len(ds)
  for name in fs:
   n+=1
   if n>max_items:break
   q=Path(root)/name
   try:b+=q.stat().st_size
   except Exception:pass
   ext[q.suffix.lower()]=ext.get(q.suffix.lower(),0)+1
  if n>max_items:break
 return {"root":str(p),"files":min(n,max_items),"directories":d,"bytes":b,"truncated":n>max_items,"extensions":dict(sorted(ext.items(),key=lambda x:-x[1])[:25])}
def repo(raw):
 p=safe_path(raw);g=p/".git";branch=head=None
 if not p.is_dir():raise RuntimeError("Repository path invalid")
 try:
  h=(g/"HEAD").read_text().strip();branch=h.split("/",2)[-1] if h.startswith("ref: ") else None;ref=g/h[5:] if h.startswith("ref: ") else None;head=ref.read_text().strip() if ref and ref.exists() else h
 except Exception:pass
 return {"path":str(p),"isGitRepository":g.exists(),"branch":branch,"head":head,"inventory":inventory(str(p),1200)}
def http_probe(url):
 u=str(url or "")
 if not u.startswith(("http://","https://")):raise RuntimeError("Only HTTP(S) allowed")
 st=time.time()
 try:
  with urllib.request.urlopen(urllib.request.Request(u,headers={"User-Agent":"TRAVIS-Worker/3"}),timeout=15) as r:r.read(4096);return {"url":u,"status":r.status,"latencyMs":int((time.time()-st)*1000),"ok":200<=r.status<400}
 except urllib.error.HTTPError as e:return {"url":u,"status":e.code,"latencyMs":int((time.time()-st)*1000),"ok":False}
def repository_audit(raw):
 p=safe_path(raw);findings=[];scanned=0
 if not p.is_dir():raise RuntimeError("Repository audit path invalid")
 secret_markers=("api_key=","apikey=","secret=","password=","private_key")
 for q in p.rglob("*"):
  if not q.is_file() or ".git" in q.parts or q.stat().st_size>600000:continue
  if q.suffix.lower() not in (".swift",".py",".md",".json",".plist",".sh"):continue
  scanned+=1
  try:text=q.read_text(errors="ignore")
  except Exception:continue
  rel=str(q.relative_to(p));lower=text.lower()
  if "fatalerror(" in lower:findings.append({"severity":"medium","file":rel,"finding":"fatalError present; verify production failure policy"})
  if "development-only safety net" in lower or "deleteDefaultStore" in text:findings.append({"severity":"high","file":rel,"finding":"development destructive persistence recovery path detected"})
  if q.suffix==".swift" and text.count("!")>40:findings.append({"severity":"low","file":rel,"finding":"high force-unwrap/exclamation density; inspect manually"})
  if "todo" in lower or "fixme" in lower:findings.append({"severity":"low","file":rel,"finding":"TODO/FIXME markers present"})
  if any(m in lower for m in secret_markers):findings.append({"severity":"high","file":rel,"finding":"possible credential literal marker; review without exposing value"})
  if len(text.splitlines())>1200:findings.append({"severity":"medium","file":rel,"finding":"very large source file; candidate for decomposition"})
 rank={"high":3,"medium":2,"low":1};findings.sort(key=lambda x:-rank[x["severity"]]);return {"path":str(p),"scannedFiles":scanned,"findings":findings[:100],"counts":{s:sum(1 for x in findings if x["severity"]==s) for s in rank},"note":"Read-only heuristic audit. Any code mutation must remain approval-gated."}
def capability(cap,args,ctx):
 if cap=="runtime.identity":return {"host":platform.node(),"workerPID":PID,"generation":GEN}
 if cap=="runtime.health":return health()
 if cap=="runtime.safety":return {"killSwitch":killed(),"arbitraryShell":False,"liveTrading":False,"withdrawals":False,"credentials":False}
 if cap=="filesystem.inventory":return inventory(args.get("path"))
 if cap=="repository.snapshot":return repo(args.get("path"))
 if cap=="repository.audit":return repository_audit(args.get("path"))
 if cap=="network.http_probe":return http_probe(args.get("url"))
 if cap=="market.analyze":
  if market is None:raise RuntimeError("Market engine unavailable")
  return market.analyze(args.get("asset","BTC"),args.get("interval","1h"))
 if cap=="market.scan":
  if market is None:raise RuntimeError("Market engine unavailable")
  assets=str(args.get("assets","BTC,ETH,SOL,XRP,BNB,ADA,DOGE,LINK")).split(",");return market.scan(assets,args.get("interval","1h"))
 if cap=="report.synthesize":
  evidence=[x for x in ctx if x.get("result")];return {"report":"TRAVIS Always-On mission completed with %d verified evidence steps. Review structured step results for full detail."%len(evidence)}
 raise RuntimeError("Unsupported mission capability: "+cap)
def execute_headless(jobid,token,j):
 p=j.get("payload") or {};goal=str(p.get("goal") or "TRAVIS mission")[:1000];plan=p.get("plan") or [{"order":1,"title":"Identity","capability":"runtime.identity"},{"order":2,"title":"Health","capability":"runtime.health"},{"order":3,"title":"Safety","capability":"runtime.safety"},{"order":4,"title":"Report","capability":"report.synthesize"}]
 completed=list((j.get("missionState") or {}).get("completedSteps") or []);done={int(x.get("order",0)) for x in completed};ctx=[{"goal":goal}]+completed
 for s in sorted(plan,key=lambda x:int(x.get("order",0))):
  order=int(s.get("order",0))
  if order in done:continue
  cap=str(s.get("capability") or "");cp={"order":order,"sourceStepID":s.get("sourceStepID"),"title":str(s.get("title") or order),"capability":cap,"status":"running","at":time.time()};pulse(jobid,token,cp);log("mission_step_started",jobID=jobid,runID=token,order=order,capability=cap)
  result=capability(cap,s.get("arguments") or {},ctx);rec={**cp,"status":"completed","result":result,"completedAt":time.time()};completed.append(rec);ctx.append(rec)
  def save(x):x["missionState"]={"completedSteps":completed,"totalSteps":len(plan)};x["checkpoint"]={**cp,"status":"completed","at":time.time()};(x.get("lease") or {}).update(expiresAt=time.time()+LEASE_TTL,renewedAt=time.time())
  if not mutate_owned(jobid,token,save):raise RuntimeError("Execution lease lost")
  log("mission_step_completed",jobID=jobid,runID=token,order=order,capability=cap)
 report=next((x.get("result",{}).get("report") for x in reversed(completed) if x.get("capability")=="report.synthesize"),None) or "Mission completed: "+goal
 return {"ok":True,"summary":"Headless mission completed","goal":goal,"completedSteps":len(completed),"totalSteps":len(plan),"steps":completed,"finalReport":report}
def execute(jobid,token,j):
 kind=j.get("kind");p=j.get("payload") or {};pulse(jobid,token)
 if kind=="heartbeatProbe":return {"ok":True,"summary":"Headless runtime probe completed"}
 if kind=="systemWatcher":return {"ok":True,"summary":"System watcher cycle completed","observation":health()}
 if kind=="repositorySnapshot":return {"ok":True,"summary":"Repository snapshot completed","repository":repo(p.get("path"))}
 if kind=="repositoryAudit":return {"ok":True,"summary":"Repository audit completed","audit":repository_audit(p.get("path"))}
 if kind=="fileInventory":return {"ok":True,"summary":"File inventory completed","inventory":inventory(p.get("path"))}
 if kind=="httpWatcher":
  o=http_probe(p.get("url"));return {"ok":True,"summary":"HTTP watcher cycle completed","observation":o,"alert":not o.get("ok")}
 if kind=="marketScan":
  if market is None:raise RuntimeError("Market engine unavailable")
  return {"ok":True,"summary":"Crypto market scan completed","market":market.scan(p.get("assets"),p.get("interval","1h"))}
 if kind=="tradingPaper":
  if market is None:raise RuntimeError("Market engine unavailable")
  result=market.paper_cycle(p);result["summary"]="Autonomous PAPER trading cycle completed";return result
 if kind=="watcher":return {"ok":True,"summary":"Local watcher cycle recorded"}
 if kind=="headlessMission":return execute_headless(jobid,token,j)
 raise RuntimeError("Unsupported kind")
def commit(jobid,token,result=None,error=None):
 def change(j):
  if j.get("deleteAfterRun"):j["_delete"]=True;return
  if error:
   failures=int(j.get("failures",0))+1;j.update(state="failed",failures=failures,lastError=error,nextRunAt=time.time()+min((2**failures)*5,300),lease=None)
  else:
   cadence=float(j.get("cadenceSeconds") or 0);j.update(lastResult=result,lastError=None,failures=0,lastCompletedAt=time.time(),missionState=None,checkpoint=None,lease=None,state="sleeping" if cadence>0 else "stopped",enabled=cadence>0,nextRunAt=time.time()+cadence if cadence>0 else None)
 ok=mutate_owned(jobid,token,change)
 if not ok:return
 with lock():
  d=document();before=len(d["jobs"]);d["jobs"]=[x for x in d["jobs"] if not x.get("_delete")]
  if len(d["jobs"])!=before:d["version"]=9;atomic(JOBS,d)
 log("job_failed" if error else "job_completed",jobID=jobid,runID=token,error=error,summary=(result or {}).get("summary"))
def public_jobs():
 with lock():jobs=document()["jobs"]
 out=[]
 for j in jobs[-75:]:
  r=j.get("lastResult") or {};m=j.get("missionState") or {};out.append({"id":j.get("id"),"title":j.get("title"),"kind":j.get("kind"),"state":j.get("state"),"nextRunAt":j.get("nextRunAt"),"failures":int(j.get("failures",0)),"recoveryCount":int(j.get("recoveryCount",0)),"lastError":j.get("lastError"),"enabled":bool(j.get("enabled",False)),"lastCompletedAt":j.get("lastCompletedAt"),"summary":r.get("summary"),"finalReport":r.get("finalReport"),"completedSteps":int(r.get("completedSteps",len(m.get("completedSteps") or []))),"totalSteps":int(r.get("totalSteps",len((j.get("payload") or {}).get("plan") or []))),"checkpoint":j.get("checkpoint"),"portfolio":r.get("portfolio"),"market":r.get("market"),"actions":r.get("actions"),"audit":r.get("audit")})
 return out
log("worker_started",workerVersion=9);recover()
while RUN:
 try:
  apply_commands();claim_data=claim()
  if claim_data:
   jid,tok,j=claim_data
   try:result=execute(jid,tok,j);commit(jid,tok,result=result)
   except Exception as e:commit(jid,tok,error=str(e))
  jobs=public_jobs();atomic(HB,{"version":9,"generation":GEN,"pid":PID,"startedAt":START,"lastBeatAt":time.time(),"killSwitch":killed(),"state":"safe-stop" if killed() else "ready","activeServiceJobs":sum(1 for j in jobs if j["enabled"] and j["state"] not in ("paused","stopped")),"failedServiceJobs":sum(1 for j in jobs if j["state"]=="failed"),"marketEngine":market is not None,"serviceJobs":jobs})
 except Exception as e:log("worker_loop_error",error=str(e))
 time.sleep(1)
log("worker_stopped");HB.unlink(missing_ok=True)
