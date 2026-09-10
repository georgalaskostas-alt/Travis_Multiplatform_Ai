#!/usr/bin/env python3
"""Deterministic crypto market intelligence and paper-trading engine for TRAVIS.
Public market data only. No exchange credentials, no live-money endpoint, no withdrawals.
"""
import json, math, os, statistics, time, urllib.parse, urllib.request
from pathlib import Path

ROOT = Path.home()/"Library/Application Support/TRAVIS/AlwaysOn"
STATE = ROOT/"paper-trading-state-v1.json"
JOURNAL = ROOT/"paper-trading-journal-v1.jsonl"
BASE = "https://api.binance.com/api/v3"
DEFAULT_WATCHLIST = ["BTC","ETH","SOL","XRP","BNB","ADA","DOGE","LINK"]


def _get(path, params):
    url = BASE + path + "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"User-Agent":"TRAVIS-MarketEngine/1.0"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read().decode("utf-8"))


def candles(asset, interval="1h", limit=200):
    rows = _get("/klines", {"symbol":asset.upper()+"USDT","interval":interval,"limit":min(max(int(limit),30),500)})
    return [{"t":int(x[0]),"o":float(x[1]),"h":float(x[2]),"l":float(x[3]),"c":float(x[4]),"v":float(x[5])} for x in rows]


def _sma(v,n): return sum(v[-n:])/n if len(v)>=n else None

def _ema_series(v,n):
    if not v:return []
    k=2/(n+1);out=[v[0]]
    for x in v[1:]:out.append(x*k+out[-1]*(1-k))
    return out

def _ema(v,n): return _ema_series(v,n)[-1] if len(v)>=n else None

def _rsi(v,n=14):
    if len(v)<=n:return None
    d=[v[i]-v[i-1] for i in range(1,len(v))][-n:]
    g=sum(max(x,0) for x in d)/n;l=sum(max(-x,0) for x in d)/n
    return 100.0 if l==0 else 100-(100/(1+g/l))

def _macd(v):
    if len(v)<26:return (None,None,None)
    f=_ema_series(v,12);s=_ema_series(v,26);line=[a-b for a,b in zip(f,s)];sig=_ema_series(line,9)[-1]
    return line[-1],sig,line[-1]-sig

def _atr(rows,n=14):
    if len(rows)<=n:return None
    tr=[]
    for i in range(1,len(rows)):
        a=rows[i];p=rows[i-1]["c"];tr.append(max(a["h"]-a["l"],abs(a["h"]-p),abs(a["l"]-p)))
    return sum(tr[-n:])/n

def _boll(v,n=20):
    if len(v)<n:return (None,None,None)
    x=v[-n:];m=sum(x)/n;sd=statistics.pstdev(x);return m+2*sd,m,m-2*sd

def _pct(v,bars):
    if len(v)<=bars or v[-1-bars]==0:return None
    return (v[-1]/v[-1-bars]-1)*100

def _rv(v,bars=24):
    r=[math.log(v[i]/v[i-1]) for i in range(1,len(v)) if v[i]>0 and v[i-1]>0][-bars:]
    return statistics.stdev(r)*math.sqrt(len(r))*100 if len(r)>1 else None


def analyze(asset, interval="1h"):
    rows=candles(asset,interval,200);c=[x["c"] for x in rows];vol=[x["v"] for x in rows];price=c[-1]
    e9,e21,e50=_ema(c,9),_ema(c,21),_ema(c,50);rsi=_rsi(c);mac,ms,mh=_macd(c);atr=_atr(rows);bu,bm,bl=_boll(c)
    vr=vol[-1]/(_sma(vol,20) or vol[-1] or 1);p1,p4,p24=_pct(c,1),_pct(c,4),_pct(c,min(24,len(c)-1));score=0.0;e=[]
    if e9 and e21: score += 1 if e9>e21 else -1;e.append("EMA9>EMA21" if e9>e21 else "EMA9<EMA21")
    if e21 and e50: score += 1 if e21>e50 else -1;e.append("EMA21>EMA50" if e21>e50 else "EMA21<EMA50")
    if rsi is not None:
        if 55<=rsi<=72:score+=.8;e.append("RSI bullish")
        elif 28<=rsi<=45:score-=.8;e.append("RSI bearish")
        elif rsi>75:score-=.25;e.append("RSI overbought-risk")
        elif rsi<25:score+=.25;e.append("RSI oversold-risk")
    if mh is not None:score += .8 if mh>0 else -.8;e.append("MACD positive" if mh>0 else "MACD negative")
    if p4 is not None:
        if p4>.5:score+=.5;e.append("4h positive momentum")
        elif p4<-.5:score-=.5;e.append("4h negative momentum")
    if vr>=1.25:score += .35 if score>=0 else -.35;e.append("volume confirmation")
    score=max(-4,min(4,score));conf=min(.95,.50+abs(score)/8);atrp=(atr/price*100) if atr else None
    regime="high-volatility" if atrp and atrp>=4 else ("uptrend" if score>=2.2 else "downtrend" if score<=-2.2 else "range/mixed")
    signal="bullish" if score>=2.4 else "bearish" if score<=-2.4 else "mild-bullish" if score>=1 else "mild-bearish" if score<=-1 else "neutral"
    return {"asset":asset.upper(),"interval":interval,"price":price,"change1hPercent":p1,"change4hPercent":p4,"change24hPercent":p24,"sma20":_sma(c,20),"sma50":_sma(c,50),"ema9":e9,"ema21":e21,"ema50":e50,"rsi14":rsi,"macd":mac,"macdSignal":ms,"macdHistogram":mh,"atr14":atr,"atrPercent":atrp,"bollingerUpper":bu,"bollingerMiddle":bm,"bollingerLower":bl,"volumeRatio20":vr,"realizedVolatilityPercent":_rv(c),"trendScore":score,"confidence":conf,"regime":regime,"signal":signal,"evidence":e,"generatedAt":time.time()}


