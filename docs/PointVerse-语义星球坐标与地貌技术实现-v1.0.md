# 点界语义星球：Embedding 坐标与认知地貌技术实现 v1.0

> 日期：2026-09-21  
> 状态：设计方案；球面 Canvas、旋转缩放、基础聚类已实现，稳定语义坐标与地貌场待分阶段落地  
> 目标平台：iOS 17+，本地优先  
> 当前模型：`intfloat/multilingual-e5-small` Core ML，384 维，Float32 计算，INT8 权重

> 2026-09-21 实施更新：已完成 P0 第一批基础设施，包括 `point_geography`
> v4 migration、坐标版本、确定性球面语义布局、已有坐标冻结、新 Point 按相似邻居落点、
> 经纬度持久化和 Globe 页面读取。固定南北 Anchor、社区大陆与层级社区树仍待后续实现。

> 布局调整：`e5-compact-sphere-v2` 将无可靠邻居的 Point 确定性地初始化在较小球面区域，
> 并限制优化后的最大分布角度。旧 `v1` 坐标保留在数据库中，新版本重新生成；这属于显式版本切换，
> 不是同版本下的无预警漂移。固定南北语义 Anchor 实现后需要再迁移到新的地理版本。

> 密度调整：`e5-dense-sphere-v3` 将分布区域的最大球面夹角从约 `0.90 rad`
> 缩至 `0.28 rad`，球冠面积约为原来的十分之一；相应缩小相似点目标距离、排斥力和
> 缩放聚合阈值。旧 v1/v2 地理记录保留，新版本首次打开时生成。

> `e5-distributed-communities-v4` 取消全局球冠，将 embedding 的确定性语义群中心分布到全球，
> 群内保持紧凑。48 条跨主题 Demo 的球面 Recall@5 从 v3 的 0.113 提升至 0.354；
> 这仍是过渡性的社区布局，不代表固定南北语义轴已经实现。

> 分区检查 UI 已加入：球面显示以代表 Point 标题暂命名的“主题候选”；“查看分区主题与成员”
> 可查看每个分区的成员标题与正文/转写，供用户核对落点。名称并非 Local Judge 的结论，
> Demo 的人工主题只作为对照，算法分区仍由 E5 社区 ID 决定。

## 1. 目标

点界不把 Point 画成一组随机散点，而是让用户的长期内容自然生成一颗独一无二的语义星球：

- Point 是星球上的地点；
- Relation 决定地点间的拓扑和地形；
- Time 留下生长、风化与冲击历史；
- 显影是进入地点后展开文字、语音、照片、视频和 AI 结果；
- 缩放层级依次呈现星球、大陆、区域和叶子 Point。

核心工程原则：

> Embedding 决定“它是谁”，Graph 决定“它和谁有关”，Geography 决定“它在哪里”，Terrain 决定“这片区域长成什么样”。

地貌表达的是用户当前阶段形成的内容结构，不是人格诊断，也不对智力、性格或价值作判断。

## 2. 为什么不能直接取 Embedding 前三维

E5 输出向量：

```text
e(text) ∈ R^384
```

这 384 维整体才构成模型的语义空间。单独取 `embedding[0...2]` 没有稳定、可解释的几何含义；更换模型、量化方式或训练版本后，轴的方向也可能变化。

正确流程是：

```text
文本 / OCR / 语音转写
        ↓
384D Embedding Space
        ↓
Cosine KNN Graph
        ↓
稳定语义地理 Geography
        ↓
球面经纬度 + 地貌高度
        ↓
相机旋转 / 屏幕投影 Display
```

必须分开保存四层数据：

| 层 | 数据 | 作用 | 是否为真实语义 |
| --- | --- | --- | --- |
| Embedding Space | 384D 向量 | 搜索、召回、聚类 | 是 |
| Graph Space | 邻居、相似度、确认关系 | 语义拓扑、路径 | 是 |
| Geography Space | 纬度、经度、社区、版本 | 稳定空间记忆 | 派生数据 |
| Display Space | 屏幕 x/y、深度、聚合节点 | 当前帧绘制与命中测试 | 否 |

