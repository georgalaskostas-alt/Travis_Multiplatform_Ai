#!/usr/bin/env python3
"""TRAVIS deterministic market intelligence + paper risk engine v2.
Public market data only. No credentials, production orders or withdrawals.
The LLM may explain evidence; it never bypasses this deterministic risk envelope.
"""
import json,math,os,statistics,time,urllib.parse,urllib.request
from pathlib import Path
ROOT=Path.home()/"Library/Application Support/TRAVIS/AlwaysOn";STATE=ROOT/"paper-trading-state-v2.json";JOURNAL=ROOT/"paper-trading-journal-v2.jsonl";CACHE=ROOT/"market-cache-v2.json";BASE="https://api.binance.com/api/v3";DEFAULT_WATCHLIST=["BTC","ETH","SOL","XRP","BNB","ADA","DOGE","LINK"]

def _atomic(path,obj):
 ROOT.mkdir(parents=True,exist_ok=True);t=path.with_suffix(path.suffix+".tmp");t.write_text(json.dumps(obj,sort_keys=True),encoding="utf-8");os.replace(t,path)
def _get(path,params):
 url=BASE+path+"?"+urllib.parse.urlencode(params);req=urllib.request.Request(url,headers={"User-Agent":"TRAVIS-MarketEngine/2.0"})
 with urllib.request.urlopen(req,timeout=15) as r:return json.loads(r.read().decode("utf-8"))
def candles(asset,interval="1h",limit=240,cache_seconds=20):
 key=f"{asset.upper()}:{interval}:{limit}";now=time.time()
 try:cache=json.loads(CACHE.read_text())
 except Exception:cache={}
 row=cache.get(key)
 if isinstance(row,dict) and now-float(row.get("at",0))<=cache_seconds:return row["rows"]
 raw=_get("/klines",{"symbol":asset.upper()+"USDT","interval":interval,"limit":min(max(int(limit),60),500)});rows=[{"t":int(x[0]),"o":float(x[1]),"h":float(x[2]),"l":float(x[3]),"c":float(x[4]),"v":float(x[5])} for x in raw];cache[key]={"at":now,"rows":rows};_atomic(CACHE,{k:v for k,v in cache.items() if now-float(v.get("at",0))<300});return rows
def _sma(v,n):return sum(v[-n:])/n if len(v)>=n else None
def _ema_series(v,n):
 if not v:return []
 k=2/(n+1);out=[v[0]]
 for x in v[1:]:out.append(x*k+out[-1]*(1-k))
 return out
def _ema(v,n):return _ema_series(v,n)[-1] if len(v)>=n else None
def _rsi(v,n=14):
 if len(v)<=n:return None
 d=[v[i]-v[i-1] for i in range(1,len(v))][-n:];g=sum(max(x,0) for x in d)/n;l=sum(max(-x,0) for x in d)/n;return 100.0 if l==0 else 100-(100/(1+g/l))
def _macd(v):
 if len(v)<35:return(None,None,None)
 f=_ema_series(v,12);s=_ema_series(v,26);offset=len(f)-len(s);line=[f[i+offset]-s[i] for i in range(len(s))];sig=_ema_series(line,9);return line[-1],sig[-1],line[-1]-sig[-1]
def _atr(rows,n=14):
 if len(rows)<=n:return None
 tr=[max(rows[i]["h"]-rows[i]["l"],abs(rows[i]["h"]-rows[i-1]["c"]),abs(rows[i]["l"]-rows[i-1]["c"])) for i in range(1,len(rows))];return sum(tr[-n:])/n
def _boll(v,n=20):
 if len(v)<n:return(None,None,None)
 x=v[-n:];m=sum(x)/n;sd=statistics.pstdev(x);return m+2*sd,m,m-2*sd
def _pct(v,bars):return None if len(v)<=bars or v[-1-bars]==0 else (v[-1]/v[-1-bars]-1)*100
def _rv(v,bars=24):
 r=[math.log(v[i]/v[i-1]) for i in range(1,len(v)) if v[i]>0 and v[i-1]>0][-bars:];return statistics.stdev(r)*math.sqrt(len(r))*100 if len(r)>1 else None
def _slope(v,n=20):
 if len(v)<n:return 0.0
 x=v[-n:];base=x[0] or 1;return (x[-1]/base-1)*100/n
