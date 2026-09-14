# 点界 PointVerse 技术方案

面向 iPhone 与 Apple Watch 的 Swift 本地优先架构

- 版本：0.9 技术草案 0.1
- 日期：2026-09-11
- 依据：《PointVerse 点界 产品文档 v0.9》与最新双端语音交互线框

## 结论

首个原生实现采用 Swift 与 SwiftUI，共享领域模型但不共享界面状态。iPhone 是权威知识库与完整体验载体，Apple Watch 是可独立保存的短语音捕获端。

原音与用户原话属于不可变源数据；转写、摘要、向量、关系和 Play 输出属于可重建或可选择的派生数据。所有保存、同步和模型任务通过明确状态机解耦，确保断网、转写失败或模型不可用时仍能可靠成点。

| 决策 | 方案 |
| --- | --- |
| 客户端 | Swift 6 语言模式评估后启用；SwiftUI 构建 iOS 与 watchOS 界面 |
| 数据 | SQLite 单一事实源；GRDB 作为访问层候选，SQLCipher 或系统数据保护完成加密验证 |
| 语音 | AVFAudio 录制原音；Speech 在能力允许时做本地转写；转写失败不影响保存 |
| 跨端 | WatchConnectivity 后台文件传输；`captureId` 幂等导入；双阶段回执 |
| 3D | RealityKit 渲染可交互点图；文字搜索和列表提供等价入口 |
| 模型 | 能力路由器统一本地与远端；远端每次展示并确认实际输入范围 |

## 1 目标与范围

本文把产品文档 v0.9 与最新 v0.9 双端语音交互转化为可实施的原生客户端方案。目标不是一次性交付全部愿景，而是先建立不会丢原始表达、可以恢复、可以演进的数据与任务骨架。

### 1.1 本期必须支持

- iPhone 大对话流：首次成功发送自动形成一个 Point，后续消息追加到同一点，未发送内容作为本地草稿恢复。
- iPhone 文字与短语音：原音先保存；本地转写异步执行，可失败、重试和人工修正。
- Apple Watch 主动 5–60 秒短语音：手表本地保存后即可反馈成功，随后后台同步到 iPhone。
- 3D 私人空间：旋转、缩放、点选、搜索定位、复位，只突出选中点的直接关系。
- Play：生成前冻结输入及 `ContextSnapshot`，区分本地与远端，结果不覆盖原点。
- 可靠性：断网、杀进程、重复传输、磁盘不足、模型不可用均有可解释状态和恢复路径。

### 1.2 暂不纳入首个工程里程碑

AI 眼镜接入、CloudKit 跨设备知识库同步、公开分享、协同编辑、Agent 外部执行、交易、专用关系模型训练和复杂物理模拟不进入首个里程碑。Apple Watch 是单独的捕获试点，不应成为手机闭环上线的阻塞条件。

## 2 架构原则

| 原则 | 工程约束 | 验收含义 |
| --- | --- | --- |
| 原件优先 | 写入音频文件与 Capture 元数据成功后，才显示已保存 | ASR、摘要、同步失败时仍可播放和导出原音 |
| 本地优先 | 记录、检索和基础整理不依赖账号或网络 | 飞行模式可记录、搜索、浏览和恢复 |
| 源与派生分离 | 派生对象保存 producer、输入版本和状态，不回写源字段 | 修改转写或换模型不改原音与旧结果 |
| 幂等 | 跨端和任务提交使用稳定 `operationId` 或 `captureId` 与唯一约束 | 重复回调、重传、重试不会生成重复 Point |
| 快照不可漂移 | Play 引用冻结的消息、附件和 Point 版本 | 原点后续修改不改变历史显影输入 |
| 能力可降级 | 能力检测先于调度，失败回到关键词、原文和手工操作 | 不因本地模型不可用自动上传远端 |

## 3 总体架构

采用多 Target、共享 Swift Package 的模块化单体。首版不引入自建服务端作为记录链路依赖；远端 Play 通过独立适配器接入，未来同步与分享另立服务边界。

