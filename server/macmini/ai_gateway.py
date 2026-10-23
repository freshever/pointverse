#!/usr/bin/env python3
"""Authenticated bridge from the Tailscale network to local Ollama."""

import hmac
import http.client
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_BODY = 1 << 20


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        if self.path != "/healthz":
            return self.error(404, "not_found")
        try:
            conn = http.client.HTTPConnection("127.0.0.1", 11434, timeout=5)
            conn.request("GET", "/api/tags")
            response = conn.getresponse()
            response.read()
            conn.close()
            if response.status != 200:
                raise RuntimeError("ollama_not_ready")
        except Exception:
            return self.error(503, "ollama_not_ready")
        body = b'{"status":"ready"}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            return self.error(404, "not_found")
        expected = "Bearer " + os.environ["POINTVERSE_AI_TOKEN"]
        if not hmac.compare_digest(self.headers.get("Authorization", ""), expected):
            return self.error(401, "unauthorized")
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return self.error(400, "invalid_content_length")
        if length <= 0 or length > MAX_BODY:
            return self.error(413, "request_too_large")
        body = self.rfile.read(length)
        try:
            conn = http.client.HTTPConnection("127.0.0.1", 11434, timeout=300)
            conn.request("POST", self.path, body, {"Content-Type": "application/json"})
            response = conn.getresponse()
            self.send_response(response.status)
            self.send_header("Content-Type", response.getheader("Content-Type", "application/json"))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "close")
            self.end_headers()
            while chunk := response.read(16384):
                self.wfile.write(chunk)
                self.wfile.flush()
            conn.close()
            self.close_connection = True
        except Exception:
            self.close_connection = True

    def error(self, status, code):
        body = json.dumps({"error": {"code": code, "message": code}}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)


def main():
    token = os.environ.get("POINTVERSE_AI_TOKEN", "")
    if len(token) < 32:
        raise SystemExit("POINTVERSE_AI_TOKEN must contain at least 32 characters")
    host = os.environ.get("POINTVERSE_AI_HOST", "100.89.246.35")
    port = int(os.environ.get("POINTVERSE_AI_PORT", "11435"))
    ThreadingHTTPServer((host, port), Handler).serve_forever()


if __name__ == "__main__":
    main()