相机旋转不得回写 Geography，也不得改变聚类成员。

## 3. 输入与 Embedding

### 3.1 规范化语义文档

每个 Point 生成一份 `PointSemanticDocument`：

```text
用户修正文稿
否则系统转写 / 文本原文

图片 OCR（存在时追加，去重）
```

规则：

- 用户修正版优先；
- 保留原语言，支持中英文跨语言关联；
- 不加入时间、设备状态等噪声；
- 不重复拼接 AI 标题；
- 内容变化递增 `contentRevision`；
- 向量绑定 `modelID + contentRevision`，禁止混用不同模型的空间。

### 3.2 归一化与距离

模型输出执行 L2 normalize：

```text
ê = e / ||e||₂
```

两个 Point 的相似度：

```text
similarity(i, j) = êᵢ · êⱼ
```

用于球面和图布局的语义距离可定义为：

```text
d_semantic(i, j) = arccos(clamp(similarity(i, j), -1, 1))
```

`1 - cosine` 可以用于排序，但角距离更适合与球面夹角比较。

### 3.3 相似度校准

不能把 E5 原始分数直接解释为“85% 相关”。UI 应显示“E5 相似系数”或经过数据集校准后的等级。

建立本地验证集，至少包含：

- 同义与跨语言同义；
- 同主题但不同结论；
- 仅共享常用词；
- 完全无关；
- 时间、天气等容易产生虚高分的短句。

关系阈值由验证集的 precision/recall 决定，而不是凭视觉调整。

## 4. KNN 语义图

对每个 Point 保留 Top-K 候选：

```text
K = 10～30
edge(i, j) = calibrated(cosine(i, j))
```

建议只保留 mutual-KNN 或满足动态阈值的边：

```text
i ∈ KNN(j) 且 j ∈ KNN(i)
```

这样能减少 E5 分数整体偏高造成的稠密“毛线团”。边分为：

- `candidate`：Embedding 自动产生；
- `confirmed`：用户确认；
- `derived`：由 Point 演化链、共同事件等规则产生；
- `rejected`：用户明确排除，后续不得自动恢复。

图是大陆、山脉和路径的主要输入，不能只依赖屏幕坐标反推关系。

## 5. 固定的南北语义轴

纬度采用长期固定、跨主题成立的高阶轴：

```text
北极：抽象 / 理论 / 原理 / 长期 / 思考
南极：具体 / 实践 / 任务 / 当下 / 行动
赤道：两者平衡或处于理念到实践的过渡区
```

### 5.1 Anchor 文本

使用多条中英文 anchor，分别求平均并归一化，避免单句措辞偏差：

```text
North anchors:
- 抽象理论、底层原理、长期思考
- abstract theory, underlying principle, long-term thinking

South anchors:
- 具体行动、当前任务、立即执行
- concrete action, current task, immediate execution
```

```text
e_N = normalize(mean(embed(northAnchors)))
e_S = normalize(mean(embed(southAnchors)))
axis = normalize(e_N - e_S)
rawLatitudeScore = ê_point · axis
```

### 5.2 分数到纬度

用本地 corpus 的稳健分位数校准，防止所有点挤在赤道：

```text
q05 = percentile(rawScore, 5%)
q95 = percentile(rawScore, 95%)
u = clamp((rawScore - q05) / (q95 - q05), 0, 1)
latitude = (u - 0.5) × 160°
```

预留南北各 10° 作为视觉极冠，避免普通 Point 贴到数学奇点。`axisVersion` 固定后，新增 Point 不得重新训练或翻转南北轴。

## 6. 经度与大陆

经度不使用单一“情感—技术”人工轴，而由用户自己的语义社区生成。

### 6.1 社区发现

推荐流程：

```text
normalized embeddings
        ↓
mutual KNN graph
        ↓
Leiden community detection
        ↓
6～12 个宏观社区
        ↓
大陆 / 群岛候选
```