| 层 | 模块 | 职责 |
| --- | --- | --- |
| 界面 | `PhoneApp`、`WatchApp` | SwiftUI 页面、导航、无障碍和状态呈现；不直接访问数据库或模型 SDK |
| 应用 | `CaptureFeature`、`ConversationFeature`、`SpaceFeature`、`PlayFeature` | 用例编排、状态机、用户意图和错误恢复 |
| 领域 | `PointCore` | 实体、值对象、仓储协议、领域事件和不变量 |
| 任务 | `TaskEngine` | 持久化任务队列、重试、取消、资源与网络条件 |
| 能力 | `AudioKit`、`SpeechAdapter`、`ModelGateway`、`WatchBridge`、`GraphRenderer` | 封装 Apple 框架与远端模型差异 |
| 基础设施 | `PointStore`、`BlobStore`、`Crypto`、`Diagnostics` | SQLite、附件目录、密钥、迁移、指标和隐私日志 |

### 3.1 建议工程结构

```text
PointVerse.xcworkspace
├── Apps
│   ├── PointVersePhone
│   └── PointVerseWatch
├── Packages
│   ├── PointCore
│   ├── PointStore
│   ├── CaptureKit
│   ├── TaskEngine
│   ├── ModelGateway
│   ├── GraphSpace
│   └── TestSupport
```

UI Feature 依赖领域协议，基础设施实现协议后在 Composition Root 注入。共享包不得依赖具体 SwiftUI View，避免手表 Target 被手机 UI 和重型模型依赖拖入。

### 3.2 并发模型

使用结构化并发：

- `DatabaseActor` 串行化事务。
- `BlobStoreActor` 负责文件落盘和校验。
- `CaptureCoordinator` 管理录音会话。
- `TaskScheduler` 处理持久化任务。
- 界面模型标记 `@MainActor`。
- WatchConnectivity 回调先进入 bridge actor，再发布领域事件。
- 所有跨 actor 传递的数据使用不可变、`Sendable` 的标识和值对象。

## 4 核心数据模型

SQLite 是元数据与关系的权威来源；音频、图片和大结果保存为受保护文件，数据库只保存相对路径、长度、哈希和 MIME。主键使用 UUID 字符串。所有时间以 UTC 保存，同时记录原始时区偏移。

| 实体 | 关键字段 | 不变量 |
| --- | --- | --- |
| `Point` | `id, title?, status, headRevision, createdAt, updatedAt` | 标题可空；Point 本身不拼接覆盖原文 |
| `PointRevision` | `id, pointId, revision, createdAt, reason` | 修订号单调递增；历史只追加 |
| `CaptureSession` | `id, pointId?, draft, state, revision` | 首次持久消息在事务内创建 Point 并绑定 |
| `Message` | `id, sessionId, sequence, role, modality, state` | `sessionId + sequence` 唯一；用户源消息不可被 AI 改写 |
| `Asset` | `id, messageId, kind, path, sha256, duration, state` | 文件原子落盘后才进入 `available` |
| `Capture` | `captureId, deviceId, capturedAt, location?, syncState` | `captureId` 全局唯一；重复导入返回既有结果 |
| `Transcript` | `id, assetId, engineText, userText?, locale, producer, state` | 修正版另存；不覆盖引擎结果或原音 |
| `ContextSnapshot` | `id, capturedAt, source, note?, location?, pointVersionRefs` | 创建后不可变；未知字段为空 |
| `Relation` | `fromPoint, toPoint, type, evidence, producer, confirmation` | 推断与用户确认分开；引用版本可追踪 |
| `PlaySession` | `id, snapshotId, perspective, execution, status, model` | 确认后输入清单冻结；状态只按状态机迁移 |
| `Result` | `id, playSessionId, payloadRef, adoption, createdAt` | 草稿结果不自动进入空间；采纳是显式动作 |
| `DurableTask` | `id, type, payload, state, attempts, nextRunAt` | `operationId` 唯一；有界重试且崩溃可恢复 |

### 4.1 关键数据库约束

```sql
UNIQUE(captures.capture_id)
UNIQUE(messages.session_id, messages.sequence)
UNIQUE(point_revisions.point_id, point_revisions.revision)
UNIQUE(durable_tasks.operation_id)

-- 历史快照使用限制删除
FOREIGN KEY ... ON DELETE RESTRICT

-- 可重建派生数据使用级联删除
FOREIGN KEY ... ON DELETE CASCADE
```