def analyze(asset,interval="1h"):
 rows=candles(asset,interval,240);c=[x["c"] for x in rows];vol=[x["v"] for x in rows];price=c[-1];e9,e21,e50,e100=_ema(c,9),_ema(c,21),_ema(c,50),_ema(c,100);rsi=_rsi(c);mac,ms,mh=_macd(c);atr=_atr(rows);bu,bm,bl=_boll(c);vr=vol[-1]/(_sma(vol,20) or vol[-1] or 1);p1,p4,p24=_pct(c,1),_pct(c,4),_pct(c,min(24,len(c)-1));score=0.0;e=[]
 if e9 and e21:score += 1.0 if e9>e21 else -1.0;e.append("EMA9>EMA21" if e9>e21 else "EMA9<EMA21")
 if e21 and e50:score += .9 if e21>e50 else -.9;e.append("EMA21>EMA50" if e21>e50 else "EMA21<EMA50")
 if e50 and e100:score += .55 if e50>e100 else -.55;e.append("EMA50>EMA100" if e50>e100 else "EMA50<EMA100")
 if rsi is not None:
  if 54<=rsi<=70:score+=.75;e.append("RSI constructive")
  elif 30<=rsi<=44:score-=.75;e.append("RSI weak")
  elif rsi>78:score-=.35;e.append("RSI overbought risk")
  elif rsi<22:score+=.20;e.append("RSI capitulation risk")
 if mh is not None:score += .75 if mh>0 else -.75;e.append("MACD positive" if mh>0 else "MACD negative")
 slope=_slope(c,20);score += max(-.5,min(.5,slope*2))
 if p4 is not None and abs(p4)>.5:score += .4 if p4>0 else -.4;e.append("4h momentum confirmation")
 if vr>=1.25:score += .35 if score>=0 else -.35;e.append("volume confirmation")
 score=max(-5,min(5,score));atrp=(atr/price*100) if atr else None;volatility=_rv(c);regime="high-volatility" if atrp and atrp>=4 else("uptrend" if score>=2.4 else"downtrend" if score<=-2.4 else"range/mixed");confidence=min(.96,.46+abs(score)/8+(0.04 if vr>=1.25 else 0));signal="bullish" if score>=2.7 else"bearish" if score<=-2.7 else"mild-bullish" if score>=1.2 else"mild-bearish" if score<=-1.2 else"neutral"
 return {"asset":asset.upper(),"interval":interval,"price":price,"change1hPercent":p1,"change4hPercent":p4,"change24hPercent":p24,"sma20":_sma(c,20),"sma50":_sma(c,50),"ema9":e9,"ema21":e21,"ema50":e50,"ema100":e100,"rsi14":rsi,"macd":mac,"macdSignal":ms,"macdHistogram":mh,"atr14":atr,"atrPercent":atrp,"bollingerUpper":bu,"bollingerMiddle":bm,"bollingerLower":bl,"volumeRatio20":vr,"realizedVolatilityPercent":volatility,"trendSlope20":slope,"trendScore":score,"confidence":confidence,"regime":regime,"signal":signal,"evidence":e,"generatedAt":time.time()}
def scan(assets=None,interval="1h"):
 assets=list(dict.fromkeys((assets or DEFAULT_WATCHLIST)))[:20];out=[];errors={}
 for a in assets:
  try:out.append(analyze(str(a).upper(),interval))
  except Exception as ex:errors[str(a).upper()]=str(ex)
 out.sort(key=lambda x:(abs(x["trendScore"]),x["confidence"]),reverse=True);return {"generatedAt":time.time(),"interval":interval,"assets":out,"errors":errors,"coverage":len(out)/len(assets) if assets else 0,"disclaimer":"Probabilistic market analysis; no strategy guarantees profit."}
def load_state(starting_balance=10000.0):
 try:s=json.loads(STATE.read_text())
 except Exception:s={"version":2,"cash":starting_balance,"equityHigh":starting_balance,"positions":[],"trades":[],"realizedPnL":0.0,"day":time.strftime("%Y-%m-%d"),"dailyRealizedPnL":0.0,"lastEntryByAsset":{}}
 s.setdefault("positions",[]);s.setdefault("trades",[]);s.setdefault("lastEntryByAsset",{});s.setdefault("equityHigh",starting_balance);s.setdefault("cash",starting_balance);s.setdefault("realizedPnL",0.0)
 if s.get("day")!=time.strftime("%Y-%m-%d"):s["day"]=time.strftime("%Y-%m-%d");s["dailyRealizedPnL"]=0.0
 return s
