"""Bounded media adapters and owner-scoped, durable image jobs on the Mac."""
import base64
import contextlib
import json
import os
import secrets
import sqlite3
import subprocess
import tempfile
import threading
import time
import uuid
from pathlib import Path
from model_adapters import LocalProcessAdapter

ROOT = Path(__file__).resolve().parent
PYTHON = ROOT / "media-runtime/bin/python"
RUNNER = ROOT / "media_runner.py"
STORE = ROOT / "data/ai"
DB = STORE / "jobs.sqlite"
MODELS = {"embeddings": "e5-small", "audio": "clap", "image": "sd15", "recording": "recording-coreml"}
DEFAULT_SOUNDS = ["human speech", "music", "applause", "rain", "a dog barking", "a cat meowing", "road traffic", "birds singing", "wind", "a door closing", "keyboard typing", "silence"]

def ready(kind):
    if kind == "recording":
        return (ROOT / "recording-runner").is_file() and (ROOT / "models/recording-coreml/revision.json").is_file()
    return kind in MODELS and PYTHON.is_file() and RUNNER.is_file() and (ROOT / "models" / MODELS[kind] / "revision.json").is_file()

def validate(kind, payload):
    if not isinstance(payload, dict):
        raise ValueError("invalid_request")
    aliases = {"embeddings": ("pointverse-embedding", "e5-small"), "audio": ("pointverse-sound", "clap"),
               "image": ("pointverse-image", "sd15"), "tts": ("pointverse-speech", "macos-system-voices"),
               "recording": ("pointverse-recording", "recording-coreml")}
    if payload.get("model") is not None and payload["model"] not in aliases.get(kind, ()):
        raise ValueError("model_not_allowed")
    if kind == "embeddings":
        inputs = payload.get("input")
        if isinstance(inputs, str):
            inputs = [inputs]
        if not isinstance(inputs, list) or not 1 <= len(inputs) <= 16 or any(not isinstance(t, str) or not 0 < len(t) <= 2000 for t in inputs):
            raise ValueError("invalid_embedding_input")
        purpose = payload.get("input_type", "passage")
        if purpose not in ("query", "passage"):
            raise ValueError("invalid_input_type")
        return {"input": inputs, "input_type": purpose}
    if kind == "recording":
        return {}
    if kind == "audio":
        candidates = payload.get("candidates", DEFAULT_SOUNDS)
        if not isinstance(candidates, list) or not 2 <= len(candidates) <= 16 or any(not isinstance(t, str) or not 0 < len(t) <= 100 or not t.isascii() for t in candidates):
            raise ValueError("invalid_sound_candidates")
        return {"candidates": candidates}
    if kind == "image":
        prompt = payload.get("prompt")
        seed = payload.get("seed", secrets.randbelow(1 << 32))
        if not isinstance(prompt, str) or not 1 <= len(prompt.strip()) <= 600:
            raise ValueError("invalid_prompt")
        if not isinstance(seed, int) or isinstance(seed, bool) or not 0 <= seed < (1 << 32):
            raise ValueError("invalid_seed")
        if payload.get("size", "512x512") != "512x512" or payload.get("n", 1) != 1:
            raise ValueError("unsupported_image_size")
        request_id = str(uuid.UUID(payload.get("request_id", "")))
        return {"prompt": prompt.strip(), "seed": seed, "request_id": request_id}
    if kind == "tts":
        text = payload.get("input")
        voice = payload.get("voice", "zh")
        if not isinstance(text, str) or not 1 <= len(text.strip()) <= 160 or voice not in ("zh", "en") or payload.get("response_format", "wav") != "wav":
            raise ValueError("invalid_speech_input")
        return {"input": text.strip(), "voice": voice}
    raise ValueError("unknown_capability")

def infer(kind, payload, timeout=120, cancelled=None):
    if not ready(kind):
        raise ValueError("model_not_installed")
    command = (str(ROOT / "recording-runner"), str(ROOT / "models/recording-coreml")) if kind == "recording" else (str(PYTHON), str(RUNNER), kind, str(ROOT / "models" / MODELS[kind]))
    adapter = LocalProcessAdapter(command, timeout=timeout, cancelled=cancelled)
    return json.loads(adapter.execute(payload).body)

def synthesize(payload):
    voices = {"zh": "Tingting (中文（中国大陆）)", "en": "Samantha"}
    with tempfile.TemporaryDirectory(prefix="pointverse-tts-") as temp:
        path = Path(temp)
        (path / "input.txt").write_text(payload["input"])
        subprocess.run(["/usr/bin/say", "-v", voices[payload["voice"]], "-r", "180", "-f", str(path / "input.txt"), "-o", str(path / "speech.aiff")],
                       capture_output=True, timeout=60, check=True)
        subprocess.run(["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16@22050", str(path / "speech.aiff"), str(path / "speech.wav")],
                       capture_output=True, timeout=15, check=True)
        audio = (path / "speech.wav").read_bytes()
        if len(audio) > 4 << 20 or audio[:4] != b"RIFF":
            raise ValueError("invalid_speech_output")
        return audio

