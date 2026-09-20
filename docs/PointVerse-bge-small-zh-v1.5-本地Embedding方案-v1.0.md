# 点界 iPhone 本地 Embedding 与 Local Judge 技术方案 v1.0

> 实施更新（2026-09-18）：为支持中文与英文跨语言关联，实际模型已由
> `bge-small-zh-v1.5` 替换为 `intfloat/multilingual-e5-small`；采用 384 维、
> Float32 计算与 INT8 权重。本文其余 BGE 内容保留为早期选型记录。

> 状态：设计方案，尚未实现  
> 目标平台：iOS 17+  
> 首选模型：`BAAI/bge-small-zh-v1.5`

术语说明：此前讨论中的“Jev”指 `Local Judge`。本文和代码统一使用 `Judge`，避免把它误解为某个模型名称。

## 1. 结论

第一版使用 `bge-small-zh-v1.5` 替换当前星图中的 Apple `NaturalLanguage` sentence embedding，同时保留后者作为模型未安装或推理失败时的降级路径。

模型负责三件事：

1. 新 Point 保存后生成 512 维归一化向量。
2. 通过 cosine similarity 召回历史 Point Top-K。
3. 为搜索、关系候选和星图布局提供候选，不直接断言两个 Point 的关系类型。

模型约 24M 参数、512 维、MIT License。官方用法采用 `[CLS]` hidden state，并在相似度计算前进行 L2 归一化；官方也说明相似度的相对排序比固定绝对阈值更重要，阈值应使用自己的数据校准。[模型卡](https://huggingface.co/BAAI/bge-small-zh-v1.5)

## 2. 产品边界

Embedding 只回答：

> “哪些历史 Point 在语义上可能相关？”

它不回答：

- 两个观点是支持、反驳还是互补；
- 两个人是否产生共鸣；
- 自动连线是否是事实；
- 一个 Point 是否重要。

星图中的淡线表示系统候选，用户确认后的关系才是持久关系。低相似度也不等于反对或无关。

## 3. 输入契约

每个 Point 生成一份规范化的 `embeddingText`：

```text
用户修正文稿
或系统语音转写
或文本 Point 原文

图片 OCR 文字（如有）
```

规则：

- 用户修正版优先于系统转写。
- 不加入时间、设备名、状态提示等噪声字段。
- 不把 AI 标题重复拼入正文。
- 去除多余空白，但保留原语言和标点。
- 内容变化时递增 `contentRevision`，旧向量失效并排队重算。
- 第一版 corpus 和普通 Point-to-Point 比较均不加 instruction。
- 只有“短搜索词查长 Point”实验确认有效后，查询侧才添加官方中文检索 instruction；文档侧永远不加。官方说明 v1.5 不加 instruction 也可使用，短查询检索场景才建议实验 instruction。[模型卡](https://huggingface.co/BAAI/bge-small-zh-v1.5)

## 4. Core ML 模型设计

### 4.1 转换边界

Core ML 模型只包含 Transformer、CLS pooling 和 L2 normalize：

```text
input_ids:      Int32 [1, sequenceLength]
attention_mask: Int32 [1, sequenceLength]
token_type_ids: Int32 [1, sequenceLength]

                ↓ BERT

last_hidden_state[:, 0, :]

                ↓ L2 normalize

embedding: Float32/Float16 [1, 512]
```

Tokenizer 放在 Swift 层，不塞进 Core ML。这样便于测试、升级词表和定位文本预处理错误。

### 4.2 序列长度

第一版固定 `sequenceLength = 128`，降低转换和 Neural Engine 编译风险。超长 Point 按 token 切成最多 4 个 128-token chunk，各 chunk 推理后取平均并再次 L2 normalize。

第二阶段再评估 `32/64/128/256` 的 `EnumeratedShapes`。Apple 建议有限的枚举形状优于完全动态范围，因为系统可针对这些形状优化。[Flexible Input Shapes](https://apple.github.io/coremltools/docs-guides/source/flexible-inputs.html)

### 4.3 转换产物

固定以下版本信息：

```text
modelID:       baai-bge-small-zh-v1.5-coreml-fp32
sourceRepo:    BAAI/bge-small-zh-v1.5
sourceRevision:<固定 commit SHA>
dimension:     512
maxTokens:     128
pooling:       cls
normalization: l2
format:        mlprogram
minimumOS:     iOS 17
```

使用 PyTorch wrapper 导出 TorchScript/ExportedProgram，再通过 `coremltools` 转成 `mlprogram`。Apple 将 `mlprogram` 作为新功能和性能优化的主要格式；PyTorch 转换必须声明输入形状。[转换格式](https://apple.github.io/coremltools/docs-guides/source/target-conversion-formats.html)、[输入输出类型](https://apple.github.io/coremltools/docs-guides/source/model-input-and-output-types.html)

第一版使用 FP16 权重和计算。INT8 只在真机精度和性能基准完成后考虑，不直接采用通用 PyTorch 量化默认值；Apple 提醒其默认量化设置不一定适合 Core ML 和 Apple 硬件。[Core ML Tools FAQ](https://apple.github.io/coremltools/docs-guides/source/faqs.html)

## 5. Tokenizer

新增独立模块：

```swift
protocol TextTokenizer: Sendable {
    func encode(_ text: String, maxLength: Int) throws -> TokenizedInput
}

struct TokenizedInput: Sendable {
    let inputIDs: [Int32]
    let attentionMask: [Int32]
    let tokenTypeIDs: [Int32]
}
```

实现必须与 Hugging Face 模型仓库中的 tokenizer 配置和 `vocab.txt` 对齐：特殊 token、中文字符切分、大小写、标点、WordPiece、截断及 padding 均不能自行猜测。

转换工具生成至少 100 条 tokenizer golden fixtures；Swift 输出必须逐 token 等于 Python `AutoTokenizer` 输出。

## 6. iOS 运行时架构

```text
Point 保存／转写修正／OCR 更新
              ↓
     EmbeddingTask 入队
              ↓
      BGETokenizer (Swift)
              ↓
   BGEEmbedding.mlmodelc (Core ML)
              ↓
  512维 L2-normalized vector
              ↓
  SQLite embedding 表 + Top-K 索引
              ↓
 搜索候选／关系候选／星图布局
```

建议接口：

```swift
protocol LocalEmbeddingProvider: Sendable {
    var modelID: String { get }
    var dimension: Int { get }
    func encode(_ text: String) async throws -> EmbeddingVector
}

actor BGEEmbeddingProvider: LocalEmbeddingProvider { ... }
actor SystemEmbeddingProvider: LocalEmbeddingProvider { ... } // 降级
```

约束：

- Core ML 模型实例由 actor 串行持有，避免重复加载。
- 后台批处理时每批 8–16 个 Point，遇到低电量或 thermal serious 暂停。
- 新 Point 优先，历史回填次之。
- 推理失败不影响 Point 保存、搜索原文或 OCR。
- App 进入后台时保存任务状态，不承诺无限后台运行。

## 7. SQLite 数据设计

新增表：

```sql
CREATE TABLE point_embeddings (
    point_id          TEXT NOT NULL REFERENCES points(id) ON DELETE CASCADE,
    content_revision  INTEGER NOT NULL,
    model_id          TEXT NOT NULL,
    dimension         INTEGER NOT NULL,
    dtype             TEXT NOT NULL,
    vector_blob       BLOB NOT NULL,
    vector_norm       REAL NOT NULL,
    created_at        REAL NOT NULL,
    PRIMARY KEY (point_id, model_id)
);

CREATE INDEX point_embeddings_model
ON point_embeddings(model_id, content_revision);
```

第一版推理输出可用 Float32，落库建议转为 Float16：

- 10 万 Point × 512 × 4 bytes ≈ 195 MiB（Float32）。
- 10 万 Point × 512 × 2 bytes ≈ 98 MiB（Float16）。
- INT8 理论上约 49 MiB，但需要额外量化参数和召回精度验证。

向量必须与 `modelID + contentRevision` 绑定；切换模型时不能混算不同向量空间。

## 8. Top-K 召回

### P0：可验证版本

- 规模目标：最多 10,000 Point。
- 向量已归一化，因此 cosine similarity 等价于 dot product。
- 使用 Accelerate/vDSP 分块扫描 Float16/Float32 BLOB。
- 维护固定大小 min-heap，返回 Top-20，UI 默认展示 Top-10。
- 不使用全局固定阈值过滤，只按排名返回并显示置信区间。

### P1：规模升级

当本地数据达到 10k、单次扫描 P95 超过 150ms，再引入 ANN（例如 HNSW）。不要在没有规模证据前增加第三方向量数据库依赖。

## 9. 星图接入

现有 SwiftUI Canvas 伪 3D 保留，替换其相似度来源：

```text
当前：NaturalLanguage / 字符 bigram
目标：bge-small-zh-v1.5 cosine Top-K
降级：NaturalLanguage → bigram
```

布局规则：

- Top-K 相似度只产生吸引力候选。
- 所有节点保持最低排斥力，避免重叠。
- 相似度先按当前数据集分布做 percentile 映射，再转为布局强度；不直接把 0.5 当作“相关”。
- 每个 Point 最多显示 2 条候选连线。
- 用户确认关系使用更强的固定吸引力，并与模型候选使用不同样式。
- 模型更新或正文改变时平滑过渡位置，不瞬间重排整个空间。

## 10. Local Judge

第一版 Judge 不是另一个大模型，而是可解释规则层：

```text
embedding Top-20
      ↓
去除自身、空文本、重复 Point
      ↓
时间／来源／用户已拒绝关系过滤
      ↓
Top-10 候选
      ↓
用户：相关／不相关／建立关系
```

记录用户反馈，形成点界自己的评测集。只有 Top-K 质量成立后，才评估轻量 reranker 或关系分类器。

### 10.1 关系类型

```swift
enum SuggestedRelationKind: String, Codable, Sendable {
    case duplicate      // 基本重复
    case extend         // 补充或延伸
    case contradict     // 命题存在冲突
    case related        // 同主题，但证据不足以细分
    case unknown        // 无法可靠判断
}
```

`unknown` 是正常结果，不是错误。Judge 不能根据低 cosine 分数输出 `contradict`，也不能把高分直接等同于 `duplicate`。

### 10.2 P0 规则 Judge

P0 不引入第二个神经网络。规则 Judge 输入一个源 Point 和 embedding Top-20，输出经过过滤的候选：

```swift
struct RelationCandidate: Identifiable, Sendable {
    let id: UUID
    let sourcePointID: PointID
    let targetPointID: PointID
    let embeddingScore: Float
    let rank: Int
    let kind: SuggestedRelationKind
    let reasonCode: String
    let modelID: String
    let sourceRevision: Int
    let targetRevision: Int
}

protocol LocalRelationJudging: Sendable {
    func judge(
        source: PointSemanticDocument,
        candidates: [SimilarityHit]
    ) async throws -> [RelationCandidate]
}
```

P0 判断逻辑：

1. 删除自身、空文本和已删除 Point。
2. 合并同一目标的重复 chunk 命中。
3. 排除用户明确标记“不相关”的候选。
4. 完全相同的规范化正文标记为 `duplicate`。
5. 其余候选标记为 `related` 或 `unknown`，不自动输出 `extend/contradict`。
6. 返回 Top-10，并保存可解释的 `reasonCode`。

### 10.3 P1 语义 Judge

只有 P0 的 Recall@10 达标并积累足够人工关系标签后，才增加语义 Judge。其输入限制为 Top-20 文本对，输出必须包含：

```json
{
  "kind": "extend",
  "confidence": 0.82,
  "sourceEvidence": "……",
  "targetEvidence": "……"
}
```

P1 可比较三条路线：

- 轻量 cross-encoder/reranker；
- 用人工样本微调的小型分类器；
- 用户主动触发的远端 Judge。

不允许为了展示关系而默认回退到生成式猜测。证据无法对应到双方原文时输出 `unknown`。

### 10.4 候选与确认关系分离

```sql
CREATE TABLE relation_candidates (
    id                  TEXT PRIMARY KEY NOT NULL,
    source_point_id     TEXT NOT NULL REFERENCES points(id) ON DELETE CASCADE,
    target_point_id     TEXT NOT NULL REFERENCES points(id) ON DELETE CASCADE,
    embedding_model_id  TEXT NOT NULL,
    judge_model_id      TEXT NOT NULL,
    source_revision     INTEGER NOT NULL,
    target_revision     INTEGER NOT NULL,
    similarity          REAL NOT NULL,
    suggested_kind      TEXT NOT NULL,
    confidence          REAL,
    reason_code         TEXT NOT NULL,
    state               TEXT NOT NULL CHECK (state IN ('suggested','accepted','rejected','stale')),
    created_at          REAL NOT NULL,
    updated_at          REAL NOT NULL,
    UNIQUE(source_point_id, target_point_id, embedding_model_id, judge_model_id)
);

CREATE TABLE point_relations (
    id              TEXT PRIMARY KEY NOT NULL,
    source_point_id TEXT NOT NULL REFERENCES points(id) ON DELETE CASCADE,
    target_point_id TEXT NOT NULL REFERENCES points(id) ON DELETE CASCADE,
    kind            TEXT NOT NULL,
    origin          TEXT NOT NULL CHECK (origin IN ('user','accepted_suggestion')),
    created_at      REAL NOT NULL,
    UNIQUE(source_point_id, target_point_id, kind)
);
```

`relation_candidates` 可重建，`point_relations` 是用户事实，模型升级不能覆盖。

### 10.5 失效规则

发生以下任一情况，候选标记为 `stale` 并重新排队：

- 任一 Point 的正文、修正转写或 OCR 内容变化；
- embedding 模型 ID 改变；
- Judge 版本或规则版本改变；
- 用户删除相关 Point。

用户已经接受的 `point_relations` 不自动失效，但界面可以提示其来源内容已更新。

## 11. 任务调度与数据流

### 11.1 Durable Task 状态机

在现有 `durable_tasks` 基础上增加任务类型：

```text
embedding(pointID, contentRevision, modelID)
    queued → running → succeeded
                     ↘ failed → retry

relationRefresh(pointID, contentRevision, modelID, judgeID)
    等待 embedding 成功
    queued → running → succeeded
                     ↘ failed → retry
```

幂等键：

```text
embedding:{pointID}:{contentRevision}:{modelID}
relation:{pointID}:{contentRevision}:{modelID}:{judgeID}
```

调度要求：

- Point 事务提交后才创建 embedding 任务。
- `relationRefresh` 不能早于当前 revision 的 embedding。
- 同一 Point 的旧 revision 任务启动前直接取消。
- 前台新 Point 优先级高于历史回填。
- 重试采用有上限的指数退避；模型未安装属于等待资源，不计普通失败次数。

### 11.2 端到端序列

```text
用户保存 Point
      ↓
原文事务提交成功
      ↓
EmbeddingTask(contentRevision=3)
      ↓
BGE Core ML → 512维归一化向量
      ↓
向量原子写入 SQLite
      ↓
Top-20 cosine 召回
      ↓
Local Judge 过滤／分类
      ↓
保存 relation_candidates
      ↓
星图淡线 + 候选列表
      ↓
用户接受／拒绝
      ↓
point_relations 或 rejected feedback
```

## 12. 模型交付

推荐首版按需下载，而不是直接塞进主 App：

- App 没有模型也能记录、转写、OCR 和关键词搜索。
- 用户启用“语义星图”时下载模型。
- manifest 固定 URL、revision、字节数、SHA-256、license 和最低 App schema。
- 下载完成后先校验 SHA-256，再原子移动到模型目录。
- 模型删除只清理模型文件和可重建 embedding，不删除 Point 原文。
- 如果试点用户规模很小，也可以先内置 `.mlpackage`，减少下载链路变量；正式发布前再决定包内或按需资源。

## 13. 转换与质量门禁

转换脚本必须输出：

1. `.mlpackage`。
2. tokenizer 资源和版本清单。
3. 模型 SHA-256。
4. Python/Core ML golden embeddings。
5. 转换环境 lockfile。

门禁：

- 100 条样本中，Python 与 Core ML embedding cosine ≥ 0.999。
- Python 与 Swift tokenizer token IDs 100% 一致。
- Core ML 输出维度恒为 512，norm 在 `[0.999, 1.001]`。
- 中文、英文、中英混合、空白、emoji、超长文本均有用例。
- iPhone 真机首次加载、热启动、单条推理、20 条批处理分别记录耗时、峰值内存、能耗和 thermal state。

## 14. 产品验收

先建立至少 200 个真实 Point、50 个查询的人工评测集，每个查询由用户标注 3–10 个相关 Point。

P0 通过标准：

- Recall@10 ≥ 0.80。
- 至少 80% 查询的 Top-3 中出现一个用户认可结果。
- iPhone 目标机型热推理 P95 ≤ 120ms/Point（最终数值以真机基准调整）。
- 10k Point Top-10 扫描 P95 ≤ 150ms。
- embedding 失败不丢 Point，也不阻塞普通搜索。
- 星图候选线可关闭、可拒绝，且不会被描述成事实关系。
- Judge 对 `duplicate` 的 Precision ≥ 0.95；证据不足时允许输出 `unknown`。
- 用户拒绝过的同版本候选不会再次出现。

## 15. 测试矩阵

| 层级 | 必测内容 |
|---|---|
| Tokenizer | 中文、繁体、英文、中英混合、emoji、空白、超长截断，与 Python token IDs 完全一致 |
| Core ML | 输出 512 维、L2 norm、Python/Core ML cosine、一致模型 revision |
| 数据库 | 幂等写入、revision 失效、模型隔离、Point 删除级联、Float16 编解码 |
| 召回 | Top-K 排序、相同分数稳定排序、自身排除、chunk 合并、10k 性能 |
| Judge | duplicate 精度、拒绝反馈、unknown、不得用低相似度推断 contradict |
| 任务 | 崩溃恢复、旧 revision 取消、缺模型等待、重试上限、低电量暂停 |
| UI | 候选与确认关系样式不同、接受／拒绝、模型不可用降级、星图平滑更新 |

## 16. 实施顺序

1. 固定模型 revision、许可证和 tokenizer 文件。
2. 编写 Python wrapper、Core ML 转换脚本及 golden fixtures。
3. 实现 Swift WordPiece tokenizer，并通过逐 token 对照。
4. 实现 `BGEEmbeddingProvider` 和模型生命周期。
5. 添加数据库 migration、durable embedding task 和历史回填。
6. 用 Accelerate 实现 Top-K。
7. 实现 P0 规则 Judge、候选表、接受／拒绝反馈。
8. 替换星图相似度输入，区分候选关系与用户关系。
9. 建立真实 Point 评测集，校准 instruction、chunk 和候选阈值。
10. 真机完成延迟、内存、能耗与包体评测后再决定 FP16／INT8。
11. 达到召回门禁后再评估 P1 语义 Judge。

## 17. 暂不做

- 不上 `Qwen3-Embedding-0.6B`。
- 不在第一版加入 reranker。
- 不把 embedding 距离解释为支持或反驳。
- 不把模型输出同步到云端。
- 不在没有评测集时凭感觉固定 `0.8` 等全局阈值。
- 不让不同模型版本的向量互相计算距离。
