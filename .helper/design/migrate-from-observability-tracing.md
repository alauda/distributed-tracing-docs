# 从 Observability/Distributed Tracing 迁移到 Alauda Distributed Tracing

> 设计文档 · 中文 · 2026-05-08

## 1. 背景

| 维度 | 老方案（Observability/Distributed Tracing） | 新方案（Alauda Distributed Tracing） |
| :--- | :--- | :--- |
| Jaeger 版本 | 1.60.0 | 2.16.0 |
| Jaeger Operator | Alauda build of Jaeger（CRD：`jaegertracing.io/v1.Jaeger`） | Alauda Build of OpenTelemetry v2 Operator（通过 `opentelemetry.io/v1beta1.OpenTelemetryCollector` 部署 Jaeger Binary） |
| OTel Operator | Alauda build of OpenTelemetry（包名 `opentelemetry-operator`，0.108.0） | Alauda Build of OpenTelemetry v2（包名 `opentelemetry-operator2`，0.147.0） |
| 部署 OTel Collector 的命名空间 | 与 Operator **可以同名**（默认 `cpaas-system`） | **必须**与 Operator 不同（Operator 在 `opentelemetry-operator2`） |
| Java auto-instrumentation 镜像 | Operator 自带，可以不设置 `Instrumentation.spec.java.image` | Operator 不自带，**必须**显式设置 `spec.java.image` |
| ES 索引前缀（默认） | `acp-tracing-<cluster>` | `acp-<cluster>` |
| ES 索引清理方式 | 每日索引（按日期切分） + `jaeger-es-index-cleaner` CronJob 定时清理 | 索引别名 + Index Rollover + ILM 自动清理 |
| Tracing UI 入口 | ACP 定制 UI（依赖 `acp-tracing-ui` Feature Switch） | Jaeger UI（通过 OAuth2 Proxy 集成 ACP 认证） |
| Service Mesh 兼容性 | 兼容 Alauda Service Mesh v1 | **不兼容** Alauda Service Mesh v1，仅兼容 v2 |

参考：
- 老方案部署：`acp-docs/docs/en/observability/tracing/installation.mdx`、`servicemesh2-docs/docs/en/integration/observability/distributed-tracing-and-mesh.mdx`
- 新方案部署：`distributed-tracing-docs/docs/en/installing/installing-distributed-tracing.mdx`
- OTel v1 → v2 迁移：`opentelemetry-docs/docs/en/migrating/migrating-to-v2.mdx`
- ES 后端：`distributed-tracing-docs/docs/en/configuration/storage-backends/elasticsearch.mdx`

## 2. 迁移目标

1. 应用无需修改 OTLP 上报地址（保持 `otel-collector.cpaas-system:4317`）。
2. 迁移期间老的调用链可继续查询（最长保留 7 天，等同于老 ES Index Cleaner 的 `numberOfDays`）。
3. 提供"双写"过渡能力，使新 Jaeger UI 在迁移后立即拥有可查询的数据，避免"切过去之后什么都看不到"。
4. 迁移过程对应用 Pod 影响最小（仅需要一次 deployment rollout 来更新 Java agent）。
5. 迁移完成后，老 Jaeger / 老 Jaeger Operator 可以安全卸载，老 ES 索引可以清理。

## 3. 对原始迁移思路的评估

原始思路：
> 1. 不卸载老的 Observability/Distributed Tracing 中的 jaeger 组件。
> 2. 把 Alauda build of OpenTelemetry 迁移到 Alauda Build of OpenTelemetry v2，新的 OTel Collector 推荐部署在原始命名空间中。
> 3. 部署新的 jaeger 组件，对接好 ES。
> 4. 新部署的 OTel Collector 的调用链 pipeline 中添加新 jaeger 地址，**双写**到新老 jaeger。
> 5. 7 天后停止双写，删除老 Jaeger 实例和 jaeger-operator。

**结论：思路整体可行，建议采纳。** 在此基础上需要补充以下要点（已在第 4–8 章展开）：

