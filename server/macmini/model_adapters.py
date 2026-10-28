"""Provider boundary. External execution is opt-in and never an automatic fallback."""
import http.client
import ipaddress
import json
import os
import subprocess
import time
from dataclasses import dataclass
from typing import Protocol
from urllib.parse import urlsplit

@dataclass(frozen=True)
class AdapterResult:
    body: bytes
    content_type: str

class ModelAdapter(Protocol):
    def execute(self, payload: dict, *, allow_external: bool = False, capability: str = "chat") -> AdapterResult: ...

@dataclass(frozen=True)
class LocalProcessAdapter:
    command: tuple
    timeout: int = 120
    cancelled: object = None

    def execute(self, payload, *, allow_external=False, capability="chat"):
        process = subprocess.Popen(self.command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        deadline = time.monotonic() + self.timeout
        try:
            process.stdin.write(json.dumps(payload).encode())
            process.stdin.close()
            process.stdin = None
            while True:
                if self.cancelled and self.cancelled():
                    raise RuntimeError("inference_cancelled")
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(self.command, self.timeout)
                try:
                    output, error = process.communicate(timeout=min(1, remaining))
                    break
                except subprocess.TimeoutExpired:
                    continue
            if process.returncode:
                raise subprocess.CalledProcessError(process.returncode, self.command, output=output, stderr=error)
            return AdapterResult(output, "application/json")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            for stream in (process.stdin, process.stdout, process.stderr):
                if stream is not None:
                    stream.close()

@dataclass(frozen=True)
class OpenAICompatibleAdapter:
    base_url: str
    model: str
    key_environment: str
    enabled: bool = False

    def __post_init__(self):
        url = urlsplit(self.base_url)
        if url.scheme != "https" or not url.hostname or url.username or url.password or url.query or url.fragment or url.hostname == "localhost":
            raise ValueError("invalid_provider_endpoint")
        try:
            address = ipaddress.ip_address(url.hostname)
        except ValueError:
            address = None
        if address is not None and not address.is_global:
            raise ValueError("private_provider_endpoint")
        if not self.key_environment.startswith("POINTVERSE_PROVIDER_") or not self.model:
            raise ValueError("invalid_provider_configuration")

    def execute(self, payload, *, allow_external=False, capability="chat"):
        if not self.enabled or not allow_external:
            raise PermissionError("external_provider_not_authorized")
        paths = {"chat": "/chat/completions", "embeddings": "/embeddings", "image": "/images/generations", "tts": "/audio/speech"}
        if capability not in paths:
            raise ValueError("unsupported_external_capability")
        if any(key in payload for key in ("api_key", "base_url", "endpoint", "authorization")):
            raise ValueError("caller_provider_configuration_forbidden")
        key = os.environ.get(self.key_environment, "")
        if len(key) < 20:
            raise PermissionError("provider_key_not_configured")
        url = urlsplit(self.base_url)
        connection = http.client.HTTPSConnection(url.hostname, url.port or 443, timeout=90)
        try:
            body = json.dumps({**payload, "model": self.model}).encode()
            connection.request("POST", url.path.rstrip("/") + paths[capability], body,
                               {"Authorization": "Bearer " + key, "Content-Type": "application/json"})
            response = connection.getresponse()
            # Do not follow redirects or forward either gateway credentials or
            # user tokens. Provider keys exist only in operator-managed env.
            if not 200 <= response.status < 300:
                raise RuntimeError("external_provider_failed")
            result = response.read((8 << 20) + 1)
            if len(result) > 8 << 20:
                raise ValueError("external_response_too_large")
            return AdapterResult(result, response.getheader("Content-Type", "application/json"))
        finally:
            connection.close()