历史快照不直接外键到会被删除或更新的可变行，而应保存版本引用与必要的显示副本。删除 Point 时先生成 tombstone，并在一个事务中清理当前关系、搜索索引和未完成派生任务；被历史 Play 引用的最小来源元数据保留到用户明确清除历史。

### 4.2 存储与加密决策

首选方案为 SQLite + GRDB，并在技术探测中比较两种加密路径：

- A：使用 SQLCipher 完成数据库级加密。
- B：使用系统 Data Protection 保护数据库、WAL、SHM 与附件，并以 Keychain 保存应用级密钥，用于加密导出包。

选择门槛是冷启动、迁移、崩溃恢复、备份恢复和 1,000 Point 性能，而不是 API 简洁度。SwiftData 可用于早期界面原型，但在唯一约束、FTS、显式事务、加密文件与迁移验证完成前，不作为持久层最终承诺。

## 5 捕获与自动成点

### 5.1 iPhone 文本事务

1. 用户发送时生成 `messageId` 和 `operationId`；空会话先保持 draft，不创建 Point。
2. `DatabaseActor` 开启事务：若 `session.pointId` 为空，则创建 Point、首个 `PointRevision` 和 `Message`；否则追加 Message 并递增修订。
3. 提交成功后 UI 才显示“已保存”；失败保留 composer 内容与 `operationId`，允许原请求重试。
4. 同一 `operationId` 再次提交直接返回既有 Message，避免重复点击或恢复重放造成重复成点。

### 5.2 iPhone 语音事务

1. `AVAudioRecorder` 写入同目录临时文件，限制时长并实时显示录音状态。
2. 完成时先关闭文件、计算校验值，再通过原子 rename 移入 `BlobStore`；同时事务写入 Capture、Asset、Message 和 Point。
3. 提交成功即显示“原音已保存”；随后入队 transcription 与 analysis 两个 `DurableTask`。
4. 转写结果进入 Transcript；用户修改只写 `userText` 和 `editedAt`。ASR 失败只更新派生任务状态。

### 5.3 保存状态

| 状态 | 进入条件 | 允许操作 |
| --- | --- | --- |
| `draft` | 尚未发送或录音未完成 | 编辑、取消 |
| `committing` | 正在写文件和数据库 | 等待；异常退出后由临时文件恢复器判断 |
| `savedLocal` | 原件和元数据事务已完成 | 播放、继续对话、进入同步或派生 |
| `deriving` | ASR 或分析任务执行中 | 浏览、继续记录、取消派生 |
| `derived` | 派生成功 | 查看、修正、重建 |
| `derivationFailed` | 派生失败 | 播放原件、重试或忽略 |

## 6 Apple Watch 到 iPhone 同步

手表不是临时遥控器，而是能独立完成可靠保存的捕获节点。传输采用 WatchConnectivity：音频用后台文件传输，元数据随文件发送；即时消息仅用于在线状态提示和快速回执，不承担可靠交付。

### 6.1 双端协议

| 步骤 | Watch | iPhone |
| --- | --- | --- |
| 1 本地保存 | 生成 `captureId`，保存 m4a 与 `manifest.json`，状态为 `savedOnWatch` | 无要求 |
| 2 排队 | `transferFile(audio, metadata)`，记录 transfer token | 后台接收 |
| 3 导入 | 保留源文件直到收到业务回执 | 校验 schema、哈希和大小；按 `captureId` 幂等事务导入 |
| 4 回执 | 收到 `imported`、`duplicate` 或 `rejected`，更新 UI | 通过可靠 userInfo 发送 `captureId + import result` |
| 5 清理 | 仅 `imported` 或 `duplicate` 后按保留策略清理 | 启动派生任务 |

### 6.2 状态机与异常

```text
recording → committing → savedOnWatch → queued → transferring
                                     ↘ waitingForConnection

transferring → importedOnPhone → acknowledged → eligibleForCleanup
transferring → retryScheduled | rejected
```

