# OTel 应用调用链存储到 OpenSearch 的每日容量评估

> 适用对象：使用 `docs/en/installing/installing-distributed-tracing-opensearch.mdx`（对应测试脚本 `runme-test_installing-distributed-tracing-opensearch.sh`）部署 **Alauda Distributed Tracing**、以 **OpenSearch** 作为 Jaeger 后端存储的客户。
>
> 目标：给出「OTel 应用每日产生的调用链，存储到 OpenSearch 所需容量」的评估方法、实测单位成本与估算公式，供客户按自身 QPS / 服务数 / 调用链规模换算磁盘需求。

---

## 一、结论速览（TL;DR）

基于真实环境实测（Alauda Build of Jaeger v2 + OpenSearch 3.3.1，索引 `5 shards / 1 replica`）：

| 单位 | 主分片（逻辑数据） | 含 1 副本（实际磁盘） |
|---|---|---|
| **单个 span** | ≈ **1.3 KB** | ≈ **2.6 KB** |
| **单条调用链（3 span）** | ≈ 3.9 KB | ≈ **7.7 KB** |

> 说明：以上为「未合并实况值」（保守，贴近活跃当天索引状态）。经段合并压实后约低 10%（单 span 主 ≈1.16 KB / 含副本 ≈2.33 KB）。规划建议直接采用 **含副本 2.6 KB/span**。

**每日容量估算公式（含 1 副本）：**

```
每秒 span 数 (span/s) = 每秒调用链数(QPS) × 每条调用链平均 span 数

每日新增容量 ≈ span/s × 86400 × 2.6 KB
7 天常驻容量 ≈ 每日新增容量 × 7        （JAEGER_INDEX_RETENTION_DAYS 默认 7）
```

**快速参照**（含 1 副本、retention=7 天、单 span 2.6 KB 规划值）：

| span 写入速率 | 每日新增 span | 每日新增容量 | 7 天常驻容量 |
|---:|---:|---:|---:|
| 60 span/s（≈20 链/s × 3 span） | 5.2M | ≈ 12.9 GB | ≈ 90 GB |
| 300 span/s（≈100 链/s × 3 span） | 25.9M | ≈ 64 GB | ≈ 450 GB |
| 1,000 span/s | 86.4M | ≈ 214 GB | ≈ 1.46 TB |
| 2,000 span/s | 172.8M | ≈ 428 GB | ≈ 2.93 TB |

> ⚠️ 上表基于本次测试的「精简 Java HTTP 自动埋点 span」。**真实业务 span 若携带更多/更大的自定义属性（DB 语句、消息体、业务字段等），单 span 体量会更大**，请结合第五章「校正系数」放大，并**强烈建议用自身流量实测 1 天校准**（方法见第七章）。

---

## 二、评估背景与已知条件

| 项目 | 值 |
|---|---|
| 存储后端 | OpenSearch **3.3.1**（Lucene 10.3.1），3 个数据节点，集群健康 green |
| 追踪组件 | Alauda Build of Jaeger v2（`jaeger:2.16.0-r2`）+ OpenTelemetry Collector `0.147.0` |
| Span 索引 | `acp-business-1-jaeger-span-<yyyy-MM-dd>`，每日一个索引 |
| 索引分片 | **shards = 5，replicas = 1**（默认） |
| 数据保留 | `JAEGER_INDEX_RETENTION_DAYS` = **7 天**（由 `jaeger-es-index-cleaner` CronJob 每日 `30 2 * * *` 删除 7 天前索引，实测 args=`["7", ...]`） |
| 采样 | OTel Collector 仅含 `memory_limiter` + `batch` 处理器，**无采样**；应用侧默认全量上报（实测 100 请求 → 300 span 一一对应验证） |
| 测试链路 | `asm-client` → `otel-demo-consumer-for-test` → `otel-demo-provider-for-test`，单请求产生 **3 个 span** |

**未知（需客户提供或实测）**：OTel 服务数量、QPS、每条调用链的 span 数与属性规模。本文把这些作为公式入参，实测部分只负责标定「单 span / 单调用链」的存储单价。

---

## 三、测试方法

