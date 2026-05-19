# 从 Observability/Distributed Tracing 迁移到 Alauda Distributed Tracing

> 设计文档 · 中文 · 2026-05-09

## 1. 背景

| 维度                           | 老方案（Observability/Distributed Tracing）                             | 新方案（Alauda Distributed Tracing）                                                                                   |
| :----------------------------- | :---------------------------------------------------------------------- | :--------------------------------------------------------------------------------------------------------------------- |
| Jaeger 版本                    | 1.60.0                                                                  | 2.16.0                                                                                                                 |
| Jaeger Operator                | Alauda Build of Jaeger（CRD：`jaegertracing.io/v1.Jaeger`）             | Alauda Build of OpenTelemetry v2 Operator（通过 `opentelemetry.io/v1beta1.OpenTelemetryCollector` 部署 Jaeger Binary） |
| OTel Operator                  | Alauda build of OpenTelemetry（包名 `opentelemetry-operator`，0.108.0） | Alauda Build of OpenTelemetry v2（包名 `opentelemetry-operator2`，0.147.0）                                            |
| 部署 OTel Collector 的命名空间 | 与 Operator **可以同名**（默认 `cpaas-system`）                         | **必须**与 Operator 不同（Operator 在 `opentelemetry-operator2`）                                                      |
| Java auto-instrumentation 镜像 | Operator 自带，可以不设置 `Instrumentation.spec.java.image`             | Operator 不自带，**必须**显式设置 `spec.java.image`                                                                    |
| ES 索引前缀（默认）            | `acp-tracing-<cluster>`                                                 | `acp-<cluster>`                                                                                                        |
| ES 索引清理方式                | 每日索引（按日期切分） + `jaeger-es-index-cleaner` CronJob 定时清理     | 索引别名 + Index Rollover + ILM 自动清理                                                                               |
| Tracing UI 入口                | ACP 定制 UI（依赖 `acp-tracing-ui` Feature Switch）                     | Jaeger UI（通过 OAuth2 Proxy 集成 ACP 认证）                                                                           |
| Service Mesh 兼容性            | 兼容 Alauda Service Mesh v1                                             | **不兼容** Alauda Service Mesh v1，仅兼容 v2                                                                           |

参考：

- 老方案部署：`acp-docs/docs/en/observability/tracing/installation.mdx`、`servicemesh2-docs/docs/en/integration/observability/distributed-tracing-and-mesh.mdx`
- 新方案部署：`distributed-tracing-docs/docs/en/installing/installing-distributed-tracing.mdx`
- OTel v1 → v2 迁移：`opentelemetry-docs/docs/en/migrating/migrating-to-v2.mdx`
- ES 后端：`distributed-tracing-docs/docs/en/configuration/storage-backends/elasticsearch.mdx`

## 2. 迁移目标

1. 应用无需修改 OTLP 上报地址（保持 `otel-collector.cpaas-system:4317`）。
2. 切换前的历史调用链：在老 Jaeger UI 中可继续查询，**默认 7 天**（与老 `esIndexCleaner.numberOfDays` 对齐），随老索引自然过期。
3. 切换后的新调用链：直接进入新 Jaeger，新 UI 立即可用。
4. 迁移过程对应用 Pod 影响最小（仅需要一次 deployment rollout 来更新 Java agent）。
5. 迁移完成后，老 Jaeger / 老 Jaeger Operator 可以安全卸载，老 ES 索引可以清理。
6. **可选**：在并行验证、跨团队渐进切换、或需要"快速回滚"的高保守场景下，提供"双写到新老 Jaeger"的可选路径。

## 3. 对原始迁移思路的评估

### 3.1 原始思路回顾

> 1. 不卸载老的 Observability/Distributed Tracing 中的 jaeger 组件。
> 2. 把 Alauda build of OpenTelemetry 迁移到 Alauda Build of OpenTelemetry v2，新的 OTel Collector 推荐部署在原始命名空间中。
> 3. 部署新的 jaeger 组件，对接好 ES。
> 4. 新部署的 OTel Collector 的调用链 pipeline 中添加新 jaeger 地址，**双写**到新老 jaeger。
> 5. 7 天后停止双写，删除老 Jaeger 实例和 jaeger-operator。

### 3.2 评估结论

**整体可行**，但**不建议把双写作为默认路径**：

> 关键认知：双写并不能让"切换前的历史 trace"出现在新 Jaeger UI 中。无论是否双写，T0 之前的 trace 都只在老 Jaeger 中。双写只是让"T0 之后的新 trace"在新老两边都有一份冗余 —— 而 T0 之后的数据本来就在新 Jaeger 里，冗余的价值有限。

