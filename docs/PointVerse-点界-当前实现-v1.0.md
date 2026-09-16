# 点界 PointVerse 当前实现状态

> 版本：v1.0
> 日期：2026-09-13
> 范围：`ios/` 原生工程（截至提交 `0b0c7db`）
> 目的：如实记录代码库已经落地的能力，与《核心语音POC v0.9》《技术方案 v0.9》两份设计文档做对照，标注简化、扩展与未实现项。本文不代表产品方向的最终结论，只反映工程现状。

> 2026-09-15 精简版更新：iPhone 已移除 Whisper、Qwen、Qwen-VL、Stable Diffusion 的构建与运行时依赖，语音转写统一使用 Apple Speech 强制端侧模式，图片文字使用 Vision OCR，标题使用转写首句规则生成。新增 SceneKit 3D 星图作为 Point 浏览入口；当前连线仅为视觉布局提示，尚未持久化关系语义。

## 0 结论摘要

工程已经超出 POC 文档定义的"录音 → 转写 → 单一标题"范围，长成了一个多模态本地优先应用：语音捕获、拍照/相册配图、图片生成（显影）、逐点对话（Chat）、四语言界面切换均已实现并可运行。但在"结构化整理"和"可靠任务调度"两处核心设计上，实现比文档设想的简单：

- LLM 只产出**标题**一个字段，POC 设计的 `summary/tags/nextQuestion` 结构化输出留在类型定义里，从未被真正生成过。
- `durable_tasks` 表按文档设计写入，但没有任何代码读取它做重试/续租；真实的"任务队列"是启动时扫描一遍未完成转写并重跑一次。
- FTS5 全文索引表持续维护写入，但搜索查询实际走的是 `LIKE` 模糊匹配，索引表是写而不读的死代码路径。

同时，图片生成（Stable Diffusion 2.1 本地推理）、点内拍照与视觉理解（Qwen3-VL）、逐点对话、四语言本地化系统，均是两份设计文档完全没有提及的新增能力。

## 1 总体架构

```text
PointVerseApp (SwiftUI, iOS 17+)
├── Features/Capture          录音、拍照采样、语言选择
├── Features/PointDetail      转写、对话、显影、照片管理
├── Features/PointList        列表与搜索
├── Features/ModelSettings    模型下载/校验/卸载
├── Features/ImageGeneration  独立文生图/图片取字工具
└── App                       多语言容器、后台下载事件

PointVerseKit (Swift Package)
├── Domain        值类型 DTO：PointID/StoredAudio/PointImage/PointDraft…
├── Infrastructure
│   ├── Database  GRDB + SQLite，两次迁移 v1/v2
│   ├── Storage   AudioBlobStore / ImageBlobStore（内容寻址、路径穿越防护）
│   └── Models    ModelRegistry + ModelExecutionGate（全局单模型互斥锁）
└── UseCases      CaptureUseCase（actor，串行化一次录音生命周期）

Vendor
├── WhisperRuntime   whisper.cpp 静态 XCFramework
└── LlamaRuntime     llama.cpp 静态 XCFramework（含 mtmd 多模态 API）

外部依赖（project.yml）
├── ml-stable-diffusion（Apple）→ Core ML Stable Diffusion 2.1 Base
└── ZIPFoundation → 解压图生成模型包
```

四个 Tab：记录（Capture）、想法（PointList）、模型（ModelSettings）、图片（ImageGeneration）。

## 2 领域模型（与 POC 设计的差异）

`PointVerseKit/Sources/PointVerseKit/Domain/Models.swift` 是一组 `Sendable` 值类型，不是 ORM 对象图。

| 类型 | 说明 |
| --- | --- |
| `VoiceCaptureCommand` | 携带 `operationID`，是幂等机制的入口 |
| `StoredAudio` | 落盘后的音频元数据（路径、sha256、时长、编码） |
| `PointImage` | **新增概念**：点上挂载的一张图片，含 `recognizedText`（OCR 或生成 prompt） |
| `ConversationMessage` | **新增概念**：点内的对话消息（用户/模型） |
| `PointDraft` | POC 设想的结构化产出（title/summary/tags/nextQuestion），**只在测试中被构造过，生产代码从未使用** |

结论：POC 文档"标题 + 摘要 + 标签 + 下一问"的结构化整理契约，在实现里被简化为**只生成标题**。`derivations` 表里的 `summary/tags_json/next_question/raw_json` 列仍在 schema 中，但没有任何 INSERT 语句写入过。

## 3 数据库

GRDB + SQLite，`DatabaseMigrator` 两次迁移：`v1`（POC 设计的核心表）、`v2-point-images`（新增图片表）。

### v1（基本照抄 POC 设计）

`points`、`messages`（`operation_id` 唯一约束承担幂等）、`audio_assets`、`transcripts`、`derivations`、`durable_tasks`、`point_search`（FTS5, `unicode61`）— 表结构与 POC 文档第 7.1 节几乎一致。

### v2 新增

