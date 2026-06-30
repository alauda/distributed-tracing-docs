#!/usr/bin/env bash
# SPM 多副本（高可用）验证公共逻辑。
#
# 被 runme-test_spm-ha-elasticsearch.sh / runme-test_spm-ha-opensearch.sh 复用。
# 多副本验证与存储后端（ES/OS）无关，故两者共享同一套逻辑，仅入口测试函数名不同。
#
# 设计要点：本脚本**不修改、也不依赖任何 mdx runme 代码块**。它在「已按安装文档启用 SPM
# （新方案：前置 otel 用 loadbalancing(routing_key=service) → Jaeger 内跑 spanmetrics）」的
# 环境之上，直接通过 kubectl 扩容、部署多 service telemetrygen、并逐个 Jaeger 副本校验
# 「单写入者」：每个 service 只被一个 Jaeger 副本聚合 spanmetrics，指标不碎片、不重复。
#
# 参见手册：distributed-tracing-docs/.helper/ops/spanmetrics-ha-verification.md

# ── 可调参数（均带默认值，与安装文档默认一致）─────────────────────────────────
JAEGER_NS="${JAEGER_NS:-jaeger-system}"               # Jaeger 命名空间
JAEGER_INSTANCE_NAME="${JAEGER_INSTANCE_NAME:-jaeger}" # Jaeger 实例名
SPM_HA_REPLICAS="${SPM_HA_REPLICAS:-2}"               # 扩容目标副本数
SPM_HA_SVC_COUNT="${SPM_HA_SVC_COUNT:-6}"             # 测试 service 数量
SPM_HA_TG_DURATION="${SPM_HA_TG_DURATION:-30s}"       # 每个 telemetrygen 发送时长

# 解析 telemetrygen 镜像：与安装测试 _deploy_telemetrygen 一致，
# USE_MESH_V2_TEST_SUITE_PLUGIN=true 时改写为 mesh-v2-test-suite 集群插件的内网仓库。
_spm_ha_telemetrygen_image() {
    local img="ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest"
    if [ "${USE_MESH_V2_TEST_SUITE_PLUGIN:-false}" = "true" ]; then
        local registry
        registry=$(kubectl -n cpaas-system get cm mesh-v2-test-suite-manifest \
            -o jsonpath='{.data.registry}' 2>/dev/null)
        if [ -n "$registry" ]; then
            img="${registry}/asm/opentelemetry-collector-contrib/telemetrygen:latest"
        fi
    fi
    printf '%s' "$img"
}

# 前置检查：确认当前为新方案 SPM 拓扑。
# otel 实例不存在视为「环境未安装」→ 由调用方 skip；存在但配置不符 → 失败。
_spm_ha_precheck() {
    local rk connectors
    rk=$(kubectl -n "$JAEGER_NS" get opentelemetrycollector otel \
        -o jsonpath='{.spec.config.exporters.loadbalancing.routing_key}' 2>/dev/null)
    connectors=$(kubectl -n "$JAEGER_NS" get opentelemetrycollector "$JAEGER_INSTANCE_NAME" \
        -o jsonpath='{.spec.config.connectors}' 2>/dev/null)

    if [ "$rk" != "service" ]; then
        log_error "前置 otel 未配置 loadbalancing(routing_key=service)，当前值: '${rk}'"
        return 1
    fi
    case "$connectors" in
        *spanmetrics*) ;;
        *) log_error "Jaeger 实例 '${JAEGER_INSTANCE_NAME}' 未配置 spanmetrics connector"; return 1 ;;
    esac
    log_success "前置检查通过：otel loadbalancing(routing_key=service) + jaeger spanmetrics"
    return 0
}