因此 **默认推荐路径调整为单写**（"思路 4" 在默认流程中删除）：

- 应用经新 OTel v2 Collector 仅写新 Jaeger。
- 老 Jaeger 不接收新数据，但**继续运行**，提供切换前历史数据查询。
- 7 天后老索引自然过期，老 Jaeger 已无可查数据，按"思路 5" 卸载。

双写降级为**可选路径**（适用于：跨团队渐进切换、并行验证、需要观察期内一键回滚的高保守场景）。

### 3.3 默认路径下需要补充的要点

| 编号 | 补充点                                                                                                                                                                 | 原因                                                                                                                                 |
| :--- | :--------------------------------------------------------------------------------------------------------------------------------------------------------------------- | :----------------------------------------------------------------------------------------------------------------------------------- |
| 补 1 | OTel v1 → v2 必须串行：先卸载 v1 Operator + 删除 v1 Collector / Instrumentation，然后才能装 v2。**不能并行**                                                           | OTel v1 与 v2 Operator 共享 CRD（`OpenTelemetryCollector`、`Instrumentation`），OLM 不允许两个 Operator 同时拥有同一 CRD             |
| 补 2 | 老 Jaeger 不受 OTel v1 → v2 迁移影响                                                                                                                                   | 老 Jaeger Operator 拥有 `jaegertracing.io/v1.Jaeger` 这一独立 CRD，与 OTel 互不冲突 —— **这是"老 Jaeger 保留 7 天"方案能成立的前提** |
| 补 3 | OTel v2 切换会导致一段**调用链采集中断窗口**（删除 v1 Collector → v2 Collector Ready）                                                                                 | 应用 Pod 不会重启，但 OTel SDK 会在该窗口内丢弃部分 span。建议在低峰期执行                                                           |
| 补 4 | OTel v2 不再自带 Java agent 镜像，**必须**为每个 `Instrumentation` 显式设置 `spec.java.image`；并且需要 rollout restart 已注入应用                                     | v2 Operator 不再托管该镜像，老 Pod 仍带 v1 init container，调用链导出会失败直到 rollout                                              |
| 补 5 | 如果集群已安装 **Alauda Service Mesh v1**，必须先迁移到 SM v2                                                                                                          | OTel v2 与 SM v1 不兼容，在 SM v1 存在时安装 OTel v2 会破坏服务网格的 tracing                                                        |
| 补 6 | 老的 `acp-tracing-ui` Feature Switch 在迁移完成后应当关闭，ACP 上原 **Observability → Tracing** 菜单不再可用，改为通过 Jaeger UI 的 Ingress 入口访问                   | 新方案不再提供 ACP 定制 UI，老 UI 依赖的 API 已被弃用                                                                                |
| 补 7 | 老 Jaeger 实例删除后，`jaeger-es-index-cleaner` CronJob 一并消失，**老 ES 索引（`acp-tracing-<cluster>-jaeger-*`）不再被自动清理**，需要手动删除或配合 ES 维护流程清理 | 否则老索引会一直占用 ES 存储                                                                                                         |
| 补 8 | 用户沟通：必须提前告知"切换前数据 → 老 UI；切换后数据 → 新 UI"，否则用户会在新 UI 找不到历史 trace 时困惑                                                              | 单写路径下，新老 UI 的数据是按时间切分的，不是镜像                                                                                   |
| 补 9 | "新 OTel Collector 部署在原始命名空间"建议**完全采纳**                                                                                                                 | 直接消除应用侧改地址的成本，是这套迁移方案最大的价值点                                                                               |

### 3.4 双写（可选路径）的取舍

| 场景                     | 单写默认路径                               | 双写可选路径                                      |
| :----------------------- | :----------------------------------------- | :------------------------------------------------ |
| 切换前历史 trace 查询    | 老 UI（最多 7 天）—— 一样                  | 老 UI（最多 7 天）—— 一样                         |
| 切换后新 trace 查询      | 仅新 UI                                    | 新老 UI 都可以                                    |
| ES 写入与存储压力        | 不变（老侧仅自然衰减，无新写入）           | 大约 2× 持续 7 天                                 |
| OTel Collector 配置      | 一个 exporter                              | 两个 exporter，每个配独立 sending_queue           |
| 配置变更次数             | 部署 v2 Collector 一次                     | 部署一次 + 7 天后停止双写一次                     |
| 观察期内回滚到老路径     | 需重写 OTel exporter                       | 只需在 traces.exporters 中去掉新 Jaeger，立即生效 |
| 跨团队渐进切换 UI        | 不支持（新 UI 的"切换前"那段时间没有数据） | 支持（双写期间两边都有最新数据）                  |
| 并行验证（生产流量对比） | 仅依赖 telemetrygen 等独立测试             | 可对同一 traceID 在新老侧做属性/span 数对比       |