- 连接断开：停留在 `savedOnWatch` 或 `queued`，不改变“已在手表保存”的事实。
- 重复传输：iPhone 命中 `captureId` 唯一约束并校验哈希；相同内容返回 `duplicate`，哈希冲突进入 quarantine。
- 磁盘不足：录音结束前若不可提交，不给成功触觉；保留可恢复临时文件时明确提示。
- 回执丢失：Watch 可以重传；iPhone 幂等返回既有导入结果。
- 位置拒绝：`location` 为空并记录 `permissionDenied` 采集状态，不阻塞音频。

### 6.3 Watch 首版范围与职责边界

Apple Watch 首版只承担**主动、短时、可靠的语音捕获**，不在手表执行 Whisper、Qwen、视觉理解或图片生成。所有转写、标题生成、搜索索引与后续对话仍由 iPhone 完成，以控制手表的包体、内存、耗电和发热。

首版必须支持：

- 与 iPhone 首页一致的 `Capture／记录` 心智：按住开始录音，松开结束并保存。
- 单段录音建议限制为 5–60 秒；取消不产生 Capture。
- 手机离线、未启动或暂时不可达时，原音仍先保存在 Watch。
- 最近记录显示 `已保存到手表／等待同步／传输中／已到达 iPhone／同步失败` 等事实状态。
- 保存成功给予触觉反馈，但只有文件和 manifest 均落盘后才能反馈成功。
- 可选择录音语言；位置作为后续可选上下文，不进入首版阻断范围。

首版不做：

- Watch 端转写、标题生成、聊天、图片或显影。
- 后台持续监听或自动开始录音。
- 依赖即时可达性的远程录音控制。
- complication、Widget、Siri／快捷指令和 Action Button；这些在可靠传输通过后单独立项。

### 6.4 Watch 本地记录与共享协议

每次录音生成稳定的 `captureId`，并在 Watch 沙盒中形成音频与 manifest 两个原件：

```text
Application Support/PointVerseWatch/Captures/{captureId}/
├── audio.m4a
└── manifest.json
```

共享协议放在 `PointVerseKit` 的轻量模块中，只包含 `Codable + Sendable` 值类型，不依赖 GRDB、SwiftUI 或任何模型运行时：

```swift
public struct WatchCaptureManifest: Codable, Sendable {
    public let schemaVersion: Int
    public let captureID: UUID
    public let capturedAt: Date
    public let localeIdentifier: String
    public let durationMilliseconds: Int
    public let byteCount: Int64
    public let sha256: String
}

public enum WatchImportResult: String, Codable, Sendable {
    case imported
    case duplicate
    case rejected
}

public struct WatchImportReceipt: Codable, Sendable {
    public let captureID: UUID
    public let result: WatchImportResult
    public let importedAt: Date
    public let rejectionCode: String?
}
```

Watch 保存状态：

```text
recording → committing → savedOnWatch → queued → transferring
                                     ↘ waitingForConnection

transferring → importedOnPhone → acknowledged → eligibleForCleanup
transferring → queued | rejected
```

`captureId` 在整个生命周期保持不变。传输重试不得重新生成 ID；Watch 在收到 `imported` 或 `duplicate` 业务回执之前保留原音。

### 6.5 iPhone 幂等导入

Watch 使用 `WCSession.transferFile(_:metadata:)` 发送音频与 manifest 元数据。`sendMessage` 只可用于双方在线时的即时状态提示，不能承担音频的可靠交付。

iPhone 在 `WCSessionDelegate` 收到文件后必须：

1. 立即将系统提供的临时文件复制到 App 自己的 staging 目录，不能在 delegate 返回后继续依赖临时 URL。
2. 校验 `schemaVersion`、必填字段、文件长度与 SHA-256。
3. 使用 `captureId` 作为现有 `VoiceCaptureCommand.operationID`，复用 `messages.operation_id UNIQUE` 约束完成幂等事务导入。
4. 首次成功返回 `imported`；相同 `captureId + sha256` 再次到达返回 `duplicate`；相同 `captureId` 但哈希不同则拒绝并隔离审查。
5. 数据库提交成功后才启动现有 Whisper 转写和 Qwen 标题链路。
6. 通过 `transferUserInfo` 向 Watch 发送可靠业务回执；回执丢失时允许 Watch 重传，iPhone 必须再次返回既有结果。