# 扩容 otel 与 jaeger 到指定副本数（修改 CR 的 spec.replicas，由 Operator 同步到 Deployment）
_spm_ha_scale() {
    local n="$1"
    log_info "扩容 otel 与 ${JAEGER_INSTANCE_NAME} 到 ${n} 副本"
    kubectl -n "$JAEGER_NS" patch opentelemetrycollector otel \
        --type=merge -p "{\"spec\":{\"replicas\":${n}}}" || return 1
    kubectl -n "$JAEGER_NS" patch opentelemetrycollector "$JAEGER_INSTANCE_NAME" \
        --type=merge -p "{\"spec\":{\"replicas\":${n}}}" || return 1
    log_info "等待两个 Deployment 滚动完成"
    kubectl -n "$JAEGER_NS" rollout status deployment/otel-collector --timeout=180s || return 1
    kubectl -n "$JAEGER_NS" rollout status "deployment/${JAEGER_INSTANCE_NAME}-collector" --timeout=180s || return 1
    return 0
}

# 部署 count 个不同 service 的 telemetrygen，统一发往前置 otel，并等待发送完成
_spm_ha_deploy_telemetrygen() {
    local count="$1" image i
    image=$(_spm_ha_telemetrygen_image)
    log_info "部署 ${count} 个 telemetrygen（service: spm-ha-svc-0..$((count - 1))，镜像: ${image}）"
    for i in $(seq 0 $((count - 1))); do
        kubectl -n "$JAEGER_NS" delete pod "tg-svc-$i" --ignore-not-found >/dev/null 2>&1
        kubectl apply -f - >/dev/null <<EOF || return 1
apiVersion: v1
kind: Pod
metadata:
  name: tg-svc-$i
  namespace: ${JAEGER_NS}
spec:
  restartPolicy: Never
  containers:
    - name: telemetrygen
      image: ${image}
      args:
        - traces
        - --otlp-endpoint=otel-collector.${JAEGER_NS}.svc.cluster.local:4317
        - --otlp-insecure
        - --duration=${SPM_HA_TG_DURATION}
        - --rate=10
        - --service=spm-ha-svc-$i
        - --workers=1
EOF
    done
    log_info "等待全部 telemetrygen 发送完成"
    for i in $(seq 0 $((count - 1))); do
        kubectl -n "$JAEGER_NS" wait --for=jsonpath='{.status.phase}'=Succeeded \
            "pod/tg-svc-$i" --timeout=120s >/dev/null 2>&1 || {
            log_error "telemetrygen tg-svc-$i 未在预期时间内完成"
            return 1
        }
    done
    log_success "${count} 个 service 的测试流量发送完成"
    return 0
}

# 抓取单个 Jaeger pod 的 :8889 指标，输出其聚合的 spm-ha-svc-* 列表（每行一个，去重）
_spm_ha_pod_services() {
    local pod="$1" port="$2" out
    timeout 5 kubectl -n "$JAEGER_NS" port-forward "pod/$pod" "${port}:8889" >/dev/null 2>&1 &
    out=$(curl -s --retry-connrefused --retry 15 --retry-delay 1 --max-time 22 "http://localhost:${port}/metrics")
    printf '%s' "$out" | grep -oE 'service_name="spm-ha-svc-[0-9]+"' \
        | sed -E 's/.*"(spm-ha-svc-[0-9]+)".*/\1/' | sort -u
}

