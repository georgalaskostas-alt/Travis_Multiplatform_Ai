#!/usr/bin/env python3
"""TRAVIS Binance SPOT TESTNET adapter.
Hard-coded testnet endpoint, no withdrawal API, no production host. Orders require an
asset-specific standing mandate exported by the Swift app plus Keychain credentials.
Every order is additionally constrained by deterministic exposure, loss, duplicate-order
and kill-switch guards. This module intentionally has no production/live endpoint.
"""
import hashlib,hmac,json,math,subprocess,time,urllib.parse,urllib.request,urllib.error,os
from pathlib import Path
ROOT=Path.home()/"Library/Application Support/TRAVIS/AlwaysOn";MANDATES=ROOT/"trading-mandates-v1.json";STATE=ROOT/"testnet-trading-state-v1.json";JOURNAL=ROOT/"testnet-trading-journal-v1.jsonl";CONTROL=ROOT/"worker-control.json"
BASE="https://testnet.binance.vision";SERVICE="com.konstantinos.Travis-Multiplatform-Ai"
MAX_ORDER_NOTIONAL=1000.0;MAX_PORTFOLIO_NOTIONAL=3000.0;MAX_OPEN_POSITIONS=3;MAX_DAILY_REALIZED_LOSS=250.0;MAX_ORDER_KEYS=5000

def _key(account):
    try:
        r=subprocess.run(["/usr/bin/security","find-generic-password","-s",SERVICE,"-a",account,"-w"],capture_output=True,text=True,timeout=5,check=False);v=r.stdout.strip();return v if r.returncode==0 and v else None
    except Exception:return None

def credentials():
    key=_key("binance-testnet-api-key");secret=_key("binance-testnet-api-secret")
    if not key or not secret:raise RuntimeError("Binance testnet credentials unavailable to headless worker")
    return key,secret

def mandates():
    try:d=json.loads(MANDATES.read_text());return set(str(x).upper() for x in d.get("testnetAssets",[])) if not d.get("liveTrading",False) else set()
    except Exception:return set()

def _kill_switch():
    try:return bool(json.loads(CONTROL.read_text()).get("killSwitch",False))
    except Exception:return False

def _public(path,params=None):
    u=BASE+path+("?"+urllib.parse.urlencode(params) if params else "")
    with urllib.request.urlopen(urllib.request.Request(u,headers={"User-Agent":"TRAVIS-Testnet/2"}),timeout=15) as r:return json.loads(r.read().decode())

def _signed(method,path,params=None):
    if _kill_switch():raise RuntimeError("TRAVIS emergency kill switch active")
    key,secret=credentials();p=dict(params or {});p["timestamp"]=int(time.time()*1000);p["recvWindow"]=5000;query=urllib.parse.urlencode(p);sig=hmac.new(secret.encode(),query.encode(),hashlib.sha256).hexdigest();url=BASE+path+"?"+query+"&signature="+sig;req=urllib.request.Request(url,headers={"X-MBX-APIKEY":key,"User-Agent":"TRAVIS-Testnet/2"},method=method)
    try:
        with urllib.request.urlopen(req,timeout=20) as r:return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        try:detail=e.read().decode()
        except Exception:detail=""
        raise RuntimeError(f"Binance testnet HTTP {e.code}: {detail[:500]}")

def account():return _signed("GET","/api/v3/account")
def price(asset):return float(_public("/api/v3/ticker/price",{"symbol":asset.upper()+"USDT"})["price"])
def symbol_info(asset):
    symbol=asset.upper()+"USDT";info=_public("/api/v3/exchangeInfo",{"symbol":symbol})["symbols"][0];filters={x["filterType"]:x for x in info.get("filters",[])};return info,filters

def normalize_qty(asset,qty):
    _,filters=symbol_info(asset);lot=filters.get("LOT_SIZE",{});step=float(lot.get("stepSize",1));minimum=float(lot.get("minQty",0));maximum=float(lot.get("maxQty",qty));q=max(minimum,min(float(qty),maximum));q=math.floor(q/step+1e-10)*step if step>0 else q;precision=max(0,min(12,len(str(step).rstrip("0").split(".")[1]) if "." in str(step) else 0));return f"{q:.{precision}f}".rstrip("0").rstrip(".")
def _journal(event,**kw):
    ROOT.mkdir(parents=True,exist_ok=True)
    with JOURNAL.open("a") as f:f.write(json.dumps({"at":time.time(),"event":event,**kw},sort_keys=True)+"\n")
def _state():
    try:s=json.loads(STATE.read_text())
    except Exception:s={"version":2,"positions":[],"orderKeys":[],"day":time.strftime("%Y-%m-%d"),"dailyRealizedPnL":0.0}
    s.setdefault("positions",[]);s.setdefault("orderKeys",[]);s.setdefault("day",time.strftime("%Y-%m-%d"));s.setdefault("dailyRealizedPnL",0.0)
    today=time.strftime("%Y-%m-%d")
    if s.get("day")!=today:s["day"]=today;s["dailyRealizedPnL"]=0.0
    return s

def _save(s):
    ROOT.mkdir(parents=True,exist_ok=True);s["version"]=2;s["orderKeys"]=list(s.get("orderKeys",[]))[-MAX_ORDER_KEYS:];t=STATE.with_suffix(".tmp");t.write_text(json.dumps(s,sort_keys=True));os.replace(t,STATE)
def _require_asset(asset):
    a=str(asset).upper().strip()
    if a not in mandates():raise RuntimeError(f"No standing testnet mandate for {a}")
    return a