> 默认采用单写。仅当明确需要"跨团队渐进切换"、"生产流量并行验证"、或"观察期一键回滚"时，才启用双写。

## 4. 关键设计

### 4.1 老组件保留 vs 卸载

| 组件                                            | 迁移期间状态                                                                         | 迁移后状态                                            |
| :---------------------------------------------- | :----------------------------------------------------------------------------------- | :---------------------------------------------------- |
| 老 Jaeger Operator（`jaegertracing.io/v1`）     | **保留**                                                                             | 卸载                                                  |
| 老 Jaeger 实例（`jaeger-prod`，`cpaas-system`） | **保留**，**仅供查询历史 trace**（默认路径下没有新写入；启用双写时也同时接收新写入） | 删除                                                  |
| 老 OTel v1 Operator                             | 必须卸载（CRD 冲突）                                                                 | 已卸载                                                |
| 老 OTel v1 Collector / Instrumentation          | 必须先删除（v1 Operator 卸载前置）                                                   | 已删除                                                |
| 老 ES 索引 `acp-tracing-<cluster>-jaeger-*`     | 老 cleaner 继续按 `numberOfDays` 清理；默认路径下不再有新写入                        | 老 cleaner 随老 Jaeger 删除而消失，需手动清理残余索引 |

### 4.2 命名空间布局

```
opentelemetry-operator        (老 OTel v1 Operator) → 迁移后卸载
opentelemetry-operator2       (新 OTel v2 Operator)
jaeger-operator               (老 Jaeger v1 Operator) → 迁移完成后卸载
jaeger-system                 (新 Jaeger v2 实例)
cpaas-system                  (老/新 OTel Collector：先 v1，再 v2；老 Jaeger 实例 jaeger-prod 也在这里)
```

### 4.3 数据流（默认：单写）

**迁移前：**

```
App (Java agent v1)
  └─ OTLP → otel-collector.cpaas-system:4317 (OTel v1)
              └─ otlp → jaeger-prod-collector-headless.cpaas-system:4317 (老 Jaeger 1.60.0)
                          └─ ES 索引: acp-tracing-<cluster>-jaeger-* (按日切分，7 天 cleaner)
```

**迁移后（默认单写）：**

```
App (Java agent v2，rollout 后)
  └─ OTLP → otel-collector.cpaas-system:4317 (OTel v2 — 同地址，replicates v1 接入点)
              └─ otlp/jaeger-new → jaeger-collector.jaeger-system:4317 (新 Jaeger v2)
                                      └─ acp-<cluster>-jaeger-* (新 ES 索引，ILM 管理)

老 Jaeger 实例继续运行（仅供查询）：
  jaeger-prod (cpaas-system) → acp-tracing-<cluster>-jaeger-* (无新写入，cleaner 按 numberOfDays 清理)
```

**观察期（≥ 7 天）后：**

```
App
  └─ OTLP → otel-collector.cpaas-system:4317 (OTel v2)
              └─ otlp/jaeger-new → jaeger-collector.jaeger-system:4317
                                      └─ acp-<cluster>-jaeger-*

老 Jaeger 实例与 Operator 已卸载；老 ES 索引已手动清理。
```

### 4.4 数据流（可选：双写，仅当 §3.4 表中"双写"理由成立时启用）

**双写期间：**

```
App
  └─ OTLP → otel-collector.cpaas-system:4317 (OTel v2)
              ├─ otlp/jaeger-old → jaeger-prod-collector-headless.cpaas-system:4317 (老 Jaeger)
              │                       └─ acp-tracing-<cluster>-jaeger-* (老 ES 索引)
              └─ otlp/jaeger-new → jaeger-collector.jaeger-system:4317 (新 Jaeger v2)
                                      └─ acp-<cluster>-jaeger-* (新 ES 索引)
```

观察期结束后通过 patch 把 `otlp/jaeger-old` 从 `traces.exporters` 中移除，回到 §4.3 的稳态。

### 4.5 7 天观察期的依据