| 编号 | 补充点 | 原因 |
| :--- | :--- | :--- |
| 补 1 | OTel v1 → v2 必须串行：先卸载 v1 Operator + 删除 v1 Collector / Instrumentation，然后才能装 v2。**不能并行** | OTel v1 与 v2 Operator 共享 CRD（`OpenTelemetryCollector`、`Instrumentation`），OLM 不允许两个 Operator 同时拥有同一 CRD |
| 补 2 | 老 Jaeger 不受 OTel v1 → v2 迁移影响 | 老 Jaeger Operator 拥有 `jaegertracing.io/v1.Jaeger` 这一独立 CRD，与 OTel 互不冲突。这是双写方案能成立的前提 |
| 补 3 | OTel v2 切换会导致一段**调用链采集中断窗口**（删除 v1 Collector → v2 Collector Ready） | 应用 Pod 不会重启，但 OTel SDK 会在该窗口内丢弃部分 span。建议在低峰期执行 |
| 补 4 | **建议先部署新 Jaeger v2，再创建 OTel v2 Collector（带双写）**，而不是先创建 OTel v2 Collector 再补 Jaeger v2 | 这样 OTel v2 Collector 创建时 dual-write 立即生效，少一次配置变更 |
| 补 5 | OTel v2 不再自带 Java agent 镜像，**必须**为每个 `Instrumentation` 显式设置 `spec.java.image`；并且需要 rollout restart 已注入应用 | v2 Operator 不再托管该镜像，老 Pod 仍带 v1 init container，调用链导出会失败直到 rollout |
| 补 6 | 如果集群已安装 **Alauda Service Mesh v1**，必须先迁移到 SM v2 | OTel v2 与 SM v1 不兼容，在 SM v1 存在时安装 OTel v2 会破坏服务网格的 tracing |
| 补 7 | 老的 `acp-tracing-ui` Feature Switch 在迁移完成后应当关闭，ACP 上原 **Observability → Tracing** 菜单不再可用，改为通过 Jaeger UI 的 Ingress 入口访问 | 新方案不再提供 ACP 定制 UI，老 UI 依赖的 API 已被弃用 |
| 补 8 | 老 Jaeger 实例删除后，`jaeger-es-index-cleaner` CronJob 一并消失，**老 ES 索引（`acp-tracing-<cluster>-jaeger-*`）不再被自动清理**，需要手动删除或配合 ES 维护流程清理 | 否则老索引会一直占用 ES 存储 |
| 补 9 | 双写期间 ES 存储用量大约翻倍 | 同一条 trace 同时写入老 `acp-tracing-<cluster>` 索引和新 `acp-<cluster>` 索引；需要预留容量 |
| 补 10 | 双写期间，新老 Jaeger UI 入口路径不同（`/clusters/<cluster>/acp/jaeger` vs `/clusters/<cluster>/jaeger`），用户在 7 天观察期内可同时访问两者 | 老 UI 通过老 Ingress 暴露，新 UI 通过新 Ingress 暴露，互不干扰 |

> "新 OTel Collector 推荐部署在原始命名空间"这条建议**完全采纳**。它直接消除了应用侧改地址的成本，是这套迁移方案最大的价值点。

## 4. 关键设计

### 4.1 老组件保留 vs 卸载

| 组件 | 迁移期间状态 | 迁移后状态 |
| :--- | :--- | :--- |
| 老 Jaeger Operator（`jaegertracing.io/v1`） | **保留** | 卸载 |
| 老 Jaeger 实例（`jaeger-prod`，`cpaas-system`） | **保留**（继续接收双写流量、继续提供老 UI 查询） | 删除 |
| 老 OTel v1 Operator | 必须卸载（CRD 冲突） | 已卸载 |
| 老 OTel v1 Collector / Instrumentation | 必须先删除（v1 Operator 卸载前置） | 已删除 |
| 老 ES 索引 `acp-tracing-<cluster>-jaeger-*` | 双写继续写入，老 cleaner 继续清理 7 天前数据 | 老 cleaner 随老 Jaeger 删除而消失，需手动清理残余索引 |

### 4.2 命名空间布局

```
opentelemetry-operator        (老 OTel v1 Operator) → 迁移后卸载
opentelemetry-operator2       (新 OTel v2 Operator)
jaeger-operator               (老 Jaeger v1 Operator) → 迁移完成后卸载
jaeger-system                 (新 Jaeger v2 实例)
cpaas-system                  (老/新 OTel Collector：先 v1，再 v2；老 Jaeger 实例 jaeger-prod 也在这里)
```

### 4.3 数据流

**迁移前：**

```
App (Java agent v1)
  └─ OTLP → otel-collector.cpaas-system:4317 (OTel v1)
              └─ otlp → jaeger-prod-collector-headless.cpaas-system:4317 (老 Jaeger 1.60.0)
                          └─ ES 索引: acp-tracing-<cluster>-jaeger-* (按日切分，7 天 cleaner)
```

**迁移期间（双写）：**

```
App (Java agent v2，rollout 后)
  └─ OTLP → otel-collector.cpaas-system:4317 (OTel v2 — 同地址，replicates v1 接入点)
              ├─ otlp/jaeger-old → jaeger-prod-collector-headless.cpaas-system:4317 (老 Jaeger，仍在 cpaas-system)
              │                       └─ acp-tracing-<cluster>-jaeger-* (老 ES 索引)
              └─ otlp/jaeger-new → jaeger-collector.jaeger-system:4317 (新 Jaeger v2)
                                      └─ acp-<cluster>-jaeger-* (新 ES 索引，ILM 管理)
```

**迁移完成（去掉 jaeger-old）：**

```
App
  └─ OTLP → otel-collector.cpaas-system:4317 (OTel v2)
              └─ otlp/jaeger-new → jaeger-collector.jaeger-system:4317
                                      └─ acp-<cluster>-jaeger-*
```

