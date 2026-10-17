#!/usr/bin/env python3
"""TRAVIS headless intelligence gateway v2.
Cost policy: exact verified cache -> OpenAI Luna/Terra/Sol by workload -> Anthropic fallback.
Provider output is text/evidence only; this module never executes model-produced code/commands.
"""
import hashlib,json,os,subprocess,time,urllib.request,urllib.error
from pathlib import Path
SERVICE="com.konstantinos.Travis-Multiplatform-Ai";ROOT=Path.home()/"Library/Application Support/TRAVIS/AlwaysOn";CACHE=ROOT/"headless-ai-cache-v2.json";USAGE=ROOT/"headless-ai-usage-v2.jsonl";POLICY=ROOT/"headless-ai-policy-v2.json"
PRICING={"gpt-5.6-luna":(.20,.02,1.20),"gpt-5.6-terra":(2.0,.20,12.0),"gpt-5.6-sol":(4.0,.40,20.0)}

def _key(account):
 try:
  r=subprocess.run(["/usr/bin/security","find-generic-password","-s",SERVICE,"-a",account,"-w"],capture_output=True,text=True,timeout=5,check=False);v=r.stdout.strip();return v if r.returncode==0 and v else None
 except Exception:return None
def _request(url,headers,body):
 req=urllib.request.Request(url,data=json.dumps(body).encode(),headers={"Content-Type":"application/json",**headers},method="POST")
 with urllib.request.urlopen(req,timeout=150) as r:return json.loads(r.read().decode())
def _read(path,default):
 try:return json.loads(path.read_text())
 except Exception:return default
def _atomic(path,obj):ROOT.mkdir(parents=True,exist_ok=True);t=path.with_suffix(path.suffix+".tmp");t.write_text(json.dumps(obj,sort_keys=True));os.replace(t,path)
def _policy():
 p=_read(POLICY,{"cacheTTLSeconds":21600,"maxCacheEntries":250,"preferOpenAI":True});return p if isinstance(p,dict) else {}
def _fingerprint(prompt,model,max_tokens):return hashlib.sha256((model+"\0"+str(max_tokens)+"\0"+prompt).encode()).hexdigest()
def _cache_get(key):
 c=_read(CACHE,{"entries":{}});e=(c.get("entries") or {}).get(key);ttl=float(_policy().get("cacheTTLSeconds",21600));return e.get("result") if isinstance(e,dict) and time.time()-float(e.get("at",0))<=ttl else None
def _cache_put(key,result):
 c=_read(CACHE,{"version":2,"entries":{}});rows=c.setdefault("entries",{});rows[key]={"at":time.time(),"result":result};limit=max(20,min(int(_policy().get("maxCacheEntries",250)),1000));ordered=sorted(rows.items(),key=lambda kv:kv[1].get("at",0),reverse=True)[:limit];c["entries"]=dict(ordered);_atomic(CACHE,c)
def _usage(provider,model,usage,cached=False,workload="routine"):
 ROOT.mkdir(parents=True,exist_ok=True);inp=int(usage.get("input_tokens",usage.get("inputTokens",0)) or 0);out=int(usage.get("output_tokens",usage.get("outputTokens",0)) or 0);details=usage.get("input_tokens_details") or {};cin=int(details.get("cached_tokens",usage.get("cache_read_input_tokens",0)) or 0);cost=None
 if provider=="OpenAI" and model in PRICING:
  ir,cr,orate=PRICING[model];cost=(max(0,inp-cin)*ir+cin*cr+out*orate)/1_000_000
 row={"at":time.time(),"provider":provider,"model":model,"workload":workload,"inputTokens":inp,"cachedInputTokens":cin,"outputTokens":out,"estimatedCostUSD":cost,"localResponseCache":cached}
 with USAGE.open("a",encoding="utf-8") as f:f.write(json.dumps(row,sort_keys=True)+"\n")
def _workload(prompt,explicit=None):
 if explicit in ("routine","complex","frontier"):return explicit
 p=prompt.lower();front=["critical architecture","security architecture","self-evolution architecture","autonomous system design","production incident"];complexm=["codebase","audit","recommend","market","portfolio","architecture","reasoning","verification","source code"]
 if any(x in p for x in front):return"frontier"
 if any(x in p for x in complexm):return"complex"
 return"routine"
