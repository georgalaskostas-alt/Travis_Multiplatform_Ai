#!/usr/bin/env python3
"""TRAVIS Binance SPOT TESTNET adapter.
Hard-coded testnet endpoint, no withdrawal API, no production host. Orders require an
asset-specific standing mandate exported by the Swift app plus Keychain credentials.
"""
import hashlib,hmac,json,math,subprocess,time,urllib.parse,urllib.request,urllib.error
from pathlib import Path
ROOT=Path.home()/"Library/Application Support/TRAVIS/AlwaysOn";MANDATES=ROOT/"trading-mandates-v1.json";STATE=ROOT/"testnet-trading-state-v1.json";JOURNAL=ROOT/"testnet-trading-journal-v1.jsonl"
BASE="https://testnet.binance.vision";SERVICE="com.konstantinos.Travis-Multiplatform-Ai"

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

def _public(path,params=None):
    u=BASE+path+("?"+urllib.parse.urlencode(params) if params else "")
    with urllib.request.urlopen(urllib.request.Request(u,headers={"User-Agent":"TRAVIS-Testnet/1"}),timeout=15) as r:return json.loads(r.read().decode())

def _signed(method,path,params=None):
    key,secret=credentials();p=dict(params or {});p["timestamp"]=int(time.time()*1000);p["recvWindow"]=5000;query=urllib.parse.urlencode(p);sig=hmac.new(secret.encode(),query.encode(),hashlib.sha256).hexdigest();url=BASE+path+"?"+query+"&signature="+sig;req=urllib.request.Request(url,headers={"X-MBX-APIKEY":key,"User-Agent":"TRAVIS-Testnet/1"},method=method)
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
    try:return json.loads(STATE.read_text())
    except Exception:return {"version":1,"positions":[],"orderKeys":[]}
def _save(s):
    t=STATE.with_suffix(".tmp");t.write_text(json.dumps(s,sort_keys=True));t.replace(STATE)
def _require_asset(asset):
    a=asset.upper()
    if a not in mandates():raise RuntimeError(f"No standing testnet mandate for {a}")
    return a

def market_buy(asset,quote_usdt,client_key):
    a=_require_asset(asset);s=_state()
    if client_key in s.get("orderKeys",[]):return {"duplicate":True,"clientKey":client_key}
    notional=max(10,min(float(quote_usdt),2000));px=price(a);qty=normalize_qty(a,notional/px)
    cid=("travis"+hashlib.sha256(client_key.encode()).hexdigest()[:24])[:32]
    result=_signed("POST","/api/v3/order",{"symbol":a+"USDT","side":"BUY","type":"MARKET","quantity":qty,"newClientOrderId":cid,"newOrderRespType":"FULL"})
    executed=float(result.get("executedQty",0));quote=float(result.get("cummulativeQuoteQty",0));fill=quote/executed if executed>0 else px
    s.setdefault("positions",[]).append({"id":client_key,"asset":a,"qty":executed,"entry":fill,"open":True,"openedAt":time.time(),"orderId":result.get("orderId")});s.setdefault("orderKeys",[]).append(client_key);_save(s);_journal("testnet_buy",asset=a,qty=executed,price=fill,orderId=result.get("orderId"));return {"asset":a,"qty":executed,"price":fill,"orderId":result.get("orderId"),"status":result.get("status")}
def market_sell(asset,qty,client_key):
    a=_require_asset(asset);s=_state()
    if client_key in s.get("orderKeys",[]):return {"duplicate":True,"clientKey":client_key}
    quantity=normalize_qty(a,qty);cid=("travis"+hashlib.sha256(client_key.encode()).hexdigest()[:24])[:32]
    result=_signed("POST","/api/v3/order",{"symbol":a+"USDT","side":"SELL","type":"MARKET","quantity":quantity,"newClientOrderId":cid,"newOrderRespType":"FULL"});executed=float(result.get("executedQty",0));quote=float(result.get("cummulativeQuoteQty",0));fill=quote/executed if executed>0 else price(a);s.setdefault("orderKeys",[]).append(client_key)
    remaining=executed
    for p in s.get("positions",[]):
        if p.get("open") and p.get("asset")==a and remaining>0:
            used=min(float(p.get("qty",0)),remaining);remaining-=used
            if used>=float(p.get("qty",0))-1e-12:p.update(open=False,closedAt=time.time(),exit=fill,pnl=(fill-float(p["entry"]))*float(p["qty"]))
    _save(s);_journal("testnet_sell",asset=a,qty=executed,price=fill,orderId=result.get("orderId"));return {"asset":a,"qty":executed,"price":fill,"orderId":result.get("orderId"),"status":result.get("status")}
def state_snapshot():
    s=_state();return {"positions":[p for p in s.get("positions",[]) if p.get("open")],"closed":[p for p in s.get("positions",[]) if not p.get("open")][-50:],"mandatedAssets":sorted(mandates())}