若第一版不引入 Leiden 实现，可暂用“阈值连通分量 + 小社区合并”，但数据库和接口仍按可替换的 `CommunityDetector` 设计。

### 6.2 社区在经度上的排列

社区之间的总边权为：

```text
W(A, B) = Σ edgeWeight(i, j), i ∈ A, j ∈ B
```

使用确定性的圆周排列，使强关联社区相邻。可采用：

1. 最大权重社区固定在 `0°`；
2. 按社区间边权构造 maximum spanning tree；
3. 对树做稳定遍历得到圆周顺序；
4. 社区经度宽度按节点数的平方根分配；
5. 保留最小海洋间隔。

大陆中心经度必须绑定稳定 `communityID`。小规模新增 Point 只在已有大陆内部调整，不重新旋转整颗星球。

### 6.3 大陆内部坐标

在每个社区内部，将语义邻域映射到大陆中心附近的切平面：

- P0：确定性球面力导向布局；
- P1：PCA 384→32，再用 PaCMAP/UMAP 得到局部 2D；
- 将局部 2D 通过球面 exponential map 投射到社区中心；
- 只做局部 relaxation，不允许全局重新洗牌。

PaCMAP/UMAP 仅用于显示坐标，不取代原始 Embedding 和 KNN Graph。

## 7. 球面坐标

经纬度和高度转换为三维坐标：

```text
x = (R + h) × cos(latitude) × cos(longitude)
y = (R + h) × sin(latitude)
z = (R + h) × cos(latitude) × sin(longitude)
```

约定：

- `latitude ∈ [-80°, 80°]`；
- `longitude ∈ [-180°, 180°)`；
- 基础半径 `R = 1`；
- `h` 为地貌高度，不参与语义相似度；
- 数据库存经纬度，不存当前相机投影后的屏幕坐标。

## 8. 坐标稳定性与增量更新

空间记忆是产品核心。不能每新增一个 Point 就全量运行 UMAP 并让旧地点漂移。

### 8.1 新 Point 落点

```text
新 Point
   ↓
生成 Embedding
   ↓
查 Top-K 邻居
   ↓
计算固定纬度
   ↓
由邻居投票选择 community
   ↓
邻居球面加权质心作为初始经度
   ↓
仅松弛新 Point 和一跳邻居
```

球面加权质心：

```text
p₀ = normalize(Σ wᵢ × pᵢ)
```

如果最高社区置信度不足，新 Point 进入海洋，形成孤立 Point 或新岛候选。

### 8.2 漂移预算

- 普通内容更新：旧 Point 单次位移不超过 `1°`；
- 社区结构变化：后台渐进迁移，不超过每日 `0.5°`；
- 用户固定地点：位移为 `0°`；
- 模型升级：生成新 `geographyVersion`，旧版保留到迁移完成；
- 大陆整体可缓慢漂移，但必须保持内部相对位置和用户地标。

### 8.3 坐标版本

```text
geographyVersion =
  modelID
  + anchorVersion
  + graphVersion
  + layoutAlgorithmVersion
```

任一关键算法变化都创建新版本，禁止静默覆盖导致整颗星球突然翻转。

## 9. 地图缩放与稳定聚合

聚合必须基于旋转前的固定球面坐标，而不是屏幕像素距离。

```text
clusterMembership = f(latitude, longitude, zoomLevel)
screenPosition = cameraProjection(latitude, longitude, yaw, pitch)
```

因此：

- 旋转只改变屏幕位置和前后遮挡；
- 同一 zoom level 下，集合成员不变；
- 缩放时按固定层级拆分：星球 → 大陆 → 区域 → Point；
- 点击聚合节点进入下一层级；
- 叶子层点击进入 Point 显影。

长期方案使用稳定的层级社区树：

```text
Planet
└── Continent
    └── Region
        └── Local Cluster
            └── Point
```

不要用每帧 greedy clustering，否则成员可能受遍历顺序影响。

## 10. 地貌场

地貌不是随机皮肤，而是多个可解释字段叠加：