建议增加迁移表，记录来源、冲突与回执事实：

```sql
CREATE TABLE watch_imports (
    capture_id TEXT PRIMARY KEY NOT NULL,
    point_id TEXT REFERENCES points(id) ON DELETE CASCADE,
    source_device_id TEXT,
    audio_sha256 TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('importing', 'imported', 'rejected')),
    rejection_code TEXT,
    captured_at REAL NOT NULL,
    imported_at REAL
);
```

`VoiceCaptureCommand` 同时增加 `sourceDevice` 与明确的 `capturedAt`。列表时间使用实际捕获时间，不使用手机收到文件的时间。

### 6.6 工程结构与依赖约束

在现有 `ios/` 工程中新增 Watch target，建议结构如下：

```text
ios/
├── PointVerseWatchApp
│   ├── App
│   ├── Capture
│   ├── History
│   ├── Storage
│   └── Connectivity
├── PointVerseApp
│   └── WatchImport
└── PointVerseKit
    └── WatchTransfer
```

- `PointVerseWatchApp` 只依赖共享协议、AVFAudio、WatchConnectivity 和轻量文件存储。
- Watch target 不得链接 GRDB、whisper.cpp、llama.cpp、Stable Diffusion 或视觉投影框架。
- iPhone 的 `WatchImportCoordinator` 负责回调桥接、校验、文件提交和派生调度；WatchConnectivity delegate 不直接操作 SwiftUI 状态。
- 两端均在启动时激活 `WCSession`，并将系统回调转入各自 actor 后再改变持久化状态。
- Bundle ID、`WKCompanionAppBundleIdentifier`、签名团队与部署版本必须在真机联调前冻结。

### 6.7 后台边界与资源策略

- 普通 Watch App 在用户降腕后可能被挂起，录音应由用户在前台主动开始，并尽快在结束时完成本地提交。
- 文件保存成功后交给 WatchConnectivity 的系统队列机会式传输，不自行维持网络连接或轮询 iPhone。
- 首版 60 秒内的主动捕获不默认引入 `WKExtendedRuntimeSession`。只有真实测试证明降腕会中断有效录音时，才评估合法适用的后台模式；不能仅为了延长运行时间而错误声明 mindfulness、workout 等用途。
- Watch 只计算文件 SHA-256 和必要元数据，不做转写、摘要或压缩重编码。
- 同时限制本地待同步数量与可用磁盘下限；空间不足时停止新录音并明确提示，不自动删除未回执原音。
- WatchConnectivity 的后台行为必须使用真实配对的 iPhone 与 Apple Watch 测试；模拟器结果不作为可靠性证据。

### 6.8 实施批次与验收

| 批次 | 实现内容 | 退出条件 |
| --- | --- | --- |
| W0 工程探测 | 新建 watchOS target；签名、权限、AVAudioRecorder、WCSession 真机连通 | 真机可启动并录制一段 60 秒以内音频 |
| W1 本地可靠捕获 | staging、原子提交、manifest、重启恢复、最近记录状态 | iPhone 关机时 Watch 仍可保存、重启后可播放或重传 |
| W2 后台文件同步 | `transferFile`、iPhone staging 接收、SHA-256 校验 | 两端不同时前台也能最终完成一次传输 |
| W3 幂等导入与回执 | `captureId` 导入、`watch_imports`、`transferUserInfo` 回执 | 重复传输只生成一个 Point；回执丢失后可收敛 |
| W4 派生与体验 | 接入 iPhone Whisper/Qwen；Watch 状态与触觉；错误恢复 | Watch 原音进入现有列表并完成异步转写，派生失败不影响原音 |
| W5 扩展入口 | complication、Widget、快捷指令或 Action Button 单项实验 | 只有可靠闭环通过且入口价值有证据时启动 |

首版阻断验收：

