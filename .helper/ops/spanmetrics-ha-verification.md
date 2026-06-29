# Span Metrics 多副本（高可用）扩容验证手册

> 适用分支：`perf/span-metrics` · 中文 · 2026-06-29
>
> 关联设计文档：[`../design/spanmetrics-connector-ha.md`](../design/spanmetrics-connector-ha.md)

## 1. 目的

`perf/span-metrics` 分支将 SPM（Service Performance Monitoring）改造为**两层 gateway 拓扑**：

- **前置 OTel Collector（`otel`）**：无状态，`traces` 管道用 `loadbalancing` exporter 按 `routing_key: service` 把 span 路由到 Jaeger。
- **Jaeger（`${JAEGER_INSTANCE_NAME}`）**：运行 `spanmetrics` connector 生成 RED 指标，并通过 `prometheus` exporter（`:8889`）暴露。

本手册用于在**已按安装文档部署并启用 SPM** 的环境上，手动把 OTel Collector 和 Jaeger 扩容到多副本，并验证扩容后 **span-metrics 指标依然正确**——即满足「单写入者原则」：每个 service 的 RED 指标只由**唯一一个** Jaeger 副本聚合，不碎片化、不重复计数。

## 2. 为什么多副本需要专门验证

`spanmetrics` 是**有状态**连接器：它把每个 span 累加进**内存中**的 RED series（`calls`、`duration` 直方图）。如果多个副本都聚合**同一个 service** 的 span，每个副本各自发出同一组 `(service, operation)` 标签但计数互不相同的 series，Prometheus 抓取时会在副本间「跳来跳去」，导致计数非单调、分位数错误——这违反了 [Single Writer Principle](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/connector/spanmetricsconnector/README.md)。

两层 gateway 方案通过前置层 `routing_key: service` 的一致性哈希，保证**同一个 service 的所有 span 恒定路由到同一个 Jaeger 副本**，因此每个 service 只被一个副本聚合。本手册的验证目标，就是用实测数据确认这一点在多副本下成立。

## 3. 前提条件

- 已按安装文档（[Elasticsearch](../../docs/en/installing/installing-distributed-tracing-elasticsearch.mdx) 或 [OpenSearch](../../docs/en/installing/installing-distributed-tracing-opensearch.mdx)）完成部署，并执行了「(Optional) Enabling Service Performance Monitoring (SPM)」章节启用 SPM（新方案）。
- `kubectl` 可访问集群，具备 `jaeger-system` 命名空间的操作权限。
- 已设置与安装文档一致的环境变量：

  ```bash
  export JAEGER_NS="jaeger-system"      # Jaeger 所在命名空间
  export JAEGER_INSTANCE_NAME="jaeger"  # Jaeger 实例名
  ```

## 4. 步骤一：确认当前为新方案 SPM 拓扑

扩容前先确认前置 Collector 已用 `loadbalancing` 按 `service` 路由、Jaeger 已运行 `spanmetrics`：

```bash
# 前置 otel 的 routing_key 应为 service
kubectl -n ${JAEGER_NS} get opentelemetrycollector otel \
  -o jsonpath='{.spec.config.exporters.loadbalancing.routing_key}{"\n"}'

# Jaeger 的 connectors 应包含 spanmetrics
kubectl -n ${JAEGER_NS} get opentelemetrycollector ${JAEGER_INSTANCE_NAME} \
  -o jsonpath='{.spec.config.connectors}{"\n"}'
```

期望输出：第一条为 `service`，第二条包含 `spanmetrics`。若不符，请先按安装文档完成 SPM 配置。

## 5. 步骤二：扩容 OTel Collector 与 Jaeger

`OpenTelemetryCollector` 由 Operator 管理，**必须修改 CR 的 `spec.replicas`**（直接 scale Deployment 会被 Operator 还原）。这里以 2 副本为例：

```bash
export REPLICAS=2

kubectl -n ${JAEGER_NS} patch opentelemetrycollector otel \
  --type=merge -p "{\"spec\":{\"replicas\":${REPLICAS}}}"
kubectl -n ${JAEGER_NS} patch opentelemetrycollector ${JAEGER_INSTANCE_NAME} \
  --type=merge -p "{\"spec\":{\"replicas\":${REPLICAS}}}"

# 等待两个 Deployment 滚动完成
kubectl -n ${JAEGER_NS} rollout status deployment/otel-collector --timeout=180s
kubectl -n ${JAEGER_NS} rollout status deployment/${JAEGER_INSTANCE_NAME}-collector --timeout=180s
```

确认副本均已就绪：

```bash
kubectl -n ${JAEGER_NS} get pod -l app.kubernetes.io/managed-by=opentelemetry-operator \
  | grep -E "otel-collector|${JAEGER_INSTANCE_NAME}-collector"
```

> **要点**：前置 Collector 无状态、可任意扩；Jaeger 扩到 N 副本后，靠前置层的 `routing_key: service` 保证每个 service 只落一个副本——这正是下一步要验证的。

## 6. 步骤三：发送多 service 测试流量

为了观察「不同 service 被分散路由、且每个 service 只落一个副本」，部署 6 个 **service 名各不相同** 的 `telemetrygen`，统一发往前置 Collector（`otel-collector:4317`）：