class ImageJobs:
    def __init__(self, execution, admission, resources, unload, translate):
        STORE.mkdir(parents=True, exist_ok=True, mode=0o700)
        with self.connection() as db:
            db.execute("CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY, owner TEXT NOT NULL, request_key TEXT NOT NULL, state TEXT NOT NULL, created REAL NOT NULL, payload TEXT NOT NULL, result TEXT, error TEXT, UNIQUE(owner,request_key))")
            # A killed process may have partially written an image; never label
            # that successful or silently replay a completed GPU operation.
            db.execute("UPDATE jobs SET state='failed', error='worker_restarted', payload='{}' WHERE state='running'")
        DB.chmod(0o600)
        self.execution, self.admission, self.resources = execution, admission, resources
        self.unload, self.translate = unload, translate
        threading.Thread(target=self.worker, daemon=True).start()

    @contextlib.contextmanager
    def connection(self):
        db = sqlite3.connect(DB, timeout=10)
        db.row_factory = sqlite3.Row
        try:
            yield db
            db.commit()
        except Exception:
            db.rollback()
            raise
        finally:
            db.close()

    def prune(self, db):
        expired = db.execute("SELECT id FROM jobs WHERE created < ? AND state NOT IN ('queued','running')", (time.time() - 86400,)).fetchall()
        for row in expired:
            (STORE / (str(uuid.UUID(row["id"])) + ".png")).unlink(missing_ok=True)
            db.execute("DELETE FROM jobs WHERE id=?", (row["id"],))

    def create(self, owner, payload):
        owner = str(uuid.UUID(owner))
        with self.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            self.prune(db)
            prior = db.execute("SELECT id,state FROM jobs WHERE owner=? AND request_key=?", (owner, payload["request_id"])).fetchone()
            if prior:
                return {"id": prior["id"], "status": prior["state"], "poll_after_seconds": 3}
            count = db.execute("SELECT count(*) FROM jobs WHERE state IN ('queued','running')").fetchone()[0]
            own = db.execute("SELECT count(*) FROM jobs WHERE owner=? AND state IN ('queued','running')", (owner,)).fetchone()[0]
            total = db.execute("SELECT count(*) FROM jobs").fetchone()[0]
            if count >= 2 or own or total >= 100:
                return None
            job_id = str(uuid.uuid4())
            db.execute("INSERT INTO jobs(id,owner,request_key,state,created,payload) VALUES(?,?,?,'queued',?,?)", (job_id, owner, payload["request_id"], time.time(), json.dumps(payload)))
        return {"id": job_id, "status": "queued", "poll_after_seconds": 3}

    def get(self, owner, job_id):
        owner, job_id = str(uuid.UUID(owner)), str(uuid.UUID(job_id))
        with self.connection() as db:
            row = db.execute("SELECT * FROM jobs WHERE owner=? AND id=? AND created > ?", (owner, job_id, time.time() - 86400)).fetchone()
        if row is None:
            return None
        result = {"id": job_id, "status": row["state"]}
        if row["state"] == "succeeded":
            result.update(json.loads(row["result"]))
            result["data"] = [{"b64_json": base64.b64encode((STORE / (job_id + ".png")).read_bytes()).decode()}]
        elif row["state"] == "failed":
            result["error"] = row["error"]
        else:
            result["poll_after_seconds"] = 3
        return result

    def worker(self):
        while True:
            time.sleep(1)
            try:
                with self.connection() as db:
                    self.prune(db)
                    db.execute("UPDATE jobs SET state='failed',error='queue_expired',payload='{}' WHERE state='queued' AND created<?", (time.time() - 600,))
                    pending = db.execute("SELECT count(*) FROM jobs WHERE state='queued'").fetchone()[0]
                if pending == 0:
                    continue
            except (sqlite3.Error, OSError):
                continue
            if not ready("image") or not self.resources() or not self.admission.acquire(blocking=False):
                continue
            acquired = False
            try:
                acquired = self.execution.acquire(timeout=10)
                if not acquired:
                    continue
                with self.connection() as db:
                    db.execute("BEGIN IMMEDIATE")
                    row = db.execute("SELECT * FROM jobs WHERE state='queued' ORDER BY created LIMIT 1").fetchone()
                    if row is None:
                        continue
                    db.execute("UPDATE jobs SET state='running' WHERE id=?", (row["id"],))
                job_id = row["id"]
                output = STORE / (job_id + ".png")
                try:
                    if time.time() - row["created"] > 600:
                        raise ValueError("queue_expired")
                    payload = json.loads(row["payload"])
                    if not payload["prompt"].isascii():
                        self.unload(keep="qwen3.5:4b")
                        payload["prompt"] = self.translate(payload["prompt"])
                    self.unload()
                    payload["output_path"] = str(output)
                    def cancelled():
                        with self.connection() as db:
                            state = db.execute("SELECT state FROM jobs WHERE id=?", (job_id,)).fetchone()
                            return state is None or state["state"] == "cancelled"
                    result = infer("image", payload, timeout=300, cancelled=cancelled)
                    if not output.is_file() or output.stat().st_size > 4 << 20:
                        raise ValueError("invalid_image_output")
                    output.chmod(0o600)
                    with self.connection() as db:
                        updated = db.execute("UPDATE jobs SET state='succeeded',result=?,payload='{}' WHERE id=? AND state='running'", (json.dumps(result), job_id))
                        if updated.rowcount != 1:
                            output.unlink(missing_ok=True)
                except Exception:
                    output.unlink(missing_ok=True)
                    with self.connection() as db:
                        db.execute("UPDATE jobs SET state='failed',error='generation_failed',payload='{}' WHERE id=? AND state='running'", (job_id,))
            except Exception:
                # Transient local DB errors must not kill the worker thread.
                time.sleep(1)
            finally:
                if acquired:
                    self.execution.release()
                self.admission.release()

    def cancel(self, owner, job_id):
        owner, job_id = str(uuid.UUID(owner)), str(uuid.UUID(job_id))
        with self.connection() as db:
            db.execute("UPDATE jobs SET state='cancelled',payload='{}' WHERE owner=? AND id=? AND state IN ('queued','running')", (owner, job_id))
        return self.get(owner, job_id)