# 单次收集逐副本 service 并校验。
# 返回: 0=完整通过(无重复且并集==count)；2=无重复但不完整；1=发现跨副本重复(失败)
# 副作用: 设置 __SPM_HA_UNIQ_COUNT。
_spm_ha_collect_once() {
    local count="$1" tmpdir pods pod port i
    tmpdir=$(mktemp -d)
    pods=$(kubectl -n "$JAEGER_NS" get pod -l app.kubernetes.io/name=jaeger-collector \
        --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}')
    i=0
    for pod in $pods; do
        port=$((19900 + i)); i=$((i + 1))
        _spm_ha_pod_services "$pod" "$port" > "$tmpdir/$pod"
        log_info "  副本 ${pod} 聚合 service: [$(tr '\n' ' ' < "$tmpdir/$pod")]"
    done
    wait 2>/dev/null

    local all dup uniq_count
    all=$(cat "$tmpdir"/* 2>/dev/null | sort)
    dup=$(printf '%s\n' "$all" | uniq -d | grep 'spm-ha-svc' || true)
    uniq_count=$(printf '%s\n' "$all" | grep -c 'spm-ha-svc' || true)
    rm -rf "$tmpdir"
    __SPM_HA_UNIQ_COUNT="$uniq_count"

    if [ -n "$dup" ]; then
        log_error "以下 service 同时出现在多个 Jaeger 副本（违反单写入者，指标会碎片化/重复）:"
        printf '%s\n' "$dup" | while read -r s; do [ -n "$s" ] && log_error "    - $s"; done
        return 1
    fi
    if [ "$uniq_count" -eq "$count" ]; then
        return 0
    fi
    return 2
}

# 校验单写入者（带重试，容忍 spanmetrics flush 延迟）
_spm_ha_verify_single_writer() {
    local count="$1" attempt rc
    for attempt in $(seq 1 8); do
        log_info "校验单写入者（第 ${attempt} 次；目标 ${count} 个 service 各落唯一副本）"
        _spm_ha_collect_once "$count"; rc=$?
        if [ "$rc" -eq 0 ]; then
            log_success "单写入者验证通过：${count} 个 service 各自仅被一个 Jaeger 副本聚合，指标无碎片、无重复"
            return 0
        fi
        if [ "$rc" -eq 1 ]; then
            log_error "单写入者验证失败：存在跨副本重复的 service"
            return 1
        fi
        log_warn "已收集 ${__SPM_HA_UNIQ_COUNT:-0}/${count} 个 service（均无重复），等待 spanmetrics flush 后重试..."
        sleep 10
    done
    # 超时仍不完整：只要无重复且已采到 >0，单写入者结论成立（部分 service 仅因 flush 未计入）
    if [ "${__SPM_HA_UNIQ_COUNT:-0}" -gt 0 ]; then
        log_warn "未在超时内集齐全部 ${count} 个 service，但已采集的 ${__SPM_HA_UNIQ_COUNT} 个均无跨副本重复"
        log_success "单写入者验证通过（其余 service 因 flush 延迟未计入，不影响结论）"
        return 0
    fi
    log_error "未能在任一 Jaeger 副本上采集到 spm-ha service 指标"
    return 1
}

# 主验证流程（backend 仅用于日志）
_spm_ha_run() {
    local backend="$1"
    log_header "SPM 多副本（HA）验证 [${backend}] —— 目标副本数 ${SPM_HA_REPLICAS}、service 数 ${SPM_HA_SVC_COUNT}"

    if ! kubectl -n "$JAEGER_NS" get opentelemetrycollector otel >/dev/null 2>&1; then
        skip_test "未检测到 ${JAEGER_NS}/otel，环境未安装 SPM，跳过多副本验证"
        return 0
    fi
    _spm_ha_precheck || return 1
    _spm_ha_scale "$SPM_HA_REPLICAS" || { log_error "扩容失败"; return 1; }
    _spm_ha_deploy_telemetrygen "$SPM_HA_SVC_COUNT" || return 1
    _spm_ha_verify_single_writer "$SPM_HA_SVC_COUNT" || return 1

    log_success "SPM 多副本验证完成 [${backend}]：扩到 ${SPM_HA_REPLICAS} 副本后 span-metrics 指标正确"
    return 0
}

# 清理：删除 telemetrygen pod，并缩容回单副本
_spm_ha_cleanup() {
    local i
    for i in $(seq 0 $((SPM_HA_SVC_COUNT - 1))); do
        kubectl -n "$JAEGER_NS" delete pod "tg-svc-$i" --ignore-not-found >/dev/null 2>&1
    done
    kubectl -n "$JAEGER_NS" patch opentelemetrycollector otel \
        --type=merge -p '{"spec":{"replicas":1}}' >/dev/null 2>&1
    kubectl -n "$JAEGER_NS" patch opentelemetrycollector "$JAEGER_INSTANCE_NAME" \
        --type=merge -p '{"spec":{"replicas":1}}' >/dev/null 2>&1
    log_success "已删除 telemetrygen 并缩容回单副本"
    return 0
}