```bash
# 离线/内网环境请将镜像替换为内网仓库中的 telemetrygen 镜像
TELEMETRYGEN_IMAGE="ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest"

for i in $(seq 0 5); do
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: tg-svc-$i
  namespace: ${JAEGER_NS}
spec:
  restartPolicy: Never
  containers:
    - name: telemetrygen
      image: ${TELEMETRYGEN_IMAGE}
      args:
        - traces
        - --otlp-endpoint=otel-collector.${JAEGER_NS}.svc.cluster.local:4317
        - --otlp-insecure
        - --duration=30s
        - --rate=10
        - --service=spm-ha-svc-$i
        - --workers=1
EOF
done

# 等待全部发送完成
for i in $(seq 0 5); do
  kubectl -n ${JAEGER_NS} wait --for=jsonpath='{.status.phase}'=Succeeded pod/tg-svc-$i --timeout=120s
done
```

## 7. 步骤四：验证单写入者（核心）

逐个 Jaeger 副本查询其 `:8889` 暴露的 spanmetrics，提取每个副本上聚合的 service：

```bash
PODS=$(kubectl -n ${JAEGER_NS} get pod -l app.kubernetes.io/name=jaeger-collector \
  --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}')

i=0
for pod in $PODS; do
  port=$((18900 + i)); i=$((i + 1))
  # 用 timeout 自动回收端口转发，无需手动 kill
  timeout 12 kubectl -n ${JAEGER_NS} port-forward "pod/$pod" ${port}:8889 >/dev/null 2>&1 &
  out=$(curl -s --retry-connrefused --retry 12 --retry-delay 1 --max-time 15 "http://localhost:${port}/metrics")
  echo "=== 副本 $pod 上聚合的 service ==="
  echo "$out" | grep -oE 'service_name="spm-ha-svc-[0-9]+"' | sort -u
done
wait 2>/dev/null
```

### 判定标准

- ✅ **通过**：每个 `spm-ha-svc-X` 只出现在**一个**副本上（各副本的 service 集合两两不相交），且 6 个 service 的并集完整无缺失。这证明 `routing_key: service` 生效，每个 service 由唯一副本聚合，指标正确。
- ❌ **失败**：若同一个 `spm-ha-svc-X` 同时出现在多个副本上，说明该 service 的 span 被打散，spanmetrics 发生碎片化，RED 指标会重复/跳变。

### 真实环境示例输出（2 副本）

```text
=== 副本 jaeger-collector-69c7484c94-jkhm7 上聚合的 service ===
service_name="spm-ha-svc-0"
service_name="spm-ha-svc-1"
service_name="spm-ha-svc-3"
service_name="spm-ha-svc-4"
=== 副本 jaeger-collector-69c7484c94-xxgc8 上聚合的 service ===
service_name="spm-ha-svc-2"
service_name="spm-ha-svc-5"
```

6 个 service 分散到 2 个副本（4 + 2），互不重叠 → **验证通过**。

> **指标值为何正确**：由于每个 service 只在一个副本产生 `traces_span_metrics_calls`/`_duration`，ACP Prometheus 抓取所有副本后，每个 service 的指标来自唯一来源，不会因多副本重复累加而翻倍；Jaeger Monitor 标签页通过 PromQL `rate()` 读取，结果与单副本一致。

## 8. （可选）从 Jaeger UI 确认

登录 Jaeger UI 的 **Monitor** 标签页，依次选择 `spm-ha-svc-0` ~ `spm-ha-svc-5`，确认每个 service 的 Request/Error/Duration 曲线正常、连续、无异常跳变。

## 9. 步骤五：清理与缩容

```bash
# 删除测试流量 Pod
for i in $(seq 0 5); do kubectl -n ${JAEGER_NS} delete pod tg-svc-$i --ignore-not-found; done

# 缩容回单副本（按需保留多副本）
kubectl -n ${JAEGER_NS} patch opentelemetrycollector otel \
  --type=merge -p '{"spec":{"replicas":1}}'
kubectl -n ${JAEGER_NS} patch opentelemetrycollector ${JAEGER_INSTANCE_NAME} \
  --type=merge -p '{"spec":{"replicas":1}}'
```

## 10. 多副本下的注意事项

- **计数器重置**：Jaeger 副本滚动更新/扩缩容时，spanmetrics 计数器可能瞬时非单调。RED 指标应始终通过 PromQL `rate()`/`increase()` 消费，二者可容忍重置。
- **单 service 热点**：单个超大流量 service 会被整体哈希到一个 Jaeger 副本（存储 + 指标都压在该副本），负载按 service 数量而非请求量均衡。
- **headless Service 依赖**：前置层的 `dns` resolver 依赖 Operator 自动创建的 `${JAEGER_INSTANCE_NAME}-collector-headless`，请勿删除。

## 11. 自动化测试

本手册的验证逻辑已固化为自动化测试，见 `docs-runme-tests` 仓库：

- `run-tracing-all.sh` 的 **Case 3**（Elasticsearch）与 **Case 4**（OpenSearch）
- 测试脚本：`docs/en/installing/runme-test_spm-ha-elasticsearch.sh` / `runme-test_spm-ha-opensearch.sh`