### 4.4 等待 7 天的依据

- 老 Jaeger 实例配置 `esIndexCleaner.numberOfDays: 7`，即 7 天前的索引会被定时删除。
- 设双写开始时间为 T0：
  - T0 之前的 trace 数据**只在老索引**中。这部分数据从其入库时刻起最多保留 7 天。
  - T0 ~ T0+7d 期间的 trace 数据**同时存在于新老索引**，新 Jaeger UI 可查。
  - T0+7d 之后，老索引中 T0 之前的数据已被 cleaner 清理完毕；老索引中剩余的数据（T0 之后）在新 Jaeger UI 中也都能查到。
- **结论：T0+7d 是停止双写并卸载老 Jaeger 的最早安全时间点。**

> 如果用户业务上不在意"切之前的老 trace 查不到"，可以**跳过双写**直接单写新 Jaeger，这种场景下迁移可以省掉双写步骤，直接进入第 5 章中的 Step 5（不要把老 Jaeger exporter 加入 pipeline）和 Step 11（不需要等待 7 天，可立即卸载老 Jaeger）。

## 5. 迁移步骤

> 本章假设：集群当前正常运行老 Observability/Distributed Tracing；ES 8.x 可用，且执行人具备 ES 管理员权限（创建 ILM 策略需要）；已具备 `cluster-admin`。

整体步骤如下：

```
[Step 1]  迁移前准备（盘点 + 备份 + 兼容性检查）
[Step 2]  卸载 OTel v1：删除 Instrumentation → 删除 Collector → 卸载 v1 Operator
              ↓ 调用链采集中断窗口开始
[Step 3]  安装 OTel v2 Operator
[Step 4]  部署新 Jaeger v2 实例（jaeger-system 命名空间）
[Step 5]  部署 OTel v2 Collector（cpaas-system 命名空间，配置双写）
              ↓ 调用链采集恢复（双写到新老 Jaeger）
[Step 6]  重建 Instrumentation（设置 spec.java.image）
[Step 7]  Rollout 已注入应用，更换为 v2 Java agent
[Step 8]  验证（telemetrygen + 真实业务流量）
[Step 9]  观察期：≥ 7 天
[Step 10] 停止双写：从 OTel v2 Collector 中移除老 Jaeger exporter
[Step 11] 卸载老 Jaeger 实例 + 老 Jaeger Operator
[Step 12] 收尾：关闭 acp-tracing-ui Feature Switch、清理老 ES 索引
```

### Step 1：迁移前准备

1. 盘点 OTel v1 资源、识别业务影响：

    ```bash
    kubectl get csv -A | grep -iE 'opentelemetry|jaeger'
    kubectl get opentelemetrycollector -A
    kubectl get instrumentation -A
    kubectl get jaeger -A
    kubectl get pods -A -o json | jq -r '
      .items[]
      | select(.metadata.annotations["instrumentation.opentelemetry.io/inject-java"])
      | "\(.metadata.namespace)/\(.metadata.name)"'
    ```

2. 备份 v1 资源（用于回滚参考）：

    ```bash
    mkdir -p ./otel-v1-backup ./jaeger-v1-backup
    kubectl get opentelemetrycollector -A -o yaml > ./otel-v1-backup/collectors.yaml
    kubectl get instrumentation -A -o yaml      > ./otel-v1-backup/instrumentations.yaml
    kubectl get subscription -n opentelemetry-operator opentelemetry-operator -o yaml \
      > ./otel-v1-backup/subscription.yaml || true
    kubectl get jaeger -A -o yaml > ./jaeger-v1-backup/jaegers.yaml
    ```

3. 准备 v2 Java agent 镜像。开源镜像示例：`ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:2.26.1`；离线/合规环境使用自建镜像（见 `opentelemetry-docs/docs/en/configuration/instrumentation/java.mdx`）。

4. 兼容性检查：

    - **Service Mesh**：若集群存在 Alauda Service Mesh v1，**先**完成 SM v1 → v2 迁移再继续。
    - **OTel Collector 配置**：对照 `opentelemetry-docs` 中 [v2.0.0 Release Notes](../../opentelemetry-docs/docs/en/about/release-notes/v2-0-0.mdx) 校验 v1 Collector 中所有 receiver/processor/exporter/connector/extension 是否仍受支持，重点关注 `service.telemetry.metrics` 配置 schema 在 0.147.0 中的变化。
    - **ES 权限**：确认执行账号能创建 ILM 策略和索引模板。

5. 通知调用链下游消费方（开发者、Kiali 用户、SRE 看板）即将进入维护窗口；建议在低峰期执行 Step 2–8。

### Step 2：卸载 OTel v1

> ⚠️ 本步骤开始后，应用调用链采集中断，直到 Step 5 完成。

