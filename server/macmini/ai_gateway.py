#!/usr/bin/env python3
"""Authenticated bridge from the Tailscale network to local Ollama."""

import hmac
import http.client
import json
import os
import shutil
import threading
import base64
import io
import subprocess
import tempfile
import wave
import struct
import screenprobe_backend
import media_backend
from model_storage import model_storage_ready
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_BODY = 1 << 20
MODEL = os.environ.get("POINTVERSE_AI_MODEL", "qwen3.5:4b")
MIN_FREE_BYTES = int(os.environ.get("POINTVERSE_MIN_FREE_GIB", "10")) * (1 << 30)
EXECUTION = threading.BoundedSemaphore(1)
ADMISSION = threading.BoundedSemaphore(3)  # one running, at most two waiting
QUEUE_TIMEOUT = 10
SUPPORT = os.path.dirname(os.path.abspath(__file__))
SPEECH_MODEL_ID = os.environ.get("POINTVERSE_SPEECH_MODEL", "whisper-large-v3-turbo")
if SPEECH_MODEL_ID not in ("whisper-small", "whisper-large-v3-turbo", "qwen3-asr-1.7b"):
    raise ValueError("speech_model_not_allowed")
MODEL_ROOT = os.environ.get("POINTVERSE_MODEL_ROOT", os.path.join(SUPPORT, "models"))
MODEL_VOLUME = os.environ.get("POINTVERSE_MODEL_VOLUME", "")
MODEL_VOLUME_UUID = os.environ.get("POINTVERSE_MODEL_VOLUME_UUID", "")
SPEECH_MODEL = os.path.join(MODEL_ROOT, SPEECH_MODEL_ID)
SPEECH_PYTHON = os.path.join(SUPPORT, "asr-runtime" if SPEECH_MODEL_ID == "qwen3-asr-1.7b" else "runtime", "bin", "python")
SPEECH_RUNNER = "transcribe-qwen.py" if SPEECH_MODEL_ID == "qwen3-asr-1.7b" else "transcribe.py"
MAX_AUDIO_BODY = 8 << 20
CHAT_BACKEND = os.environ.get("POINTVERSE_CHAT_BACKEND", "ollama")
DESKTOP_USER = os.environ.get("POINTVERSE_DESKTOP_USER_ID", "")
JOBS = None

def translate_image_prompt(prompt):
    conn = http.client.HTTPConnection("127.0.0.1", 11434, timeout=90)
    try:
        conn.request("POST", "/v1/chat/completions", json.dumps({"model": "qwen3.5:4b", "stream": False,
                     "reasoning_effort": "none", "max_tokens": 128, "messages": [
                         {"role": "system", "content": "Translate the user's image description into a concise English image-generation prompt. Return only the prompt."},
                         {"role": "user", "content": prompt}]}), {"Content-Type": "application/json"})
        response = conn.getresponse()
        if response.status != 200:
            raise ValueError("translation_failed")
        text = json.loads(response.read())["choices"][0]["message"]["content"]
        if not isinstance(text, str) or not 0 < len(text) <= 1000:
            raise ValueError("translation_failed")
        return text
    finally:
        conn.close()

def selected_chat_model(requested):
    return {"pointverse-cloud": "qwen3.5:4b",
            "pointverse-cloud-enhanced": "qwen3.5:9b"}.get(requested, MODEL)

