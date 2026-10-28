#!/bin/zsh
set -euo pipefail

if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo "usage: $0 /path/to/pointverse-ai-token" >&2
  exit 2
fi
command -v tailscale >/dev/null || { echo "Tailscale is required" >&2; exit 1; }
command -v ollama >/dev/null || { echo "Ollama is required" >&2; exit 1; }

python3 - <<'PY'
import json, os, shutil, urllib.request
with urllib.request.urlopen("http://127.0.0.1:11434/api/tags", timeout=5) as response:
    models = json.load(response).get("models", [])
installed = any(m.get("name") == "qwen2.5:3b" for m in models)
used = sum(m.get("size", 0) for m in models)
free = shutil.disk_usage(os.path.expanduser("~")).free
# Conservative tag-size sum may count shared layers twice; never underestimates.
if not installed and (used + 2 * (1 << 30) > 8 * (1 << 30) or free < 14 * (1 << 30)):
    raise SystemExit("Insufficient model budget: reserve 10 GiB free, 4 GiB download headroom, 8 GiB model budget")
PY
ollama pull qwen2.5:3b

worker_ip="$(tailscale ip -4 | head -1)"
[[ -n "$worker_ip" ]] || { echo "Tailscale is not connected" >&2; exit 1; }
token="$(tr -d '\r\n' < "$1")"
[[ ${#token} -ge 32 ]] || { echo "token is too short" >&2; exit 1; }

support="$HOME/Library/Application Support/PointVerse"
plist="$HOME/Library/LaunchAgents/org.dianjie.ai-gateway.plist"
install -d -m 700 "$support" "$HOME/Library/LaunchAgents"
install -m 700 "${0:A:h}/ai_gateway.py" "$support/ai_gateway.py"
install -m 700 "${0:A:h}/screenprobe_backend.py" "$support/screenprobe_backend.py"

POINTVERSE_WORKER_IP="$worker_ip" POINTVERSE_WORKER_TOKEN="$token" \
POINTVERSE_WORKER_SCRIPT="$support/ai_gateway.py" POINTVERSE_WORKER_PLIST="$plist" \
python3 - <<'PY'
import os, plistlib
p = {
    "Label": "org.dianjie.ai-gateway",
    "ProgramArguments": ["/usr/bin/python3", os.environ["POINTVERSE_WORKER_SCRIPT"]],
    "EnvironmentVariables": {
        "POINTVERSE_AI_TOKEN": os.environ["POINTVERSE_WORKER_TOKEN"],
        "POINTVERSE_AI_HOST": os.environ["POINTVERSE_WORKER_IP"],
        "POINTVERSE_AI_PORT": "11435",
        "POINTVERSE_AI_MODEL": "qwen2.5:3b",
        "POINTVERSE_MIN_FREE_GIB": "10",
    },
    "RunAtLoad": True,
    "KeepAlive": True,
    "StandardOutPath": os.path.expanduser("~/Library/Logs/pointverse-ai-gateway.log"),
    "StandardErrorPath": os.path.expanduser("~/Library/Logs/pointverse-ai-gateway.error.log"),
}
with open(os.environ["POINTVERSE_WORKER_PLIST"], "wb") as f:
    plistlib.dump(p, f)
os.chmod(os.environ["POINTVERSE_WORKER_PLIST"], 0o600)
PY

launchctl bootout "gui/$(id -u)/org.dianjie.ai-gateway" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$plist"
curl --fail --silent "http://$worker_ip:11435/healthz"
echo
echo "worker ready: http://$worker_ip:11435/v1/chat/completions"