- 老 Jaeger 配置 `esIndexCleaner.numberOfDays: 7`，即创建后超过 7 天的索引会被定时删除。
- 设迁移切换时间为 T0：
  - **默认单写**：老 Jaeger 在 T0 之后没有新写入；T0 时存在的索引（覆盖 T0-7d ~ T0）按其各自创建时间陆续被 cleaner 删除。最坏情况下，T0+8d 时几乎所有可查询的老数据已经过期。
  - **可选双写**：T0 之后老 Jaeger 仍有新写入（同时也写新 Jaeger），但因为新 Jaeger 已经收到了一份，双写时间到 T0+7d 后停止双写并不影响数据完整性。
- 任一路径下，**T0+7d** 都是"老 Jaeger 不再有独占价值"的最早安全卸载时点。

> 如果业务确认无需查询切换前历史 trace，观察期可以**完全跳过**，部署完 v2 Collector 后立即进入清理章节。

## 5. 迁移步骤（默认：单写）

> 假设：集群当前正常运行老 Observability/Distributed Tracing；ES 8.x 可用，且执行人具备 ES 管理员权限（创建 ILM 策略需要）；已具备 `cluster-admin`。

整体步骤：

```
[Step 1]  迁移前准备（盘点 + 备份 + 兼容性检查 + 用户公告）
[Step 2]  卸载 OTel v1：删除 Instrumentation → 删除 Collector → 卸载 v1 Operator
              ↓ 调用链采集中断窗口开始
[Step 3]  安装 OTel v2 Operator
[Step 4]  部署新 Jaeger v2 实例（jaeger-system）
[Step 5]  部署 OTel v2 Collector（cpaas-system，单写到新 Jaeger）
              ↓ 调用链采集恢复（写入新 Jaeger；老 Jaeger 仅供查询历史）
[Step 6]  重建 Instrumentation（设置 spec.java.image）
[Step 7]  Rollout 已注入应用，更换为 v2 Java agent
[Step 8]  验证（telemetrygen + 真实业务流量 + ES 索引）
[Step 9]  观察期：≥ 7 天（老 Jaeger 历史数据自然过期）
[Step 10] 卸载老 Jaeger 实例 + 老 Jaeger Operator
[Step 11] 收尾：关闭 acp-tracing-ui Feature Switch、清理老 ES 索引
```

> 与原方案的差异：合并/移除了"配置双写"和"停止双写"两个步骤，从 12 步精简到 11 步。如需双写，参见第 6 章。

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

2. 备份 v1 资源：

   ```bash
   mkdir -p ./acp-tracing-backup
   kubectl get jaeger                -A -o yaml > ./acp-tracing-backup/jaegers.yaml
   kubectl get opentelemetrycollector -A -o yaml > ./acp-tracing-backup/collectors.yaml
   kubectl get instrumentation        -A -o yaml > ./acp-tracing-backup/instrumentations.yaml
   kubectl get subscription -n opentelemetry-operator opentelemetry-operator -o yaml \
     > ./acp-tracing-backup/otel-v1-subscription.yaml || true
   kubectl get csv -n opentelemetry-operator -o yaml \
     > ./acp-tracing-backup/otel-v1-csv.yaml || true
   ```

3. 准备 v2 Java agent 镜像（开源镜像或自建镜像）。

4. 兼容性检查：SM v1（先迁 v2）、OTel v1 Collector 配置中是否有 v2 不支持的组件、ES 权限。

5. **用户公告**：明确告知"切换后新 trace 在 `<platform-url>/clusters/<cluster>/jaeger`；切换前历史 trace 仍在 `<platform-url>/clusters/<cluster>/acp/jaeger`，最多保留 7 天"。

### Step 2：卸载 OTel v1

> ⚠️ 本步骤开始后，应用调用链采集中断，直到 Step 5 完成。

```bash
# 2.1 删除 Instrumentation
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
  startingCSV: opentelemetry-operator2.v0.146.0-r0
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

### Step 5：部署 OTel v2 Collector（默认单写）

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
      otlp/jaeger-new: # ← 仅写新 Jaeger
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
          exporters: [debug, otlp/jaeger-new]
        metrics:
          receivers: [otlp]
          processors: [memory_limiter, filter/metric_apis, transform, batch]
          exporters: [debug, prometheus]
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

> **exporter 名称带 `jaeger-new` 后缀**：保留这种命名是为了如果后续临时启用双写（第 6 章），可以在不改动现有 exporter 的前提下追加 `otlp/jaeger-old`，回滚时也对称。

应用后等待就绪：

```bash
kubectl rollout status deployment/otel-collector -n cpaas-system --timeout=180s
```

此时调用链采集恢复，新到达的 trace 写入新 Jaeger；老 Jaeger 没有新写入，但仍可查询历史 trace。

### Step 6：重建 Instrumentation

```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: acp-common-java
  namespace: cpaas-system