def validate_messages(messages):
    images = 0
    text_size = 0
    for message in messages:
        if not isinstance(message, dict) or message.get("role") not in ("user", "assistant", "system"):
            raise ValueError("invalid_message")
        content = message.get("content")
        if isinstance(content, str):
            text_size += len(content)
            continue
        if not isinstance(content, list) or not content:
            raise ValueError("invalid_content")
        for part in content:
            if not isinstance(part, dict):
                raise ValueError("invalid_part")
            if part.get("type") == "text" and isinstance(part.get("text"), str):
                text_size += len(part["text"])
                continue
            if part.get("type") != "image_url" or message["role"] != "user":
                raise ValueError("invalid_part")
            images += 1
            if images > 1:
                raise ValueError("too_many_images")
            value = part.get("image_url")
            url = value.get("url") if isinstance(value, dict) else None
            if not isinstance(url, str) or not url.startswith(("data:image/jpeg;base64,", "data:image/png;base64,")):
                raise ValueError("inline_image_required")
            prefix, encoded = url.split(",", 1)
            data = base64.b64decode(encoded, validate=True)
            if not data or len(data) > 512000:
                raise ValueError("image_too_large")
            if (prefix == "data:image/png;base64" and data.startswith(b"\x89PNG\r\n\x1a\n")
                    and len(data) >= 33 and data[8:16] == b"\x00\x00\x00\x0dIHDR"):
                width, height = struct.unpack(">II", data[16:24])
            elif prefix == "data:image/jpeg;base64" and data.startswith(b"\xff\xd8"):
                width = height = 0
                offset = 2
                while offset + 4 <= len(data):
                    if data[offset] != 255:
                        raise ValueError("invalid_jpeg")
                    marker = data[offset + 1]
                    size = int.from_bytes(data[offset + 2:offset + 4], "big")
                    if size < 2 or offset + 2 + size > len(data):
                        raise ValueError("invalid_jpeg")
                    if marker in (192, 193, 194):
                        if size < 8:
                            raise ValueError("invalid_jpeg")
                        height, width = struct.unpack(">HH", data[offset + 5:offset + 9])
                        break
                    offset += 2 + size
            else:
                raise ValueError("image_format_mismatch")
            if not (0 < width <= 1536 and 0 < height <= 1536 and width * height <= 1572864):
                raise ValueError("image_dimensions")
    if text_size > 16000:
        raise ValueError("text_too_large")

def unload_chat_models(keep=None):
    for model in ("qwen3.5:4b", "qwen3.5:9b"):
        if model == keep:
            continue
        cleanup = http.client.HTTPConnection("127.0.0.1", 11434, timeout=15)
        try:
            cleanup.request("POST", "/api/generate", json.dumps({"model": model, "keep_alive": 0}),
                            {"Content-Type": "application/json"})
            response = cleanup.getresponse()
            response.read()
            if response.status != 200:
                raise ValueError("model_unload_failed")
        finally:
            cleanup.close()


def speech_ready():
    if not model_storage_ready(MODEL_ROOT,MODEL_VOLUME,MODEL_VOLUME_UUID,MIN_FREE_BYTES):return False
    names=("model.safetensors","config.json","tokenizer_config.json","preprocessor_config.json","vocab.json","merges.txt","revision.json") if SPEECH_MODEL_ID=="qwen3-asr-1.7b" else ("model.bin","config.json","tokenizer.json")
    return os.path.isfile(SPEECH_PYTHON) and all(os.path.isfile(os.path.join(SPEECH_MODEL,name)) for name in names)


def validate_audio(payload):
    audio = base64.b64decode(payload["audio"], validate=True)
    with wave.open(io.BytesIO(audio), "rb") as wav:
        if (wav.getnchannels() != 1 or wav.getsampwidth() != 2 or wav.getframerate() != 16000
                or not 0 < wav.getnframes() <= 120 * 16000):
            raise ValueError("expected mono PCM16 16kHz WAV, at most 120 seconds")
        if len(wav.readframes(wav.getnframes())) != wav.getnframes() * 2:
            raise ValueError("truncated WAV")
    return audio