```sql
CREATE TABLE point_images (
  id TEXT PRIMARY KEY NOT NULL,
  point_id TEXT NOT NULL REFERENCES points(id) ON DELETE CASCADE,
  relative_path TEXT NOT NULL UNIQUE,
  sha256 TEXT NOT NULL,
  byte_count INTEGER NOT NULL,
  recognized_text TEXT,
  created_at REAL NOT NULL
);
```

### 三处"写了但没真正用"的死代码路径

1. **`durable_tasks`**：`commitVoiceCapture` 插入一行 `transcribe` 任务，`saveTranscript`/`failTranscription` 会更新它的状态，但没有任何调度器读取 `next_run_at`/`lease_until` 做重试或续租。真正驱动转写的是 `TranscriptionService.resumePending()`：启动时查一遍 `transcripts.state IN ('queued','running')` 的点，逐个重跑一次——没有退避、没有次数上限、没有崩溃后基于 `operationID` 的重放。
2. **`point_search` FTS5 表**：每次转写/标题/图片 OCR 完成都会 `refreshSearch` 重建索引，但 `listPoints(matching:)` 实际用的是对 `accepted_title`/`user_text`/`engine_text`/`summary`/`tags_json`/`point_images.recognized_text` 做 `LIKE '%...%' ESCAPE '\'` 扫描，从未查询过 `point_search`。
3. **`AssetState.committing`/`.quarantined`**：类型和 CHECK 约束都在，但所有音频资产都直接以 `'available'` 状态写入，没有分阶段提交/隔离审查流程。

幂等机制是真实生效的：`messages.operation_id` 唯一约束 + 插入前查重（`PointDatabase.commitVoiceCapture`），同一 `operationID` 重复提交返回同一个 `PointID`。但这个 ID 只存活在 `CaptureUseCase` actor 的内存里，进程被杀后不会持久化重放——保护的是同一会话内的重复点击/竞态，而不是 POC 设想的"崩溃后凭 operationId 重放"。

## 4 语音捕获与转写

`CaptureUseCase`（`PointVerseKit`）是一个 actor，串行化 `start → finish/cancel` 一次录音的生命周期，`finish` 失败会尝试删除已落盘的音频文件做回滚。`SystemAudioRecorder`（app 层）封装 `AVAudioRecorder`，AAC/M4A、24kHz 单声道；踩过一个坑：`.spokenAudio` 音频模式在真机上触发 `paramErr -50`，改用 `.default` 模式（代码注释有记录）。

转写走 `HybridSpeechRecognizer`：

- 已安装本地 Whisper 模型 → 用 `WhisperRecognizer`（直接调用 whisper.cpp C API），语言只做 zh/ja/en 三选一 + auto 的桶分类，不支持任意 locale 直通；每次转写后销毁 context，不做常驻模型。
- 未安装 → 回退到系统 `SFSpeechRecognizer`（`requiresOnDeviceRecognition = true`）；**模拟器上直接抛错**，提示"请使用真机测试"。

转写成功后立即：写入基于规则的兜底标题（`fallbackTitle`，字符截断+省略号），再异步尝试 LLM 标题生成（`QwenTitleGenerator.generateTitle`）——LLM 只输出纯文本标题，不是 JSON，靠字符串后处理（去除 ChatML 标记、取首行、按语言截断）清洗；失败不重试，直接保留规则标题。

标题的 `model_id` 会拼接界面语言（如 `qwen3-0.6b-q8_0-title-zh-hans`），因此**切换界面语言会让所有点的标题重新生成一遍**。

## 5 本地大模型的实际用途

`QwenTitleGenerator`（llama.cpp 封装）承担三件事，全部是纯文本 prompt + 字符串解析，没有 JSON schema/grammar 约束：

1. 生成标题（见上）。
2. `generateReply`：驱动点内对话功能，把最近 8 轮对话 + 语音转写作为上下文。
3. `translateImagePromptToEnglish`：把中/日文的文生图请求翻译成英文 prompt（因为本地 Stable Diffusion 模型只认英文）。

`QwenVisionGenerator`（同文件内另一个 actor）用 Qwen3-VL + mmproj 投影模型，通过 llama.cpp 的 `mtmd_*` 多模态 API 做图片理解/描述，是转写之外的第二条本地模型链路，POC 文档完全未提及。

全局用一个 `ModelExecutionGate` actor（互斥锁 + FIFO 等待队列）确保 whisper/llama/vision/diffusion 任一时刻只有一个模型在跑——这是工程上应对大模型内存压力的必要设计，两份文档都没写。

## 6 图片生成与拍照能力（全新功能，两份设计文档均未涉及）

- **文生图**：Apple `ml-stable-diffusion` 包运行 Core ML 版 Stable Diffusion 2.1 Base（6-bit 量化），40 步 DPM-Solver++，针对人物/动物主体做了手工的正向/负向 prompt 增强（对抗多肢体、融合爪子等 SD2.1 常见畸变）。
- **图片取字**：Vision 框架 `VNRecognizeTextRequest`，纯系统能力，无需下载模型。
- **拍照/相册配图**：录音过程中可选开启摄像头帧采样（每 1.2 秒一帧，最多 12 帧，事后从中挑最多 5 张保留），或在点详情页手动拍照/选相册图片，统一走正方形裁剪 UI 后存入 `point_images`。
- **"显影"（Manifestation）**：点详情页内的功能，把该点的语音转写 + 已有照片描述 + 最近对话拼成上下文，翻译成英文后调用本地文生图，生成结果可选择"加入想法"存回同一个点的时间线。

