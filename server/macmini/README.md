# Mac mini AI and storage node

The Mac mini is the private compute and durable-storage node for `dianjie.org`.
It must not expose Ollama, PostgreSQL, or attachment storage directly to the public Internet. The public server reaches it over Tailscale.

## AI

Ollama remains bound to localhost. `ai_gateway.py` exposes only the chat-completions route on the Mac mini's Tailscale address and requires a private bearer token shared with the VPS. The production text model is `qwen2.5:3b`, a non-reasoning model that returns visible text within the client's short output budgets. Set `AI_MODEL=qwen2.5:3b` on the VPS and install the same model on every worker. The repository's Qwen3-VL file still needs its matching vision projector before image input can be enabled.

Run `install-worker.sh /path/to/pointverse-ai-token` on each additional Mac after installing Tailscale, Ollama, and the selected model. Add the resulting Tailscale URL to the VPS `AI_UPSTREAM_URL` comma-separated list. An optional `|weight` gives faster machines more initial capacity, for example `http://100.64.0.1:11435/v1/chat/completions|2.5,http://100.64.0.2:11435/v1/chat/completions|1`. The coordinator continuously adjusts placement using observed response latency and active request count. Repeatedly failing nodes are temporarily removed and automatically retried after a backoff period.

## Storage

Production data will live on an external APFS volume. Set the final mount path only after the disk is connected. Services must require the mount to exist and must not silently fall back to the Mac system disk. Keep separate directories for PostgreSQL data, attachments, models, and backups.

The existing public-server database remains authoritative until the external disk is mounted, initialized, backed up, restored, and verified.