def scan(assets=None,interval="1h"):
    assets=(assets or DEFAULT_WATCHLIST)[:20];out=[];errors={}
    for a in assets:
        try:out.append(analyze(a,interval))
        except Exception as ex:errors[a]=str(ex)
    out.sort(key=lambda x:abs(x["trendScore"]),reverse=True)
    return {"generatedAt":time.time(),"interval":interval,"assets":out,"errors":errors,"disclaimer":"Probabilistic analysis; no strategy can guarantee profit."}


def load_state(starting_balance=10000.0):
    try:s=json.loads(STATE.read_text())
    except Exception:s={"version":1,"cash":starting_balance,"equityHigh":starting_balance,"positions":[],"trades":[],"realizedPnL":0.0,"day":time.strftime("%Y-%m-%d"),"dailyRealizedPnL":0.0}
    if s.get("day")!=time.strftime("%Y-%m-%d"):s["day"]=time.strftime("%Y-%m-%d");s["dailyRealizedPnL"]=0.0
    return s

def save_state(s):
    ROOT.mkdir(parents=True,exist_ok=True);tmp=STATE.with_suffix(".tmp");tmp.write_text(json.dumps(s,sort_keys=True));os.replace(tmp,STATE)
def journal(event,**fields):
    ROOT.mkdir(parents=True,exist_ok=True)
    with JOURNAL.open("a") as f:f.write(json.dumps({"at":time.time(),"event":event,**fields},sort_keys=True)+"\n")


def portfolio_snapshot(s, marks=None):
    marks=marks or {};open_value=0;unreal=0
    for p in s["positions"]:
        if not p.get("open"):continue
        px=marks.get(p["asset"],p["entry"]);open_value+=p["qty"]*px;unreal+=(px-p["entry"])*p["qty"]
    equity=s["cash"]+open_value;s["equityHigh"]=max(s.get("equityHigh",equity),equity);dd=(equity/s["equityHigh"]-1)*100 if s["equityHigh"] else 0
    closed=s.get("trades",[]);wins=[t for t in closed if t.get("pnl",0)>0];losses=[t for t in closed if t.get("pnl",0)<0];grossWin=sum(t["pnl"] for t in wins);grossLoss=abs(sum(t["pnl"] for t in losses))
    return {"cash":s["cash"],"equity":equity,"unrealizedPnL":unreal,"realizedPnL":s.get("realizedPnL",0),"dailyRealizedPnL":s.get("dailyRealizedPnL",0),"openPositions":sum(1 for p in s["positions"] if p.get("open")),"closedTrades":len(closed),"wins":len(wins),"losses":len(losses),"winRate":len(wins)/len(closed) if closed else 0,"profitFactor":grossWin/grossLoss if grossLoss>0 else None,"drawdownPercent":dd}


