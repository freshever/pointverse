"""Operator test: prove account routing without sending any desktop message.

Run before arming the desktop. Temporary credentials/users are always removed.
"""
import hashlib
import json
import secrets
import subprocess
import urllib.error
import urllib.request
import uuid
from pathlib import Path

psql = ["/opt/homebrew/opt/postgresql@17/bin/psql", "-p", "15432", "-U", "alex", "-d", "pointverse", "-v", "ON_ERROR_STOP=1"]
owner = subprocess.check_output(psql + ["-Atc", "select user_id from email_credentials where email='robust@123.com'"], text=True).strip()
assert str(uuid.UUID(owner)) == owner
arm = Path.home()/"Library/Application Support/PointVerse/screenprobe-ready"
assert not arm.exists(), "Disarm desktop before verification"
other = str(uuid.uuid4())
owner_token, other_token = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
owner_hash, other_hash = (hashlib.sha256(t.encode()).hexdigest() for t in (owner_token, other_token))

def sql(text):
    subprocess.run(psql, input=text, text=True, stdout=subprocess.DEVNULL, check=True)

def request(token):
    req = urllib.request.Request("https://dianjie.org/v1/ai/chat/completions",
        data=json.dumps({"messages":[{"role":"user","content":"Reply OK"}],"max_tokens":16}).encode(),
        headers={"Authorization":"Bearer "+token, "Content-Type":"application/json",
                 "User-Agent":"PointVerse-Migration-Test/1.0", "X-PointVerse-Authenticated-User":owner})
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, json.load(error)

try:
    sql(f"BEGIN; INSERT INTO users(id,display_name) VALUES('{other}','Account routing smoke test'); INSERT INTO auth_sessions(token_hash,user_id,expires_at) VALUES(decode('{owner_hash}','hex'),'{owner}',now()+interval '5 minutes'),(decode('{other_hash}','hex'),'{other}',now()+interval '5 minutes'); COMMIT;")
    status, result = request(owner_token)
    assert status == 422 and result["error"]["code"] == "desktop_not_armed", "Owner did not reach desktop gate"
    status, result = request(other_token)
    assert status == 200 and result["model"] == "qwen2.5:3b", "Other account bypassed identity isolation"
    print("PASS: authorized account reaches desktop gate; spoofed other account stays on Qwen; no GUI message sent")
finally:
    sql(f"DELETE FROM auth_sessions WHERE token_hash=decode('{owner_hash}','hex'); DELETE FROM users WHERE id='{other}';")