spec:
  java:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:2.26.1 # ← v2 必填
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

2. **合成流量验证**（telemetrygen → 应只在新 Jaeger UI 出现）：

   ```bash
   kubectl apply -n cpaas-system -f - <<EOF
   apiVersion: v1
   kind: Pod
   metadata:
     name: migration-check
   spec:
     restartPolicy: Never
     containers:
       - name: telemetrygen
         image: ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest
         args: ["traces","--otlp-endpoint=otel-collector.cpaas-system.svc.cluster.local:4317",
                "--otlp-insecure","--duration=120s","--service=migration-check","--rate=2"]
   EOF
   ```

   - 新 Jaeger UI（`<platform-url>/clusters/<cluster>/jaeger`）→ Service 选 `migration-check`，应能查到 traces。
   - 老 Jaeger UI（`<platform-url>/clusters/<cluster>/acp/jaeger`）→ Service 选 `migration-check`，**不应**有新数据（除非启用了第 6 章的双写）。

3. **真实业务验证**：选 1–2 个已 rollout 的关键应用，触发一次请求，确认 traceID 在新 Jaeger 中可检索。

4. **ES 端**：

   ```bash
   curl -k -u "$ES_USER:$ES_PASS" "$ES_ENDPOINT/_cat/indices?v" \
     | grep -E 'acp-tracing-|acp-' | sort
   ```

   - 新索引 `acp-<cluster>-jaeger-*-000001` 应在持续增长。
   - 老索引 `acp-tracing-<cluster>-jaeger-*` 不再增长，按日期陆续被 cleaner 删除。

5. **导出失败计数**：

   ```bash
   kubectl -n cpaas-system port-forward deployment/otel-collector 8888:8888 --address 127.0.0.1 >/dev/null 2>&1 &
   sleep 2
   curl -s http://127.0.0.1:8888/metrics | grep '^otelcol_exporter_send_failed_spans_total'
   ```

   `otelcol_exporter_send_failed_spans_total{exporter="otlp/jaeger-new"}` 应保持稳定。

### Step 9：观察期（≥ 7 天）

- 老 Jaeger UI 仍可查询切换前历史数据。`jaeger-es-index-cleaner` 按日删除创建超过 7 天的索引；T0+8d 时几乎所有可查的老数据已过期。
- 期间用新 Jaeger UI 校验仪表盘、告警、Kiali 集成、Java agent v2 的指标命名变化。
- 如有用户报告"在新 UI 找不到昨天的 trace"，引导其去老 UI（这是数据按时间切分的预期表现）。

> 如确认无人查询切换前历史 trace，可缩短甚至跳过观察期，直接进入 Step 10。

### Step 10：卸载老 Jaeger 实例与 Operator

```bash
# 10.1 删除老 Jaeger 实例及配套资源
kubectl -n cpaas-system delete ingress       jaeger-prod-query        --ignore-not-found
kubectl -n cpaas-system delete podmonitor    jaeger-prod-monitor      --ignore-not-found
kubectl -n cpaas-system delete jaeger        jaeger-prod              --ignore-not-found
kubectl -n cpaas-system delete rolebinding   jaeger-prod-rb           --ignore-not-found
kubectl -n cpaas-system delete role          jaeger-prod-role         --ignore-not-found
kubectl -n cpaas-system delete sa            jaeger-prod-sa           --ignore-not-found
kubectl -n cpaas-system delete secret        jaeger-prod-oauth2-proxy --ignore-not-found
kubectl -n cpaas-system delete secret        jaeger-prod-es-basic-auth --ignore-not-found
kubectl -n cpaas-system delete configmap     jaeger-prod-oauth2-proxy --ignore-not-found

# 10.2 卸载 Alauda Build of Jaeger Operator
kubectl -n jaeger-operator delete subscription jaeger-operator --ignore-not-found
CSV=$(kubectl -n jaeger-operator get csv -o name | grep -i jaeger-operator)
[ -n "$CSV" ] && kubectl -n jaeger-operator delete "$CSV"
```

> 若启用了第 6 章的双写，必须**先**执行 §6.2 移除 `otlp/jaeger-old`，再卸载老 Jaeger，否则 v2 Collector 的 OTLP exporter 会持续报错。