1. **清空历史数据**：删除遗留的 `acp-business-1-jaeger-span-*` / `jaeger-service-*` 索引，排除旧数据（多为 telemetrygen 合成 span，体量偏小、会低估容量）干扰。
2. **标定管道**：从 `asm-client` 发送 100 个测试请求，等待管道刷新后 OpenSearch 精确新增 ≈300 个 span → 验证「每请求 3 span、无采样、无丢失」。
3. **批量灌入**：并发发送约 1600+ 次相同调用链请求，累计约 5000 个 span 作为样本。
4. **净化样本**：K8s 存活/就绪探针会对 Spring Boot 应用的 `/actuator/health` 持续埋点，混入约 5% 健康检查 span（更小）。通过 `_delete_by_query` 删除全部 `GET /actuator/health` span，仅保留纯业务调用链 span。
5. **测量**：`_flush` + `_forcemerge` 后读取 `_cat/indices` 的 `store.size`（主+副本）与 `pri.store.size`（仅主），并用**查询层 `_count`** 获取真实 span 数。

### ⚠️ 关键计量口径：真实 span 数 ≠ `docs.count`

Jaeger 的 span mapping 中 `tags`、`process.tags`、`logs` 均为 **`nested` 类型**。在 Lucene 中，**每个 nested 对象会被存成一条独立的隐藏子文档**。因此：

- `_cat/indices` / `_stats` 里的 `docs.count` 是 **Lucene 文档数**（父 span + 全部 nested 标签子文档），本测试中每个 span 约对应 **42 条 Lucene 文档**，被放大了几十倍；
- **真实 span 数**必须用**查询层 `_count`** 或对 `process.serviceName` 聚合得到（nested 子文档在普通查询层不可见）。

> 若误用 `docs.count` 作分母，会把单 span 体量严重算小（本测试会低估约 40 倍），这是容量评估中最常见的坑。

---

## 四、实测数据与单位成本

### 4.1 纯业务样本（已剔除健康检查 span）

| 指标 | 值 |
|---|---|
| 真实业务 span 数（`_count`） | **4,933**（= 1,644 条调用链 × 3 span，另删除 272 个健康检查 span） |
| 调用链组成 | `GET /proxy/get`(consumer 入站) : `GET`(consumer 出站) : `GET /hello`(provider 入站) = 1644 : 1644 : 1644，即恰好 **3 span/链** |
| Lucene 文档数 | 208,831（≈42 docs/span，印证 nested 放大） |
| `pri.store.size`（仅主分片） | 5,721,465 B ≈ **5.46 MB** |
| `store.size`（主 + 1 副本） | 11,469,162 B ≈ **10.94 MB**（≈ 2× 主，印证 replicas=1） |

### 4.2 单位存储成本

| 口径 | 单 span·主分片 | 单 span·含副本 | 单调用链(3 span)·含副本 |
|---|---:|---:|---:|
| 段合并压实后（下界） | 1,160 B | 2,325 B | 6.81 KB |
| 未合并实况（上界，**规划采用**） | ≈ 1,308 B | ≈ **2,622 B** | ≈ **7.68 KB** |

> 未合并实况值由「混合样本压实前/后实测比例 1314/1165 ≈ 1.128」换算得到，代表活跃当天索引尚未充分合并时的占用，作为保守规划基准。

### 4.3 单 span 体量构成（为何一个 span ≈ 1.3 KB）

以 consumer 入站 span 为例：

- 原始 `_source` 紧凑 JSON ≈ **3,671 B**；压缩落盘后主分片 ≈1,160 B，**压缩比 ≈ 0.32×**（Lucene 对重复的资源属性/字段名压缩效果好）。
- 属性构成：**17 个 span 标签**（`http.request.method`、`http.route`、`url.path`、`http.response.status_code`、`network.peer.*`、`thread.*`、`user_agent.original` 等）+ **26 个资源属性 `process.tags`**（`k8s.*`、`host.*`、`os.*`、`process.*`、`service.*`、`telemetry.sdk.*` 等丰富的 K8s/JVM/OTel SDK 元数据）+ 0 条 logs。

**单 span 体量主要由「span 标签数 + 资源属性数 + 各标签值长度」决定**。这是不同调用链、不同服务 span 大小差异的根本原因。

---

## 五、影响容量的关键因素与校正系数

实测单价基于「精简 Java HTTP 自动埋点、高度重复的测试流量」。落到客户真实场景，请按下列因素校正：