```text
Terrain = f(
  Density,
  Importance,
  Connectivity,
  Impact,
  Time,
  Activity
)
```

建议使用细分二十面体 `Icosphere` 作为地貌网格，避免经纬网在两极采样过密。每个网格顶点存以下字段：

| 字段 | 来源 | 地貌含义 |
| --- | --- | --- |
| density | 附近 Point 的球面核密度 | 大陆/海洋 |
| cohesion | 社区内部平均边权 | 大陆稳定度 |
| importance | 回看、引用、用户固定、高层总结 | 海拔/山峰 |
| connectivity | 强边和路径的连续程度 | 山脉 |
| impact | 短时间新增量、事件强度 | 陨石坑/环形山 |
| age | 内容和结构持续时间 | 沉积/风化 |
| activity | 最近访问与新增 | 发光/火山活跃度 |

### 10.1 球面核密度

网格位置 `g` 的密度：

```text
density(g) = Σ mass(i) × exp(-angle(g, pᵢ)² / 2σ²)
```

- 高密度、高内聚、长期稳定区域形成大陆；
- 低密度、高不确定区域形成海洋；
- 小而内聚、与大陆边权弱的社区形成岛屿或群岛。

### 10.2 高度

```text
height(g) =
  a × normalizedDensity(g)
  + b × importance(g)
  + c × connectivity(g)
  - oceanThreshold
```

高度必须做平滑和限幅，防止单个噪声 Point 产生尖刺。山峰表示高密度或高重要度主题核心，不表达“更聪明”。

### 10.3 山脉

山脉对应连续的强关系路径。先从确认边和长期稳定候选边中寻找高权重路径，再沿球面测地线累加 ridge field：

```text
ridge(g) += pathWeight × exp(-distanceToPath(g)² / 2σ_ridge²)
```

山脉是逐渐生长的连续结构，不等同于一次性事件。

### 10.4 陨石坑与环形山

陨石坑对应有明确时间起点的高冲击事件：

```text
crater(r) = -A × exp(-r² / 2σ₁²)
            +B × exp(-(r-rimRadius)² / 2σ₂²)
```

- 中心负高度形成坑；
- 外圈正高度形成环；
- `A` 由事件冲击强度决定；
- `rimRadius` 由受影响 Point 数和传播层级决定；
- 事件影响随时间风化，但历史标记保留。

不能仅因某区域密度高就生成陨石坑，否则无法区分“慢慢长出的山峰”和“突然发生的冲击”。

### 10.5 火山、冰原与风化

- 火山：近期高活跃、高势能、未形成稳定结论的社区；
- 冰原：长期不活跃但仍保留的稳定内容；
- 风化：视觉锐度和活动光效随时间降低，不删除原始 Point；
- 海洋：低密度、未归类空间，不代表无价值。

## 11. 数据库设计

在现有 `point_embeddings` 基础上增加：

