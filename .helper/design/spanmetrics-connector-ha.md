# Span Metrics Connector 多副本（高可用）下的 SPM 部署设计

> 设计文档 · 中文 · 2026-06-29

## 1. 背景与前提

文档位置：`distributed-tracing-docs/docs/en/installing/installing-distributed-tracing.mdx` 的
**「(Optional) Enabling Service Performance Monitoring (SPM)」** 小节。

当前文档的做法（两个组件均 `replicas: 1`）：

| 组件                                  | 角色                | spanmetrics 位置                                                                                                                   | 指标路径                                                                        |
| :------------------------------------ | :------------------ | :--------------------------------------------------------------------------------------------------------------------------------- | :------------------------------------------------------------------------------ |
| 前置 OTel Collector（`otel`）         | 接收 + 转发         | **在这里** —— `traces` 管道 → `spanmetrics` connector → `metrics/spanmetrics` 管道 → `prometheus` exporter（`:8889`，pull 拉取式） | ACP Prometheus 通过 ServiceMonitor 抓取                                         |
| Jaeger v2（`OpenTelemetryCollector`） | 存储（ES）+ 查询/UI | 无                                                                                                                                 | `jaeger_query` 通过 PromQL 从 ACP Prometheus 反查 RED 指标，点亮 Monitor 标签页 |

**本设计的前提（硬性要求）：**

> **OTel Collector 与 Jaeger 都必须支持多副本（`replicas > 1`）以实现高可用。**

这个前提是后续所有结论的关键约束。正是「两个组件都要多副本」这一条，**唯一地**把方案收敛到「两层 gateway + 按 `service` 负载均衡」—— 见第 4 节。

---

## 2. 问题确认：spanmetrics 在多副本下为什么会出错

**结论：把 spanmetrics 直接放在多副本组件里，RED 指标会算错。** 这是 OTel 官方明确承认的限制。

**根因：spanmetrics 是有状态、按 span 聚合的连接器，违反 Single Writer Principle。**

- spanmetrics 把每个 span 累加进**内存中**的 RED series（`calls_total`、duration 直方图），默认每 60s flush 一次。
- 多副本时，每个副本都是**独立的聚合器**，各自发出**同一组 `(service, operation)` 标签**的 series，但计数各不相同。Prometheus 抓取时会在多个实例间「跳来跳去」。
  - issue #32043 原话：_"the metric seems to jump from collector to collector. Each collector has a different current sum metric."_
- OTel scaling 文档原话：_"When different collectors receive data related to the same service, aggregations based on the service name will be **inaccurate**."_
- 后果：计数非单调、分位数错误、扩缩容/重启时计数器重置。

**两个必须知道的细节：**

1. **当前文档（`replicas: 1`）其实没问题。** 当前配置在单副本下是正确的；这是一个**无法横向扩展**的限制，而不是当前配置的 bug。本设计要解决的是「升到多副本后」的正确性。
2. **`includeCollectorInstanceID` 特性门控在新版本默认开启。** 它给每个副本的 metrics 加一个 `collector.instance.id` UUID 维度，只是让「裸标签冲突」变成「每副本一条独立 series」以满足数据模型，**并不会把它们合并成一条正确的 service 级聚合**。所以即使在新版上，多副本的 SPM 数字依然不可信（碎片化 + 计数器重置）。

---

## 3. 为什么本前提排除了「单写入者」简化方案

如果**只有前置 OTel Collector 需要多副本**，其实有一个更简单的解法：把 spanmetrics 从前置 collector 移走，固定在**单副本**的 Jaeger（或一个单副本专用 collector）里 —— 单实例天然是「单写入者」，聚合正确；前置 collector 则无状态、随意扩。OTel `spanmetricsconnector` README 自己就建议为 Prometheus 用 _"a dedicated pipeline with a single spanmetricsconnector instance"_。

但**本设计的前提要求 Jaeger 也必须多副本**。一旦 Jaeger 扩到 N 副本、且每个副本都跑 spanmetrics 并接收同一个 service 的 span，就会在 Jaeger 内部**原样复现**第 2 节的多写入者问题。

> 因此，在「两者都要多副本」的前提下，单写入者方案不可用，**必须引入确定性路由**，让每个 service 的 span 只落到唯一一个跑 spanmetrics 的实例上。这就强制走向第 4 节的两层 gateway 方案。

---

## 4. 方案：两层 gateway + Load Balancing Exporter（`routing_key: service`）

