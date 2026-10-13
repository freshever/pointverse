# 点界 PointVerse 当前实现状态

> 文档版本：v1.2
>
> 更新日期：2026-10-13
>
> 代码基线：`4f31d9c`（build 18）及其后的宇宙缩放修复
>
> 范围：`ios/` 原生 iPhone、Designed for iPhone on Mac 与 Apple Watch 工程
>
> 性质：本文记录代码库已经落地的能力和已知边界，不代表所有设计方向都已完成。

## 0. 结论摘要

当前工程已经从“录音并转写”的语音 POC，发展成一个本地优先的多模态 Point 系统。主要闭环包括：

```text
语音／文本／照片
       ↓
原始内容可靠保存
       ↓
系统 Speech 或 Whisper 转写
       ↓
Qwen 标题、对话与内容整理
       ↓
multilingual-e5-small 语义向量
       ↓
关联候选、语义宇宙
       ↓
照片理解、声音理解、图片显影
```

当前已经实现：

- iPhone 文本与语音捕获，保存后进入 Point 详情。
- Apple Watch 独立录音、离线暂存及通过 WatchConnectivity 传输到 iPhone。
- Apple Speech 与本地 Whisper 多候选转写，用户可以选择和修正结果。
- Qwen 本地标题、Point 内对话和生图提示词整理。
- Vision OCR 与 Qwen3-VL 照片理解。
- `multilingual-e5-small` Core ML INT8 权重按需下载、Float32 推理、384 维向量和跨语言关联。
- 由恒星系、星球和球面地图组成的统一语义宇宙；支持连续相机缩放、星球旋转、搜索定位和多级细节。
- Stable Diffusion 2.1 Core ML 本地文生图，以及从 Point 详情发起的“显影”。
- 本地声音理解：响度、节奏、BPM、音高、音符、调性、旋律序列和 CLAP 音乐语义标签。
- 中文简体、中文繁体、英文和日文界面切换。
- 模型后台下载、断点续传、校验、镜像回退和卸载。
- OpenRouter、Groq、OpenAI 及 OpenAI Chat Completions 兼容服务的自定义网络模型。
- 本地 GGUF 导入、Edge0 实验后端，以及文本、视觉、图片、语音、Embedding 和声音能力的独立路由。
- AI 标题、回复和图片保存实际模型来源，长按内容可查看来源信息。

尚未形成完整闭环的主要部分：

- 语义星球的局部近邻保持仍需优化；1024 Point 实验的 `Neighbor Recall@5` 只有 `0.108`。
- 省／市／区名称目前主要由确定性关键词规则生成并允许手工修改，尚未接入完整的本地模型命名流程。
- 关系主要来自 E5 相似度候选；支持、反驳、延伸等 Local Judge 关系类型尚未可靠实现。
- `durable_tasks` 仍不是完整的后台租约、退避和重试调度器。
- 跨设备资料库同步、备份恢复、导出和端到端加密尚未完成。
- 产品层面的“旧点再发现 → 继续思考 → 确认关系 → 保存新结果”尚未形成统一闭环。
- `PlaySession`、`PlayResult`、`ContextSnapshot` 仍未成为统一领域对象；当前聊天、显影和整理分别实现。
- 旧 Point 主动回看、推荐原因、用户反馈和“每周有效再发现”指标尚未实现。

## 1. 平台与工程结构

最低系统版本：

- iOS 17.0+
- watchOS 10.0+
- Xcode 26+
- Apple Silicon Mac 可用 “Designed for iPhone” 运行 iOS App；E5 不再被代码主动禁用。

当前主要模块：