```sql
CREATE TABLE point_geography (
    point_id             TEXT NOT NULL REFERENCES points(id) ON DELETE CASCADE,
    geography_version    TEXT NOT NULL,
    content_revision     INTEGER NOT NULL,
    community_id         TEXT,
    latitude             REAL NOT NULL,
    longitude            REAL NOT NULL,
    altitude             REAL NOT NULL DEFAULT 0,
    placement_confidence REAL NOT NULL,
    is_pinned            INTEGER NOT NULL DEFAULT 0,
    updated_at           REAL NOT NULL,
    PRIMARY KEY (point_id, geography_version)
);

CREATE TABLE semantic_communities (
    id                    TEXT PRIMARY KEY NOT NULL,
    geography_version     TEXT NOT NULL,
    parent_id             TEXT,
    level                 INTEGER NOT NULL,
    centroid_vector       BLOB NOT NULL,
    center_latitude       REAL NOT NULL,
    center_longitude      REAL NOT NULL,
    angular_radius        REAL NOT NULL,
    stability_score       REAL NOT NULL,
    created_at            REAL NOT NULL,
    updated_at            REAL NOT NULL
);

CREATE TABLE point_relations (
    source_point_id       TEXT NOT NULL REFERENCES points(id) ON DELETE CASCADE,
    target_point_id       TEXT NOT NULL REFERENCES points(id) ON DELETE CASCADE,
    relation_kind         TEXT NOT NULL,
    source                TEXT NOT NULL,
    weight                REAL NOT NULL,
    model_id              TEXT,
    state                 TEXT NOT NULL,
    created_at            REAL NOT NULL,
    updated_at            REAL NOT NULL,
    PRIMARY KEY (source_point_id, target_point_id, relation_kind)
);

CREATE TABLE terrain_events (
    id                    TEXT PRIMARY KEY NOT NULL,
    event_kind            TEXT NOT NULL,
    center_latitude       REAL NOT NULL,
    center_longitude      REAL NOT NULL,
    radius                REAL NOT NULL,
    intensity             REAL NOT NULL,
    started_at            REAL NOT NULL,
    decay_rate            REAL NOT NULL,
    source_point_id       TEXT REFERENCES points(id) ON DELETE SET NULL
);
```

地貌网格可以由上述数据按需重建。P0 不必保存每个网格顶点；当重建耗时超过目标后，再缓存 `terrain_tiles`。

## 12. Swift 模块边界

```swift
protocol SemanticGraphBuilding: Sendable {
    func build(embeddings: [PointEmbeddingRecord]) async throws -> SemanticGraph
}

protocol CommunityDetecting: Sendable {
    func detect(graph: SemanticGraph) async throws -> CommunityHierarchy
}

protocol GeographyLayingOut: Sendable {
    func place(
        graph: SemanticGraph,
        communities: CommunityHierarchy,
        previous: GeographySnapshot?
    ) async throws -> GeographySnapshot
}

protocol TerrainGenerating: Sendable {
    func generate(
        geography: GeographySnapshot,
        graph: SemanticGraph,
        events: [TerrainEvent]
    ) async throws -> TerrainSnapshot
}
```

建议目录：

```text
PointVerseKit/
└── SemanticPlanet/
    ├── SemanticGraph.swift
    ├── CommunityDetector.swift
    ├── SemanticAnchors.swift
    ├── SphericalLayout.swift
    ├── GeographyStore.swift
    ├── TerrainField.swift
    └── PlanetVersion.swift

PointVerseApp/
└── Features/SemanticPlanet/
    ├── GlobeMapView.swift
    ├── GlobeProjection.swift
    ├── GlobeCamera.swift
    ├── GlobeLOD.swift
    └── TerrainRenderer.swift
```

图、坐标和地貌生成属于 `PointVerseKit`，SwiftUI 只负责相机、投影、绘制和交互。

## 13. 渲染方案

### 13.1 P0：SwiftUI Canvas

沿用当前系统 UI 方案：

- 正交球面投影；
- 经纬网和前后遮挡；
- 固定球面坐标聚类；
- 拖动旋转、双指缩放；
- Point、关系线、社区色块；
- 点击聚合节点放大，点击叶子进入详情。

P0 地貌可先用颜色场和等高线表达，不立即引入 SceneKit。

### 13.2 P1：Metal 地貌网格

当需要真实山体、环形山光照和大规模 LOD 时，再用 Metal/RealityKit 渲染 Icosphere：

- 顶点位移由 height field 决定；
- 法线由邻域高度重算；
- 海陆、冰原、活动度进入 shader；
- Point 标记和文字仍可用 SwiftUI overlay；
- 坐标和交互模型不随渲染器更换。

渲染器只是 Geography/Terrain 的消费者，不能拥有语义规则。

## 14. 性能预算

第一阶段目标：

| 数据量 | 策略 |
| ---: | --- |
| ≤ 10k Point | Accelerate 全量 Top-K 或分块扫描 |
| 10k～100k | HNSW/ANN，后台维护 KNN |
| 屏幕可见节点 | 聚合后 ≤ 300 |
| Canvas 关系线 | ≤ 500 条 |
| 地貌网格 P0 | 颜色场 2k～10k samples |
| 地貌网格 P1 | Icosphere 分级 LOD |

