# Service Graph Connector 与 Span Metrics Connector 同时多副本（高可用）的部署设计

> 设计文档 · 中文 · 2026-06-29

> 关联文档：[`spanmetrics-connector-ha.md`](./spanmetrics-connector-ha.md)（仅 spanmetrics 的多副本方案）。本文在其基础上加入 servicegraph connector。

## 1. 问题

是否能**同时**使用 Service Graph Connector 和 Span Metrics Connector，并且**相关组件全部支持多副本（高可用）**？如果能，如何配置？

**直接结论：**

| 问题                                | 答案                                                                                       |
| :---------------------------------- | :----------------------------------------------------------------------------------------- |
| 两个连接器 + 全部多副本，能支持吗？ | ✅ **能**，但不能共用一套负载均衡                                                          |
| 为什么                              | spanmetrics 要 `routing_key: service`，servicegraph 要 `routing_key: traceID`，二者互斥    |
| 怎么配                              | 前置无状态层**分叉成两套 loadbalancing exporter**，各按各的 key 路由到各自的有状态连接器层 |
| 一个隐藏前提                        | 「Service Graph」在 Jaeger 语境里有歧义，先看第 2 节                                       |

---

## 2. 先厘清：你说的「Service Graph」是哪一个？（这决定架构）

这一步最关键，因为核实后发现 **Jaeger UI 并不消费 servicegraph connector 的输出**：

| 你想要的东西                                                              | 由谁产生                                                                                                  | 与 servicegraph connector 的关系                                                                                   |
| :------------------------------------------------------------------------ | :-------------------------------------------------------------------------------------------------------- | :----------------------------------------------------------------------------------------------------------------- |
| **Jaeger 自带的依赖图**（"System Architecture" / Dependencies 标签页）    | **spark-dependencies / Flink 批处理作业**读取 ES 里的 span 计算依赖边，写回存储                           | ❌ 无关。Jaeger v2 **根本没打包** servicegraph connector（架构文档里内嵌的连接器只有 `Span Metrics` 和 `Forward`） |
| **Grafana 的 Service Graph / Node Graph 面板**（带请求率/延迟的服务拓扑） | **OTel servicegraph connector** → 产出 `traces_service_graph_request_total` 等指标 → Prometheus → Grafana | ✅ 这才是 servicegraph connector 的用途                                                                            |
| **Jaeger Monitor 标签页**（RED 指标）                                     | **spanmetrics connector**                                                                                 | ——                                                                                                                 |

**两个重要推论：**

1. **如果你要的是 Jaeger 自带的依赖图** → 那根本用不着 servicegraph connector，也就**没有路由冲突问题**。它是个周期性批作业，从 ES 读全量 span 算依赖边，**对 span 路由亲和性零要求**，天然兼容任意多副本。这种情况下你只需要管 spanmetrics 的 HA（即关联文档的结论），servicegraph 不参与。
2. **如果你要的是 Grafana 的服务拓扑图（真正的 servicegraph connector）** → 因为 Jaeger v2 没打包它，你必须**单独跑一个标准的 collector-contrib 发行版**来承载它。第 3–4 节就是这个场景。

> 下面假设你确实要 **servicegraph connector + spanmetrics connector 两者都跑、都多副本**。

---

## 3. 为什么不能共用一套负载均衡（核心冲突）

| 连接器           | 需要的 routing_key | 原因（一手来源原文）                                                                                                                                                                              |
| :--------------- | :----------------- | :------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **spanmetrics**  | **`service`**      | loadbalancing README：按 `traceID` 路由会让「每个 collector 都看到 `service+operation` 标签」→ Prometheus **标签冲突**；按 service 路由则「每个 collector 只看到一个 service name，可无冲突推送」 |
| **servicegraph** | **`traceID`**      | servicegraph README：「该连接器必须处理一条边的**两端**……如果一条 trace 的 span 分散在多个实例上，就无法可靠配对。解决办法是在运行此连接器的实例前面加一层 load balancing exporter」              |