```bash
# 2.1 删除 Instrumentation（不会立即影响已注入 Pod，但阻止 v1 Operator 注入新 Pod）
for ns in $(kubectl get instrumentation -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' | sort -u); do
  kubectl -n "$ns" delete instrumentation --all
done

# 2.2 删除 OpenTelemetryCollector（应用 OTLP 导出此后开始失败）
for ns in $(kubectl get opentelemetrycollector -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' | sort -u); do
  kubectl -n "$ns" delete opentelemetrycollector --all
done

# 2.3 卸载 v1 Operator（必须删除 CSV 才能解除 CRD 占用）
kubectl delete subscription opentelemetry-operator -n opentelemetry-operator
CSV=$(kubectl get csv -n opentelemetry-operator -o name | grep -i opentelemetry-operator)
[ -n "$CSV" ] && kubectl -n opentelemetry-operator delete "$CSV"

# 2.4 等待 v1 CSV 完全清理
kubectl get csv -A | grep '^opentelemetry-operator '   # 期望输出为空

# 2.5 清理 v1 Collector 在 cpaas-system 创建的 RBAC 与 ServiceMonitor
kubectl -n cpaas-system delete servicemonitor otel-collector-monitoring otel-collector --ignore-not-found
kubectl -n cpaas-system delete sa otel-collector --ignore-not-found
kubectl delete clusterrolebinding otel-collector:cpaas-system:cluster-admin --ignore-not-found
```

> ⚠️ 不要删除 `opentelemetrycollectors.opentelemetry.io` 与 `instrumentations.opentelemetry.io` CRD —— v2 Operator 安装时会接管并升级它们。

### Step 3：安装 OTel v2 Operator

按 `opentelemetry-docs/docs/en/installing/install-opentelemetry.mdx` 执行：

```bash
kubectl get namespace opentelemetry-operator2 || kubectl create namespace opentelemetry-operator2

kubectl apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  annotations:
    cpaas.io/target-namespaces: ""
  labels:
    catalog: platform
  name: opentelemetry-operator2
  namespace: opentelemetry-operator2
spec:
  channel: stable
  installPlanApproval: Manual
  name: opentelemetry-operator2
  source: platform
  sourceNamespace: cpaas-system
  startingCSV: opentelemetry-operator2.v0.146.0-r0    # 或当前 channel 中的最新版本
EOF

kubectl -n opentelemetry-operator2 wait --for=condition=InstallPlanPending subscription/opentelemetry-operator2 --timeout=2m
PLAN="$(kubectl -n opentelemetry-operator2 get subscription opentelemetry-operator2 -o jsonpath='{.status.installPlanRef.name}')"
kubectl -n opentelemetry-operator2 patch installplan "$PLAN" --type=json \
  -p='[{"op": "replace", "path": "/spec/approved", "value": true}]'
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded csv --all -n opentelemetry-operator2 --timeout=3m
```

### Step 4：部署新 Jaeger v2 实例

按 `distributed-tracing-docs/docs/en/installing/installing-distributed-tracing.mdx` 执行（命名空间 `jaeger-system`、实例名 `jaeger`、索引前缀默认 `acp-${CLUSTER_NAME}`）：

1. 设置环境变量并准备 ES 凭据 Secret。
2. 在 ES 创建 ILM 策略 `jaeger-ilm-policy`（`hot.rollover.max_age: 1d`、`delete.min_age: 7d` —— 与老方案 7 天保留一致）。
3. 运行 `jaeger-es-rollover-init` Job，初始化索引模板与别名。
4. 创建 OAuth2 Proxy Secret，apply `jaeger.yaml`（OpenTelemetryCollector）。
5. 创建 Ingress `${JAEGER_BASEPATH}` = `/clusters/${CLUSTER_NAME}/jaeger`，与老 UI 路径 `/clusters/${CLUSTER_NAME}/acp/jaeger` 不冲突，可同时访问。

完成后，新 Jaeger Collector 服务地址：`jaeger-collector.jaeger-system.svc.cluster.local:4317`。

> **保留新 Jaeger 索引前缀的默认值（`acp-<cluster>`）**，与老前缀（`acp-tracing-<cluster>`）保持差异，避免 ES 端混用导致 schema/mapping 冲突。

### Step 5：部署 OTel v2 Collector（双写）

在 `cpaas-system` 命名空间中创建 OTel v2 Collector，命名 **`otel`**（与老一致），保持 Service 名 `otel-collector` 与 4317/4318 端口不变 —— 应用侧 OTLP 上报地址完全无须修改。

```yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: otel
  namespace: cpaas-system
  labels:
    prometheus: kube-prometheus
spec:
  mode: deployment
  replicas: 1
  resources:
    requests:
      cpu: 250m
      memory: 512Mi
    limits:
      cpu: "2"
      memory: 1Gi
  observability:
    metrics:
      enableMetrics: true
  config:
    receivers:
      otlp:
        protocols:
          grpc: { endpoint: 0.0.0.0:4317 }
          http: { endpoint: 0.0.0.0:4318 }
      zipkin: {}
    processors:
      batch: {}
      memory_limiter:
        check_interval: 1s
        limit_percentage: 80
        spike_limit_percentage: 20
      filter/metric_apis:
        metrics:
          datapoint:
            - attributes["http.route"] == "/actuator/health" or attributes["uri"] == "/actuator/health"
            - attributes["http.route"] == "/actuator/prometheus" or attributes["uri"] == "/actuator/prometheus"
      transform:
        metric_statements:
          - context: datapoint
            statements:
              - delete_key(attributes, "inner.client.ms.name")
              - delete_key(attributes, "inner.client.ms.namespace")
              - delete_key(attributes, "inner.client.cluster.name")
              - delete_key(attributes, "inner.client.env.type")
              - set(attributes["namespace"],   resource.attributes["k8s.namespace.name"])
              - set(attributes["container"],   resource.attributes["k8s.container.name"])
              - set(attributes["service_name"], resource.attributes["service.name"])
              - set(attributes["pod"],         resource.attributes["k8s.pod.name"])
    exporters:
      debug: {}
      # ── 双写 #1：老 Jaeger（迁移完成后删除）──
      otlp/jaeger-old:
        endpoint: dns:///jaeger-prod-collector-headless.cpaas-system:4317
        balancer_name: round_robin
        tls:
          insecure: true
        sending_queue:
          enabled: true
        retry_on_failure:
          enabled: true
      # ── 双写 #2：新 Jaeger v2 ──
      otlp/jaeger-new:
        endpoint: jaeger-collector.jaeger-system.svc.cluster.local:4317
        tls:
          insecure: true
        sending_queue:
          enabled: true
        retry_on_failure:
          enabled: true
      prometheus:
        add_metric_suffixes: false
        endpoint: 0.0.0.0:8889
        resource_to_telemetry_conversion:
          enabled: true
    service:
      pipelines:
        traces:
          receivers: [otlp, zipkin]
          processors: [memory_limiter, batch]
          exporters: [debug, otlp/jaeger-old, otlp/jaeger-new]   # ← 双写
        metrics:
          receivers:  [otlp]
          processors: [memory_limiter, filter/metric_apis, transform, batch]
          exporters:  [debug, prometheus]
      telemetry:
        metrics:
          readers:
            - pull:
                exporter:
                  prometheus:
                    host: 0.0.0.0
                    port: 8888
                    without_scope_info: true
                    without_type_suffix: true
                    without_units: true
        logs:
          level: info
```

> **关于 `otlp/jaeger-old` 的容错**：老 Jaeger 在双写期间任何故障都会被 `retry_on_failure` 缓冲；如果用户希望"老 Jaeger 出问题时不影响新 Jaeger 写入"，OTLP exporter 默认 per-exporter 独立队列即满足该要求。

> **关于 metrics pipeline**：保留与 OTel v1 相同的 `filter/metric_apis` 与 `transform` 处理器，使 ACP 监控告警侧（消费 Prometheus 抓取到的指标）的字段语义一致。如果用户原本没有这些处理器，可以删除。

应用后等待就绪：

```bash
kubectl rollout status deployment/otel-collector -n cpaas-system --timeout=180s
```

此时调用链采集恢复，新到达的 trace 同时进入新老 Jaeger。

### Step 6：重建 Instrumentation

```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: acp-common-java
  namespace: cpaas-system
spec:
  java:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:2.26.1   # ← v2 必填
  exporter:
    endpoint: http://otel-collector.cpaas-system:4317
  env:
    - name: SERVICE_CLUSTER
      value: "<cluster-name>"
    - name: OTEL_TRACES_EXPORTER
      value: otlp
    - name: OTEL_METRICS_EXPORTER
      value: otlp
    - name: OTEL_EXPORTER_OTLP_ENDPOINT
      value: http://otel-collector.cpaas-system:4317
    - name: OTEL_SERVICE_NAME
      value: $(SERVICE_NAME).$(SERVICE_NAMESPACE)
    - name: OTEL_RESOURCE_ATTRIBUTES
      value: service.namespace=$(SERVICE_NAMESPACE),cluster.name=$(SERVICE_CLUSTER)
  sampler:
    type: parentbased_traceidratio
    argument: "1"
```

> 老用户的 Pod 注解 `instrumentation.opentelemetry.io/inject-java: cpaas-system/acp-common-java` 会继续生效，不需要改 Deployment 模板，只需要 rollout（Step 7）。

### Step 7：滚动应用以替换 Java agent

```bash
kubectl get deploy -A -o json | jq -r '
  .items[]
  | select(.spec.template.metadata.annotations["instrumentation.opentelemetry.io/inject-java"])
  | "\(.metadata.namespace) \(.metadata.name)"' \
| while read ns name; do
    kubectl -n "$ns" rollout restart deployment/"$name"
    kubectl -n "$ns" rollout status  deployment/"$name" --timeout=180s
  done
```