后台重算必须检查电量和 thermal state；新 Point 的局部落点优先，全局社区整理延后。

## 15. 质量指标

不能只凭“看起来漂亮”验收。

### 15.1 语义保持

- `Neighbor Recall@10`：低维球面邻居对原始 384D Top-10 的召回；
- Trustworthiness：球面近邻中有多少是真正高维近邻；
- 社区内部平均相似度；
- 跨语言同义 Pair 的球面距离。

### 15.2 稳定性

- 新增 1 个 Point 后，旧 Point 的 P50/P95 角位移；
- App 重启后坐标差异必须为 0；
- 旋转时 cluster membership 变化必须为 0；
- 同一算法版本重复运行结果必须确定一致。

### 15.3 可解释性

- 北极/南极 anchor 人工样本排序正确率；
- 用户能否理解大陆、岛屿、山峰、陨石坑的区别；
- 地貌说明必须描述结构，不进行人格评判。

### 15.4 坐标诊断模式

增加仅用于验证的“坐标诊断”入口：全局面板检查整颗星球，点击 Point 后查看落点依据。诊断数据必须注明 `modelID`、`geographyVersion`、内容版本和计算时间，以免把旧版结果误认为当前结果。

不要展示 384 个原始 Embedding 维度并为其命名；单个向量分量没有稳定的人类语义。界面展示由固定 Anchor 计算的**可解释轴**及原始余弦分数：

| Point 指标 | 计算/来源 | 用途与状态 |
| --- | --- | --- |
| 抽象 ↔ 行动 | `cos(e, northAnchor) - cos(e, southAnchor)` | 纬度依据；固定 Anchor 落地后显示 |
| 内在 ↔ 外部、情感 ↔ 理性、回忆 ↔ 规划 | 各轴两端 Anchor 的余弦差 | 实验性解释轴；验证通过前不参与落点 |
| 纬度、经度 | `point_geography` | 当前可显示；现阶段南北还没有语义解释 |
| 落点置信度 | `placement_confidence` | 当前可显示；现阶段是最近邻相似度的启发式分数，不是统计概率 |
| Top-K 最近邻及相似系数 | 同一 `modelID` 的原始 Embedding cosine | 当前可计算；显示邻居标题与系数，不称为“相关百分比” |
| 球面角距离 | `acos(clamp(pᵢ · pⱼ, -1, 1))` | 对照语义相似度，查找“语义近却画得远”的 Point |
| 社区 ID、内聚度 | 社区发现后的成员和内部边权 | 社区算法落地后显示 |
| 坐标漂移 | 更新前后球面角距离 | 用版本化快照或更新记录计算；仅有当前坐标时不能回溯 |

示例 UI 应分清真实值与解释：

```text
Point：今天研究球面投影算法
模型：multilingual-e5-small  ·  地理版本：e5-semantic-sphere-v1

抽象—行动：待校准（当前纬度不代表该轴）
坐标：31.2°N，121.5°E
落点置信度：0.86（启发式）
最近邻：Embedding 坐标方法 · cosine 0.934 · 球面夹角 8.1°
```

全局面板至少显示以下分布及异常样本：

1. `Neighbor Recall@10 = |KNN_embedding(i) ∩ KNN_sphere(i)| / min(10, n-1)` 的均值、P10；排除自身，数据不足 11 个时使用实际邻居数。
2. 语义 cosine 与球面角距离的秩相关性；列出高相似但球面距离很远的前 20 对。
3. 纬度直方图（例如每 20° 一桶）、南北半球比例、极区和赤道拥挤程度。
4. 无可靠邻居 Point 比例、最近邻 cosine 分布、落点置信度分布。
5. 社区落地后显示社区数量、规模、内部与外部相似度、孤岛比例。
6. 坐标版本更新后显示旧 Point 角位移 P50/P95/最大值；同版本重启必须为 `0°`。