```text
ios/
├── PointVerseApp                 iPhone / iPad 兼容应用
│   ├── App                       容器、启动、语言和后台下载
│   └── Features
│       ├── Capture               语音、文本、相机帧捕获
│       ├── Embedding             E5 Core ML 与语义索引
│       ├── PointDetail           转写、对话、照片、声音理解、显影
│       ├── PointList             列表与搜索
│       ├── StarMap               保留的星图、语义星球与当前语义宇宙
│       ├── ImageGeneration       Stable Diffusion 与 OCR
│       └── ModelSettings         模型下载和选择
├── PointVerseKit                 领域模型、数据库、存储和布局算法
├── PointVerseWatchApp            Watch 录音、暂存和传输
└── Vendor
    ├── LlamaRuntime              llama.cpp / 多模态运行时
    └── StableDiffusionRuntime    本地图片生成运行时
```

主应用当前有 5 个 Tab：记录、想法、宇宙、图片和模型。原星图与星球页面代码仍然保留，但不再作为独立 Tab 展示。原有独立测试模式和球面分布 Demo 的入口已迁移到模型页。

## 2. 捕获与 Point 生命周期

### 2.1 iPhone

记录页支持语音和文本两种模式。语音路径为：

```text
开始录音
  ↓
AAC / M4A 原音写入本地
  ↓
SQLite 事务创建 Point、Message、AudioAsset、Transcript 与任务
  ↓
立即进入详情
  ↓
后台转写、标题和 Embedding
```

录音过程中可以启用相机采样，结束后选择保留的画面。文本模式直接创建 Point，不要求麦克风，因此适合模拟器和 My Mac 调试。

`CaptureUseCase` 是 actor，串行化一次录音的 `start → finish/cancel` 生命周期。`messages.operation_id` 有唯一约束，同一操作重复提交会返回已有 Point，避免同一会话内重复落库。

### 2.2 Apple Watch

Watch App 已作为独立 target 存在，当前链路为：

```text
Watch 录音
  ↓
本地 WatchCaptureStore 暂存
  ↓
WatchConnectivity 文件传输
  ↓
iPhone PhoneWatchTransferReceiver 接收
  ↓
进入与 iPhone 录音相同的数据库和转写流程
```

传输失败或手机暂时不可达时，Watch 保留待发送录音，后续继续尝试。Watch 不在手表端运行 Whisper、E5、Qwen 或图片模型。

## 3. 转写、标题与对话

### 3.1 转写

默认可以使用系统 `SFSpeechRecognizer`，并要求端侧识别。安装 Whisper 后可以用本地 whisper.cpp 生成另一份转写候选。

数据库从 v5 开始保存 `transcription_candidates`：

- 同一段原音可保留多个引擎结果。
- 用户可在详情页切换当前采用的候选。
- 用户修正写入 `user_text`，不会覆盖引擎原文。
- 切换候选或修正内容会递增 Point revision，并触发 Embedding 重算。

### 3.2 标题与对话

Qwen 本地语言模型目前承担：

- 根据 Point 内容生成标题。
- 在 Point 详情中根据原文和最近上下文回复。
- 按不同对话角色生成简洁或探索式回答。
- 将中文、日文等请求整理为 Stable Diffusion 使用的英文提示词。

模型不可用时，标题使用规则式首句／截断结果；Point 保存、原音播放和文字编辑不会被模型失败阻塞。

## 4. 图片、OCR、视觉理解与显影

图片可以来自录音期间的相机采样、详情页拍照、相册、涂鸦或本地生成。

图片处理由两层能力组成：

- Vision OCR：快速提取图片文字，不需要额外模型。
- Qwen3-VL：结合 OCR 描述物体、场景和可能含义，需要语言模型与视觉投影模型。

识别结果写入 `point_images.recognized_text`，并进入 Point 的语义文本，使照片内容可以参与 E5 关联和星球布局。

“显影”流程已经位于 Point 详情页：

1. 汇总当前 Point 的转写、图片说明和对话上下文。
2. Qwen 整理英文画面提示词。
3. Stable Diffusion 2.1 Core ML 生成 512×512 候选图。
4. 用户确认后将图片保存回当前 Point 时间线。

当前主要是 text-to-image，不保证保持输入照片的结构；图生图、局部重绘和 ControlNet 尚未接入。

## 5. E5 Embedding 与关联