冲突的本质：servicegraph 要把 **client span（service A）和 server span（service B）** 配对，它们**同一个 traceID 但不同 service** → 必须按 traceID 路由才能落到同一实例；而 spanmetrics 按 service 聚合 → 必须按 service 路由。**同一份 span 流不可能同时按两种 key 路由。**

官方明确的解法（Grafana Alloy 文档原话，servicegraph 与 tail-sampling 同属「要 traceID」那一类）：

> _"The tail sampling processor requires routing_key = 'traceID' whereas the spanmetrics connector requires routing_key = 'service'. **To load balance both types of components, two different sets of load balancers have to be set up**: one set with routing_key = 'traceID' ... and another set with routing_key = 'service' for span metrics."_

---

## 4. 能支持 —— 配置方案：前置层分叉成两套 LB

### 4.1 拓扑

```
                          apps (OTLP)
                              │
                              ▼
        ┌─────────────────────────────────────────────┐
        │  Tier 1：前置 OTel Collector（无状态，副本 N）   │
        │  traces 管道分叉到两个 loadbalancing exporter   │
        └───────────────┬───────────────────┬───────────┘
            routing_key=service        routing_key=traceID
                        │                       │
                        ▼                       ▼
        ┌───────────────────────┐   ┌───────────────────────────┐
        │ Tier 2a：Jaeger 层      │   │ Tier 2b：servicegraph 层    │
        │ （副本 N）              │   │ 独立 contrib collector（N）  │
        │ • 存储 traces → ES     │   │ • servicegraph connector    │
        │ • spanmetrics connector│   │                             │
        └──────────┬────────────┘   └─────────────┬──────────────┘
                   │ prometheus                    │ prometheus
                   ▼                               ▼
            PromQL 存储 ──► Jaeger Monitor    PromQL 存储 ──► Grafana 服务拓扑
```

> 关于 routing_key 的澄清：loadbalancing README 说 `traceID` "invalid for metrics"，指的是当你负载均衡一条 **metrics 信号**管道时不能用 traceID。这里我们路由的是 **traces（span）信号**，按 traceID 路由 span 完全合法 —— 这正是 servicegraph/tail-sampling 的标准做法。

### 4.2 Tier 1（前置层）—— 分叉两套 LB

```yaml
exporters:
  loadbalancing/spanmetrics: # → 喂 Jaeger（spanmetrics）
    routing_key: service
    protocol: { otlp: { tls: { insecure: true } } }
    resolver:
      k8s:
        service: ${JAEGER_INSTANCE_NAME}-collector.${JAEGER_NS}
        ports: [4317]
  loadbalancing/servicegraph: # → 喂独立的 servicegraph 层
    routing_key: traceID
    protocol: { otlp: { tls: { insecure: true } } }
    resolver:
      k8s:
        service: servicegraph-collector.${JAEGER_NS}
        ports: [4317]
service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [loadbalancing/spanmetrics, loadbalancing/servicegraph] # 每个 span 同时分发到两边
```

### 4.3 Tier 2a（Jaeger 层，多副本）—— 收 service 路由的 span，做存储 + spanmetrics

```yaml
connectors: { spanmetrics: {} }
service:
  pipelines:
    traces: # 收到的是 service 路由后的 span
      exporters: [jaeger_storage_exporter, spanmetrics]
    metrics/spanmetrics:
      receivers: [spanmetrics]
      exporters: [prometheus]
```

> 该层的多副本正确性细节见关联文档 [`spanmetrics-connector-ha.md`](./spanmetrics-connector-ha.md)。

### 4.4 Tier 2b（servicegraph 层，独立 contrib collector，多副本）—— 收 traceID 路由的 span