def _model(workload):return "gpt-5.6-sol" if workload=="frontier" else "gpt-5.6-terra" if workload=="complex" else "gpt-5.6-luna"
def anthropic(prompt,max_tokens=1800,model="claude-sonnet-4-6",workload="complex"):
 key=_key("anthropic-api-key")
 if not key:raise RuntimeError("Anthropic key unavailable to headless worker")
 obj=_request("https://api.anthropic.com/v1/messages",{"x-api-key":key,"anthropic-version":"2023-06-01"},{"model":model,"max_tokens":max(64,min(int(max_tokens),6000)),"messages":[{"role":"user","content":prompt}]});text="\n".join(x.get("text","") for x in obj.get("content",[]) if x.get("type")=="text").strip()
 if not text:raise RuntimeError("Anthropic returned no text")
 _usage("Anthropic",model,obj.get("usage",{}),False,workload);return {"provider":"Anthropic","model":model,"text":text,"usage":obj.get("usage",{}),"cached":False}
def openai(prompt,max_tokens=1800,model=None,workload="routine"):
 key=_key("openai-api-key")
 if not key:raise RuntimeError("OpenAI key unavailable to headless worker")
 model=model or _model(workload);cache_key=_fingerprint(prompt,model,max_tokens);cached=_cache_get(cache_key)
 if cached is not None:_usage("local-cache",model,{},True,workload);return {**cached,"cached":True,"cacheSource":"TRAVIS exact verified response cache"}
 body={"model":model,"input":prompt,"max_output_tokens":max(64,min(int(max_tokens),8000)),"prompt_cache_key":"travis-headless-"+workload,"prompt_cache_options":{"ttl":"30m"},"reasoning":{"effort":"high" if workload=="frontier" else "medium" if workload=="complex" else "low"}}
 obj=_request("https://api.openai.com/v1/responses",{"Authorization":"Bearer "+key},body);parts=[]
 for item in obj.get("output",[]):
  for c in item.get("content",[]):
   if c.get("type") in ("output_text","text") and c.get("text"):parts.append(c["text"])
 text="\n".join(parts).strip()
 if not text:raise RuntimeError("OpenAI returned no text")
 result={"provider":"OpenAI","model":model,"text":text,"usage":obj.get("usage",{}),"cached":False};_usage("OpenAI",model,obj.get("usage",{}),False,workload);_cache_put(cache_key,result);return result
def generate(prompt,max_tokens=1800,workload=None):
 workload=_workload(prompt,workload);errors=[];prefer=bool(_policy().get("preferOpenAI",True));providers=[lambda:openai(prompt,max_tokens,workload=workload),lambda:anthropic(prompt,max_tokens,workload=workload)] if prefer else [lambda:anthropic(prompt,max_tokens,workload=workload),lambda:openai(prompt,max_tokens,workload=workload)]
 for provider in providers:
  try:return provider()
  except Exception as e:errors.append(str(e))
 raise RuntimeError("No headless AI provider succeeded: "+" | ".join(errors))
def analyze_market(market_report,portfolio=None):
 prompt="""You are the risk-aware TRAVIS crypto research analyst. Analyze only the structured evidence below. Explain regime, strongest/weakest setups, conflicting evidence, portfolio exposure and what to monitor. Never promise profit or issue/execute live-money orders. Explicitly state uncertainty.\n\nMARKET DATA:\n"""+json.dumps(market_report,sort_keys=True)[:50000]
 if portfolio is not None:prompt+="\n\nPORTFOLIO:\n"+json.dumps(portfolio,sort_keys=True)[:15000]
 return generate(prompt,2200,"complex")
def recommend_code_improvements(audit):
 prompt="""You are TRAVIS reviewing its own codebase. Based ONLY on this deterministic read-only audit evidence, propose prioritized improvements. Never claim changes were applied. For each recommendation give evidence, expected benefit, risk, exact files to inspect and verification tests. Code/GUI mutation requires explicit user approval.\n\nAUDIT:\n"""+json.dumps(audit,sort_keys=True)[:50000]
 return generate(prompt,2400,"complex")
def usage_summary():
 rows=[]
 try:rows=[json.loads(x) for x in USAGE.read_text().splitlines() if x.strip()]
 except Exception:pass
 return {"requests":len(rows),"cachedResponses":sum(1 for x in rows if x.get("localResponseCache")),"estimatedCostUSD":sum(float(x.get("estimatedCostUSD") or 0) for x in rows),"inputTokens":sum(int(x.get("inputTokens",0)) for x in rows),"cachedInputTokens":sum(int(x.get("cachedInputTokens",0)) for x in rows),"outputTokens":sum(int(x.get("outputTokens",0)) for x in rows)}
