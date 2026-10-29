# Mac mini AI and storage node

The Mac mini is the private compute and durable-storage node for `dianjie.org`.
It must not expose Ollama, PostgreSQL, or attachment storage directly to the public Internet. The public server reaches it over Tailscale.

## AI

Experimental desktop backend: set `POINTVERSE_CHAT_BACKEND=screenprobe` and `POINTVERSE_DESKTOP_USER_ID` to an explicitly authorized account UUID. The application overwrites `X-PointVerse-Authenticated-User` from its authenticated user, and the private gateway selects the desktop adapter only for that UUID. Other accounts remain on Ollama. The private gateway bearer key remains mandatory; the identity header alone does not authorize a caller. It starts unarmed: after opening a dedicated test chat, an operator writes mode-600 `screenprobe-ready` in the support directory with JSON `{"allow_next":true}`. This accepts any prompt from the authorized account, once, within five minutes; it performs no prompt-content routing. Requests from that account while unarmed return 422 to prevent automatic retries. The runner has a 240-second timeout, kills its process group on timeout, and removes captured screenshots and candidate text after reading. The runner reads the latest completed assistant message using its heading and copy action; this remains experimental UI automation. This is a single-account experiment, not multi-user desktop isolation. Remove the backend environment override to restore Ollama.

Ollama remains bound to localhost. `ai_gateway.py` exposes only the chat-completions route on the Mac mini's Tailscale address and requires a private bearer token shared with the VPS. The production default is `qwen3.5:4b`. Public aliases `pointverse-cloud` (fast/default) and `pointverse-cloud-enhanced` (quality) resolve to `qwen3.5:4b` and `qwen3.5:9b` respectively. Install both on each chat worker. Unknown model names fall back to the configured default; callers cannot load arbitrary models. Thinking is disabled for bounded visible replies. 

Run `install-worker.sh /path/to/pointverse-ai-token` on each additional Mac after installing Tailscale, Ollama, and the selected model. Add the resulting Tailscale URL to the VPS `AI_UPSTREAM_URL` comma-separated list. An optional `|weight` gives faster machines more initial capacity, for example `http://100.64.0.1:11435/v1/chat/completions|2.5,http://100.64.0.2:11435/v1/chat/completions|1`. The coordinator continuously adjusts placement using observed response latency and active request count. Repeatedly failing nodes are temporarily removed and automatically retried after a backoff period.

## Storage

### Cloud speech: Qwen3-ASR-1.7B

Production uses `qwen3-asr-1.7b` on Apple Silicon via MLX Audio 0.6.3, in a separate `asr-runtime` Python 3.11 environment. The selected weights are the 8bit conversion `mlx-community/Qwen3-ASR-1.7B-8bit` (upstream `Qwen/Qwen3-ASR-1.7B`), pinned at `a8379a2e2f9e313c9292cdf1af4055ab56d50d55`, approximately 2.30 GiB. `qwen-asr-model.json` pins every file's SHA-256 or Git-blob hash; `qwen-asr-requirements.lock` records the tested runtime. The pinned MLX wheel requires macOS 26 or later. Runtime code/packages stay on the internal disk; model weights and Hugging Face model caches are on the external volume.

The public native `/v1/ai/audio/transcriptions` and browser `/web/ai/audio/transcriptions` contracts stay unchanged: authenticated JSON `{"audio":"<base64 WAV>"}`, mono PCM16 16 kHz, at most 120 seconds and an 8 MiB body. iOS and Android can select the existing cloud transcription route without a new app build. The response reports the actual model, `backend=mlx`, `precision=8bit`, detected language and chunk-level segments. Qwen cuts long audio at low-energy boundaries around 30 seconds; these are chunk timestamps, not forced word alignment. Chinese and Cantonese segments are normalized to Simplified Chinese; other language segments remain unchanged and `raw_text` is retained when normalization changes text. Partial/token-exhausted output is rejected.

The gateway retains its one shared inference slot, unloads its two chat models before recognition, invokes the worker with a 120-second timeout and deletes temporary WAV files. The one-shot worker uses only the local verified model and exits to release GPU memory. MLX has an 8 GiB memory limit and a 256 MiB cache limit. No request can choose a model path, trigger a download or fall back to internal model storage.

Whisper large-v3-turbo and Whisper-small remain available on the external volume for operator rollback. `POINTVERSE_SPEECH_MODEL` allows those two older models plus `qwen3-asr-1.7b`; the legacy runtime is unchanged. Old workers retain their Whisper default until explicitly configured.

