# PointVerse distributed AI architecture

Status: incremental implementation. The Mac gateway supports bounded text chat and optional one-shot Whisper base speech recognition behind the same execution slot. The service includes an authenticated JSON audio transcription route. Image generation, durable jobs, heartbeat registration and iOS cloud audio integration remain planned.

## Symmetric capability contract

iOS and Mac workers use the same capability identifiers and task semantics. A node advertises installed, verified models only. Symmetry means compatible interfaces and portable tasks; it does not require identical model binaries or hardware. Cloud execution remains an explicit user choice for locally processed private content. Never silently send local-only jobs to the cloud.

| Capability | Input → output | Remote API |
| --- | --- | --- |
| language | messages → text | POST /v1/ai/chat/completions |
| imageGeneration | prompt and options → image asset | asynchronous job |
| embedding | text → vector with model and dimension | POST /v1/ai/embeddings |
| vision | text and image assets → text | chat with declared vision model |
| speech | audio asset → transcript with timestamps | asynchronous job |
| audioUnderstanding | audio asset and question → text | asynchronous job |
| speechSynthesis | text and voice → audio asset | asynchronous job |

The first six identifiers match ExternalModelCapability on iOS. speechSynthesis must be added to the shared client contract when its UI and runtime adapter are implemented.

## Topology

Clients reach dianjie.org over HTTPS with their user session. The VPS terminates HTTPS, serves public H5 assets directly, and streams API requests over Tailscale to the Mac application/data node, which authenticates, validates and schedules work. User accounts, sessions, attachments and durable jobs belong on the Mac data node, not the VPS. Workers communicate only over Tailscale; individual revocable node credentials are planned beyond the current shared gateway key. Ollama, image runtimes, speech runtimes and storage stay private.

Each worker may host several adapters: chat, image generation, transcription, audio understanding and speech synthesis. The adapter translates the shared task into the installed runtime's API. iOS Core ML models and Mac runtime models may differ while satisfying the same task contract.

## Registration and heartbeat

A provisioned node identity registers capabilities, exact model revision, memory requirements, concurrency limits and supported input/output formats. The coordinator validates these against an operator-managed allowlist. Heartbeats report process health, active tasks, queue depth, available memory and thermal state. A missing heartbeat expires the node lease and stops new assignments.

Node credentials cannot access user accounts, list other users' assets, or enroll arbitrary new nodes. Job-scoped authorization permits a worker to read only its assigned inputs and write its own outputs. Do not return node URLs or internal credentials to clients.

## Placement

Filter by capability, model revision, input limits, free memory, runtime availability and user execution policy before scoring eligible nodes. Embeddings must use a compatible model revision and dimension; never mix incompatible vector spaces in one index.

Estimate completion cost from queue delay + transfer cost + execution cost. Track network round trip and throughput separately from model latency. Track prefill, first token, tokens/second, image steps/second and audio real-time factor by model and task size. Seed estimates from a reproducible benchmark, then update using measured moving averages. Include model loading cost and a preference for already loaded models.

Reserve a node slot atomically and hold it until the entire response or job completes, including streaming. Enforce per-model and whole-device memory/concurrency budgets: image generation and language inference on the same Mac compete for the same memory. A GPU-heavy task may reserve the device exclusively. Performance weights alone cannot prevent overload.

Nodes return to service through a single limited recovery probe after a circuit-breaker cooldown. Avoid routing all waiting requests to a recovering node. Client cancellation must not count as node failure. Bounded connect, queue and execution deadlines are separate. Never wait five minutes for an unreachable node before attempting failover.

## Durable job protocol

Use durable jobs for image/audio tasks: create → queued → leased → running → succeeded/failed/cancelled. Persist model revision, input hashes, owner, progress and output assets. Use an idempotency key and lease generation to prevent duplicate client submissions and stale worker results. A worker renews its lease; expired leases can be reassigned with bounded retries. Cancellation is propagated to the runtime and releases resources.

Store uploads once as user-owned assets and pass references to workers. Enforce upload size, decoded image dimensions and audio duration before scheduling. A job may only reference assets owned by its user. Return expiring authorized asset access instead of embedding large base64 payloads in queue records. Interrupted partial outputs are never marked successful.

## Storage

Keep the current authoritative database until external storage has been mounted, verified and backed up. Move asset storage to the external disk as a separate migration. Require the expected volume identity at startup; never fall back silently to the Mac system disk. A second Mac improves compute availability but does not make one external disk highly available. Replication and tested restore procedures are required separately.

## Rollout

1. Fix chat slot accounting, stream completion measurement, bounded failover and recovery probes; add scheduler metrics.
2. Add versioned node registration, authenticated heartbeats and capability discovery. Discovery must distinguish installed, ready and unavailable states.
3. Implement durable jobs and asset authorization, then add one image adapter and one transcription adapter on the current Mac. Verify memory budgets and cancellation under concurrent load.
4. Add speech synthesis and audio understanding adapters, then implement the iOS cloud capability selection and task progress UI. Keep local/cloud execution visible and preserve local-only defaults where configured.
5. Enroll a second Mac with its own key. Test mixed hardware load, network loss, worker restart, expired leases, incompatible models and recovery. Enable additional capabilities only after real inference and output-format validation.

Before choosing runtime/model packages, inventory each Mac's chip, RAM, OS, available disk and expected uptime. Model choice is per capability and hardware class; do not assume old Intel Macs support the same acceleration as Apple silicon.
