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
>
> ℹ️ **采样**：当前环境为 **100% 全采样**（`acp-common-java` Instrumentation 配置 `parentbased_traceidratio=1`），即所有调用链全部落库、无数据缩减，`sr=1`；若后续开启采样，容量按采样率线性下调（见第五、七章）。
>
> 📊 **每日 span 量优先用监控指标读取**：可直接从 OTel Collector 指标 `otelcol_exporter_sent_spans{exporter="jaeger_storage_exporter"}` 得到真实落库 span 数，再 × 2.6 KB 换算容量（见第七章「方法 A」），比按 QPS 估算更准。

---

## 二、评估背景与已知条件

| 项目 | 值 |
|---|---|
| 存储后端 | OpenSearch **3.3.1**（Lucene 10.3.1），3 个数据节点，集群健康 green |
| 追踪组件 | Alauda Build of Jaeger v2（`jaeger:2.16.0-r2`）+ OpenTelemetry Collector `0.147.0` |
| Span 索引 | `acp-business-1-jaeger-span-<yyyy-MM-dd>`，每日一个索引 |
| 索引分片 | **shards = 5，replicas = 1**（默认） |
| 数据保留 | `JAEGER_INDEX_RETENTION_DAYS` = **7 天**（由 `jaeger-es-index-cleaner` CronJob 每日 `30 2 * * *` 删除 7 天前索引，实测 args=`["7", ...]`） |
| 采样 | **100% 全采样**：应用侧 `acp-common-java` Instrumentation（`otelv2-java-demo` NS）配置 `sampler.type=parentbased_traceidratio`、`argument=1`；OTel Collector 无采样处理器 → 追踪数据无缩减（`sr=1`）。实测 100 请求 → 300 span 一一对应，印证全采样、无丢失。 |
| 应用上报 | 应用经 OTLP/HTTP 上报至 `otel-collector.jaeger-system.svc:4318`（`otel` collector）→ `load_balancing` 转发 `jaeger-collector`（`jaeger` collector）→ `jaeger_storage_exporter` 写入 OpenSearch |
| 实时监控 | ACP kube-prometheus 已采集两个 collector 的内部指标（`otelcol_*`），可实时估算每日 span 吞吐与落库量（见第七章「方法 A」） |
| 测试链路 | `asm-client` → `otel-demo-consumer-for-test` → `otel-demo-provider-for-test`，单请求产生 **3 个 span** |

**未知（需客户提供或实测）**：OTel 服务数量、QPS、每条调用链的 span 数与属性规模。本文把这些作为公式入参，实测部分只负责标定「单 span / 单调用链」的存储单价。

---

## 三、测试方法

1. **清空历史数据**：删除遗留的 `acp-business-1-jaeger-span-*` / `jaeger-service-*` 索引，排除旧数据（多为 telemetrygen 合成 span，体量偏小、会低估容量）干扰。
2. **标定管道**：从 `asm-client` 发送 100 个测试请求，等待管道刷新后 OpenSearch 精确新增 ≈300 个 span → 验证「每请求 3 span、100% 全采样（`sr=1`）、无丢失」。
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
| **采样率 `sr`** | 本环境 **100% 全采样**（`acp-common-java` Instrumentation `parentbased_traceidratio`、`argument=1`）。采样在**应用侧 SDK** 决策，非 Collector。若调小 `argument`（如 `0.1`）或在 Collector 增加采样处理器，则仅命中 span 落盘。 | 结果 **× 采样率**（如 10% 采样则 ×0.1；**当前 =1，不缩减**） |
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
  sr         = 采样率（全采样/无采样 = 1.0；本环境实测 = 1.0）
  retention  = 保留天数（默认 7）