```yaml
connectors: { servicegraph: {} }
service:
  pipelines:
    traces: # 收到的是 traceID 路由后的 span，一条 trace 的两端都在同一实例
      exporters: [servicegraph]
    metrics/servicegraph:
      receivers: [servicegraph]
      exporters: [prometheus]
```

---

## 5. 各组件 HA 一览

| 组件                                 | 是否可多副本 | 靠什么保证正确                                              |
| :----------------------------------- | :----------- | :---------------------------------------------------------- |
| Tier 1 前置 collector                | ✅ 任意扩    | 无状态，不做聚合                                            |
| Tier 2a Jaeger（存储 + spanmetrics） | ✅ N 副本    | 前置层 `routing_key: service` → 每个 service 只落一个实例   |
| Tier 2b servicegraph                 | ✅ N 副本    | 前置层 `routing_key: traceID` → 一条 trace 的两端落同一实例 |
| Jaeger 自带依赖图                    | ✅           | spark/Flink 批作业读 ES，与路由无关                         |

---

## 6. 必须注意的坑

1. **servicegraph 不在 Jaeger v2 里** → Tier 2b 必须用**标准 collector-contrib** 镜像，不能用 Jaeger 镜像（Jaeger v2 内嵌的连接器只有 Span Metrics 和 Forward）。
2. **servicegraph 的输出喂 Grafana，不喂 Jaeger UI**。别指望它点亮 Jaeger 的依赖图 —— 那是另一套（spark/Flink）。
3. **两层都有计数器重置问题**：滚动更新/扩缩容时会出现瞬时非单调，需正确设置 `resource_metrics_key_attributes`，并靠 PromQL `rate()`/`increase()` 容忍重置。
4. **`service` 路由热点**：单个大流量 service 会整体压到一个 Jaeger 副本（存储 + 指标都在那个副本）。若担心存储热点，可把存储路径和 spanmetrics 路径解耦 —— 存储走 traceID/轮询到 Jaeger，spanmetrics 单独建一个 service 路由的专用层（代价是多一个组件）。
5. **servicegraph 配对窗口**：它有内存配对 store 和等待超时（`store.ttl` 等），未配对的 span 会计入 `traces_service_graph_unpaired_spans_total`。traceID 路由能消除「因路由导致的」未配对；但跨实例的 span 仍可能因采样/埋点缺失而真正未配对。
6. **servicegraph 指标基数可能很高**（社区有相关 issue，如 #34843），上线前评估 Prometheus 容量。

---

## 7. 一句话决策建议

- **只想要 Jaeger 里的服务依赖图** → 不用碰 servicegraph connector，spark/Flink 作业即可，只需按关联文档处理 spanmetrics 的 HA。
- **要 Grafana 级别的实时服务拓扑（servicegraph connector）+ Jaeger Monitor（spanmetrics），且都多副本** → 第 4 节的「两套 LB 分流」，这是唯一正确的横向扩展方式。
- 若某一层吞吐其实单实例扛得住，可把该连接器固定为单副本（天然单写入者），省掉对应那套 LB。

---

## 8. 来源

- [servicegraph connector README](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/connector/servicegraphconnector/README.md) —— 需处理边的两端、需 LB 前置；指标名 `traces_service_graph_*`
- [loadbalancing exporter README](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/exporter/loadbalancingexporter/README.md) —— routing_key 取值、service vs traceID
- [Grafana Alloy loadbalancing 文档](https://grafana.com/docs/alloy/latest/reference/components/otelcol/otelcol.exporter.loadbalancing/) —— 「两套负载均衡」、servicegraph 用 traceID
- [Jaeger v2 架构](https://www.jaegertracing.io/docs/2.18/architecture/) —— 内嵌连接器仅 Span Metrics + Forward
- [spark-dependencies](https://github.com/jaegertracing/spark-dependencies) 与 [Jaeger FAQ](https://www.jaegertracing.io/docs/next-release-v2/faq/) —— 依赖图由批作业从存储计算