- Watch 已显示“已保存”的原音在重启、断连和手机关机后不得丢失。
- 相同 `captureId` 任意次数重传只生成一个 Point。
- 相同 `captureId` 出现不同哈希时不得静默覆盖。
- iPhone 收到文件但转写或模型失败时，原音仍可播放和再次处理。
- Watch 未收到业务回执前不得清理本地原音。
- 覆盖断连、乱序、重复传输、回执丢失、两端杀进程、磁盘不足和多 Watch 切换测试。

## 7 本地语音与模型能力

### 7.1 能力路由

`CapabilityRegistry` 在运行时依据设备、系统、语言、权限、模型资源、低电量和网络状态，返回 `available`、`preparing`、`unavailable` 或 `requiresConsent`。产品界面展示能力结果，不用编译期假设替代真机探测。

| 能力 | 首选 | 降级 |
| --- | --- | --- |
| 语音转写 | Speech 框架且 `supportsOnDeviceRecognition` 为真；请求强制本地 | 保留原音，允许稍后重试或人工补充 |
| 摘要与标签 | 设备可用的本地模型适配器 | 关键词与规则；不生成也不阻塞 |
| 向量 | 可替换的 `LocalEmbeddingProvider` | FTS5 或关键词召回 |
| Play | 用户选择的本地 Provider | 显示不可用；用户可另行选择远端并确认范围 |
| 朗读 | `AVSpeechSynthesizer` 临时 TTS | 仅显示文本；默认不保存合成音频 |

### 7.2 任务调度

`DurableTask` 保存任务类型、输入版本、前置条件、重试次数和 `nextRunAt`。调度器按 `captureCommit`、`transcription`、`pointAnalysis`、`embedding`、`relationRefresh`、`remotePlay` 分队列并设置并发上限。

不可重试错误直接终止；网络、资源未就绪等错误采用指数退避和抖动。取消只阻断尚未开始或可取消的本地任务，不能承诺追回已发送的远端费用。

## 8 3D 点界

RealityKit 只负责展示和拾取，图关系与布局结果来自 `GraphSpace` 领域模块。点的位置是用户可控布局，不代表事实判断；固定节点带 pin 标记，自动布局不得覆盖。首版只渲染可见节点和选中点的一跳关系。

| 组件 | 职责 | 性能策略 |
| --- | --- | --- |
| `GraphQuery` | 按视口、搜索和关系深度取节点 | 分页与增量加载；不把全量正文送入渲染层 |
| `LayoutEngine` | 生成或恢复 x、y、z 与固定状态 | 后台计算；版本化布局；可取消 |
| `RealityRenderer` | 节点、边、相机、点击和手势 | 实体复用、批量材质、LOD、按需标签 |
| `SelectionModel` | 选中节点和直接关系 | 稳定 ID；更新局部实体 |
| `TextNavigator` | 搜索、列表与辅助访问 | 与 3D 使用同一查询和导航命令 |

性能门：以 1,000 Point 的合成数据在基准设备测试首次可交互时间、旋转帧率、搜索定位时延、选中反馈和内存峰值。若 RealityKit 标签或大量边影响帧率，优先减少同时呈现内容，而不是牺牲文字等价入口。

## 9 Play 与上下文快照

1. 用户选择 Point、消息、附件、关联点、原记录上下文和当前问题。
2. 系统创建不可变 `ContextSnapshot` 与 `InputSnapshot`，展示逐项清单、执行位置和费用状态。
3. 用户确认后创建 `PlaySession`；本地或远端 Provider 只接收快照 DTO，不可直接读取仓库。
4. 结果先保存为 draft Result。用户选择另存为新 Point、附着原点或丢弃。
5. 再次 Play 新建 PlaySession 和 Result，不覆盖旧结果。

### 9.1 远端最小暴露面

`RemotePlayProvider` 接收显式 materialized payload，内容由 `ScopeBuilder` 根据确认后的 ID 和版本组装。请求日志只保存 `operationId`、提供方、模型标识、字节数、耗时、状态和费用，不保存原文。

取消前未提交则零请求；提交后记录 `cancelRequested`，结果到达时按策略丢弃或进入未采纳草稿。

## 10 搜索与关系推荐