def resources_ready():
    return model_storage_ready(MODEL_ROOT,MODEL_VOLUME,MODEL_VOLUME_UUID,MIN_FREE_BYTES)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        if self.path.startswith("/v1/jobs/"):
            if not self.authorized():
                return self.error(401, "unauthorized")
            try:
                result = JOBS.get(self.headers.get("X-PointVerse-Authenticated-User", ""), self.path.removeprefix("/v1/jobs/")) if JOBS else None
                return self.json_response(200, result) if result else self.error(404, "job_not_found")
            except (ValueError, OSError):
                return self.error(404, "job_not_found")
        if self.path not in ("/healthz", "/v1/capabilities"):
            return self.error(404, "not_found")
        if self.path == "/v1/capabilities" and not self.authorized():
            return self.error(401, "unauthorized")
        try:
            conn = http.client.HTTPConnection("127.0.0.1", 11434, timeout=5)
            conn.request("GET", "/api/tags")
            response = conn.getresponse()
            tags = json.loads(response.read())
            conn.close()
            if response.status != 200:
                raise RuntimeError("ollama_not_ready")
            installed = next((m for m in tags.get("models", []) if m.get("name") == MODEL), None)
            if installed is None or not resources_ready():
                raise RuntimeError("resources_not_ready")
        except Exception:
            return self.error(503, "ollama_not_ready")
        capabilities = [{"id": "language", "model": MODEL, "size_bytes": installed.get("size", 0)}]
        if CHAT_BACKEND == "ollama" and MODEL in ("qwen3.5:4b", "qwen3.5:9b"):
            capabilities.append({"id": "vision", "model": MODEL, "max_images": 1,
                                 "max_image_bytes": 512000, "inline_only": True})
        if CHAT_BACKEND == "screenprobe":
            capabilities = [{"id": "language", "model": "codex-desktop-experimental",
                             "ready": screenprobe_backend.ready(), "experimental": True}]
        if speech_ready():
            capabilities.append({"id": "speech", "model": SPEECH_MODEL_ID, "max_audio_seconds": 120,
                                 "format": "pcm16_mono_16000_wav_base64"})
        for kind in ("embeddings", "audio", "image", "recording"):
            if media_backend.ready(kind):
                capabilities.append({"id": kind, "model": media_backend.MODELS[kind], "async": kind == "image"})
        capabilities.append({"id": "speech_synthesis", "model": "macos-system-voices", "format": "wav"})
        body = json.dumps({"status": "ready"} if self.path == "/healthz" else {
            "protocol_version": 1,
            "capabilities": capabilities,
            "limits": {"concurrency": 1, "queue_capacity": 2, "queue_timeout_seconds": QUEUE_TIMEOUT,
                       "max_request_bytes": MAX_BODY, "max_output_tokens": 512},
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path.startswith("/v1/jobs/") and self.path.endswith("/cancel"):
            if not self.authorized():
                return self.error(401, "unauthorized")
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 <= length <= 1024:
                    return self.error(413, "request_too_large")
                self.rfile.read(length)
                result = JOBS.cancel(self.headers.get("X-PointVerse-Authenticated-User", ""), self.path[len("/v1/jobs/"):-len("/cancel")]) if JOBS else None
                return self.json_response(200, result) if result else self.error(404, "job_not_found")
            except ValueError:
                return self.error(404, "job_not_found")
        media_routes = {"/v1/embeddings": "embeddings", "/v1/audio/classifications": "audio", "/v1/images/generations": "image", "/v1/audio/speech": "tts", "/v1/audio/analysis": "recording"}
        if self.path in media_routes:
            return self.run_media(media_routes[self.path])
        if self.path not in ("/v1/chat/completions", "/v1/audio/transcriptions"):
            return self.error(404, "not_found")
        if not self.authorized():
            return self.error(401, "unauthorized")
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return self.error(400, "invalid_content_length")
        speech = self.path == "/v1/audio/transcriptions"
        if length <= 0 or length > (MAX_AUDIO_BODY if speech else MAX_BODY):
            return self.error(413, "request_too_large")
        body = self.rfile.read(length)
        try:
            payload = json.loads(body)
            if speech:
                if not speech_ready():
                    return self.error(503, "speech_not_ready")
                audio = validate_audio(payload)
            else:
                audio = None
            if speech:
                return self.run_speech(audio)
            if not isinstance(payload, dict) or not isinstance(payload.get("messages"), list) or not payload["messages"]:
                return self.error(400, "messages_required")
            validate_messages(payload["messages"])
            maximum = payload.get("max_tokens", 256)
            if isinstance(maximum, bool) or not isinstance(maximum, int) or maximum < 1:
                return self.error(400, "invalid_token_limit")
            # Allowlist prevents caller-supplied runtime options and model names.
            selected_model = selected_chat_model(payload.get("model"))
            payload = {"model": selected_model, "messages": payload["messages"], "stream": False,
                       "max_tokens": min(maximum, 512), "temperature": 0.3,
                       "reasoning_effort": "none"}
            body = json.dumps(payload).encode()
        except (ValueError, TypeError, KeyError, wave.Error, EOFError):
            return self.error(400, "invalid_request")
        if not resources_ready():
            return self.error(503, "insufficient_disk_space")
        if not ADMISSION.acquire(blocking=False):
            return self.error(503, "node_busy")
        acquired = False
        conn = None
        headers_sent = False
        try:
            acquired = EXECUTION.acquire(timeout=QUEUE_TIMEOUT)
            if not acquired:
                return self.error(503, "queue_timeout")
            if (CHAT_BACKEND == "screenprobe" and DESKTOP_USER
                    and self.headers.get("X-PointVerse-Authenticated-User") == DESKTOP_USER):
                if not screenprobe_backend.ready():
                    return self.error(422, "desktop_not_armed")
                try:
                    result = screenprobe_backend.complete(payload["messages"])
                except (RuntimeError, ValueError) as error:
                    code = str(error)
                    allowed = {"desktop_not_armed", "invalid_messages", "desktop_prompt_limit", "desktop_test_prompt_mismatch",
                               "desktop_execution_failed", "desktop_answer_missing", "desktop_answer_invalid",
                               "desktop_response_timeout"}
                    print("Desktop bridge rejected: " + (code if code in allowed else "invalid_request"), flush=True)
                    return self.error(422, code if code in allowed else "desktop_test_failed")
                except (OSError, subprocess.SubprocessError):
                    return self.error(422, "desktop_test_failed")
                response_body = json.dumps(result).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(response_body)))
                self.end_headers()
                self.wfile.write(response_body)
                return
            if selected_model in ("qwen3.5:4b", "qwen3.5:9b"):
                unload_chat_models(keep=selected_model)
            conn = http.client.HTTPConnection("127.0.0.1", 11434, timeout=300)
            conn.request("POST", self.path, body, {"Content-Type": "application/json"})
            response = conn.getresponse()
            self.send_response(response.status)
            self.send_header("Content-Type", response.getheader("Content-Type", "application/json"))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "close")
            self.end_headers()
            headers_sent = True
            while chunk := response.read(16384):
                self.wfile.write(chunk)
                self.wfile.flush()
            self.close_connection = True
        except Exception:
            if not headers_sent:
                self.error(502, "runtime_unavailable")
            self.close_connection = True
        finally:
            if conn is not None:
                conn.close()
            if acquired:
                EXECUTION.release()
            ADMISSION.release()

    def run_speech(self, audio):
        if not resources_ready():
            return self.error(503, "insufficient_disk_space")
        if not ADMISSION.acquire(blocking=False):
            return self.error(503, "node_busy")
        acquired = False
        try:
            acquired = EXECUTION.acquire(timeout=QUEUE_TIMEOUT)
            if not acquired:
                return self.error(503, "queue_timeout")
            unload_chat_models()
            with tempfile.TemporaryDirectory(prefix="pointverse-speech-") as directory:
                path = os.path.join(directory, "input.wav")
                with open(path, "wb") as output:
                    output.write(audio)
                result = subprocess.run([SPEECH_PYTHON, os.path.join(SUPPORT, SPEECH_RUNNER), SPEECH_MODEL, path],
                                        capture_output=True, timeout=120, check=True)
                body = json.dumps(json.loads(result.stdout)).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (subprocess.SubprocessError, ValueError, OSError):
            self.error(502, "speech_failed")
        finally:
            if acquired:
                EXECUTION.release()
            ADMISSION.release()

    def authorized(self):
        expected = "Bearer " + os.environ["POINTVERSE_AI_TOKEN"]
        return hmac.compare_digest(self.headers.get("Authorization", ""), expected)

    def json_response(self, status, payload):
        body = json.dumps(payload, allow_nan=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def run_media(self, kind):
        if not self.authorized():
            return self.error(401, "unauthorized")
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= (MAX_AUDIO_BODY if kind in ("audio", "recording") else 65536):
                return self.error(413, "request_too_large")
            raw = json.loads(self.rfile.read(length))
            payload = media_backend.validate(kind, raw)
            audio = validate_audio(raw) if kind in ("audio", "recording") else None
            if audio:
                with wave.open(io.BytesIO(audio)) as wav:
                    if wav.getnframes() / wav.getframerate() > 30:
                        raise ValueError("sound_duration_limit")
                    if kind == "recording" and not 5.1 <= wav.getnframes() / wav.getframerate() <= 10:
                        raise ValueError("recording_duration_limit")
        except (ValueError, TypeError, KeyError, wave.Error, EOFError, AttributeError):
            return self.error(400, "invalid_request")
        if kind != "tts" and not media_backend.ready(kind):
            return self.error(503, "model_not_installed")
        if not resources_ready():
            return self.error(503, "insufficient_disk_space")
        if kind == "image":
            try:
                result = JOBS.create(self.headers.get("X-PointVerse-Authenticated-User", ""), payload) if JOBS else None
                return self.json_response(202, result) if result else self.error(503, "image_queue_full")
            except ValueError:
                return self.error(401, "authenticated_user_required")
        if not ADMISSION.acquire(blocking=False):
            return self.error(503, "node_busy")
        acquired = False
        try:
            acquired = EXECUTION.acquire(timeout=QUEUE_TIMEOUT)
            if not acquired:
                return self.error(503, "queue_timeout")
            unload_chat_models()
            if kind == "tts":
                body = media_backend.synthesize(payload)
                self.send_response(200)
                self.send_header("Content-Type", "audio/wav")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            with tempfile.TemporaryDirectory(prefix="pointverse-media-") as directory:
                if audio:
                    path = os.path.join(directory, "input.wav")
                    with open(path, "wb") as output:
                        output.write(audio)
                    payload["audio_path"] = path
                result = media_backend.infer(kind, payload)
            return self.json_response(200, result)
        except (subprocess.SubprocessError, OSError, ValueError, KeyError):
            return self.error(502, "media_execution_failed")
        finally:
            if acquired:
                EXECUTION.release()
            ADMISSION.release()

    def error(self, status, code):
        self.close_connection = True
        body = json.dumps({"error": {"code": code, "message": code}}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        if status == 503:
            self.send_header("Retry-After", "5")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)


def main():
    global JOBS
    token = os.environ.get("POINTVERSE_AI_TOKEN", "")
    if len(token) < 32:
        raise SystemExit("POINTVERSE_AI_TOKEN must contain at least 32 characters")
    host = os.environ.get("POINTVERSE_AI_HOST", "100.89.246.35")
    port = int(os.environ.get("POINTVERSE_AI_PORT", "11435"))
    JOBS = media_backend.ImageJobs(EXECUTION, ADMISSION, resources_ready, unload_chat_models, translate_image_prompt)
    ThreadingHTTPServer((host, port), Handler).serve_forever()


if __name__ == "__main__":
    main()
