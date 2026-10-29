#!/usr/bin/env python3
"""Public API verification with synthetic audio and a short-lived isolated test identity."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import secrets
import shlex
import subprocess
import time
import urllib.error
import urllib.request
import uuid
import wave


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--samples',required=True,type=Path);parser.add_argument('--via-vps',action='store_true');args=parser.parse_args()
    psql=['/opt/homebrew/opt/postgresql@17/bin/psql','-p','15432','-U','alex','-d','pointverse','-v','ON_ERROR_STOP=1']
    def sql(value):subprocess.run(psql,input=value,text=True,stdout=subprocess.DEVNULL,check=True)
    owner=str(uuid.uuid4());token=secrets.token_urlsafe(32);digest=hashlib.sha256(token.encode()).hexdigest();reports=[]
    def request(path,payload=None):
        if args.via_vps:
            remote="""import sys,json,urllib.request
item=json.load(sys.stdin)
body=json.dumps(item['payload']).encode() if item['payload'] is not None else None
request=urllib.request.Request('https://dianjie.org'+item['path'],data=body,headers={'Authorization':'Bearer '+item['token'],'Content-Type':'application/json','User-Agent':'PointVerse-Migration-Test/1.0'})
with urllib.request.urlopen(request,timeout=150) as response:sys.stdout.buffer.write(response.read(8<<20))
"""
            result=subprocess.check_output(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=15','alex@172.245.205.27','python3 -c '+shlex.quote(remote)],input=json.dumps({'path':path,'payload':payload,'token':token}).encode(),timeout=180)
            return json.loads(result)
        body=json.dumps(payload).encode() if payload is not None else None
        req=urllib.request.Request('https://dianjie.org'+path,data=body,headers={'Authorization':'Bearer '+token,'Content-Type':'application/json','User-Agent':'PointVerse-Migration-Test/1.0'})
        with urllib.request.urlopen(req,timeout=150) as response:return json.load(response)
    try:
        sql(f"BEGIN; INSERT INTO users(id,display_name) VALUES('{owner}','Qwen ASR deployment verification'); INSERT INTO auth_sessions(token_hash,user_id,expires_at) VALUES(decode('{digest}','hex'),'{owner}',now()+interval '15 minutes'); COMMIT;")
        capabilities=request('/v1/ai/capabilities')
        # The public coordinator may wrap worker capabilities; transcription is the authoritative check.
        for name in ['chinese','english','long','silence']:
            audio=(args.samples/(name+'.wav')).read_bytes();start=time.monotonic()
            result=request('/v1/ai/audio/transcriptions',{'audio':base64.b64encode(audio).decode()})
            assert result['model']=='qwen3-asr-1.7b',result.get('model')
            if name=='chinese':assert '语音' in result['text'] and '硬盘' in result['text'] and result.get('text_script')=='Hans'
            if name=='english':assert 'speech' in result['text'].lower() and result['language']=='en'
            if name=='long':assert len(result['segments'])>=2 and result['segments'][-1]['end']>30
            if name=='silence':assert not result['text'].strip(),'Digital silence must not invent words'
            reports.append({'sample':name,'seconds':round(time.monotonic()-start,2),'model':result['model'],'language':result['language'],'segments':len(result['segments']),'text':result['text']})
            print(json.dumps(reports[-1],ensure_ascii=False),flush=True)
        (args.samples/'public-api-proof.json').write_text(json.dumps(reports,ensure_ascii=False,indent=2))
    finally:
        sql(f"DELETE FROM users WHERE id='{owner}';")


if __name__=='__main__':main()
