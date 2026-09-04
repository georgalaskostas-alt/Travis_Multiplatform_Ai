#!/usr/bin/env python3
"""TRAVIS headless supervisor foundation. No exchange credentials or live trading."""
import json, os, signal, sys, time
from pathlib import Path

ROOT=Path.home()/"Library/Application Support/TRAVIS/AlwaysOn"
ROOT.mkdir(parents=True,exist_ok=True)
HEARTBEAT=ROOT/"worker-heartbeat.json"
CONTROL=ROOT/"worker-control.json"
RUN=True

def stop(*_):
    global RUN; RUN=False
signal.signal(signal.SIGTERM,stop); signal.signal(signal.SIGINT,stop)

def atomic_json(path,payload):
    tmp=path.with_suffix(path.suffix+".tmp")
    tmp.write_text(json.dumps(payload,sort_keys=True),encoding="utf-8")
    os.replace(tmp,path)

def control():
    try:return json.loads(CONTROL.read_text(encoding="utf-8"))
    except Exception:return {"killSwitch":False}

started=time.time()
while RUN:
    c=control()
    atomic_json(HEARTBEAT,{"version":1,"pid":os.getpid(),"startedAt":started,"lastBeatAt":time.time(),"killSwitch":bool(c.get("killSwitch",False)),"state":"safe-stop" if c.get("killSwitch") else "ready"})
    time.sleep(2)
try: HEARTBEAT.unlink()
except FileNotFoundError: pass
sys.exit(0)