拍照配图与文生图共用同一张 `point_images` 表——无论来源是相机、相册还是本地生成，落到数据库里都是同一种记录，只是 `recognized_text` 字段含义不同（OCR 文本 vs 生成用的 prompt）。

## 7 模型管理

`ModelRegistry` 内置 8 个模型清单（3 个 Whisper 量化档位、2 个 Qwen3 语言模型、1 个 Stable Diffusion、2 个 Qwen3-VL 视觉模型+投影模型），每个都带 SHA-256、体积、所需磁盘空间、License、下载镜像。

`ModelDownloadManager` 的实现比两份文档设想的更完整：

- 用后台 `URLSession`（`background` 配置）下载，配合 `AppDelegate` 的 `handleEventsForBackgroundURLSession`，App 被系统挂起后下载不中断。
- 支持断点续传（`resumeData` 落盘复用）。
- 多镜像回退：官方源失败或校验失败自动换镜像（`hf-mirror.com`/`modelscope.cn`，照顾国内网络环境）。
- 安装即校验：SHA-256 通过后才原子改名为正式文件，不一致会自动换源重试。
- **卸载功能已实现**（删除已装/部分下载/续传文件，压缩包类模型连解压目录一起清理）。

## 8 界面与交互

- **CaptureView**：长按录音，可选同步拍照，录音时可临时切换语言；保存后立即跳转详情页，转写在后台异步进行（不阻塞导航）。
- **PointListView**：可搜索列表（走上文提到的 LIKE 查询）、滑动删除、下拉刷新。
- **PointDetailView**：播放原音、转写文字可编辑修正（只写 `user_text`，不覆盖 `engine_text`，符合"源数据不可覆盖"的原则）、失败可重试转写、照片+对话混排的时间线、文字/语音两种方式发消息、"显影"入口、删除点。
- **ModelSettingsView**：界面语言切换 + 各类模型的下载/选择/卸载。
- **ImageGenerationView**：独立的文生图与图片取字工具。

## 9 本地化

`Resources/{en,ja,zh-Hans,zh-Hant}.lproj` 四套语言资源，但**不是**依赖 SwiftUI 原生的 `LocalizedStringKey`/系统 locale——而是自建了一套 `AppLocalization` + `AppText`，通过 `@AppStorage("appLanguage")` 驱动运行时手动查表，允许应用内切换语言立即生效、无需重启系统设置。这套机制两份设计文档完全没有提到。

## 10 与设计文档的偏差一览

**比文档简化的部分**

- 结构化 LLM 产出（title/summary/tags/nextQuestion）→ 只剩标题。
- DurableTask 调度（lease/重试/退避）→ 启动时扫一遍未完成任务重跑一次，无持久化重放。
- FTS5 全文索引 → 写入维护，但搜索走 LIKE，索引未被查询使用。
- 音频资产的 `committing/quarantined` 阶段状态 → 直接落地为 `available`，无隔离审查流程。
- Whisper 多语言支持 → 只桶分为 zh/ja/en/auto 四类。

**文档之外新增的能力**

- 本地文生图（Stable Diffusion 2.1 Core ML）+ "显影"功能。
- 点内拍照/相册配图 + Qwen3-VL 视觉理解。
- 点内对话（Chat）能力，语音/文字均可发消息。
- 四语言、应用内实时切换的自建本地化系统。
- 更完整的模型生命周期管理：后台下载、断点续传、多镜像、卸载。
- 全局 `ModelExecutionGate`，保证本地模型互斥执行。
- 无 Whisper 模型时自动回退系统 `SFSpeechRecognizer`。

**文档规划但未实现的部分**

- 跨设备同步、Apple Watch、3D 点图、关系推荐——两份文档中属于更远期范围的内容，代码中完全没有涉及，符合预期（未提前建设）。

## 11 测试覆盖

`PointVerseKit` 包内两个测试文件，覆盖数据库幂等/搜索/级联删除/转写状态机（`PointDatabaseTests`）和模型校验/断点续传（`ModelRegistryTests`）。App 层（转写编排、LLM 生成、图片生成、UI）目前没有自动化测试覆盖。

## 12 建议关注点（供后续讨论，非结论）

1. `durable_tasks` 和 `point_search` 目前是写入但不消费的表，要么补上真正的调度/检索逻辑，要么考虑简化掉以减少认知负担和维护成本。
2. `PointDraft` 类型已经与实际产出脱节，如果确认不做结构化整理，可以考虑清理测试和类型定义，避免误导后来者。
3. 图片生成、点内对话、拍照配图这几项已是产品的实际组成部分，建议尽快补一份面向这些新能力的设计说明，让 backlog（`docs/backlog.md`）和技术方案与实现同步。