诊断计算使用同一批有效内容版本的 Embedding 与 Geography；缺向量的 Point 单独计数，不进入 Recall 或距离相关性分母。对数量多时分批/采样计算，避免打开地图阻塞主线程。

验收不设脱离数据集的固定“正常分数”。先建立同义、跨语言同义、同主题不同结论、无关短句的人工样本集，再记录基线并比较每次布局版本。任何优化都同时检查近邻保持、坐标稳定与用户能否读懂，不能只为了漂亮而牺牲语义。

## 16. 当前实现与目标差距

当前代码已经具备：

- `multilingual-e5-small` 本地 Embedding；
- cosine 关系候选；
- SwiftUI Canvas 球面；
- 经纬网、旋转、缩放和前后遮挡；
- 基于球面角距离的稳定聚合；
- v4 确定性语义社区、稳定 `communityID` 与社区球面中心；
- 社区内紧凑布局、已有坐标与社区身份冻结；
- 基于屏幕缩放级别、但与相机旋转无关的 Point 聚合；
- 地理层原型：语义大陆、海岸/分区边界、区内道路和跨区航线；
- 分区候选名称、成员列表与稳定的社区颜色。

已完成 P0 第一批基础设施：`point_geography` v4 migration、坐标版本、确定性球面布局、已有坐标冻结、新 Point 按语义社区落点，以及 Globe 页面读取持久化经纬度。当前的社区算法是确定性的远点播种方案，属于验证产品形态的过渡实现，不等同于最终 mutual-KNN + Leiden。当前仍未做到：

- 固定南北语义 anchor；
- 基于 Judge 的稳定分区命名；
- 完整的局部增量布局与显式漂移预算（目前旧坐标完全冻结）；
- 层级社区树；
- 连续海拔、河流、山脉、事件与历史演化；
- 坐标诊断页面及可解释语义轴分数。

### 16.1 当前地理层原型

地理层使用未旋转的球面坐标生成，之后才应用相机旋转和正交投影。因此拖动星球时，大陆归属、海岸和行政边界不会变化。

- **陆地**：球面采样格离任一社区成员足够近时成为陆地；超出影响半径的低密度区域保持为海洋。
- **行政区**：陆地格归属球面角距离最近的社区中心，颜色由稳定 `communityID` 决定。
- **海岸**：陆地格与海洋格之间绘制青色实线。
- **区界**：两个不同社区的相邻陆地格之间绘制同社区色虚线。
- **道路**：同一社区内的强关系绘制为实线，并增加暗色底边保证可读性。
- **航线**：跨社区关系绘制为虚线；它表达跨主题连接，不改变行政区归属。

当前使用 6° 采样网格，这是 Canvas 原型的性能与边界平滑度折中。后续可以替换为持久化的球面 Voronoi/icosphere 网格，但必须保持“世界坐标先确定、相机投影后执行”的约束。

### 16.2 行政层级与地图式交互

当前地图在稳定语义社区之上生成三级候选行政层级：

- **省**：一级语义社区，一个稳定 `communityID` 对应一个省；命名器读取省内全部正文，生成领域级主题名。
- **市**：在省内根据球面局部方位进行确定性分片，再根据该分片全部正文生成子主题名。
- **区**：在市内继续进行局部方位分片，根据区内全部正文生成更具体的主题名。

精简版 App target 当前没有包含 Qwen/llama 生成式运行时，因此第一阶段使用本地可解释命名器：领域语义词表识别宏观主题，跨文档关键词识别细分主题，兜底算法使用区域内多篇正文共同出现的中文 n-gram。它不会再截取某一个代表 Point 冒充区域主题。该结果仍是候选名称；恢复 Local Judge 后，应由生成式 Judge 基于区域代表样本和高频关键词生成短名称，并保存名称版本、来源和用户修订记录。

区域命名同时属于知识整理功能，采用“系统缺省、用户最终决定”的双层值：

