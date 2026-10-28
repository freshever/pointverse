"""Operator-only migration smoke test; creates and removes an isolated test user."""
import base64
import hashlib
import json
import secrets
import shutil
import subprocess
import urllib.request
import uuid
from pathlib import Path

user = str(uuid.uuid4())
token = secrets.token_urlsafe(32)
digest = hashlib.sha256(token.encode()).hexdigest()
psql = ["/opt/homebrew/opt/postgresql@17/bin/psql", "-p", "15432", "-U", "alex", "-d", "pointverse", "-v", "ON_ERROR_STOP=1"]
def sql(value):
    subprocess.run(psql, input=value, text=True, stdout=subprocess.DEVNULL, check=True)

def request(path, payload=None, method=None, raw=None):
    body = raw if raw is not None else (json.dumps(payload).encode() if payload is not None else None)
    req = urllib.request.Request("https://dianjie.org" + path, data=body, method=method,
        headers={"Authorization": "Bearer " + token, "User-Agent": "PointVerse-Migration-Test/1.0", "Content-Type": "application/octet-stream" if raw is not None else "application/json"})
    with urllib.request.urlopen(req, timeout=150) as response:
        return response.read()

try:
    sql(f"BEGIN; INSERT INTO users(id,display_name) VALUES('{user}','Migration smoke test'); INSERT INTO auth_sessions(token_hash,user_id,expires_at) VALUES(decode('{digest}','hex'),'{user}',now()+interval '10 minutes'); COMMIT;")
    request("/v1/sync/points")
    asset = b"PointVerse migration smoke test\n"
    asset_hash = hashlib.sha256(asset).hexdigest()
    request("/v1/sync/assets/"+asset_hash, method="PUT", raw=asset)
    assert request("/v1/sync/assets/"+asset_hash) == asset
    assert (Path.home()/"Library/Application Support/PointVerse/data/cloud"/user/asset_hash).read_bytes() == asset
    reply = json.loads(request("/v1/ai/chat/completions", {"messages":[{"role":"user","content":"Reply with OK"}], "max_tokens":32}))
    assert reply["choices"][0]["message"]["content"].strip()
    audio = base64.b64encode(Path("/tmp/pointverse-speech-test.wav").read_bytes()).decode()
    speech = json.loads(request("/v1/ai/audio/transcriptions", {"audio":audio}))
    assert speech["text"].strip() and speech["segments"]
    print("PASS: public authentication, asset upload/download on Mac, chat, speech transcription")
finally:
    sql(f"DELETE FROM users WHERE id='{user}';")
    directory = Path.home()/"Library/Application Support/PointVerse/data/cloud"/user
    if directory.exists():
        shutil.rmtree(directory)