### External model storage

The production volume is `/Volumes/PointVerseData` (APFS UUID `0EA22AF4-CEDD-4E8D-9C17-81C7E4E0AD80`). PointVerse models live at `/Volumes/PointVerseData/PointVerse/models`; `~/Library/Application Support/PointVerse/models` links there. The Hugging Face model cache is `/Volumes/PointVerseData/PointVerse/huggingface/hub`, with a compatible link from `~/.cache/huggingface/hub`. Existing Ollama weights already live at `/Volumes/PointVerseData/Ollama/models` through `~/.ollama/models`.

The gateway launch agent pins `POINTVERSE_MODEL_ROOT`, `POINTVERSE_MODEL_VOLUME` and `POINTVERSE_MODEL_VOLUME_UUID`. `model_storage.py` checks the mounted external device identity, path containment and free space before admitting model work. A missing/replaced/unmounted disk rejects inference; it never creates an internal replacement directory or silently downloads weights. Reconnect the expected volume before restarting service.

Deployment tools:

1. Create `asr-runtime` with Python 3.11 and install `qwen-asr-requirements.lock`.
2. Copy existing models and Hugging Face model cache to the intended external paths; retain originals until verification.
3. Run `install-qwen-asr.py --volume /Volumes/PointVerseData --volume-uuid 0EA22AF4-CEDD-4E8D-9C17-81C7E4E0AD80`. Downloads are resumable, bounded and hash-verified. The range downloader honors 429 backoff and can reduce concurrency; HTTP tools inherit the operator's configured system proxy.
4. Run `activate-qwen-asr.py` with the same volume arguments and `--sample /path/to/known-chinese-test.wav`. It verifies copies, preserves live gateway differences via a three-way merge, backs up private configuration, switches model/cache links and tests real speech before enabling Qwen. Failure restores the previous service; model copies remain safe.
5. Run `verify-qwen-asr.py --samples /path/to/synthetic-wavs` (or `--via-vps`) against the public HTTPS API. This uses a short-lived isolated test identity and removes it and its session in `finally`.
6. After successful public verification, use `finalize-external-models.py --backup <activated-backup-directory>`. It verifies the active volume, links and service, rechecks file hashes, and removes only the matching internal model duplicate backups. Code and private configuration backups remain available for rollback.

The deployment verified a Chinese sentence, English, a 30.85-second mixed-language recording and digital silence through the production HTTPS endpoint. Private-node inference for that 30.85-second recording took about 4.8 seconds in the test; Internet upload/round-trip time is additional. Storage/format/gateway tests: 25 passed. No production user recordings were used for verification.

### Small-disk worker policy

The current 16 GiB Mac mini executes one inference at a time, admits two waiting requests, and rejects queue waits over 10 seconds. The gateway allowlists the two chat models, unloads the alternate model under the shared execution lock before inference, caps output at 512 tokens, and rejects new work below 10 GiB free space. These are process-local limits shared by this gateway's requests; direct Ollama callers are outside this limiter. Keep Ollama private.

The worker installer historically checks an 8 GiB model budget and requires 14 GiB free before adding the approximately 2 GiB chat model, allowing download headroom. This conservative check sums tag sizes and can double-count shared layers. It does not delete existing models. Model downloads outside the installer are outside this budget. Authenticated `GET /v1/capabilities` reports the actual ready adapters and shared node limits. Qwen speech and the existing media adapters use the same device-wide execution budget.

Production data currently lives on the Mac mini internal disk under `~/Library/Application Support/PointVerse/data`, with separate `postgres` and `cloud` directories. Migration backups are in `backups`, and model files are separate. PostgreSQL 17 listens only on localhost port 15432; the native application listens on the Tailscale address port 8081. The VPS serves public H5 static assets and proxies API requests over HTTPS, with no production database or attachment store.

An external APFS volume can be adopted in a later verified migration. Require its expected identity and mount at startup and never silently fall back to the internal disk. The current Mac database is authoritative. A local migration backup is not an independent disaster-recovery backup; arrange a separate backup target before relying on this as the sole durable copy.
# External providers

The disabled external adapter boundary and future integration requirements are documented in [EXTERNAL_MODELS.md](EXTERNAL_MODELS.md). Production inference stays on the Mac mini until an external provider is explicitly configured and authorized.

The external-model migration removed 7,351,200,965 bytes of verified duplicate internal weights/cache. Small code and private configuration backups remain under the support deployment-backups directory; runtime packages remain internal.