- 每个省、市、区都有由内容分析产生的 `defaultName`；
- 每个行政单元使用稳定层级 ID，例如 `province:{communityID}/city:2/district:1`；
- 用户可以在“语义分区 → 修改省市区名称”中编辑名称；
- 用户名称作为 override 保存，地图与内容列表优先显示 override；
- 用户可以单独恢复某个地名的系统缺省值；
- 当前 override 使用本机 `UserDefaults` JSON 持久化，正式版应迁移到数据库并记录修改时间与命名来源，以支持同步和历史回退。

显示优先级为：

`userOverride ?? generatedDefaultName`

地图采用 LOD 控制标签，避免 1024 Point 同时显示文字：

| 缩放 | 显示标签 |
| --- | --- |
| `< 1.8×` | 省名 |
| `1.8×～5×` | 市名 |
| `5×～10×` | 区名 |
| `≥ 10×` | 区名与 Point 正文内容；18× 后展示更长正文 |

拖动不再使用固定角速度。手势位移除以当前投影球半径得到旋转角度，即：

`angularDelta = dragDistance / projectedGlobeRadius`

因此放大后，同样的手指滑动距离只移动较小的地理范围，行为接近平面地图的“一比一拖动”，不会在高倍缩放时让球面快速滚过大量区域。

旋转状态不能使用带 `pitch ∈ [-90°, 90°]` 限制的经纬欧拉角。该方式在南北极产生奇异点：接近极点时，纵向拖动被边界截断，横向拖动退化为绕极点旋转。当前实现保存完整的 3×3 正交旋转矩阵，并把每次手势转换成相机空间 X/Y 轴旋转：

`orientation = verticalDelta × horizontalDelta × dragStartOrientation`

因此视图能够连续跨过南极和北极，极区不会失去平移方向；世界坐标、行政归属和聚合关系仍保持不变，改变的只有相机朝向。

因此当前页面可以验证交互，但还不能被视为最终的“认知地理”。

## 17. 实施路线

### P0：稳定语义地理

1. 增加 `point_geography` 和版本字段；
2. 固定南北 anchor 并实现纬度校准；
3. 构建 mutual-KNN 图；
4. 实现确定性社区检测和稳定 `communityID`；
5. 实现大陆经度排列与局部球面布局；
6. 当前 Canvas 改为读取持久化经纬度；
7. 增加坐标稳定性测试。
8. 增加坐标诊断模式：先展示经纬度、启发式置信度、最近邻及全局 Recall；Anchor 和社区落地后再开放对应轴分数与内聚度。

### P1：地图层级

1. 生成层级社区树；
2. 星球/大陆/区域/Point 四级 LOD；
3. 搜索后飞行定位；
4. 关系路径和语义路线；
5. 新 Point 局部插入，避免全局漂移。

### P2：认知地貌

1. Icosphere 地貌网格；
2. density/cohesion/importance/activity 字段；
3. 大陆、海洋、岛屿和山脉；
4. `terrain_events` 驱动陨石坑与环形山；
5. 时间风化、冰原和火山状态；
6. 地貌与显影策略联动。

### P3：历史与共享

1. 星球时间轴和历史快照；
2. 大陆漂移、分裂与融合回放；
3. 可控共享区域；
4. 星球间共振、航线和共享岛。

## 18. 最终约束

1. 原始 Embedding 永远是语义真值，球面坐标只是稳定投影。  
2. 经纬度由语义结构生成，不能反向决定内容含义。  
3. 旋转和屏幕投影不能改变 Point 坐标、关系或集合成员。  
4. 新 Point 默认局部落点，禁止无版本的全局重排。  
5. 山峰是逐渐生长的结构，陨石坑是有起点的冲击事件。  
6. 海洋是未形成稳定结构的空间，不是无价值区域。  
7. 地貌用于帮助用户理解自己的内容历史，不用于人格评判。  

点界语义星球最终表达为：

> Point 留下内容，Relation 塑造地貌，Time 留下历史；用户不是在管理笔记，而是在探索自己的思想世界。
