"""Operator smoke test with synthetic input and immediately revoked sessions."""
import base64
import hashlib
import io
import json
import math
import os
import secrets
import subprocess
import time
import urllib.error
import urllib.request
import uuid
import wave
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy.signal import resample_poly

PSQL = ["/opt/homebrew/opt/postgresql@17/bin/psql", "-p", "15432", "-U", "alex", "-d", "pointverse", "-v", "ON_ERROR_STOP=1"]
email = os.environ["POINTVERSE_TEST_ACCOUNT"]
owner = subprocess.check_output(PSQL + ["-v", "account=" + email], input="SELECT user_id FROM email_credentials WHERE email=:'account';", text=True)
# psql's regular tabular output includes headers; keep UUID validation explicit.
owner = next(line.strip() for line in owner.splitlines() if len(line.strip()) == 36)
owner = str(uuid.UUID(owner))
other = str(uuid.uuid4())
tokens = [secrets.token_urlsafe(32), secrets.token_urlsafe(32)]
hashes = [hashlib.sha256(t.encode()).hexdigest() for t in tokens]
BASE = "https://dianjie.org/v1/ai/"

def sql(statement):
    subprocess.run(PSQL, input=statement, text=True, check=True, stdout=subprocess.DEVNULL)

def call(route, payload=None, *, token=tokens[0], method=None):
    req = urllib.request.Request(BASE + route, data=json.dumps(payload).encode() if payload is not None else None,
                                 method=method, headers={"Authorization": "Bearer " + token, "Content-Type": "application/json", "User-Agent": "PointVerse-Migration-Test/1.0"})
    start = time.monotonic()
    with urllib.request.urlopen(req, timeout=150) as response:
        body = response.read((8 << 20) + 1)
        assert len(body) <= 8 << 20
        result = json.loads(body) if "json" in response.headers.get("Content-Type", "") else body
        print(route, response.status, round(time.monotonic() - start, 2), "seconds", flush=True)
        return result

try:
    sql(f"BEGIN; INSERT INTO users(id,display_name) VALUES('{other}','Media isolation smoke test'); INSERT INTO auth_sessions(token_hash,user_id,expires_at) VALUES(decode('{hashes[0]}','hex'),'{owner}',now()+interval '15 minutes'),(decode('{hashes[1]}','hex'),'{other}',now()+interval '15 minutes'); COMMIT;")
    capabilities = call("capabilities")
    print("Capabilities:", [c["id"] for c in capabilities["capabilities"]], flush=True)
    try:
        call("capabilities", token="invalid")
        raise AssertionError("Unauthenticated media access allowed")
    except urllib.error.HTTPError as error:
        assert error.code == 401
    vectors = call("embeddings", {"input": ["太阳是一颗恒星。", "The sun is a star."], "input_type": "passage"})
    a, b = [row["embedding"] for row in vectors["data"]]
    assert len(a) == len(b) == 384 and all(math.isfinite(x) for x in a + b)
    assert 0.99 < sum(x*x for x in a) < 1.01
    print("Multilingual cosine:", round(sum(x*y for x,y in zip(a,b)), 3), flush=True)
    spoken = call("audio/speech", {"input": "你好，我正在测试点界的云端语音识别功能。欢迎使用点界。", "voice": "zh"})
    with wave.open(io.BytesIO(spoken)) as reader:
        assert reader.getnchannels() == 1 and reader.getsampwidth() == 2
        pcm = np.frombuffer(reader.readframes(reader.getnframes()), dtype="<i2")
        rate = reader.getframerate()
    mono = resample_poly(pcm.astype(np.float32), 16000, rate).clip(-32768,32767).astype("<i2")
    wav = io.BytesIO()
    with wave.open(wav, "wb") as writer:
        writer.setnchannels(1); writer.setsampwidth(2); writer.setframerate(16000); writer.writeframes(mono.tobytes())
    audio = base64.b64encode(wav.getvalue()).decode()
    speech = call("audio/transcriptions", {"audio": audio})
    assert speech.get("text", "").strip() and speech.get("model") == "whisper-small"
    print("Synthetic transcript:", speech["text"], flush=True)
    sounds = call("audio/classifications", {"audio": audio, "candidates": ["human speech", "music", "rain", "a dog barking"]})
    assert len(sounds["embedding"]) == 512 and sounds["scores_relative"]
    print("Sound candidate:", sounds["labels"][0]["label"], flush=True)
    image = Image.new("RGB", (256,256), "white")
    draw = ImageDraw.Draw(image); draw.rectangle((20,70,110,160), fill="red"); draw.ellipse((140,70,230,160), fill="blue")
    buffer = io.BytesIO(); image.save(buffer, format="PNG")
    description = call("chat/completions", {"model": "pointverse-cloud", "max_tokens": 128, "messages": [{"role": "user", "content": [
        {"type": "text", "text": "用中文说明左右图形的颜色和形状。"},
        {"type": "image_url", "image_url": {"url": "data:image/png;base64," + base64.b64encode(buffer.getvalue()).decode()}}]}]})
    print("Synthetic image description:", description["choices"][0]["message"]["content"], flush=True)
    cancelled = call("images/generations", {"prompt": "a pine tree", "request_id": str(uuid.uuid4())})
    assert call("jobs/" + cancelled["id"] + "/cancel", {})["status"] == "cancelled"
    try:
        call("jobs/" + cancelled["id"], token=tokens[1])
        raise AssertionError("Cross-account job disclosure")
    except urllib.error.HTTPError as error:
        assert error.code == 404
    payload = {"prompt": "a red cube on a white table, studio photograph, soft light", "seed": 42, "request_id": str(uuid.uuid4())}
    job = call("images/generations", payload)
    assert call("images/generations", payload)["id"] == job["id"]
    deadline = time.monotonic() + 420
    while time.monotonic() < deadline:
        result = call("jobs/" + job["id"])
        if result["status"] == "succeeded":
            output = base64.b64decode(result["data"][0]["b64_json"], validate=True)
            generated = Image.open(io.BytesIO(output)); assert generated.size == (512,512)
            assert any(lo != hi for lo,hi in generated.convert("RGB").getextrema())
            Path("/tmp/pointverse-public-generated.png").write_bytes(output)
            print("Image job succeeded:", job["id"], result["model"], flush=True)
            break
        if result["status"] in ("failed", "cancelled"):
            raise AssertionError("Image job did not succeed: " + json.dumps(result))
        time.sleep(3)
    else:
        raise AssertionError("Image polling deadline exceeded")
    print("PASS: public media inference, authentication, ownership, cancellation and idempotency", flush=True)
finally:
    sql(f"DELETE FROM auth_sessions WHERE token_hash=decode('{hashes[0]}','hex'); DELETE FROM users WHERE id='{other}';")