def save_state(s):_atomic(STATE,s)
def journal(event,**fields):
 ROOT.mkdir(parents=True,exist_ok=True)
 with JOURNAL.open("a",encoding="utf-8") as f:f.write(json.dumps({"at":time.time(),"event":event,**fields},sort_keys=True)+"\n")
def portfolio_snapshot(s,marks=None):
 marks=marks or {};open_value=unreal=0.0
 for p in s["positions"]:
  if not p.get("open"):continue
  px=marks.get(p["asset"],p["entry"]);open_value+=p["qty"]*px;unreal+=(px-p["entry"])*p["qty"]
 equity=s["cash"]+open_value;s["equityHigh"]=max(float(s.get("equityHigh",equity)),equity);dd=(equity/s["equityHigh"]-1)*100 if s["equityHigh"] else 0;closed=s.get("trades",[]);wins=[t for t in closed if t.get("pnl",0)>0];losses=[t for t in closed if t.get("pnl",0)<0];gw=sum(t.get("pnl",0) for t in wins);gl=abs(sum(t.get("pnl",0) for t in losses));return {"cash":s["cash"],"equity":equity,"grossExposure":open_value,"exposurePercent":open_value/equity*100 if equity>0 else 0,"unrealizedPnL":unreal,"realizedPnL":s.get("realizedPnL",0),"dailyRealizedPnL":s.get("dailyRealizedPnL",0),"openPositions":sum(1 for p in s["positions"] if p.get("open")),"closedTrades":len(closed),"wins":len(wins),"losses":len(losses),"winRate":len(wins)/len(closed) if closed else 0,"profitFactor":gw/gl if gl>0 else None,"drawdownPercent":dd}