> 大规模集群建议**分批滚动**，每批观察 OTel Collector 错误日志和新 Jaeger UI 中是否能看到该批服务的 traces，再继续下一批。

### Step 8：验证

1. **Operator/Collector/Instrumentation 状态**：

    ```bash
    kubectl get csv -A | grep -i opentelemetry          # 仅 v2，PHASE=Succeeded
    kubectl get opentelemetrycollector -A               # cpaas-system/otel + jaeger-system/jaeger 都 Ready
    kubectl get instrumentation -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{.spec.java.image}{"\n"}{end}'
    ```

2. **合成流量验证**（telemetrygen）：

    ```bash
    kubectl apply -n cpaas-system -f - <<EOF
    apiVersion: v1
    kind: Pod
    metadata:
      name: telemetrygen
    spec:
      restartPolicy: Never
      containers:
        - name: telemetrygen
          image: ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest
          args: ["traces","--otlp-endpoint=otel-collector.cpaas-system.svc.cluster.local:4317",
                 "--otlp-insecure","--duration=120s","--service=migration-check","--rate=2"]
    EOF
    ```

    - 老 Jaeger UI（`<platform-url>/clusters/<cluster>/acp/jaeger`）→ Service 选 `migration-check`，应能查到 traces。
    - 新 Jaeger UI（`<platform-url>/clusters/<cluster>/jaeger`）→ Service 选 `migration-check`，应能查到 traces。

3. **真实业务验证**：选 1–2 个已 rollout 的关键应用，触发一次请求，确认 traceID 在新老 Jaeger 中均可检索；对比一段时间内（例如 5 分钟）两边的 service 列表与 span 总量，应当基本一致（允许少量差异，因为 OTel 可能少量丢弃缓冲数据）。

4. **ES 端**：

    ```bash
    curl -k -u "$ES_USER:$ES_PASS" "$ES_ENDPOINT/_cat/indices?v" \
      | grep -E 'acp-tracing-|acp-' | sort
    ```

    - 应同时存在 `acp-tracing-<cluster>-jaeger-*`（老）与 `acp-<cluster>-jaeger-*-000001` 等（新）。

### Step 9：观察期（≥ 7 天）

- 期间持续监控两套 OTel/Jaeger 的错误率（Prometheus 上 `otelcol_exporter_send_failed_*`、`jaeger_*` 指标）。
- 期间老 Jaeger UI 仍可查询历史数据；新 Jaeger UI 已包含双写后的全部数据。
- ES 用量大约翻倍，确保磁盘水位不会触发 ES read-only。

### Step 10：停止双写

编辑 `cpaas-system/otel`，从 traces pipeline 中移除 `otlp/jaeger-old`，并删除其 exporter 定义：

```bash
kubectl -n cpaas-system patch opentelemetrycollector otel --type=merge -p '
spec:
  config:
    exporters:
      otlp/jaeger-old: null     # 显式移除
    service:
      pipelines:
        traces:
          exporters: [debug, otlp/jaeger-new]
'
kubectl rollout status deployment/otel-collector -n cpaas-system --timeout=180s
```

> 受 OpenTelemetry Operator 重新生成 Pod 的影响，期间会有秒级 trace 抖动，业务无感。

### Step 11：卸载老 Jaeger 实例与 Operator

```bash
# 11.1 删除老 Jaeger 实例及配套资源
kubectl -n cpaas-system delete ingress       jaeger-prod-query        --ignore-not-found
kubectl -n cpaas-system delete podmonitor    jaeger-prod-monitor      --ignore-not-found
kubectl -n cpaas-system delete jaeger        jaeger-prod              --ignore-not-found
kubectl -n cpaas-system delete rolebinding   jaeger-prod-rb           --ignore-not-found
kubectl -n cpaas-system delete role          jaeger-prod-role         --ignore-not-found
kubectl -n cpaas-system delete sa            jaeger-prod-sa           --ignore-not-found
kubectl -n cpaas-system delete secret        jaeger-prod-oauth2-proxy --ignore-not-found
kubectl -n cpaas-system delete secret        jaeger-prod-es-basic-auth --ignore-not-found
kubectl -n cpaas-system delete configmap     jaeger-prod-oauth2-proxy --ignore-not-found

# 11.2 通过 OperatorHub 卸载 Alauda build of Jaeger Operator（或 CLI 卸载 Subscription/CSV）
kubectl -n jaeger-operator delete subscription jaeger-operator --ignore-not-found
CSV=$(kubectl -n jaeger-operator get csv -o name | grep -i jaeger-operator)
[ -n "$CSV" ] && kubectl -n jaeger-operator delete "$CSV"
# 可选：删除 jaeger CRD（如确认集群中没有其他 Jaeger CR 实例）
# kubectl get jaeger -A
# kubectl delete crd jaegers.jaegertracing.io
```

### Step 12：收尾