def paper_cycle(config):
    assets=config.get("assets") or DEFAULT_WATCHLIST;interval=config.get("interval","1h");risk=float(config.get("riskPercent",.005));risk=min(max(risk,.001),.02);max_positions=min(max(int(config.get("maxOpenPositions",3)),1),10);daily_loss=float(config.get("maxDailyLoss",500));max_notional=float(config.get("maxPositionNotional",2000));stop_atr=float(config.get("stopATRMultiple",1.8));take_atr=float(config.get("takeProfitATRMultiple",2.7));min_score=float(config.get("minTrendScore",2.4));s=load_state(float(config.get("startingBalance",10000)));report=scan(assets,interval);marks={x["asset"]:x["price"] for x in report["assets"]}
    actions=[]
    # exits are deterministic and evaluated before entries
    for p in [x for x in s["positions"] if x.get("open")]:
        px=marks.get(p["asset"])
        if px is None:continue
        reason=None
        if px<=p["stop"]:reason="stop-loss"
        elif px>=p["take"]:reason="take-profit"
        else:
            sig=next((x for x in report["assets"] if x["asset"]==p["asset"]),None)
            if sig and sig["trendScore"]<=-1.5:reason="signal-reversal"
        if reason:
            proceeds=p["qty"]*px;pnl=(px-p["entry"])*p["qty"];s["cash"]+=proceeds;s["realizedPnL"]+=pnl;s["dailyRealizedPnL"]+=pnl;p["open"]=False;p["exit"]=px;p["closedAt"]=time.time();p["pnl"]=pnl;p["exitReason"]=reason;s["trades"].append(dict(p));actions.append({"action":"close","asset":p["asset"],"price":px,"pnl":pnl,"reason":reason});journal("paper_close",asset=p["asset"],price=px,pnl=pnl,reason=reason)
    snap=portfolio_snapshot(s,marks)
    frozen=snap["dailyRealizedPnL"]<=-abs(daily_loss)
    open_assets={p["asset"] for p in s["positions"] if p.get("open")}
    if not frozen:
        for sig in report["assets"]:
            if sum(1 for p in s["positions"] if p.get("open"))>=max_positions:break
            if sig["asset"] in open_assets or sig["trendScore"]<min_score or sig["confidence"]<.65:continue
            atr=sig.get("atr14") or sig["price"]*.02;stop_distance=max(atr*stop_atr,sig["price"]*.008);risk_dollars=max(1,snap["equity"]*risk);qty=min(risk_dollars/stop_distance,max_notional/sig["price"],s["cash"]/sig["price"])
            if qty<=0:continue
            notional=qty*sig["price"]
            if notional<10:continue
            p={"id":str(time.time_ns()),"asset":sig["asset"],"qty":qty,"entry":sig["price"],"stop":sig["price"]-stop_distance,"take":sig["price"]+atr*take_atr,"openedAt":time.time(),"open":True,"entryScore":sig["trendScore"],"entryConfidence":sig["confidence"]};s["cash"]-=notional;s["positions"].append(p);open_assets.add(sig["asset"]);actions.append({"action":"open","asset":sig["asset"],"price":sig["price"],"qty":qty,"stop":p["stop"],"take":p["take"],"riskDollars":risk_dollars});journal("paper_open",**actions[-1])
    snap=portfolio_snapshot(s,marks);save_state(s)
    return {"ok":True,"summary":"Autonomous PAPER trading cycle completed","mode":"paper","market":report,"portfolio":snap,"actions":actions,"frozenByDailyLoss":frozen,"risk":{"riskPercent":risk,"maxOpenPositions":max_positions,"maxDailyLoss":daily_loss,"maxPositionNotional":max_notional},"note":"Paper simulation only. No real-money orders were sent."}


def backtest(asset, interval="1h", limit=500):
    rows=candles(asset,interval,min(limit,500));cl=[x["c"] for x in rows]
    # Simple walk-forward EMA/RSI trend benchmark with no lookahead; research metric only.
    equity=10000.0;peak=equity;trades=[];entry=None
    for i in range(55,len(rows)):
        window=rows[:i+1];c=[x["c"] for x in window];e9,e21,e50=_ema(c,9),_ema(c,21),_ema(c,50);r=_rsi(c);px=c[-1]
        long_signal=e9 and e21 and e50 and e9>e21>e50 and r and 52<r<72
        exit_signal=e9 and e21 and (e9<e21 or (r and r>78))
        if entry is None and long_signal:entry=px
        elif entry is not None and exit_signal:
            ret=px/entry-1;equity*=1+ret;trades.append(ret);entry=None;peak=max(peak,equity)
    wins=[x for x in trades if x>0];loss=[x for x in trades if x<0];pf=sum(wins)/abs(sum(loss)) if loss else None
    return {"asset":asset.upper(),"interval":interval,"bars":len(rows),"trades":len(trades),"winRate":len(wins)/len(trades) if trades else 0,"profitFactor":pf,"returnPercent":(equity/10000-1)*100,"endingEquity":equity,"note":"Historical benchmark only; fees/slippage omitted and past performance does not guarantee future results."}