def paper_cycle(config):
 assets=config.get("assets") or DEFAULT_WATCHLIST;interval=config.get("interval","1h");risk=min(max(float(config.get("riskPercent",.005)),.001),.02);max_positions=min(max(int(config.get("maxOpenPositions",3)),1),10);daily_loss=abs(float(config.get("maxDailyLoss",500)));max_notional=max(10,float(config.get("maxPositionNotional",2000)));max_exposure=min(max(float(config.get("maxPortfolioExposurePercent",60)),5),95);max_dd=abs(float(config.get("maxDrawdownPercent",15)));stop_atr=min(max(float(config.get("stopATRMultiple",1.8)),.5),5);take_atr=min(max(float(config.get("takeProfitATRMultiple",2.7)),.5),10);min_score=min(max(float(config.get("minTrendScore",2.7)),1.5),4.5);min_conf=min(max(float(config.get("minConfidence",.68)),.5),.95);fee=min(max(float(config.get("feeRate",.001)),0),.01);slip=max(0,float(config.get("slippageBps",3)))/10000;cooldown=max(0,int(config.get("cooldownSeconds",1800)));s=load_state(float(config.get("startingBalance",10000)));report=scan(assets,interval);marks={x["asset"]:x["price"] for x in report["assets"]};actions=[]
 # exits and protective trailing-stop maintenance run before any new exposure
 for p in [x for x in s["positions"] if x.get("open")]:
  px=marks.get(p["asset"])
  if px is None:continue
  sig=next((x for x in report["assets"] if x["asset"]==p["asset"]),None);atr=(sig or {}).get("atr14") or px*.02
  if px>p["entry"]+atr:p["stop"]=max(p["stop"],px-atr*stop_atr)
  reason="stop-loss" if px<=p["stop"] else"take-profit" if px>=p["take"] else"signal-reversal" if sig and sig["trendScore"]<=-1.5 else None
  if reason:
   exit_px=px*(1-slip);gross=exit_px*p["qty"];fees=gross*fee;pnl=(exit_px-p["entry"])*p["qty"]-fees-float(p.get("entryFee",0));s["cash"]+=gross-fees;s["realizedPnL"]+=pnl;s["dailyRealizedPnL"]+=pnl;p.update(open=False,exit=exit_px,closedAt=time.time(),pnl=pnl,exitReason=reason,exitFee=fees);s["trades"].append(dict(p));actions.append({"action":"close","asset":p["asset"],"price":exit_px,"pnl":pnl,"reason":reason});journal("paper_close",**actions[-1])
 snap=portfolio_snapshot(s,marks);coverage=float(report.get("coverage",0));frozen_reasons=[]
 if snap["dailyRealizedPnL"]<=-daily_loss:frozen_reasons.append("daily-loss-limit")
 if snap["drawdownPercent"]<=-max_dd:frozen_reasons.append("max-drawdown-limit")
 if coverage<.60:frozen_reasons.append("market-data-coverage")
 if not frozen_reasons:
  open_assets={p["asset"] for p in s["positions"] if p.get("open")}
  for sig in report["assets"]:
   snap=portfolio_snapshot(s,marks)
   if snap["openPositions"]>=max_positions or snap["exposurePercent"]>=max_exposure:break
   a=sig["asset"]
   if a in open_assets or sig["trendScore"]<min_score or sig["confidence"]<min_conf or sig["regime"]=="high-volatility" and sig["confidence"]<.80:continue
   if time.time()-float(s["lastEntryByAsset"].get(a,0))<cooldown:continue
   atr=sig.get("atr14") or sig["price"]*.02;stop_distance=max(atr*stop_atr,sig["price"]*.008);risk_dollars=max(1,snap["equity"]*risk);remaining_exposure=max(0,snap["equity"]*max_exposure/100-snap["grossExposure"]);qty=min(risk_dollars/stop_distance,max_notional/sig["price"],remaining_exposure/sig["price"],s["cash"]/(sig["price"]*(1+fee+slip)))
   if qty<=0:continue
   entry=sig["price"]*(1+slip);notional=qty*entry;entry_fee=notional*fee
   if notional<10:continue
   p={"id":str(time.time_ns()),"asset":a,"qty":qty,"entry":entry,"entryFee":entry_fee,"stop":entry-stop_distance,"take":entry+atr*take_atr,"openedAt":time.time(),"open":True,"entryScore":sig["trendScore"],"entryConfidence":sig["confidence"]};s["cash"]-=notional+entry_fee;s["positions"].append(p);s["lastEntryByAsset"][a]=time.time();open_assets.add(a);actions.append({"action":"open","asset":a,"price":entry,"qty":qty,"stop":p["stop"],"take":p["take"],"riskDollars":risk_dollars,"fee":entry_fee});journal("paper_open",**actions[-1])
 snap=portfolio_snapshot(s,marks);save_state(s);return {"ok":True,"summary":"TRAVIS deterministic PAPER risk cycle completed","mode":"paper","market":report,"portfolio":snap,"actions":actions,"frozenByRisk":bool(frozen_reasons),"freezeReasons":frozen_reasons,"risk":{"riskPercent":risk,"maxOpenPositions":max_positions,"maxDailyLoss":daily_loss,"maxDrawdownPercent":max_dd,"maxPortfolioExposurePercent":max_exposure,"maxPositionNotional":max_notional,"feeRate":fee,"slippageBps":slip*10000,"cooldownSeconds":cooldown},"note":"Paper simulation only. No real-money orders were sent."}
def backtest(asset,interval="1h",limit=500,fee_rate=.001,slippage_bps=3):
 rows=candles(asset,interval,min(limit,500),0);equity=10000.0;peak=equity;maxdd=0;trades=[];entry=None;slip=slippage_bps/10000
 for i in range(110,len(rows)):
  c=[x["c"] for x in rows[:i+1]];e9,e21,e50=_ema(c,9),_ema(c,21),_ema(c,50);r=_rsi(c);px=c[-1];long_signal=e9 and e21 and e50 and e9>e21>e50 and r and 52<r<72;exit_signal=e9 and e21 and (e9<e21 or (r and r>78))
  if entry is None and long_signal:entry=px*(1+slip)
  elif entry is not None and exit_signal:
   exit_px=px*(1-slip);ret=(exit_px/entry-1)-2*fee_rate;equity*=1+ret;trades.append(ret);entry=None;peak=max(peak,equity);maxdd=min(maxdd,(equity/peak-1)*100)
 wins=[x for x in trades if x>0];loss=[x for x in trades if x<0];pf=sum(wins)/abs(sum(loss)) if loss else None;return {"asset":asset.upper(),"interval":interval,"bars":len(rows),"trades":len(trades),"winRate":len(wins)/len(trades) if trades else 0,"profitFactor":pf,"returnPercent":(equity/10000-1)*100,"maxDrawdownPercent":maxdd,"endingEquity":equity,"feeRate":fee_rate,"slippageBps":slippage_bps,"note":"Historical benchmark with fees/slippage; past performance does not guarantee future results."}