实际模型已经由早期文档中的 `bge-small-zh-v1.5` 改为：

```text
模型：intfloat/multilingual-e5-small 的 Hark Core ML 转换
模型 ID：hark-multilingual-e5-small-coreml-int8
权重：INT8，约 118 MB
计算：Float32
输出：384 维，L2 normalize
存储：Float16 little-endian BLOB
运行：Core ML，当前配置优先 CPU 稳定性
```

模型按需下载。App 内置 tokenizer；权重下载完成后，会下载并校验 Core ML descriptor，在 Application Support 中组装 `.mlpackage`，然后由系统编译为 `.mlmodelc`。

参与 Embedding 的语义证据包括：

- 文本 Point 原文；
- 用户修正或当前选中的转写；
- 图片 OCR／视觉说明；
- 后续用户对话；
- 声音理解的语义标签。

向量与 `pointID + contentRevision + modelID` 绑定。正文或派生语义发生变化时，旧向量失效并重新排队。

当前关联先从用户资料库的向量中减去公共质心，再用残差向量计算“相对关联度”，避免 multilingual E5 偏高且区间狭窄的原始余弦值让无关 Point 互相连接。详情页和星图使用相同口径；星图每个 Point 最多显示 3 条突出候选边。相对关联度只是“在当前资料库中可能相关”，不是百分比，也不是重复、支持或因果关系。

## 6. 星图、语义星球与统一宇宙

### 6.1 星图

`StarMapView` 使用 SwiftUI Canvas 构建伪 3D 空间，不再依赖 SceneKit。支持单点进入、拖动、缩放、相关连线、相似度显示，以及缩放时的节点聚合与展开。

### 6.2 语义星球

`GlobeMapView` 将持久化的经纬度投影到可旋转球面。当前实现包含：

- 经纬网和南北极语义标识；
- E5 社区颜色；
- 球面旋转、平移感和更大范围缩放；
- 与相机旋转解耦的固定聚合关系；
- 大陆／行政区域视觉层；
- 省、市、区三级名称和名称编辑器；
- 1024 条实验 Point 的独立 Demo 页面；
- 不同比例尺下逐级显示区域、聚合和叶子 Point。

`SemanticGeographyEngine` 使用稳定的 `point_geography` 记录保存坐标、community、版本、置信度和 pinned 状态。已有坐标优先保留，新 Point 根据 E5 邻居落位，避免每次启动或旋转造成集合变化。

当前使用的布局身份仍是 `relativeSemanticV6`。设计文档提出的 `semantic-atlas-v7`、稳定层级社区树和更强局部近邻保持属于下一阶段，不应写成已完成。

### 6.3 统一语义宇宙

`UniverseMapView` 以原语义星球的球面交互为基础，将少量语义星球组织成多个恒星系。当前实现包含：

- 恒星系、行星和卫星式层级表达；
- 统一的三维世界坐标和单一相机体系；
- 双指缩放及放大、缩小按钮；
- 点击星球只负责居中，不额外制造独立缩放动画；
- 星球达到约四分之一屏幕大小后逐渐显示球面地图；
- 球面可见后，拖动球体执行自转，拖动外部空间平移整个宇宙；
- 继续放大时按省、市、区和 Point 逐级显示内容；
- 搜索 Point 后将相机移动到所属星球和位置；
- 初始相机根据当前所有星球边界自动适配全景。

相机放大已改为根据宇宙最前方物体动态计算近点。小星系在局部相机中放大后会保持目标，只有用户明确缩小并远离时才释放回全宇宙相机，避免深处星系发生回弹。

## 7. 声音与音乐理解

数据库 v6～v8 增加了 `audio_understanding`、音高字段和旋律序列字段。详情页可以主动运行声音理解，当前输出包括：

- 时长和响度；
- BPM 与节奏强度；
- 主导音高；
- 检测到的音符；
- 估计调性；
- 带开始时间和时长的音符序列；
- 是否包含人声；
- 本地规则标签以及可选 CLAP 音乐语义标签。

