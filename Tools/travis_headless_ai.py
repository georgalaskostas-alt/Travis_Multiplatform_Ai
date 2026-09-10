#!/usr/bin/env python3
"""Secure provider client for TRAVIS headless reasoning.
Reads existing macOS Keychain entries using fixed service/account names. The caller
provides text only; this module never executes model-produced commands or code.
"""
import json, subprocess, urllib.request, urllib.error
SERVICE="com.konstantinos.Travis-Multiplatform-Ai"

def _key(account):
    try:
        r=subprocess.run(["/usr/bin/security","find-generic-password","-s",SERVICE,"-a",account,"-w"],capture_output=True,text=True,timeout=5,check=False)
        v=r.stdout.strip();return v if r.returncode==0 and v else None
    except Exception:return None

def _request(url,headers,body):
    req=urllib.request.Request(url,data=json.dumps(body).encode(),headers={"Content-Type":"application/json",**headers},method="POST")
    with urllib.request.urlopen(req,timeout=120) as r:return json.loads(r.read().decode())

def anthropic(prompt,max_tokens=1800,model="claude-sonnet-4-6"):
    key=_key("anthropic-api-key")
    if not key:raise RuntimeError("Anthropic key unavailable to headless worker")
    obj=_request("https://api.anthropic.com/v1/messages",{"x-api-key":key,"anthropic-version":"2023-06-01"},{"model":model,"max_tokens":max(64,min(int(max_tokens),4000)),"messages":[{"role":"user","content":prompt}]})
    text="\n".join(x.get("text","") for x in obj.get("content",[]) if x.get("type")=="text").strip()
    if not text:raise RuntimeError("Anthropic returned no text")
    return {"provider":"Anthropic","model":model,"text":text,"usage":obj.get("usage",{})}

def openai(prompt,max_tokens=1800,model="gpt-5.6"):
    key=_key("openai-api-key")
    if not key:raise RuntimeError("OpenAI key unavailable to headless worker")
    obj=_request("https://api.openai.com/v1/responses",{"Authorization":"Bearer "+key},{"model":model,"input":prompt,"max_output_tokens":max(64,min(int(max_tokens),4000))})
    parts=[]
    for item in obj.get("output",[]):
        for c in item.get("content",[]):
            if c.get("type") in ("output_text","text") and c.get("text"):parts.append(c["text"])
    text="\n".join(parts).strip()
    if not text:raise RuntimeError("OpenAI returned no text")
    return {"provider":"OpenAI","model":model,"text":text,"usage":obj.get("usage",{})}

def generate(prompt,max_tokens=1800):
    errors=[]
    for provider in (anthropic,openai):
        try:return provider(prompt,max_tokens=max_tokens)
        except Exception as e:errors.append(str(e))
    raise RuntimeError("No headless AI provider succeeded: "+" | ".join(errors))

def analyze_market(market_report,portfolio=None):
    prompt="""You are the risk-aware TRAVIS crypto research analyst. Analyze the structured market data below. Explain regime, strongest and weakest setups, conflicting evidence, portfolio exposure and what to monitor next. Do not promise profit. Do not issue or execute live-money orders. Return a concise decision-quality report with explicit uncertainty.\n\nMARKET DATA:\n"""+json.dumps(market_report)[:50000]
    if portfolio is not None:prompt+="\n\nPORTFOLIO:\n"+json.dumps(portfolio)[:15000]
    return generate(prompt,2200)

def recommend_code_improvements(audit):
    prompt="""You are TRAVIS reviewing its own codebase. Based ONLY on this read-only audit evidence, propose prioritized improvements. Never claim you applied changes. For each recommendation give evidence, expected benefit, risk, files to inspect, and verification tests. Any code/GUI mutation requires explicit user approval before execution.\n\nAUDIT:\n"""+json.dumps(audit)[:50000]
    return generate(prompt,2400)
