# Mac mini AI and storage node

The Mac mini is the private compute and durable-storage node for `dianjie.org`.
It must not expose Ollama, PostgreSQL, or attachment storage directly to the public Internet. The public server reaches it over Tailscale.

## AI

Experimental desktop backend: set `POINTVERSE_CHAT_BACKEND=screenprobe` and `POINTVERSE_DESKTOP_USER_ID` to an explicitly authorized account UUID. The application overwrites `X-PointVerse-Authenticated-User` from its authenticated user, and the private gateway selects the desktop adapter only for that UUID. Other accounts remain on Ollama. The private gateway bearer key remains mandatory; the identity header alone does not authorize a caller. It starts unarmed: after opening a dedicated test chat, an operator writes mode-600 `screenprobe-ready` in the support directory with JSON `{"allow_next":true}`. This accepts any prompt from the authorized account, once, within five minutes; it performs no prompt-content routing. Requests from that account while unarmed return 422 to prevent automatic retries. The runner has a 240-second timeout, kills its process group on timeout, and removes captured screenshots and candidate text after reading. The runner reads the latest completed assistant message using its heading and copy action; this remains experimental UI automation. This is a single-account experiment, not multi-user desktop isolation. Remove the backend environment override to restore Ollama.

Ollama remains bound to localhost. `ai_gateway.py` exposes only the chat-completions route on the Mac mini's Tailscale address and requires a private bearer token shared with the VPS. The production default is `qwen3.5:4b`. Public aliases `pointverse-cloud` (fast/default) and `pointverse-cloud-enhanced` (quality) resolve to `qwen3.5:4b` and `qwen3.5:9b` respectively. Install both on each chat worker. Unknown model names fall back to the configured default; callers cannot load arbitrary models. Thinking is disabled for bounded visible replies. The repository's Qwen3-VL file still needs its matching vision projector before image input can be enabled.

Run `install-worker.sh /path/to/pointverse-ai-token` on each additional Mac after installing Tailscale, Ollama, and the selected model. Add the resulting Tailscale URL to the VPS `AI_UPSTREAM_URL` comma-separated list. An optional `|weight` gives faster machines more initial capacity, for example `http://100.64.0.1:11435/v1/chat/completions|2.5,http://100.64.0.2:11435/v1/chat/completions|1`. The coordinator continuously adjusts placement using observed response latency and active request count. Repeatedly failing nodes are temporarily removed and automatically retried after a backoff period.

## Storage

### Optional speech adapter

Create a Python 3.11 virtual environment at `~/Library/Application Support/PointVerse/runtime`, install `speech-requirements.lock`, and run `install-speech.py` with that environment's Python. It installs pinned Whisper large-v3-turbo (approximately 1.51 GiB) with upstream SHA256/Git-blob checks, a 2 GiB model budget and a 10 GiB reserve. The runner uses CPU int8 with four threads, a 120-second execution timeout, and exits after each task. The gateway unloads chat models before transcription and keeps one shared execution slot.

`POINTVERSE_SPEECH_MODEL` allows only `whisper-large-v3-turbo` (default) or `whisper-small` (operator rollback). No caller-selected model path or automatic model download is accepted. Capabilities and transcription responses report the actual model.

Native `/v1/ai/audio/transcriptions` uses Bearer authentication; browser `/web/ai/audio/transcriptions` uses host-scoped cookies plus an Origin check. Both accept JSON `{"audio":"<base64 WAV>"}`, mono PCM16 16 kHz, at most 120 seconds and an 8 MiB body. Chinese text and segment text are normalized to Simplified Chinese using OpenCC t2s; other languages and timestamps stay unchanged. `raw_text` is included only when conversion changed the model's output. Historical user records are not rewritten. Temporary recognition audio is deleted after each request; H5 saves WAV and reviewed text separately only when the user clicks save.

### Small-disk worker policy

The current 16 GiB Mac mini executes one inference at a time, admits two waiting requests, and rejects queue waits over 10 seconds. The gateway allowlists the two cloud models, unloads the alternate model under the shared execution lock before inference, caps output at 512 tokens, and rejects new work below 10 GiB free space. These are process-local limits shared by this gateway's requests; direct Ollama callers are outside this limiter. Keep Ollama private.

The worker installer checks an 8 GiB model budget and requires 14 GiB free before adding the approximately 2 GiB chat model, allowing download headroom. This conservative check sums tag sizes and can double-count shared layers. It does not delete existing models. Model downloads outside the installer are outside this budget. Authenticated `GET /v1/capabilities` reports only the verified chat model and node limits; image and audio adapters are not yet enabled. Add all future adapters behind the same device-wide execution budget.

Production data currently lives on the Mac mini internal disk under `~/Library/Application Support/PointVerse/data`, with separate `postgres` and `cloud` directories. Migration backups are in `backups`, and model files are separate. PostgreSQL 17 listens only on localhost port 15432; the native application listens on the Tailscale address port 8081. The VPS serves public H5 static assets and proxies API requests over HTTPS, with no production database or attachment store.

An external APFS volume can be adopted in a later verified migration. Require its expected identity and mount at startup and never silently fall back to the internal disk. The current Mac database is authoritative. A local migration backup is not an independent disaster-recovery backup; arrange a separate backup target before relying on this as the sole durable copy.
# External providers

The disabled external adapter boundary and future integration requirements are documented in [EXTERNAL_MODELS.md](EXTERNAL_MODELS.md). Production inference stays on the Mac mini until an external provider is explicitly configured and authorized.