这正是 OTel 官方为「有状态处理 + 横向扩展」推荐的 two-tier gateway 模式，并且因为 **Jaeger v2 本身就是内嵌了 Span Metrics 连接器 + Prometheus exporter 的 OTel Collector 发行版**，把 spanmetrics 放进 Jaeger 是合法且等价的。

### 4.1 拓扑

```
                       apps (OTLP)
                           │
                           ▼
   ┌───────────────────────────────────────────────┐
   │  Tier 1：前置 OTel Collector `otel`（无状态，多副本）│
   │  traces 管道用 loadbalancing exporter            │
   │  routing_key: service                           │
   └───────────────────────┬─────────────────────────┘
                 按 service 一致性哈希
                           │  （同一 service 的所有 span → 同一个 Jaeger 副本）
                           ▼
   ┌───────────────────────────────────────────────┐
   │  Tier 2：Jaeger v2（多副本）                      │
   │  • 存储 traces → ES                              │
   │  • spanmetrics connector → prometheus(:8889)    │
   └───────────────────────┬─────────────────────────┘
                           │ ACP Prometheus 抓取
                           ▼
                    PromQL 存储 ──► Jaeger Monitor 标签页
```

### 4.2 两个关键点

**① `routing_key` 必须是 `service`，不能用默认的 `traceID`。** 这是整个方案的命门：

- `routing_key: service` → 同一个 service 的所有 span 都路由到**同一个**下游实例 → 该 service 的指标由唯一一个 spanmetrics 实例聚合。OTel gateway 文档原话：_"all spans of a service are sent to the same downstream Collector for metric collection, **guaranteeing accurate aggregations**."_ 而且每个实例只看到一个 service name，**不会有标签冲突**。
- `routing_key: traceID`（默认值）→ 同一个 service 的 span（来自不同 trace）会被**打散**到不同副本，重新制造碎片化和标签冲突。`loadbalancingexporter` README 把 `traceID` 对 metrics 标注为 **"Invalid"**。`traceID` 路由是给 tail-sampling 用的，不是给 spanmetrics 用的。

> 注意：`traceID` "invalid for metrics" 指的是负载均衡一条 **metrics 信号**管道；这里 Tier 1 路由的是 **traces（span）信号**，按 service 路由 span 完全合法。

**② 真正的修复是「每条 series 单写入者」，而不是「放进 Jaeger」这个动作本身。** 把 spanmetrics 放在 Jaeger 还是放在专用 collector 是正交选择；让方案正确的是前置层的 `loadbalancing(routing_key=service)`。在本前提（Jaeger 也多副本）下，二者缺一不可。

---

## 5. 配置

> 以下用 `patch`/片段方式表达，命名沿用安装文档：前置 collector 名为 `otel`，Jaeger 实例名为 `${JAEGER_INSTANCE_NAME}`，命名空间 `${JAEGER_NS}`。

### 5.1 Tier 1 —— 前置 OTel Collector（多副本，用 loadbalancing 取代 otlp/traces）

```yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: otel
  namespace: ${JAEGER_NS}
spec:
  mode: deployment
  replicas: 2 # 多副本，无状态
  config:
    exporters:
      loadbalancing:
        routing_key: service # ← 必须是 service
        protocol:
          otlp:
            tls:
              insecure: true
        resolver:
          k8s: # k8s resolver 通过 Endpoints 发现 Jaeger 各 Pod IP
            service: ${JAEGER_INSTANCE_NAME}-collector.${JAEGER_NS}
            ports:
              - 4317
    service:
      pipelines:
        traces:
          receivers: [otlp, zipkin]
          processors: [memory_limiter, batch]
          exporters: [debug, loadbalancing] # 用 loadbalancing 取代原来的 otlp/traces
```

> **RBAC**：`k8s` resolver 需要 collector 的 ServiceAccount 具备对 `endpoints` 的 `get/list/watch` 权限。若用 `dns` resolver，则需为 Jaeger collector 建一个 **headless service**（`clusterIP: None`）。

### 5.2 Tier 2 —— Jaeger v2（多副本，运行 spanmetrics）

```yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: ${JAEGER_INSTANCE_NAME}
  namespace: ${JAEGER_NS}
spec:
  mode: deployment
  replicas: 2 # 多副本；按 service 路由后各副本聚合互不重叠
  config:
    connectors:
      spanmetrics: {}
    exporters:
      prometheus:
        add_metric_suffixes: false # Jaeger 期望不带 _total 后缀的标准 OTel 指标名
        endpoint: 0.0.0.0:8889
        resource_to_telemetry_conversion:
          enabled: true
    service:
      pipelines:
        traces: # 收到的是 Tier 1 按 service 路由后的 span
          exporters: [jaeger_storage_exporter, spanmetrics] # 存储 + 指标
        metrics/spanmetrics:
          receivers: [spanmetrics]
          exporters: [prometheus]
```