### Step 11：收尾

1. **关闭 `acp-tracing-ui` Feature Switch**（在 ACP Web Console 的 Feature Switch 视图操作），并向用户公告新 Jaeger UI 入口 `<platform-url>/clusters/<cluster>/jaeger`。
2. **手动清理老 ES 索引**：

   ```bash
   curl -k -u "$ES_USER:$ES_PASS" -X DELETE \
     "$ES_ENDPOINT/acp-tracing-<cluster>-jaeger-*"
   ```

3. **更新内部文档与告警 Runbook**：把 Jaeger UI 链接、ES 索引前缀、ServiceMonitor/PodMonitor 名称都同步到新值。

## 6. 可选路径：双写到老 Jaeger

仅当需要"并行验证 / 跨团队渐进切换 / 观察期一键回滚"时启用。代价：观察期 ES 写入与存储 ≈ 2×、需要两个 patch（启用 + 关闭）。

### 6.1 启用双写

在 §5 Step 5 之后（v2 Collector 已 ready），patch 加入老 Jaeger exporter：

```bash
kubectl -n cpaas-system patch opentelemetrycollector otel --type=merge -p '
spec:
  config:
    exporters:
      otlp/jaeger-old:
        endpoint: dns:///jaeger-prod-collector-headless.cpaas-system:4317
        balancer_name: round_robin
        tls:
          insecure: true
        sending_queue:
          enabled: true
        retry_on_failure:
          enabled: true
    service:
      pipelines:
        traces:
          exporters: [debug, otlp/jaeger-new, otlp/jaeger-old]
'
kubectl rollout status deployment/otel-collector -n cpaas-system --timeout=180s
```

> ⚠️ `service.pipelines.traces.exporters` 是数组，merge patch 是**整体替换**而非追加，必须把所有需要保留的 exporter 都列出。

启用后 §5 Step 8 的合成流量应在新老两个 Jaeger UI 都能查到。

### 6.2 停止双写

§5 Step 10 卸载老 Jaeger **之前**，patch 移除：

```bash
kubectl -n cpaas-system patch opentelemetrycollector otel --type=merge -p '
spec:
  config:
    exporters:
      otlp/jaeger-old: null
    service:
      pipelines:
        traces:
          exporters: [debug, otlp/jaeger-new]
'
kubectl rollout status deployment/otel-collector -n cpaas-system --timeout=180s
```

之后 v2 Collector 仅写新 Jaeger，回到 §4.3 稳态，可以继续 §5 Step 10 卸载老 Jaeger。

## 7. 验证清单（清单式总结）

- [ ] OTel v2 Operator CSV `Succeeded`，且 v1 CSV 已不存在
- [ ] `cpaas-system/otel` 与 `jaeger-system/jaeger` 两个 OpenTelemetryCollector 均 Ready
- [ ] 全部 `Instrumentation` 资源 `spec.java.image` 已设置
- [ ] 已 rollout 的应用 Pod 中 init container 镜像为 v2 Java agent
- [ ] telemetrygen 在新 Jaeger UI 可查（默认单写）；启用双写时新老 UI 都可查
- [ ] ES 中 `acp-<cluster>-jaeger-*` 持续增长；`acp-tracing-<cluster>-jaeger-*` 不再增长（默认单写）；启用双写时两边都增长
- [ ] OTel Collector `otelcol_exporter_send_failed_spans_total{exporter="otlp/jaeger-new"}` 不持续增长
- [ ] 7 天观察期后，老 Jaeger 实例与 Operator 已卸载、`acp-tracing-ui` Feature Switch 已关闭、老 ES 索引已清理（启用了双写则先关闭双写）

## 8. 回滚方案