每秒 span 数        span/s      = QPS × S_trace × sr
每日新增容量        Daily       = span/s × 86400 × B_span × k_attr
常驻总容量          Resident    = Daily × retention
每数据节点占用      PerNode     ≈ Resident ÷ 数据节点数（本环境 3）
建议采购容量        Provision   = Resident ÷ 0.7
```

> 💡 `span/s`（或每日 span 数）**优先直接从 OTel Collector 指标读取**（第七章方法 A，`otelcol_exporter_sent_spans{exporter="jaeger_storage_exporter"}`），比 `QPS × 每链 span 数` 估算更准。后者用于**容量预测 / 尚未上线**、或对指标结果做二次校核的场景。

### 6.2 场景表（含 1 副本、`sr=1` 全采样、retention=7、k_attr=1.0）

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

假设客户：**80 个服务、峰值 150 QPS、平均每链 12 span、含 DB 调用（k_attr=1.5）、`sr=1` 全采样、1 副本、保留 7 天**：

```
span/s   = 150 × 12 × 1.0            = 1,800 span/s
每日新增 = 1,800 × 86400 × 2.6KB × 1.5 ≈ 289 GB/天
7 天常驻 = 289 × 7                    ≈ 2.03 TB
每节点   = 2.03TB ÷ 3                 ≈ 0.68 TB/数据节点
建议采购 = 2.03TB ÷ 0.7              ≈ 2.9 TB（集群总可用，约 1.0 TB/节点）
```

---

## 七、用实时指标 / 索引实测估算每日容量（强烈推荐）

有两种互补的实测方法直接得到「每日 span 数 / 每日容量」，均比纯 QPS 估算更准：

- **方法 A（推荐，估算每日调用链量）**：读 OTel Collector 指标，得实时/近 24h 落库 span 数，× 单价换算容量。无需访问 OpenSearch，适合日常估算与监控。
- **方法 B（校准单价 / 复核）**：直接读 OpenSearch 索引 `store.size` 标定「单 span 含副本字节」，也可用「昨日完整索引大小」直接得一天真实容量。

### 7.1 方法 A：用 OTel Collector 指标估算每日调用链量

OTel Collector 内部遥测指标（`otelcol_*`）已被 ACP kube-prometheus 采集。本环境链路含**两个 collector**：

| collector | Prometheus `job` | 作用 | 关键指标 |
|---|---|---|---|
| `otel` | `otel-collector-monitoring` | 接收应用 span，`load_balancing` 转发 | `otelcol_receiver_accepted_spans`（应用侧入口流量）|
| `jaeger` | `jaeger-collector-monitoring` | 接收后经 `jaeger_storage_exporter` **写入 OpenSearch** | `otelcol_exporter_sent_spans{exporter="jaeger_storage_exporter"}`（**落库量，容量核心**）|

> ⚠️ traces 管道同时挂了 `debug` exporter，`sum(otelcol_exporter_sent_spans)` 会**重复计数**，**必须用 `exporter="jaeger_storage_exporter"` 过滤**，只取写入 OpenSearch 的那一路。

**监控访问**（本环境）：

```bash
PROM='https://192.168.143.187:11780/clusters/business-1/prometheus'
# 凭据取自 secret（勿硬编码）：
U=$(kubectl get secret -n cpaas-system kube-prometheus-prometheus-basic-auth -o jsonpath='{.data.username}' | base64 -d)
P=$(kubectl get secret -n cpaas-system kube-prometheus-prometheus-basic-auth -o jsonpath='{.data.password}' | base64 -d)
q(){ curl -sk -u "$U:$P" -G "$PROM/api/v1/query" --data-urlencode "query=$1"; }
# 用法：q 'sum(rate(otelcol_exporter_sent_spans{exporter="jaeger_storage_exporter"}[5m]))'
```

也可直接在 ACP 监控（Prometheus / Grafana）界面执行下列 PromQL。

**核心查询**：

```promql
# ① 当前写入 OpenSearch 的 span 速率 (span/s)
sum(rate(otelcol_exporter_sent_spans{exporter="jaeger_storage_exporter"}[5m]))

# ② 最近 24h 实际落库 span 数 = 每日 span 量（★ 容量估算首选）
sum(increase(otelcol_exporter_sent_spans{exporter="jaeger_storage_exporter"}[24h]))

# ③ 按当前速率外推每日 span 量（流量平稳时用）
sum(rate(otelcol_exporter_sent_spans{exporter="jaeger_storage_exporter"}[5m])) * 86400

# ④ 应用侧接收速率（进入追踪管道的 span/s）
sum(rate(otelcol_receiver_accepted_spans{job="jaeger-collector-monitoring"}[5m]))

# ⑤ 每日调用链数（按每链平均 span 数换算；本 demo 每链 3 span）
sum(increase(otelcol_exporter_sent_spans{exporter="jaeger_storage_exporter"}[24h])) / 3

# ⑥ 数据完整性（应为 0，>0 表示丢数据/背压）
sum(rate(otelcol_exporter_send_failed_spans{exporter="jaeger_storage_exporter"}[5m]))
sum(rate(otelcol_receiver_refused_spans[5m]))
```

**由指标直接估算容量（最短路径）**：

```
每日落库 span 数     = 查询 ②
每日新增容量(含副本) ≈ 查询 ② × 2.6 KB × k_attr
7 天常驻容量         ≈ 每日新增 × (retention / 7)
```

**实测交叉验证（证明「指标计数 = 落库 span 数」）**：发送 200 个测试请求（应产生 200×3 = 600 业务 span），期间 `jaeger_storage_exporter` 计数增量实测 **636**，与「600 业务 span + 约 36 背景健康检查 span（约 3 分钟窗口 × 0.2 span/s）」吻合。**说明查询 ② 的 span 数即实际写入 OpenSearch、驱动容量的 span 数**，可直接乘单价换算容量。

> 说明：`increase[24h]` 需 collector 已稳定运行满 24h（否则会外推、偏差大）；collector Pod 重启会使计数器归零，`rate` / `increase` 已自动处理。流量波动大时用方法 B 的「昨日完整索引大小」复核。

### 7.2 方法 B：直接读 OpenSearch 索引大小（校准单价 / 复核）

单 span 体量对属性数量极敏感，最可靠的是用客户真实流量跑 1 天后直接测量索引。命令（在可访问 OpenSearch 的 Pod 内执行，替换 `$OS` 与索引日期）：

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

# 单 span 含副本字节 = store.size ÷ 真实span数（第②步）
# 每日新增容量      = 当天完整索引的 store.size（直接就是一天的真实落库容量，含副本）
```

