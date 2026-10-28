"""Real HTTPS recording workflow with disposable accounts and synthetic speech only."""
import base64
import hashlib
import json
import secrets
import shutil
import subprocess
import urllib.error
import urllib.request
import uuid
import wave
import time
from pathlib import Path

PSQL=['/opt/homebrew/opt/postgresql@17/bin/psql','-p','15432','-U','alex','-d','pointverse','-v','ON_ERROR_STOP=1']
users=[str(uuid.uuid4()),str(uuid.uuid4())]
tokens=[secrets.token_urlsafe(32),secrets.token_urlsafe(32)]
base='https://h5.dianjie.org'
wave_file=Path('/tmp/pointverse-cloud-test.wav')
audio=wave_file.read_bytes()
with wave.open(str(wave_file)) as reader:
    assert reader.getframerate()==16000 and reader.getsampwidth()==2 and reader.getnchannels()==1
    duration=reader.getnframes()/16000
sha=hashlib.sha256(audio).hexdigest()
root=Path.home()/'Library/Application Support/PointVerse/data/cloud'
def sql(text):subprocess.run(PSQL,input=text,text=True,check=True,stdout=subprocess.DEVNULL)
def call(path,body=None,*,owner=0,expected=200,origin=base,method=None):
    data=body if isinstance(body,bytes) else json.dumps(body).encode() if body is not None else None
    headers={'User-Agent':'PointVerse-Migration-Test/1.0','Origin':origin,'Content-Type':'application/octet-stream' if isinstance(body,bytes) else 'application/json'}
    if owner is not None:headers['Cookie']='pointverse_session='+tokens[owner]
    req=urllib.request.Request(base+path,data=data,headers=headers,method=method)
    try:r=urllib.request.urlopen(req,timeout=180)
    except urllib.error.HTTPError as e:r=e
    with r:
        result=r.read(8<<20)
        assert r.status==expected,(path,r.status,expected)
        value=json.loads(result) if 'json' in r.headers.get('Content-Type','') else result
    print(path,expected,'OK',flush=True)
    return value
try:
    for user,token in zip(users,tokens):
        digest=hashlib.sha256(token.encode()).hexdigest()
        sql(f"BEGIN; INSERT INTO users(id,display_name) VALUES('{user}','H5 synthetic recording test'); INSERT INTO auth_sessions(token_hash,user_id,expires_at) VALUES(decode('{digest}','hex'),'{user}',now()+interval '15 minutes'); COMMIT;")
    route='/web/ai/audio/transcriptions'
    payload={'audio':base64.b64encode(audio).decode()}
    call(route,payload,owner=None,expected=401)
    call(route,payload,origin='https://dianjie.org',expected=403)
    result=call(route,payload)
    assert result['text'].strip() and result['model'] in ('whisper-small','whisper-large-v3-turbo')
    assert result.get('text_script')=='Hans'
    print('Synthetic transcript:',result['text'],'model:',result['model'],flush=True)
    args={'ids':{key:str(uuid.uuid4()) for key in ('point','message','operation','asset','transcript')},'createdAt':time.time(),'sha256':sha,'byteCount':len(audio),'duration':duration,'text':result['text']+'（测试修正）','engineText':result['text'],'language':result.get('language'),'model':result['model']}
    helper=(Path(__file__).resolve().parents[1]/'internal/h5ui/assets/audio.mjs').as_uri()
    code='import {recordingManifest} from '+json.dumps(helper)+';let text="";for await(const x of process.stdin)text+=x;console.log(JSON.stringify(recordingManifest(JSON.parse(text))));'
    manifest=json.loads(subprocess.check_output(['/opt/homebrew/bin/node','--input-type=module','-e',code],input=json.dumps(args),text=True))
    asset_route='/web/sync/assets/'+sha
    call(asset_route,audio,origin='https://dianjie.org',method='PUT',expected=403)
    call(asset_route,audio,method='PUT',expected=201)
    call(asset_route,owner=1,expected=404)
    call('/web/sync/points',manifest,expected=200)
    again=call('/web/sync/points',manifest)
    page=call('/web/sync/points')
    assert len(page['items'])==1 and page['items'][0]['point_id']==manifest['point_id']
    point_route='/web/sync/points/'+manifest['point_id']+'/versions/'+again['manifest_hash']
    restored=call(point_route)
    assert restored['payload']['transcripts'][0]['engine_text']==result['text']
    assert restored['payload']['transcripts'][0]['user_text']==args['text']
    call(point_route,owner=1,expected=404)
    downloaded=call(asset_route)
    assert downloaded==audio
    print('PASS: real Whisper transcription, saved WAV and edited transcript, idempotency and account isolation',flush=True)
finally:
    for user in users:
        sql(f"DELETE FROM cloud_point_versions WHERE user_id='{user}'; DELETE FROM cloud_assets WHERE user_id='{user}'; DELETE FROM auth_sessions WHERE user_id='{user}'; DELETE FROM users WHERE id='{user}';")
        # Only directories belonging to this script's newly generated synthetic UUIDs.
        shutil.rmtree(root/user,ignore_errors=True)