**为什么这样就正确：** 前置层按 service 一致性哈希后，每个 service 的 span 只会落到唯一一个 Jaeger 副本；各副本因此负责**互不重叠**的 service 集合，各自产出完整、无冲突的 `(service, operation)` series。ACP Prometheus 抓取所有副本后取并集 = 完整全貌；任一 Jaeger 副本的 `jaeger_query` 从同一个 PromQL 存储读到的都是完整数据。存储路径同样被 service 分片到各副本写入 ES，对存储无害（span 独立写入，查询时按 traceID 重组）。

---

## 6. 各组件 HA 一览

| 组件                                  | 是否多副本 | 靠什么保证正确                                                    |
| :------------------------------------ | :--------- | :---------------------------------------------------------------- |
| Tier 1 前置 OTel Collector `otel`     | ✅ 任意扩  | 无状态，不做聚合                                                  |
| Tier 2 Jaeger（存储 + spanmetrics）   | ✅ N 副本  | 前置层 `routing_key: service` → 每个 service 只落一个 Jaeger 副本 |
| Jaeger `jaeger_query`（Monitor 读取） | ✅         | 从共享 PromQL 存储做无状态读                                      |

---

## 7. 注意事项（生产文档必须写明）

1. **计数器重置 / 滚动更新**：即便是本方案的正确拓扑，Jaeger 副本重启/扩缩容时仍会出现瞬时非单调（issue #33136 的根因）。需正确设置 `resource_metrics_key_attributes`，并依赖 PromQL `rate()`/`increase()` 的重置容忍。
2. **`service` 路由热点**：单个超大流量 service 会被整体哈希到一个 Jaeger 副本上（存储 + 指标都压在那个副本）。OTel 文档承认负载不按容量均衡。若担心存储热点，可把**存储路径与 spanmetrics 路径解耦**：存储走 traceID/轮询到 Jaeger，spanmetrics 另建一个 `service` 路由的专用层（代价是多一个组件）。
3. **resolver 与 RBAC**：`k8s` resolver 需要 `endpoints` 读权限；`dns` resolver 需要 headless service。否则 exporter 发现不了 Jaeger 各 Pod，亲和路由失效。
4. **Jaeger 官方 SPM 文档完全没有 HA 指引** —— 多副本聚合正确性的指引只存在于 OTel Collector 文档与组件 README。本设计的内容需要从 OTel 来源自行补写到 Alauda 文档中。

---

## 8. 对安装文档的落地建议

1. **现状（`replicas: 1`）不必改「对错」**：在 SPM 小节加一句适用范围说明，例如「本节将 spanmetrics 配置在 OTel Collector，仅适用于单副本部署；多副本（HA）见下方说明」。
2. **新增「SPM 高可用」小节**：直接给出本文第 4–5 节的两层 gateway + `routing_key: service` 方案，并把第 7 节四个坑写成 warning。
3. 同步修订 `configuration/spm.mdx` 的 Architecture 段，补一句「多副本聚合必须满足单写入者原则」的约束。

---

## 9. 来源（均为一手/官方）

- [spanmetricsconnector README](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/connector/spanmetricsconnector/README.md) —— _Known Limitation: the Single Writer Principle_；建议单实例专用管道
- [loadbalancingexporter README](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/exporter/loadbalancingexporter/README.md) —— `routing_key` 取值、`traceID` 对 metrics "Invalid"、`service` 避免标签冲突
- [OTel Collector scaling](https://opentelemetry.io/docs/collector/scaling/) 与 [gateway](https://opentelemetry.io/docs/collector/deploy/gateway/) —— 两层 gateway，"guaranteeing accurate aggregations"
- [Jaeger v2 架构](https://www.jaegertracing.io/docs/2.18/architecture/) —— Jaeger v2 是内嵌 Span Metrics + Prometheus exporter 的 OTel Collector 发行版
- GitHub issue [#32043](https://github.com/open-telemetry/opentelemetry-collector-contrib/issues/32043)（复现）/ [#33136](https://github.com/open-telemetry/opentelemetry-collector-contrib/issues/33136)（根因：计数器重置 + 配置）