| 阶段                   | 故障                                   | 回滚动作                                                                                                                                                         |
| :--------------------- | :------------------------------------- | :--------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Step 1 准备阶段        | 决定不迁移                             | 无操作（未触动现状）                                                                                                                                             |
| Step 2–3               | OTel v2 Operator 装不上                | `kubectl get csv -A \| grep '^opentelemetry-operator '` 应为空；若 v1 CSV 残留，手动删除后重试。如需放弃迁移：按 `migrating-to-v2.mdx` 的 _Rollback_ 章节重装 v1 |
| Step 4                 | 新 Jaeger v2 异常                      | 不影响老 Jaeger 与应用调用链。`kubectl delete -n jaeger-system opentelemetrycollector jaeger`，定位问题后重做 Step 4                                             |
| Step 5                 | OTel v2 Collector 启不来               | 应用 OTLP 失败。临时在 traces.exporters 中把 `otlp/jaeger-new` 替换为指向老 Jaeger 的 exporter（一次性 patch），把流量先回到老 Jaeger；定位问题再切回            |
| Step 8 之后 / 观察期内 | 新 Jaeger 行为异常（**默认单写路径**） | patch v2 Collector：把 `otlp/jaeger-new` 替换为指向老 Jaeger 的 exporter。或先按 §6.1 启用双写、再 patch 去掉 `otlp/jaeger-new`                                  |
| Step 8 之后 / 观察期内 | 新 Jaeger 行为异常（**已启用双写**）   | patch 去掉 `otlp/jaeger-new`，老 Jaeger 立即接管                                                                                                                 |
| Step 8 之后 / 观察期内 | 老 Jaeger 异常（**已启用双写**）       | patch 去掉 `otlp/jaeger-old`，等同提前进入 §6.2                                                                                                                  |
| Step 7                 | 应用 rollout 后无 trace                | 检查 v2 mutating webhook、`Instrumentation`、Pod init container；必要时重新 rollout                                                                              |
| 观察期                 | 决定放弃整套迁移                       | 调整 v2 Collector 的 traces.exporters 改回老 Jaeger；按 `migrating-to-v2.mdx` 的 _Rollback_ 把 OTel v2 → v1（再次 rollout 应用以恢复 v1 Java agent）             |

## 9. 风险与缓解

| 风险                                   | 影响                                                     | 缓解                                                                                                        |
| :------------------------------------- | :------------------------------------------------------- | :---------------------------------------------------------------------------------------------------------- |
| Step 2 → Step 5 之间调用链采集中断     | 该窗口内 trace 数据丢失（应用业务不受影响）              | 选择业务低峰期；脚本化串联 Step 2–5 缩短窗口；OTel SDK 默认有 buffer，影响通常可控                          |
| OTel v2 Operator 启动失败              | 全集群 OTel 不可用                                       | Step 1 先在测试集群跑一遍；保留 v1 备份 YAML 以便回滚                                                       |
| Java agent 行为差异（v1.x → v2.x）     | 自动指标命名/属性变化导致看板/告警失效                   | 提前 review 现有 Prometheus 看板和告警，按 OTel Java agent v2 release notes 调整；可在 Step 7 分批 rollout  |
| 用户在新 UI 找不到切换前 trace 而困惑  | 用户体验下降、误报 bug                                   | Step 1 用户公告中**明确**告知"切换前 → 老 UI；切换后 → 新 UI"；新 UI 顶栏可放公告                           |
| 用户提前删除老 Jaeger                  | 切换前历史 trace 永久丢失                                | Step 10 必须在观察期完成后执行；流程化为审批节点                                                            |
| 老 ES 索引未清理                       | 无业务影响但浪费空间                                     | Step 11 中明确清理动作，纳入收尾验收                                                                        |
| 集群存在 Service Mesh v1               | Step 5 后 SM v1 调用链断裂                               | Step 1 兼容性检查时拦截：先做 SM v1 → v2，再启动本迁移                                                      |
| `acp-tracing-ui` Feature Switch 未关闭 | ACP 老 Tracing 菜单仍展示，但后端已不可用 → 用户体验下降 | Step 11 中关闭；并在用户公告中明确新入口                                                                    |
| 启用了双写但未在 Step 10 之前关闭      | 老 Jaeger 卸载后 v2 Collector OTLP exporter 持续报错     | §6.2 在 Step 10 之前是硬性前置；监控 `otelcol_exporter_send_failed_spans_total{exporter="otlp/jaeger-old"}` |
| 启用双写期间 ES 容量翻倍               | ES 磁盘写满 → read-only                                  | 启用双写前评估 ES 容量、确保至少 50% 余量；只在确实需要时启用；尽量缩短双写时长                             |

## 10. 常见问题（FAQ）

**Q1：老 Jaeger 和新 Jaeger v2 能装在同一个命名空间吗？**

A：能，但不建议。新方案默认命名空间是 `jaeger-system`，老方案是 `cpaas-system`，分开放可以避免 Service 名（`*-collector`）和 Ingress 路径（`/acp/jaeger` vs `/jaeger`）潜在冲突。

**Q2：迁移期间应用 OTLP 上报地址要不要改？**

A：**不需要**。新 OTel v2 Collector 仍然部署在 `cpaas-system`、Service 名仍为 `otel-collector`、端口 4317/4318 不变。这是本方案设计的核心收益。