首版建立两级检索：SQLite FTS5 支持确定性关键词搜索；本地 embedding 仅作为候选召回。`RelationClassifier` 对候选给出同主题、支持、反驳、互补、类比或未知，并必须携带命题引用和证据。证据不足时输出未知，不把距离当反驳。

| 阶段 | 输入 | 输出 | 控制 |
| --- | --- | --- | --- |
| 召回 | 有权访问的私人 Point | Top K 候选 | 关键词或向量可独立关闭 |
| 判别 | 候选与版本化文本 | 关系类型、证据、置信 | 低于阈值为 `unknown` |
| 排序 | 用途、重复曝光、反馈 | 相关线索或另一种观点 | 跳过、不贴切、关闭 |
| 确认 | 用户选择 | confirmed Relation | 用户关系不被重建覆盖 |

## 11 安全、隐私与数据生命周期

- 权限最小化：麦克风、语音识别和位置分别申请；位置是可选上下文，权限不等于上传许可。
- 文件保护：数据库、WAL/SHM、附件、临时录音和导出包全部纳入保护策略；临时文件成功提交或过期后清理。
- 密钥：Keychain 保存应用级密钥与版本；密钥轮换、设备迁移、丢失和恢复行为形成单独 ADR。
- 日志：使用 `os.Logger` 的隐私标记；只记录匿名标识、状态、字节数、耗时和错误码，不记录原文、转写或路径。
- 导出：生成带 manifest、版本、来源与附件的加密包，也可导出可读 Markdown 或 JSON；导出需要用户明确操作。
- 删除：软删除提供恢复窗口；彻底删除清理源文件、缩略图、索引、派生结果和待执行任务，并留下不含内容的审计结果。

## 12 可观察性与错误设计

状态呈现使用用户可理解的事实：已保存到手表、等待同步、已保存到 iPhone、转写失败但原音仍在。技术错误映射到稳定 `ErrorCode`，UI 文案与重试策略分离。

| 指标 | 口径 | 隐私 |
| --- | --- | --- |
| `capture_commit_ms` | 开始提交到本地事务成功 | 不含内容；按模态、设备分桶 |
| `watch_import_success` | `captureId` 在 iPhone 完成幂等导入 | 只记录结果和重试次数 |
| `transcription_outcome` | 成功、失败、不可用、用户修正 | 不记录识别文本 |
| `search_latency_ms` | 1,000 Point 查询到结果可见 | 记录数量级和耗时 |
| `play_scope_bytes` | 确认范围的条目数和字节数 | 不记录正文 |
| `unexpected_upload` | 无有效授权的外发尝试 | 必须为零，触发阻断发布 |

## 13 测试策略

| 层级 | 重点 |
| --- | --- |
| 领域单测 | 状态迁移、修订号、快照不可变、删除规则、权限与幂等 |
| 数据库测试 | 迁移、WAL 崩溃恢复、唯一约束、FTS、级联和备份恢复 |
| 文件测试 | 原子落盘、哈希、磁盘不足、临时文件恢复、受保护状态 |
| 跨端测试 | 断连、重复、乱序、回执丢失、手机未启动、多 Watch 切换 |
| 模型契约 | 不可用、资源准备中、取消、超时、输出 schema 错误、远端范围 |
| UI 测试 | 首次成点、多轮追加、新会话、语音失败、搜索定位、Play 确认 |
| 性能 | 1,000 Point 保存、搜索、3D 帧率、启动与内存；真机记录设备和系统 |
| 隐私 | 网络代理验证基础记录零上传；日志扫描无原文；删除与导出抽检 |

## 14 分阶段实施

| 阶段 | 交付 | 退出门 |
| --- | --- | --- |
| T0 技术探测 | Swift 工程骨架；SQLite、加密、迁移；音频落盘；Speech 能力；RealityKit 1,000 点；WatchConnectivity 真机 | 每项有支持、不支持或未知记录和降级结论 |
| T1 手机可靠捕获 | 文本大对话、自动成点、草稿恢复、语音原件、基础搜索、导出删除 | 断网与重启不丢已保存内容；失败不误报成功 |
| T2 空间与本地派生 | 3D 主空间、FTS、转写修正、摘要标签、关系候选 | 模型不可用时原文、搜索和 3D 仍可用 |
| T3 Play 闭环 | ContextSnapshot、范围确认、本地或远端 Provider、结果选择、TTS | 取消、超时、费用状态、来源追溯和零越界上传通过 |
| T4 Watch 试点 | 短语音、位置可选、后台文件同步、业务回执、幂等重传 | 断连重传不重复；原音在任一派生失败时仍可用 |