| 因素 | 说明 | 校正方式 |
|---|---|---|
| **属性丰富度 `k_attr`** | 真实业务 span 常携带更多/更大属性：DB 语句、消息体大小、HTTP body、业务自定义字段、更长的 URL/参数。测试流量高度重复、压缩率偏高，会**低估**真实体量。 | 精简 HTTP 服务 ×1.0（本测）；含 DB/RPC/较多属性的典型微服务 **×1.3 ~ ×1.8**；富属性/大 payload/manual span 较多 **×2 ~ ×3** |
| **每条调用链 span 数** | Demo 为 3 span/链；真实微服务调用链常 **10 ~ 30+ span**。 | 直接进入 `span/s = QPS × 每链 span 数` |
| **采样率 `sr`** | 本环境无采样。若开启头部/尾部采样，仅采样命中的 span 落盘。 | 结果 **× 采样率**（如 10% 采样则 ×0.1） |
| **副本数 `replicas`** | 结果已按 1 副本（磁盘 ≈2× 逻辑数据）。 | 改为 `r` 副本：在含副本值上 **×(1+r)/2**；`replicas=0` 则用「主分片」列（无冗余、不推荐生产） |
| **保留天数 `retention`** | 默认 7 天。 | 常驻容量 **×(retention/7)** |
| **分片数 `shards`** | 仅影响数据在节点间的切分，**不改变总容量**；分片过多会增加小段固定开销（少量）。 | 一般无需校正 |
| **磁盘水位余量** | OpenSearch 默认 85% 触发只读、90% 拒写；需预留合并/突发余量。 | 采购容量 = 估算常驻 **÷ 0.7**（预留约 30% 空闲） |
| **其他索引** | `jaeger-service`、`jaeger-dependencies` 索引大小由「服务×操作」基数决定，不随流量线性增长，实测 <1%。 | 可忽略，或按 +1% 计入 |

---

## 六、估算公式与场景表

### 6.1 完整公式

```
设：
  QPS        = 每秒调用链数（trace/s）
  S_trace    = 每条调用链平均 span 数
  B_span     = 单 span 含副本存储 = 2.6 KB（规划值）
  k_attr     = 属性丰富度系数（见第五章，默认 1.0，典型 1.3~1.8）
  sr         = 采样率（无采样 = 1.0）
  retention  = 保留天数（默认 7）

每秒 span 数        span/s      = QPS × S_trace × sr
每日新增容量        Daily       = span/s × 86400 × B_span × k_attr
常驻总容量          Resident    = Daily × retention
每数据节点占用      PerNode     ≈ Resident ÷ 数据节点数（本环境 3）
建议采购容量        Provision   = Resident ÷ 0.7
```

### 6.2 场景表（含 1 副本、无采样、retention=7、k_attr=1.0）

| span 写入速率 | 每日新增 span | 每日新增容量 | 7 天常驻容量 |
|---:|---:|---:|---:|
| 50 span/s | 4.3M | 10.7 GB | 75 GB |
| 100 span/s | 8.6M | 21.4 GB | 150 GB |
| 200 span/s | 17.3M | 42.8 GB | 300 GB |
| 500 span/s | 43.2M | 107 GB | 750 GB |
| 1,000 span/s | 86.4M | 214 GB | 1.46 TB |
| 2,000 span/s | 172.8M | 428 GB | 2.93 TB |
| 5,000 span/s | 432M | 1.05 TB | 7.32 TB |
| 10,000 span/s | 864M | 2.09 TB | 14.6 TB |

### 6.3 按 QPS × 每链 span 数换算示例

| QPS（链/s） | span/链 | span/s | 每日新增 | 7 天常驻 |
|---:|---:|---:|---:|---:|
| 20 | 3 | 60 | 12.9 GB | 90 GB |
| 100 | 3 | 300 | 64 GB | 450 GB |
| 50 | 10 | 500 | 107 GB | 750 GB |
| 100 | 10 | 1,000 | 214 GB | 1.46 TB |
| 200 | 10 | 2,000 | 428 GB | 2.93 TB |
| 500 | 20 | 10,000 | 2.09 TB | 14.6 TB |

> 容量单位为二进制（1 GB = 1024³ B），与 OpenSearch `_cat` 口径一致。

### 6.4 计算示例

假设客户：**80 个服务、峰值 150 QPS、平均每链 12 span、含 DB 调用（k_attr=1.5）、无采样、1 副本、保留 7 天**：

```
span/s   = 150 × 12 × 1.0            = 1,800 span/s
每日新增 = 1,800 × 86400 × 2.6KB × 1.5 ≈ 289 GB/天
7 天常驻 = 289 × 7                    ≈ 2.03 TB
每节点   = 2.03TB ÷ 3                 ≈ 0.68 TB/数据节点
建议采购 = 2.03TB ÷ 0.7              ≈ 2.9 TB（集群总可用，约 1.0 TB/节点）
```