基础音频特征和单音旋律检测由本地 DSP 完成。可选的 `GridshiftCLAP` Core ML INT8 模型约 64 MB，用于补充音乐语义向量／标签。

界面支持用 `AVAudioEngine` 合成本地预览音，按识别出的音符或时间序列回放旋律。这是分析结果试听，不是对原音的重制或高保真乐谱转录；多声部和复杂伴奏准确率仍有限。

## 8. 数据库现状

SQLite 使用 GRDB，当前迁移到 v10：

| 迁移 | 主要内容 |
| --- | --- |
| v1 | Point、消息、音频、转写、派生结果、任务和全文索引 |
| v2 | Point 图片 |
| v3 | Embedding、关系候选与用户确认关系 |
| v4 | 持久化语义地理坐标 |
| v5 | 多转写候选 |
| v6 | 声音理解与 CLAP 向量 |
| v7 | 音符与调性 |
| v8 | 带时间信息的音符序列 |
| v9 | 文本内容的模型来源与生成标记 |
| v10 | 图片的模型来源与生成标记 |

重要数据原则：

- 原始录音、引擎转写和用户修正分开保存。
- Point 删除通过外键级联清理数据库记录，并尝试删除音频与图片文件。
- Embedding、地理坐标、模型标题和声音理解是可重建派生数据。
- 用户原文和用户确认关系不能被模型升级静默覆盖。

目前仍需关注：

- `durable_tasks` 会记录任务状态，但还没有完整的 lease、指数退避和后台执行器。
- FTS5 表被维护，但列表搜索仍应继续核实是否已完全切换到 FTS 查询路径。
- 资产已有 `committing/available/quarantined` 类型，但实际隔离和恢复流程仍不完整。

## 9. 本地模型与资源管理

当前模型与执行入口：

| 类别 | 模型 |
| --- | --- |
| 语音 | Whisper tiny/base/small Q5_1；Apple Speech 无需下载 |
| 语言 | Qwen3 0.6B Q8、Qwen3 1.7B Q8、Qwen3-VL 2B Q8 |
| 视觉 | Qwen3-VL 2B + mmproj |
| Embedding | Hark multilingual-e5-small Core ML INT8 |
| 图片 | Stable Diffusion 2.1 Base Core ML 6-bit |
| 音乐 | Gridshift CLAP Music Core ML INT8 |
| 实验语言模型 | Edge0 8B A1B Preview · MLX，仅适合满足内存要求的真机 |
| 外部模型 | OpenRouter、Groq、OpenAI、自定义 OpenAI 兼容接口 |
| 用户本地模型 | 可导入 GGUF，由 llama.cpp 兼容性决定是否能运行 |

`ModelDownloadManager` 支持后台 URLSession、断点续传、多下载源、磁盘空间检查、SHA-256 校验、原子安装和卸载。`ModelExecutionGate` 串行化重型模型，降低同时加载 Whisper、Qwen、视觉和扩散模型导致的内存峰值。

模型默认不随 App 打包，用户按需下载。删除模型不会删除 Point 原始内容，但会让对应派生功能暂时不可用。

网络模型按能力分别选择，语言、图片生成、视觉理解、语音、Embedding 与声音理解不共享一个隐含默认值。实际生成结果必须记录真实返回的模型信息；网络调用失败可以进行有限重试，但不会静默改用本地模型或其他服务商。

## 10. 本地化和交互状态

应用提供简体中文、繁体中文、英文和日文资源，并允许在 App 内即时切换。当前使用自建 `AppLocalization`／`AppText`，不是完全依赖 SwiftUI 的 `LocalizedStringKey`。

当前底部导航已收敛为“记录、想法、宇宙、图片、模型”。这次收敛减少了星图、星球和宇宙三个相似入口之间的理解成本，宇宙成为主要空间入口。

最新录音页面会根据可用高度和宽度进入 compact 布局，缩小日期、间距和录音按钮，改善小屏设备与横向可用空间。