**Q3：新 Jaeger UI 会不会显示切换前的历史 trace？**

A：**不会**。切换前的历史 trace 只在老 Jaeger 中。默认单写路径下，T0 之前的数据始终通过老 Jaeger UI 查询，并随老 cleaner 在 7 天后自然过期。在 Step 1 用户公告中务必把这点说清楚。

**Q4：什么情况下应该启用双写？**

A：默认推荐**单写**。仅当满足下列任一条件时再启用双写：

- 需要在生产流量上**并行验证**新 Jaeger 行为是否与老 Jaeger 一致；
- 不同团队按各自节奏从老 UI 切到新 UI，过渡期希望两边都能查到 T0 之后的数据；
- 需要观察期内的"一键回滚"能力（patch 一次即可把流量切回老 Jaeger，无需重新部署 exporter）。

代价：观察期内 ES 写入与存储 ≈ 2×、配置变更多一次（启用 + 关闭）、需要同时监控两条 exporter pipeline。

**Q5：观察期能不能缩短甚至跳过？**

A：可以。如果业务确认"切换前历史 trace 没有查询价值"，可以在 Step 8 验证完成后直接进入 Step 10。代价是切换前的所有 trace 立即不可达。

**Q6：双写期间 ES 容量评估？**

A：双写期间 ES 用量 ≈ 单写时的 2×（同一份 trace 在新老索引各落一份）。如果原老 Jaeger 7 天数据占 100GB，双写 7 天 + 新 Jaeger 自身 7 天保留意味着峰值约 200GB（双写期间）+ 100GB（双写结束、老索引 7 天衰减完）。预留 50% 空间是稳妥下限。单写路径下不存在这个翻倍问题。

**Q7：需要修改 Kiali / Service Mesh 的 tracing 配置吗？**

A：

- 如果原集群仅使用 ACP Tracing（无 SM 集成）：不需要。
- 如果原集群使用 SM v1 + 老 Jaeger：必须先迁 SM v1 → v2，SM v2 与 OTel v2 的对接见 `servicemesh2-docs/docs/en/integration/observability/distributed-tracing-and-mesh.mdx`。
- 如果原集群使用 SM v2 + 老 Jaeger：参考 `migrating-to-v2.mdx` 中的 _Alauda Service Mesh v2 integration_ 章节，把 `meshConfig.extensionProviders[].opentelemetry.service` 指向新 OTel Collector（如保留 `cpaas-system/otel-collector` 名称则不需要改）。

**Q8：迁移完成后 SPM（Service Performance Monitoring）怎么启用？**

A：本迁移方案不强制启用 SPM。如需启用，按 `installing-distributed-tracing.mdx` 中 _(Optional) Enabling Service Performance Monitoring (SPM)_ 章节给 OTel v2 Collector 添加 `spanmetrics` connector，给 Jaeger v2 添加 `metric_backends`。这一步可以在 Step 11 后追加进行，与本迁移方案相互独立。

## 11. 时间预算（参考）

| 阶段                                    | 预计耗时                           | 备注                                                   |
| :-------------------------------------- | :--------------------------------- | :----------------------------------------------------- |
| Step 1 准备                             | 0.5–1 工作日                       | 含盘点、备份、镜像与 ES 配置确认、用户公告             |
| Step 2–3 OTel v1 卸载 + v2 安装         | 10–20 分钟                         | 主要等待 CSV、InstallPlan                              |
| Step 4 部署新 Jaeger v2                 | 15–30 分钟                         | 含 ILM/索引初始化                                      |
| Step 5 部署 OTel v2 Collector（单写）   | 5–10 分钟                          |                                                        |
| **Step 2 → Step 5 调用链中断窗口**      | **约 30–60 分钟**                  | 视集群规模、镜像拉取速度                               |
| Step 6–7 Instrumentation + 应用 rollout | 0.5–1 工作日                       | 取决于注入应用数量与分批策略                           |
| Step 8 验证                             | 0.5 工作日                         |                                                        |
| Step 9 观察期                           | **≥ 7 天**（可缩短或跳过，视业务） |                                                        |
| Step 10–11 清理收尾                     | 0.5 工作日                         |                                                        |
| §6 双写（可选）                         | 启用约 5 分钟、关闭约 5 分钟       | 启用后 OTel Collector 资源用量略增；ES 写入与存储约 2× |

总体里程碑（默认单写）：T0（Step 1） → T0+1d（应用 rollout 完成、单写就绪） → T0+8d（卸载老 Jaeger、收尾完成）。