---

## 七、用自身流量实测校准（强烈推荐）

单 span 体量对属性数量极敏感，最可靠的做法是用客户真实流量跑 1 天后测量。命令（在可访问 OpenSearch 的 Pod 内执行，替换 `$OS` 与索引日期）：

```bash
OS='https://<opensearch-endpoint>:9200'
IDX='acp-business-1-jaeger-span-'$(date +%F)

# 1) 刷新并提交，保证测量稳定
curl -sk -u admin:admin -XPOST "$OS/$IDX/_flush"
curl -sk -u admin:admin -XPOST "$OS/$IDX/_refresh"

# 2) 真实 span 数（查询层 _count，不是 docs.count！）
curl -sk -u admin:admin "$OS/$IDX/_count"

# 3) 索引大小：store.size=主+副本(实际磁盘)，pri.store.size=仅主(逻辑数据)
curl -sk -u admin:admin "$OS/_cat/indices/$IDX?v&bytes=b&h=index,docs.count,store.size,pri.store.size"

# 单 span 含副本字节 = store.size ÷ 真实span数
# 每日新增        = 该值 × 当天实际 span 总数（可用当天完整索引直接读取）
```

> 提示：取一个已写满整天、且被 index-cleaner 尚未删除的**完整日期索引**测量最准。用「昨天」的索引 `store.size` 即为一天的真实新增容量（含副本）。

---

## 八、运维建议

1. **磁盘规划**：按第六章估算 7 天常驻容量，除以数据节点数得每节点占用，再 ÷0.7 预留水位余量作为采购基线；关注 OpenSearch `cluster.routing.allocation.disk.watermark`（默认 low 85% / high 90%）。
2. **控成本手段**（按优先级）：
   - **缩短保留天数**：`JAEGER_INDEX_RETENTION_DAYS`（如 3 天则常驻容量 ≈ ×3/7）；
   - **开启采样**：在 OTel Collector 增加 `probabilistic_sampler` 或尾部采样，容量按采样率线性下降；
   - **副本降为 0**：非关键环境可 `replicas=0`，磁盘减半，但**丧失冗余，生产不建议**；
   - **裁剪属性**：通过 Collector `attributes/transform` processor 丢弃冗余大属性。
3. **监控**：对 span 索引 `store.size` 与每日新增做趋势监控；对数据节点磁盘使用率告警。
4. **index-cleaner**：确认 `jaeger-es-index-cleaner` CronJob 正常执行（本环境 `30 2 * * *`），避免旧索引堆积撑爆磁盘。
5. **验证口径**：任何容量核对都用**查询层 `_count`** 取 span 数、用 `store.size`（含副本）取磁盘占用，切勿用 `docs.count`。

---

## 附录 A：实测原始数据

| 项 | 数值 |
|---|---|
| OpenSearch 版本 | 3.3.1 / Lucene 10.3.1 / 3 数据节点 / green |
| 索引 | `acp-business-1-jaeger-span-2026-07-06`，5 shards / 1 replica |
| 标定 | 100 请求 → 300 span（1:3，无采样、无丢失） |
| 纯业务样本 | 4,933 span = 1,644 链 × 3 span（删除 272 健康检查 span 后） |
| Lucene 文档数 | 208,831（≈42 docs/span，nested 放大） |
| 主分片大小 `pri.store.size` | 5,721,465 B |
| 含副本大小 `store.size` | 11,469,162 B |
| 单 span 主分片（压实/实况） | 1,160 B / ≈1,308 B |
| 单 span 含副本（压实/实况） | 2,325 B / ≈2,622 B |
| 单 span 原始 `_source` JSON | 3,671 B（17 span 标签 + 26 资源属性），压缩比 0.32× |
| retention | 7 天（index-cleaner args=`["7", ...]`） |

## 附录 B：容量单价速查（含 1 副本，规划值）

- 单 span ≈ **2.6 KB**
- 单调用链（3 span）≈ **7.7 KB**
- 1 万条 3-span 调用链 ≈ **75 MB**
- 100 万 span ≈ **2.5 GB**
- 1 亿 span ≈ **242 GB**

> 以上为「精简 HTTP span」基准，富属性场景请乘 `k_attr`（1.3~3）。