## 15 关键 ADR

| ADR | 建议决策 | 需要验证 |
| --- | --- | --- |
| 001 数据库 | SQLite + GRDB；SwiftData 暂不作为最终仓库 | 加密、迁移、并发、FTS、备份 |
| 002 加密 | Data Protection 为最低线；SQLCipher 作为数据库级方案候选 | WAL/SHM、性能、密钥轮换和导出 |
| 003 3D | RealityKit + 自有 GraphSpace | 1,000 点标签、边、拾取和辅助访问 |
| 004 Watch 协议 | `transferFile + captureId` 幂等 + 可靠业务回执 | 后台时延、磁盘压力、多设备切换 |
| 005 本地模型 | Provider 协议与能力探测，不锁定单一模型 | 设备、系统、语言矩阵、资源下载和功耗 |
| 006 远端 Play | 显式 `ScopeBuilder` 与一次一授权 | 提供方、费用、取消语义和数据保留 |

## 16 风险与缓解

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| Watch 后台传输不即时 | 用户误以为手机已收到 | 双阶段状态；手表保留原音至业务回执 |
| 本地 ASR 或模型设备差异 | 体验不一致 | 运行时能力矩阵；关键词和原音保底；不静默转云 |
| 3D 在低端设备掉帧 | 主空间不可用 | 视口裁剪、LOD、一跳关系、文字等价入口 |
| 源与派生混写 | 用户原意被覆盖 | 独立表、不可变修订、仓储层约束和回归测试 |
| 加密方案晚定 | 迁移和备份返工 | T0 先做恢复、WAL 和密钥生命周期探测 |
| 远端范围漂移 | 非预期上传 | 冻结快照、逐项清单、Provider 只接收 materialized payload |

## 17 首轮完成定义

- 同一套领域模型覆盖文本、iPhone 语音和 Watch 语音；没有为每个入口复制一套 Point。
- 所有“已保存”文案都有对应的持久化事实；手表保存与手机导入清晰区分。
- 原音、原文和历史显影可追溯；派生失败或重建不改变源数据。
- 1,000 Point 基准上保存 P95 ≤ 300ms、关键词搜索 P95 ≤ 500ms；3D 指标按选定基准设备记录实测值。
- 断网、重启、重复传输、取消、ASR 不可用、远端失败、删除和恢复用例通过。
- 网络审计证明基础记录、搜索、浏览和本地整理没有内容外发；远端 Play 与确认范围一致。

## 18 参考与依据

### 项目内依据

- [`PointVerse-点界-产品文档-v0.9.docx`](./PointVerse-点界-产品文档-v0.9.docx)
- [`interact.html`](./interact.html)：双端语音交互线框 v0.9
- [`db.mjs`](../src/db.mjs)、[`api.js`](../src/api.js)、[`main.js`](../src/main.js)：现有 H5 行为原型

现有 H5 SQLite 实现仅作为行为原型，不能直接等同于原生持久层。

### Apple 官方资料

- [Watch Connectivity](https://developer.apple.com/documentation/WatchConnectivity)
- [Transferring data with Watch Connectivity](https://developer.apple.com/documentation/watchconnectivity/transferring-data-with-watch-connectivity)
- [Speech on-device recognition capability](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition)
- [Speech local recognition requirement](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition)
- [RealityKit](https://developer.apple.com/documentation/realitykit)
- [SwiftData ModelContainer](https://developer.apple.com/documentation/swiftdata/modelcontainer)

系统最低版本、具体本地模型、远端模型提供方、Apple Watch 启动方式和位置权限细节仍需 T0 依据官方资料与真机结果冻结；本方案不提前承诺未验证的平台能力。