1. **关闭 `acp-tracing-ui` Feature Switch**（在 ACP Web Console 的 Feature Switch 视图操作），并向用户公告新 Jaeger UI 入口 `<platform-url>/clusters/<cluster>/jaeger`。
2. **手动清理老 ES 索引**：

    ```bash
    curl -k -u "$ES_USER:$ES_PASS" -X DELETE \
      "$ES_ENDPOINT/acp-tracing-<cluster>-jaeger-*"
    ```

   建议先 `_cat/indices` 列一遍核对，再执行删除。
3. **更新内部文档与告警 Runbook**：把 Jaeger UI 链接、ES 索引前缀、ServiceMonitor/PodMonitor 名称都同步到新值。

## 6. 验证清单（清单式总结）

- [ ] OTel v2 Operator CSV `Succeeded`，且 v1 CSV 已不存在
- [ ] `cpaas-system/otel` 与 `jaeger-system/jaeger` 两个 OpenTelemetryCollector 均 Ready
- [ ] 全部 `Instrumentation` 资源 `spec.java.image` 已设置
- [ ] 已 rollout 的应用 Pod 中 init container 镜像为 v2 Java agent
- [ ] telemetrygen 在新老 Jaeger UI 中均可查到
- [ ] ES 中同时出现 `acp-tracing-<cluster>-jaeger-*`（老）与 `acp-<cluster>-jaeger-*`（新）索引
- [ ] OTel Collector Prometheus 指标 `otelcol_exporter_send_failed_spans_total{exporter="otlp/jaeger-new"}` 不持续增长
- [ ] 7 天后停止双写、卸载老 Jaeger、关闭 Feature Switch、清理老 ES 索引

## 7. 回滚方案

| 阶段 | 故障 | 回滚动作 |
| :--- | :--- | :--- |
| Step 2–3 | OTel v2 Operator 装不上 | `kubectl get csv -A \| grep '^opentelemetry-operator '` 应为空；若 v1 CSV 残留，手动删除后重试。如需放弃迁移：按 `migrating-to-v2.mdx` 的 *Rollback* 章节重装 v1 |
| Step 4 | 新 Jaeger v2 异常 | 不影响老 Jaeger 与应用调用链。直接 `kubectl delete -n jaeger-system opentelemetrycollector jaeger`，定位问题后重做 Step 4 |
| Step 5 | OTel v2 Collector 启不来 / 双写失败 | 第一时间把 `otlp/jaeger-new` 从 traces.exporters 中临时移除（保留 `otlp/jaeger-old`），保证老 Jaeger 路径仍能收数；定位 v2 配置问题 |
| Step 5 | 仅 `otlp/jaeger-old` 失败（连不上老 Jaeger） | 检查老 Jaeger 实例是否 Ready；若老 Jaeger 已不可恢复且业务可接受，从 traces.exporters 中移除 `otlp/jaeger-old`，进入"无双写"模式（等同提前进入 Step 10） |
| Step 7 | 应用 rollout 后无 trace | 检查 v2 mutating webhook 是否 Ready、`Instrumentation` 是否存在、Pod init container 是否注入；必要时重新 rollout |
| Step 9 观察期 | 决定放弃新方案 | 调整 `otel` Collector 的 traces.exporters 仅保留 `otlp/jaeger-old`；不删除老 Jaeger；按 `migrating-to-v2.mdx` 的 *Rollback* 把 OTel v2 → v1（注意需要再次重启应用以恢复 v1 Java agent） |

## 8. 风险与缓解

| 风险 | 影响 | 缓解 |
| :--- | :--- | :--- |
| Step 2 → Step 5 之间调用链采集中断 | 该窗口内 trace 数据丢失（应用业务不受影响） | 选择业务低峰期；脚本化串联 Step 2–5 缩短窗口；OTel SDK 默认有 buffer，影响通常可控 |
| OTel v2 Operator 启动失败 | 全集群 OTel 不可用 | Step 1 先在测试集群跑一遍；保留 v1 备份 YAML 以便回滚 |
| Java agent 行为差异（v1.x → v2.x） | 自动指标命名/属性变化导致看板/告警失效 | 提前 review 现有 Prometheus 看板和告警，按 OTel Java agent v2 release notes 调整；可在 Step 7 分批 rollout |
| ES 双写期间存储压力 | ES 磁盘写满 → read-only | 提前评估 ES 容量、确保至少 50% 余量；缩短观察期或调小新 ILM `delete.min_age` 抹平峰值 |
| 用户提前删除老 Jaeger | 7 天内的老索引数据丢失 | Step 11 必须在 Step 9 完成 7 天观察后执行；流程化为审批节点 |
| 老 ES 索引未清理 | 无业务影响但浪费空间 | Step 12 中明确清理动作，纳入收尾验收 |
| 集群存在 Service Mesh v1 | Step 5 后 SM v1 调用链断裂 | Step 1 兼容性检查时拦截：先做 SM v1 → v2，再启动本迁移 |
| `acp-tracing-ui` Feature Switch 未关闭 | ACP 老 Tracing 菜单仍展示，但后端已不可用 → 用户体验下降 | Step 12 中关闭；并在用户公告中明确新入口 |

