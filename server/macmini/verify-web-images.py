"""Operator-only end-to-end browser API check using temporary synthetic users."""
import base64
import hashlib
import json
import secrets
import subprocess
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

PSQL = ['/opt/homebrew/opt/postgresql@17/bin/psql', '-p', '15432', '-U', 'alex', '-d', 'pointverse', '-v', 'ON_ERROR_STOP=1']
users = [str(uuid.uuid4()), str(uuid.uuid4())]
tokens = [secrets.token_urlsafe(32), secrets.token_urlsafe(32)]
hashes = [hashlib.sha256(token.encode()).hexdigest() for token in tokens]

def sql(value):
    subprocess.run(PSQL, input=value, text=True, check=True, stdout=subprocess.DEVNULL)

def call(path, payload=None, account=0, origin='https://dianjie.org', expected=200):
    headers = {'Content-Type': 'application/json', 'Origin': origin, 'User-Agent': 'PointVerse-Migration-Test/1.0'}
    if account is not None:
        headers['Cookie'] = 'pointverse_session=' + tokens[account]
    request = urllib.request.Request('https://dianjie.org' + path, headers=headers,
        data=json.dumps(payload).encode() if payload is not None else None)
    try:
        with urllib.request.urlopen(request, timeout=45) as response:
            status, data = response.status, response.read(8 << 20)
    except urllib.error.HTTPError as error:
        status, data = error.code, error.read()
    assert status == expected, (path, status, expected)
    return json.loads(data)

try:
    for user, digest in zip(users, hashes):
        sql(f"BEGIN; INSERT INTO users(id,display_name) VALUES('{user}','Synthetic web image test'); INSERT INTO auth_sessions(token_hash,user_id,expires_at) VALUES(decode('{digest}','hex'),'{user}',now()+interval '15 minutes'); COMMIT;")
    call('/web/ai/images/generations', {}, account=None, expected=401)
    call('/web/ai/images/generations', {}, origin='https://evil.example', expected=403)
    call('/v1/ai/images/generations', {}, expected=401)  # Cookie never authorizes native routes.
    payload = {'prompt': 'A small red wooden cabin in a green forest, watercolor painting, daylight', 'request_id': str(uuid.uuid4()), 'model': 'pointverse-image', 'size': '512x512', 'n': 1}
    first = call('/web/ai/images/generations', payload, expected=202)
    route = '/web/ai/jobs/' + first['id']
    assert call('/web/ai/images/generations', payload, expected=202)['id'] == first['id']
    call(route, account=1, expected=404)
    call(route + '/cancel', {}, account=1, expected=404)
    assert call(route + '/cancel', {})['status'] in ('cancelled', 'succeeded')
    payload['request_id'] = str(uuid.uuid4())
    job = call('/web/ai/images/generations', payload, expected=202)
    for _ in range(120):
        job = call('/web/ai/jobs/' + job['id'])
        if job['status'] == 'succeeded':
            image = base64.b64decode(job['data'][0]['b64_json'], validate=True)
            assert image.startswith(b'\x89PNG\r\n\x1a\n')
            assert int.from_bytes(image[16:20], 'big') == 512
            assert int.from_bytes(image[20:24], 'big') == 512
            Path('/tmp/pointverse-web-generated.png').write_bytes(image)
            print('PASS: HTTPS browser cookie, origin guard, owner isolation, idempotency, cancellation and 512x512 image generation', flush=True)
            break
        assert job['status'] in ('queued', 'running'), job['status']
        time.sleep(3)
    else:
        raise RuntimeError('image_job_timeout')
finally:
    for user in users:
        sql(f"DELETE FROM auth_sessions WHERE user_id='{user}'; DELETE FROM users WHERE id='{user}';")
