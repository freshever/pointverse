#!/usr/bin/env python3
"""Operator cutover with verified external models, a smoke test and rollback."""
import argparse
import datetime
import hashlib
import http.client
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import time
import urllib.request

from model_storage import model_storage_ready


def digest(path):
    value=hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda:stream.read(1<<20),b''):value.update(block)
    return value.digest()


def verify_copy(source,destination):
    for path in source.rglob('*'):
        other=destination/path.relative_to(source)
        if path.is_symlink():
            if not other.is_symlink() or os.readlink(path)!=os.readlink(other):raise RuntimeError('Model link verification failed')
        elif path.is_file():
            if not other.is_file() or path.stat().st_size!=other.stat().st_size or digest(path)!=digest(other):raise RuntimeError('Model copy verification failed: '+str(path.relative_to(source)))


def point_to_external(source,destination,backup):
    if source.is_symlink():
        if source.resolve()!=destination.resolve():raise RuntimeError('Existing model link points elsewhere')
        return
    if not source.exists():return
    verify_copy(source,destination)
    temporary=source.with_name('.'+source.name+'.external-next');temporary.symlink_to(destination,target_is_directory=True)
    os.replace(source,backup)
    try:os.replace(temporary,source)
    except BaseException:os.replace(backup,source);temporary.unlink(missing_ok=True);raise


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--volume',required=True,type=Path);parser.add_argument('--volume-uuid',required=True);parser.add_argument('--sample',required=True,type=Path)
    args=parser.parse_args();mount=args.volume.resolve();external=mount/'PointVerse';models=external/'models'
    if not model_storage_ready(models,str(mount),args.volume_uuid):raise SystemExit('Expected external model volume unavailable')
    manifest=json.loads((models/'qwen3-asr-1.7b/revision.json').read_text())
    expected=json.loads(Path(__file__).with_name('qwen-asr-model.json').read_text())
    if manifest!=expected:raise SystemExit('Qwen model revision is not verified')
    root=Path.home()/'Library/Application Support/PointVerse';sources=Path(__file__).resolve().parent
    plist=Path.home()/'Library/LaunchAgents/org.dianjie.ai-gateway.plist';config=plistlib.loads(plist.read_bytes())
    current=(root/'ai_gateway.py').read_bytes();stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    backup=root/'deployment-backups'/('qwen-asr-'+stamp);backup.mkdir(parents=True,mode=0o700)
    (backup/'ai_gateway.py').write_bytes(current);(backup/'gateway.plist').write_bytes(plist.read_bytes());(backup/'gateway.plist').chmod(0o600)
    base=subprocess.check_output(['git','show','HEAD:server/macmini/ai_gateway.py'],cwd=sources.parent.parent)
    (backup/'gateway.base.py').write_bytes(base)
    merged=subprocess.run(['git','merge-file','-p',str(root/'ai_gateway.py'),str(backup/'gateway.base.py'),str(sources/'ai_gateway.py')],capture_output=True)
    if merged.returncode:raise SystemExit('Live gateway has conflicting changes; no service changes made')
    compile(merged.stdout,'merged-gateway','exec')
    # Pre-verify before the brief service stop; internal backups are removed only after public checks.
    for source,destination in [(root/'models',models),(Path.home()/'.cache/huggingface/hub',external/'huggingface/hub')]:
        if not source.is_symlink() and source.exists():verify_copy(source,destination)
    if (root/'ai_gateway.py').read_bytes()!=current:raise SystemExit('Live gateway changed during preparation')
    domain=f'gui/{os.getuid()}/org.dianjie.ai-gateway'
    subprocess.run(['launchctl','bootout',domain],check=True)
    try:
        point_to_external(root/'models',models,backup/'models-internal')
        point_to_external(Path.home()/'.cache/huggingface/hub',external/'huggingface/hub',backup/'hub-internal')
        for name in ('qwen_speech_result.py','transcribe-qwen.py','model_storage.py'):
            next_path=root/(name+'.next');shutil.copyfile(sources/name,next_path);next_path.chmod(0o700);os.replace(next_path,root/name)
        # Old Whisper remains on the external volume for an immediate operator rollback.
        for model in ('qwen3.5:4b','qwen3.5:9b'):
            connection=http.client.HTTPConnection('127.0.0.1',11434,timeout=15)
            try:
                connection.request('POST','/api/generate',json.dumps({'model':model,'keep_alive':0}),{'Content-Type':'application/json'})
                response=connection.getresponse();response.read()
                if response.status!=200:raise RuntimeError('Cannot release chat model memory')
            finally:connection.close()
        started=time.monotonic()
        warm=subprocess.run([str(root/'asr-runtime/bin/python'),str(root/'transcribe-qwen.py'),str(models/'qwen3-asr-1.7b'),str(args.sample.resolve())],capture_output=True,timeout=120)
        if warm.returncode:raise RuntimeError('Qwen warm test failed: '+warm.stderr.decode(errors='replace')[-2500:])
        result=json.loads(warm.stdout)
        if result.get('model')!='qwen3-asr-1.7b' or '语音' not in result.get('text','') or '硬盘' not in result.get('text',''):raise RuntimeError('Qwen synthetic speech test did not match expected content')
        proof={'seconds':round(time.monotonic()-started,2),'result':result};(backup/'warm-test.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2))
        environment=config.setdefault('EnvironmentVariables',{})
        environment.update(POINTVERSE_SPEECH_MODEL='qwen3-asr-1.7b',POINTVERSE_MODEL_ROOT=str(models),POINTVERSE_MODEL_VOLUME=str(mount),POINTVERSE_MODEL_VOLUME_UUID=args.volume_uuid,HF_HOME=str(external/'huggingface'),HF_HUB_OFFLINE='1',TRANSFORMERS_OFFLINE='1')
        gateway_next=root/'ai_gateway.py.next';gateway_next.write_bytes(merged.stdout);gateway_next.chmod(0o700);os.replace(gateway_next,root/'ai_gateway.py')
        next_plist=plist.with_suffix('.plist.next');next_plist.write_bytes(plistlib.dumps(config));next_plist.chmod(0o600);os.replace(next_plist,plist)
        subprocess.run(['launchctl','bootstrap',f'gui/{os.getuid()}',str(plist)],check=True)
        address='http://'+environment['POINTVERSE_AI_HOST']+':'+environment.get('POINTVERSE_AI_PORT','11435')
        opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
        for attempt in range(30):
            try:
                with opener.open(address+'/healthz',timeout=5) as response:health=json.load(response)
                if health.get('status')=='ready':break
            except Exception:time.sleep(1)
        else:raise RuntimeError('Gateway health check failed')
        request=urllib.request.Request(address+'/v1/capabilities',headers={'Authorization':'Bearer '+environment['POINTVERSE_AI_TOKEN']})
        with opener.open(request,timeout=10) as response:capabilities=json.load(response)
        if not any(item.get('id')=='speech' and item.get('model')=='qwen3-asr-1.7b' for item in capabilities['capabilities']):raise RuntimeError('Qwen speech capability unavailable')
        (backup/'activated.json').write_text(json.dumps({'model':'qwen3-asr-1.7b','externalVolume':str(mount),'volumeUUID':args.volume_uuid}))
        print(json.dumps({'activated':True,'model':'qwen3-asr-1.7b','precision':'8bit','warmTestSeconds':proof['seconds'],'warmText':result['text'],'backup':str(backup)},ensure_ascii=False),flush=True)
    except BaseException:
        subprocess.run(['launchctl','bootout',domain],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        shutil.copyfile(backup/'ai_gateway.py',root/'ai_gateway.py');shutil.copyfile(backup/'gateway.plist',plist);plist.chmod(0o600)
        subprocess.run(['launchctl','bootstrap',f'gui/{os.getuid()}',str(plist)],check=True)
        print('Restored the prior speech service; external model copies remain intact.',flush=True)
        raise


if __name__=='__main__':main()