## 9. 常见问题（FAQ）

**Q1：老 Jaeger 和新 Jaeger v2 能装在同一个命名空间吗？**

A：能，但不建议。新方案默认命名空间是 `jaeger-system`，老方案是 `cpaas-system`，分开放可以避免 Service 名（`*-collector`）和 Ingress 路径（`/acp/jaeger` vs `/jaeger`）潜在冲突。

**Q2：迁移期间应用 OTLP 上报地址要不要改？**

A：**不需要**。新 OTel v2 Collector 仍然部署在 `cpaas-system`、Service 名仍为 `otel-collector`、端口 4317/4318 不变。这是本方案设计的核心收益。

**Q3：能不能不双写、直接切到新 Jaeger？**

A：可以，跳过 Step 5 中的 `otlp/jaeger-old` 与 Step 9–10。代价是迁移瞬间起，应用产生的新 trace 只在新 Jaeger 中可见；切换前已存在的老 trace 仍然在老 Jaeger 中保留 7 天（如果暂不卸载老 Jaeger，仍可通过老 UI 查询）。

**Q4：能不能跳过 `acp-tracing-ui` Feature Switch 的关闭？**

A：技术上不影响新方案运行，但 ACP **Observability → Tracing** 菜单背后的 API 在新方案下已不再受支持，用户访问会看到错误页。建议关闭并以 Jaeger UI Ingress 为唯一入口。

**Q5：老 ES 索引能在删老 Jaeger 实例之前预先迁移到新 prefix 吗？**

A：技术上可行（ES `_reindex`），但代价较高且老索引 schema 与 Jaeger v2 不一致（v1 使用按日索引，v2 使用 rollover 别名 + ILM）。**不建议**。本方案推荐"双写过渡 7 天"以等老索引自然过期，避免 reindex 复杂度。

**Q6：双写期间 ES 容量评估？**

A：粗略估算：双写期间 ES 用量 ≈ 单写时的 2 倍（同一份 trace 在新老索引各落一份）。如果原老 Jaeger 7 天数据占 100GB，双写 7 天 + 新 Jaeger 自身 7 天保留意味着峰值约 200GB（双写期间）+ 100GB（双写结束、老索引 7 天衰减完）。预留 50% 空间是稳妥下限。

**Q7：需要修改 Kiali / Service Mesh 的 tracing 配置吗？**

A：

- 如果原集群仅使用 ACP Tracing（无 SM 集成）：不需要。
- 如果原集群使用 SM v1 + 老 Jaeger：必须先迁 SM v1 → v2，SM v2 与 OTel v2 的对接见 `servicemesh2-docs/docs/en/integration/observability/distributed-tracing-and-mesh.mdx`。
- 如果原集群使用 SM v2 + 老 Jaeger：参考 `migrating-to-v2.mdx` 中的 *Alauda Service Mesh v2 integration* 章节，把 `meshConfig.extensionProviders[].opentelemetry.service` 指向新 OTel Collector（如保留 `cpaas-system/otel-collector` 名称则不需要改）。

**Q8：迁移完成后 SPM（Service Performance Monitoring）怎么启用？**

A：本迁移方案不强制启用 SPM。如需启用，按 `installing-distributed-tracing.mdx` 中 *(Optional) Enabling Service Performance Monitoring (SPM)* 章节给 OTel v2 Collector 添加 `spanmetrics` connector，给 Jaeger v2 添加 `metric_backends`。这一步可以在 Step 11 后追加进行，与本迁移方案相互独立。

## 10. 时间预算（参考）

| 阶段 | 预计耗时 | 备注 |
| :--- | :--- | :--- |
| Step 1 准备 | 0.5–1 工作日 | 含盘点、备份、镜像与 ES 配置确认 |
| Step 2–3 OTel v1 卸载 + v2 安装 | 10–20 分钟 | 主要等待 CSV、InstallPlan |
| Step 4 部署新 Jaeger v2 | 15–30 分钟 | 含 ILM/索引初始化 |
| Step 5 部署 OTel v2 Collector（双写） | 5–10 分钟 | |
| **Step 2 → Step 5 调用链中断窗口** | **约 30–60 分钟** | 视集群规模、镜像拉取速度 |
| Step 6–7 Instrumentation + 应用 rollout | 0.5–1 工作日 | 取决于注入应用数量与分批策略 |
| Step 8 验证 | 0.5 工作日 | |
| Step 9 观察期 | **≥ 7 天** | 硬性等待 |
| Step 10–12 清理收尾 | 0.5 工作日 | |

总体里程碑：T0（Step 1） → T0+1d（双写就绪、应用 rollout 完成） → T0+8d（停止双写、卸载老 Jaeger、收尾完成）。