### 10.1 应用级测试模式

模型页“实验工具”提供“进入独立测试模式”和“球面分布演示”两个入口。进入测试模式后整个应用的 5 个 Tab 都会切换到独立的测试容器，而不只是打开一个演示页面：

- 正式数据库：`pointverse.sqlite`
- 测试数据库：`test-mode/pointverse-test.sqlite`
- 测试录音和图片也写入独立的 `test-mode` 数据目录。
- 已下载的 Whisper、Qwen、E5、Stable Diffusion 和 CLAP 模型由两个模式共享，避免重复占用空间。
- WatchConnectivity 始终连接正式容器，手表记录不会误入测试库。
- 顶部紫色状态栏持续显示当前处于测试模式，并提供“+100”和“退出”。
- 每次点击“+100”向测试库追加 100 条跨技术、烹饪、园艺、天文、运动、艺术、金融、旅行、情绪和历史主题的纯文本 Point。
- E5 可用时，新测试文本会在测试库内单独生成 Embedding；不可用时仍可使用系统语义降级查看。

退出测试模式只切换回正式容器，不删除测试数据；下次进入可以继续追加，用于观察 100、200、1000 条数据下的关联、聚合和布局表现。

## 11. 测试、构建与发布状态

`PointVerseKit` 目前有 `PointDatabaseTests` 和 `ModelRegistryTests`，主要覆盖数据库、幂等、搜索／级联处理，以及模型校验和下载状态。App UI、WatchConnectivity、Core ML 真机推理、声音分析和图片生成仍缺少系统化自动测试。

当前工程配置：

- 主 App：`org.dianjie.pv`
- Watch App：`org.dianjie.pv.watchkitapp`
- Marketing Version：`0.1.0`
- 生成后的 Xcode 工程 Build：`18`，iPhone 与 Watch 已统一
- TestFlight 导出配置：`ios/ExportOptions-TestFlight.plist`
- build 18 已完成 Archive 并上传 App Store Connect；上传完成后由 Apple 继续处理。

注意：`ios/project.yml` 与生成后的 `.xcodeproj` 仍需作为两个配置来源持续核对。再次运行 XcodeGen 前，应确认 build number、资源排除规则、Watch target、Vendor framework 和脚本阶段不会被旧配置覆盖。

## 12. 下一阶段建议

下一阶段的首要目标不再是继续扩充模型或视觉效果，而是完成“有效再发现”产品闭环：

```text
记录 Point
  ↓
旧 Point 因时间或新关联重新出现
  ↓
用户看到推荐原因和原文证据
  ↓
确认有关／无关／稍后，或选择关系类型
  ↓
继续思考或主动 Play
  ↓
结果先成为草稿
  ↓
保存为新 Point／附加到原 Point／丢弃
```

建议按以下顺序实施：

1. 在“想法”页增加“继续想”，每天提供少量旧点、最近相关点和未完成结果，并说明出现原因。
2. 记录 `shown/opened/useful/notRelated/later/resultSaved` 等本地反馈，用于计算“每周有效再发现”，不采集 Point 原文。
3. 将 E5 候选关系与用户确认关系彻底分开，支持相似、延伸、支持、反驳、类比和无关；相似度不再被解释为关系结论。
4. 统一聊天、内容整理和图片显影为 `PlaySession` 与 `PlayResult`，生成结果先预览，再由用户决定如何沉淀。
5. 为宇宙提供共享的稀疏语义图、稳定社区身份、局部增量插入和原子快照；近期不继续增加森林、天气或复杂物理装饰。
6. 私人内测前补齐导出、备份恢复和回收站，避免用户内容被永久困住或误删。
7. 更新自动化与真机测试，重点覆盖 Watch 转写、模型串行执行、网络模型失败重试、语义关系、宇宙缩放和数据迁移。

下一阶段的完成标准应从“功能可以运行”改为：用户能从一条至少 7 天前的旧 Point 出发，确认一个关系或保存一个新的可追溯结果。