def _open_positions(s):return [p for p in s.get("positions",[]) if p.get("open")]
def _gross_entry_exposure(s):return sum(max(0,float(p.get("qty",0)))*max(0,float(p.get("entry",0))) for p in _open_positions(s))
def _risk_gate_buy(s,asset,notional,client_key):
    reasons=[]
    if _kill_switch():reasons.append("emergency-kill-switch")
    if client_key in s.get("orderKeys",[]):reasons.append("duplicate-idempotency-key")
    if len(_open_positions(s))>=MAX_OPEN_POSITIONS:reasons.append("max-open-positions")
    if any(p.get("asset")==asset for p in _open_positions(s)):reasons.append("asset-position-already-open")
    if notional<10 or notional>MAX_ORDER_NOTIONAL:reasons.append("order-notional-limit")
    if _gross_entry_exposure(s)+notional>MAX_PORTFOLIO_NOTIONAL:reasons.append("portfolio-exposure-limit")
    if float(s.get("dailyRealizedPnL",0))<=-MAX_DAILY_REALIZED_LOSS:reasons.append("daily-loss-circuit-breaker")
    if reasons:
        _journal("testnet_order_blocked",side="BUY",asset=asset,notional=notional,reasons=reasons,clientKey=client_key)
        raise RuntimeError("Deterministic testnet risk gate blocked order: "+",".join(reasons))

def market_buy(asset,quote_usdt,client_key):
    a=_require_asset(asset);s=_state()
    if client_key in s.get("orderKeys",[]):return {"duplicate":True,"clientKey":client_key}
    notional=float(quote_usdt);_risk_gate_buy(s,a,notional,client_key);px=price(a);qty=normalize_qty(a,notional/px)
    normalized_qty=float(qty or 0);normalized_notional=normalized_qty*px
    if normalized_qty<=0 or normalized_notional<10:raise RuntimeError("Normalized testnet quantity/notional is below executable minimum")
    if normalized_notional>MAX_ORDER_NOTIONAL*1.01:raise RuntimeError("Exchange normalization exceeded deterministic order limit")
    cid=("travis"+hashlib.sha256(client_key.encode()).hexdigest()[:24])[:32]
    result=_signed("POST","/api/v3/order",{"symbol":a+"USDT","side":"BUY","type":"MARKET","quantity":qty,"newClientOrderId":cid,"newOrderRespType":"FULL"})
    executed=float(result.get("executedQty",0));quote=float(result.get("cummulativeQuoteQty",0));fill=quote/executed if executed>0 else px
    s.setdefault("positions",[]).append({"id":client_key,"asset":a,"qty":executed,"entry":fill,"open":True,"openedAt":time.time(),"orderId":result.get("orderId")});s.setdefault("orderKeys",[]).append(client_key);_save(s);_journal("testnet_buy",asset=a,qty=executed,price=fill,notional=quote,orderId=result.get("orderId"));return {"asset":a,"qty":executed,"price":fill,"orderId":result.get("orderId"),"status":result.get("status"),"riskGate":"passed"}

def market_sell(asset,qty,client_key):
    a=_require_asset(asset);s=_state()
    if client_key in s.get("orderKeys",[]):return {"duplicate":True,"clientKey":client_key}
    if _kill_switch():raise RuntimeError("TRAVIS emergency kill switch active")
    open_qty=sum(float(p.get("qty",0)) for p in _open_positions(s) if p.get("asset")==a)
    requested=float(qty)
    if requested<=0 or open_qty<=0:raise RuntimeError("No open mandated testnet quantity available to sell")
    if requested>open_qty*1.000001:raise RuntimeError("Sell quantity exceeds tracked open position")
    quantity=normalize_qty(a,min(requested,open_qty));cid=("travis"+hashlib.sha256(client_key.encode()).hexdigest()[:24])[:32]
    result=_signed("POST","/api/v3/order",{"symbol":a+"USDT","side":"SELL","type":"MARKET","quantity":quantity,"newClientOrderId":cid,"newOrderRespType":"FULL"});executed=float(result.get("executedQty",0));quote=float(result.get("cummulativeQuoteQty",0));fill=quote/executed if executed>0 else price(a);s.setdefault("orderKeys",[]).append(client_key)
    remaining=executed;realized=0.0
    for p in s.get("positions",[]):
        if p.get("open") and p.get("asset")==a and remaining>0:
            pqty=float(p.get("qty",0));used=min(pqty,remaining);remaining-=used;piece=(fill-float(p.get("entry",fill)))*used;realized+=piece
            if used>=pqty-1e-12:p.update(open=False,closedAt=time.time(),exit=fill,pnl=(fill-float(p.get("entry",fill)))*pqty)
            else:p["qty"]=pqty-used
    s["dailyRealizedPnL"]=float(s.get("dailyRealizedPnL",0))+realized;_save(s);_journal("testnet_sell",asset=a,qty=executed,price=fill,pnl=realized,orderId=result.get("orderId"));return {"asset":a,"qty":executed,"price":fill,"pnl":realized,"orderId":result.get("orderId"),"status":result.get("status"),"riskGate":"passed"}

def state_snapshot():
    s=_state();return {"positions":_open_positions(s),"closed":[p for p in s.get("positions",[]) if not p.get("open")][-50:],"mandatedAssets":sorted(mandates()),"grossEntryExposure":_gross_entry_exposure(s),"dailyRealizedPnL":float(s.get("dailyRealizedPnL",0)),"limits":{"maxOrderNotional":MAX_ORDER_NOTIONAL,"maxPortfolioNotional":MAX_PORTFOLIO_NOTIONAL,"maxOpenPositions":MAX_OPEN_POSITIONS,"maxDailyRealizedLoss":MAX_DAILY_REALIZED_LOSS},"killSwitch":_kill_switch(),"mode":"testnet-only"}
