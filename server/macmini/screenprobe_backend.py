"""Experimental desktop adapter. No UI work occurs until locally armed."""
import json
import os
import signal
import subprocess
import tempfile
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SCRIPT = Path(os.environ.get("POINTVERSE_SCREENPROBE_SCRIPT", "/Users/alex/work/pointverse/tools/mac-ai-bridge/screenprobe.sh"))
ARM_FILE = ROOT / "screenprobe-ready"

def ready():
    try:
        return SCRIPT.is_file() and ARM_FILE.is_file() and time.time() - ARM_FILE.stat().st_mtime < 300
    except OSError:
        return False

def complete(messages):
    if not ready():
        raise RuntimeError("desktop_not_armed")
    if any(not isinstance(m, dict) or m.get("role") not in ("system", "user", "assistant")
           or not isinstance(m.get("content"), str) for m in messages):
        raise ValueError("invalid_messages")
    prompt = messages[0]["content"] if len(messages) == 1 else "\n\n".join(
        m["role"] + ":\n" + m["content"] for m in messages)
    if not prompt.strip() or len(prompt) > 12000:
        raise ValueError("desktop_prompt_limit")
    approval = json.loads(ARM_FILE.read_text())
    if approval.get("allow_next") is not True:
        raise ValueError("desktop_not_armed")
    # One-shot arming avoids subsequent/background jobs using the same desktop.
    ARM_FILE.unlink()
    with tempfile.TemporaryDirectory(prefix="pointverse-screenprobe-") as output:
        diagnostic = Path(output) / "stderr.txt"
        errors = diagnostic.open("wb")
        process = subprocess.Popen([str(SCRIPT), "--app", "com.openai.codex", "--confirmed-work-placeholder",
            "--type", prompt, "--send", "--output", output], stdout=subprocess.DEVNULL,
            stderr=errors, start_new_session=True)
        try:
            process.wait(timeout=240)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            errors.close()
            raise RuntimeError("desktop_response_timeout")
        except BaseException:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise
        if process.returncode:
            errors.close()
            import sys
            print("ScreenProbe diagnostic: " + diagnostic.read_text(errors="replace")[-2000:], file=sys.stderr, flush=True)
            raise RuntimeError("desktop_execution_failed")
        errors.close()
        answers = list(Path(output).glob("*/answer.txt"))
        if len(answers) != 1:
            raise RuntimeError("desktop_answer_missing")
        text = answers[0].read_text().strip()
        if not text or len(text) > 64000:
            raise RuntimeError("desktop_answer_invalid")
    return {"id": "chatcmpl-" + uuid.uuid4().hex, "object": "chat.completion", "created": int(time.time()),
            "model": "codex-desktop-experimental", "choices": [{"index": 0,
            "message": {"role": "assistant", "content": text}, "finish_reason": "stop"}]}