> 提示：取一个已写满整天、且被 index-cleaner 尚未删除的**完整日期索引**测量最准。用「昨天」的索引 `store.size` 即为一天的真实新增容量（含副本）；两法结果应相互印证。

---

## 八、运维建议

1. **磁盘规划**：按第六章估算 7 天常驻容量，除以数据节点数得每节点占用，再 ÷0.7 预留水位余量作为采购基线；关注 OpenSearch `cluster.routing.allocation.disk.watermark`（默认 low 85% / high 90%）。
2. **控成本手段**（按优先级）：
   - **缩短保留天数**：`JAEGER_INDEX_RETENTION_DAYS`（如 3 天则常驻容量 ≈ ×3/7）；
   - **开启 / 调低采样**：当前为 **100% 全采样**；可在 `acp-common-java` Instrumentation 调小 `sampler.argument`（如 `0.1` = 10%），或在 OTel Collector 增加 `probabilistic_sampler` / 尾部采样，容量按采样率线性下降；
   - **副本降为 0**：非关键环境可 `replicas=0`，磁盘减半，但**丧失冗余，生产不建议**；
   - **裁剪属性**：通过 Collector `attributes/transform` processor 丢弃冗余大属性。
3. **监控**：用第七章方法 A 的 PromQL 对 `otelcol_exporter_sent_spans{exporter="jaeger_storage_exporter"}` 做落库速率 / 每日增量趋势监控；对 span 索引 `store.size` 与数据节点磁盘使用率告警；关注 `otelcol_exporter_send_failed_spans`、`otelcol_receiver_refused_spans`（>0 表示丢数据）。
4. **index-cleaner**：确认 `jaeger-es-index-cleaner` CronJob 正常执行（本环境 `30 2 * * *`），避免旧索引堆积撑爆磁盘。
5. **验证口径**：任何容量核对都用**查询层 `_count`** 取 span 数、用 `store.size`（含副本）取磁盘占用，切勿用 `docs.count`。

---

## 附录 A：实测原始数据

| 项 | 数值 |
|---|---|
| OpenSearch 版本 | 3.3.1 / Lucene 10.3.1 / 3 数据节点 / green |
| 索引 | `acp-business-1-jaeger-span-2026-07-06`，5 shards / 1 replica |
| 采样 | `acp-common-java` Instrumentation（`otelv2-java-demo`）：`parentbased_traceidratio` / `argument=1` = **100% 全采样**；应用上报 `otel-collector.jaeger-system.svc:4318` |
| 标定 | 100 请求 → 300 span（1:3，全采样、无丢失） |
| 纯业务样本 | 4,933 span = 1,644 链 × 3 span（删除 272 健康检查 span 后） |
| Lucene 文档数 | 208,831（≈42 docs/span，nested 放大） |
| 主分片大小 `pri.store.size` | 5,721,465 B |
| 含副本大小 `store.size` | 11,469,162 B |
| 单 span 主分片（压实/实况） | 1,160 B / ≈1,308 B |
| 单 span 含副本（压实/实况） | 2,325 B / ≈2,622 B |
| 单 span 原始 `_source` JSON | 3,671 B（17 span 标签 + 26 资源属性），压缩比 0.32× |
| retention | 7 天（index-cleaner args=`["7", ...]`） |
| 落库指标 | `otelcol_exporter_sent_spans{exporter="jaeger_storage_exporter"}`（jaeger-collector，job=`jaeger-collector-monitoring`）= 写入 OpenSearch 的 span 数 |
| 指标交叉验证 | 发送 200 请求 → 该指标增量 **636** ≈ 600 业务 + ~36 背景 span，印证「指标计数 = 落库 span 数」 |
| 背景流量 | K8s 探针 `/actuator/health` 约 0.2 span/s（1h ≈ 720 span）；`otelcol_exporter_send_failed_spans` 无数据、`otelcol_receiver_refused_spans`=0（无丢数据） |
| 监控端点 | `https://192.168.143.187:11780/clusters/business-1/prometheus`；basic-auth 凭据在 secret `kube-prometheus-prometheus-basic-auth`（`cpaas-system`） |

## 附录 B：容量单价速查（含 1 副本，规划值）

- 单 span ≈ **2.6 KB**
- 单调用链（3 span）≈ **7.7 KB**
- 1 万条 3-span 调用链 ≈ **75 MB**
- 100 万 span ≈ **2.5 GB**
- 1 亿 span ≈ **242 GB**

> 以上为「精简 HTTP span」基准，富属性场景请乘 `k_attr`（1.3~3）。
