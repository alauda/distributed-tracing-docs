#!/usr/bin/env bash
# Alauda Distributed Tracing 安装文档测试脚本
# 对应文档: docs/en/installing/installing-distributed-tracing.mdx
# 覆盖范围: 「Installing Alauda Build of Jaeger v2」与「Deploying the OpenTelemetry
#           Collector」「Verification」章节；「(Optional) SPM」章节首期不纳入。

set -e

: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"

# 加载框架函数库
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"

# 在 opentelemetry-docs 仓库内执行命令的小封装（OTel Operator 为跨仓库前置依赖，
# 其 install-otel:* 代码块位于 opentelemetry-docs）。
# $OTEL_REPO_ROOT 由 run.sh 引擎按 repos.conf 注入。
_in_otel_repo() {
    pushd "$OTEL_REPO_ROOT" >/dev/null
    "$@"
    local rc=$?
    popd >/dev/null
    return $rc
}

# 部署 telemetrygen 生成测试 trace。
# 取出文档代码块后按需改写再执行（镜像替换与测试时长两处改动合并于此函数）：
#   - 测试时长：第一次由 TRACING_TELEMETRYGEN_TEST_DURATION_1 控制（默认 30s），
#     第二次由 TRACING_TELEMETRYGEN_TEST_DURATION_2 控制（默认 80s），覆盖文档默认的 150s
#   - 镜像：USE_MESH_V2_TEST_SUITE_PLUGIN=true 时，参考 projects/mesh/project.sh 的
#     kubectl_apply_with_mirror，从 mesh-v2-test-suite 集群插件 registry 改写 telemetrygen 镜像
_deploy_telemetrygen() {
    local duration="$1"
    local content
    content=$(runme print install-tracing:deploy-telemetrygen 2>/dev/null)
    if [ -z "$content" ]; then
        log_error "无法获取代码块内容: install-tracing:deploy-telemetrygen"
        return 1
    fi

    # 改写测试时长（文档默认 150s）
    log_info "telemetrygen 测试时长: $duration"
    content="${content//--duration=150s/--duration=$duration}"

    # 改写镜像：USE_MESH_V2_TEST_SUITE_PLUGIN=true 时使用集群插件镜像仓库
    if [ "${USE_MESH_V2_TEST_SUITE_PLUGIN:-false}" = "true" ]; then
        local registry
        registry=$(kubectl -n cpaas-system get cm mesh-v2-test-suite-manifest \
            -o jsonpath='{.data.registry}' 2>/dev/null)
        if [ -z "$registry" ]; then
            log_error "USE_MESH_V2_TEST_SUITE_PLUGIN=true 但未能从 cpaas-system/mesh-v2-test-suite-manifest 读取 data.registry"
            return 1
        fi
        log_info "使用 mesh-v2-test-suite 集群插件镜像仓库: $registry"
        content=$(printf '%s' "$content" | sed "s|ghcr\.io/open-telemetry/|${registry}/asm/|")
    fi

    eval "$content"
}

# SPM (Service Performance Monitoring) 章节测试，覆盖 install-tracing-spm:* 代码块。
# 由 test_installing_distributed_tracing 在 TRACING_TEST_SPM=true 时调用。
_test_spm() {
    log_header "Service Performance Monitoring (SPM) 测试"

    # 步骤 19: 拉取 monitoring 端点与凭据
    log_info "步骤 19: 拉取 monitoring 配置"
    eval "$(runme print install-tracing-spm:get-monitoring-config)" || {
        log_error "拉取 monitoring 配置失败"
        return 1
    }

    # 步骤 20: 创建 monitoring 凭据 Secret
    log_info "步骤 20: 创建 monitoring 凭据 Secret"
    runme run install-tracing-spm:create-monitoring-secret || {
        log_error "创建 monitoring 凭据 Secret 失败"
        return 1
    }

    # 步骤 21: Patch OpenTelemetry Collector 启用 SpanMetrics Connector
    log_info "步骤 21: Patch OpenTelemetry Collector 启用 spanmetrics"
    runme run install-tracing-spm:patch-otel-collector || {
        log_error "Patch OpenTelemetry Collector 失败"
        return 1
    }

    # 步骤 22: 等待 OpenTelemetry Collector 重启就绪
    log_info "步骤 22: 等待 OpenTelemetry Collector 重启就绪"
    runme run install-tracing-spm:wait-otel-collector-rollout || {
        log_error "等待 OpenTelemetry Collector 重启失败"
        return 1
    }

    # 步骤 23: 生成 jaeger-spm-patch.yaml 到 /tmp
    log_info "步骤 23: 生成 /tmp/jaeger-spm-patch.yaml"
    runme print install-tracing-spm:jaeger-spm-patch-yaml > /tmp/jaeger-spm-patch.yaml || {
        log_error "生成 jaeger-spm-patch.yaml 失败"
        return 1
    }

    # 步骤 24: 应用 SPM patch（需在 /tmp 目录下执行）
    log_info "步骤 24: 应用 jaeger-spm-patch.yaml"
    kubectl_apply_runme_block "install-tracing-spm:apply-jaeger-patch" "/tmp/" || {
        log_error "应用 jaeger-spm-patch.yaml 失败"
        return 1
    }

    # 步骤 25: 等待 Jaeger 重启就绪
    log_info "步骤 25: 等待 Jaeger 重启就绪"
    runme run install-tracing-spm:wait-jaeger-rollout || {
        log_error "等待 Jaeger 重启失败"
        return 1
    }

    # 步骤 26: 重新部署 telemetrygen 验证 SPM 指标（文档 Verification 要求）
    log_info "步骤 26: 重新部署 telemetrygen 验证 SPM"
    _deploy_telemetrygen "${TRACING_TELEMETRYGEN_TEST_DURATION_2:-130s}" || {
        log_error "SPM telemetrygen 验证失败"
        return 1
    }

    # 打印 Jaeger UI URL
    runme run install-tracing:print-jaeger-url

    log_success "SPM 测试完成"
    return 0
}

# 测试函数：分布式调用链安装
test_installing_distributed_tracing() {
    log_info "=========================================="
    log_info "开始 Alauda Distributed Tracing 安装测试"
    log_info "=========================================="

    # 步骤 0: 检查 Elasticsearch 配置（可由 tracing project_prepare 从 ACP ES 自动注入）
    if [ -z "${TRACING_ES_ENDPOINT:-}" ] || [ -z "${TRACING_ES_USER:-}" ] || [ -z "${TRACING_ES_PASS:-}" ]; then
        if [ -n "${TRACING_ACP_ES_CLUSTER:-}" ]; then
            log_error "TRACING_ACP_ES_CLUSTER=${TRACING_ACP_ES_CLUSTER}，但未能注入 TRACING_ES_ENDPOINT / TRACING_ES_USER / TRACING_ES_PASS"
            return 1
        fi
        log_warn "SKIPPED: TRACING_ACP_ES_CLUSTER 为空且未设置 TRACING_ES_ENDPOINT / TRACING_ES_USER / TRACING_ES_PASS，跳过分布式调用链安装测试"
        return 0
    fi
    if [ -n "${TRACING_ACP_ES_CLUSTER:-}" ]; then
        log_info "使用 ACP ES 配置: cluster=${TRACING_ACP_ES_CLUSTER} endpoint=${TRACING_ES_ENDPOINT}"
    else
        log_info "使用手动 Elasticsearch 配置: endpoint=${TRACING_ES_ENDPOINT}"
    fi

    # 步骤 1: 安装 Alauda Build of OpenTelemetry v2 Operator（跨仓库前置依赖）
    log_info "步骤 1: 安装 OpenTelemetry v2 Operator"
    if [ -z "${OTEL_REPO_ROOT:-}" ]; then
        log_error "OTEL_REPO_ROOT 未注入，无法定位 opentelemetry-docs 安装 OTel Operator"
        return 1
    fi
    _in_otel_repo install_operator \
        "opentelemetry-operator2" \
        "opentelemetry-operator2" \
        "$PKG_OPENTELEMETRY_OPERATOR2_URL" \
        "install-otel" || {
        log_error "OTel Operator 安装失败"
        return 1
    }

    # 步骤 2: 注入 Elasticsearch 连接环境变量（替代文档步骤 1 的占位符）
    log_info "步骤 2: 设置 Elasticsearch 连接环境变量"
    export ES_ENDPOINT="$TRACING_ES_ENDPOINT"
    export ES_USER="$TRACING_ES_USER"
    export ES_PASS="$TRACING_ES_PASS"

    # 步骤 3: 拉取平台配置与 Jaeger 镜像
    log_info "步骤 3: 拉取平台配置"
    eval "$(runme print install-tracing:get-platform-config)" || {
        log_error "拉取平台配置失败"
        return 1
    }

    # 步骤 4: 设置 Jaeger 默认环境变量
    log_info "步骤 4: 设置 Jaeger 默认环境变量"
    eval "$(runme print install-tracing:set-jaeger-defaults)" || {
        log_error "设置 Jaeger 默认环境变量失败"
        return 1
    }

    # 步骤 5: 创建 Jaeger 命名空间与 ES 凭据 Secret
    log_info "步骤 5: 创建命名空间与 ES 凭据 Secret"
    runme run install-tracing:create-jaeger-ns-and-es-secret || {
        log_error "创建命名空间与 ES Secret 失败"
        return 1
    }

    # 步骤 5.1: 验证 ES Secret
    log_info "步骤 5.1: 验证 ES Secret"
    runme run install-tracing:verify-es-secret || {
        log_error "验证 ES Secret 失败"
        return 1
    }

    # 步骤 6: 创建 ILM Policy
    log_info "步骤 6: 创建 ILM Policy"
    runme run install-tracing:create-ilm-policy || {
        log_error "创建 ILM Policy 失败"
        return 1
    }

    # 步骤 6.1: 验证 ILM Policy
    log_info "步骤 6.1: 验证 ILM Policy"
    runme run install-tracing:verify-ilm-policy || {
        log_error "验证 ILM Policy 失败"
        return 1
    }

    # 步骤 7: 创建 jaeger-es-rollover-init Job
    log_info "步骤 7: 创建 rollover-init Job"
    runme run install-tracing:create-rollover-init-job || {
        log_error "创建 rollover-init Job 失败"
        return 1
    }

    # 步骤 7.1: 等待 Job 完成并验证索引模板/别名
    log_info "步骤 7.1: 等待 rollover-init Job 完成并验证"
    runme run install-tracing:verify-rollover-init || {
        log_error "验证 rollover-init 失败"
        return 1
    }

    # 步骤 8: 清理 rollover-init Job
    log_info "步骤 8: 清理 rollover-init Job"
    runme run install-tracing:delete-rollover-init-job || {
        log_error "清理 rollover-init Job 失败"
        return 1
    }

    # 步骤 9: 创建 OAuth2 Proxy Secret
    log_info "步骤 9: 创建 OAuth2 Proxy Secret"
    runme run install-tracing:create-oauth2-proxy-secret || {
        log_error "创建 OAuth2 Proxy Secret 失败"
        return 1
    }

    # 步骤 10: 生成 jaeger.yaml 到 /tmp（envsubst apply 依赖 cwd 中存在该文件）
    log_info "步骤 10: 生成 /tmp/jaeger.yaml"
    runme print install-tracing:jaeger-yaml > /tmp/jaeger.yaml || {
        log_error "生成 jaeger.yaml 失败"
        return 1
    }

    # 步骤 11: envsubst 渲染并 apply（需在 /tmp 目录下执行）
    log_info "步骤 11: 渲染并应用 jaeger.yaml"
    kubectl_apply_runme_block "install-tracing:apply-jaeger" "/tmp/" || {
        log_error "应用 jaeger.yaml 失败"
        return 1
    }

    # 步骤 11.1: 等待 OpenTelemetryCollector 状态副本数收敛
    log_info "步骤 11.1: 等待 OpenTelemetryCollector status.scale.statusReplicas=1/1"
    kubectl wait "opentelemetrycollector/${JAEGER_INSTANCE_NAME}" \
        -n "${JAEGER_NS}" \
        --for=jsonpath='{.status.scale.statusReplicas}'=1/1 \
        --timeout=180s || {
        log_error "等待 OpenTelemetryCollector status.scale.statusReplicas=1/1 失败"
        return 1
    }

    # 步骤 12: 等待 Jaeger collector deployment 就绪
    log_info "步骤 12: 等待 Jaeger collector 就绪"
    runme run install-tracing:wait-jaeger-rollout || {
        log_error "等待 Jaeger collector 就绪失败"
        return 1
    }

    # 步骤 13: 给命名空间打 cpaas.io/project 标签
    log_info "步骤 13: 标记 Jaeger 命名空间"
    runme run install-tracing:label-jaeger-ns || {
        log_error "标记命名空间失败"
        return 1
    }

    # 步骤 14: 创建 Jaeger Ingress
    log_info "步骤 14: 创建 Jaeger Ingress"
    runme run install-tracing:create-jaeger-ingress || {
        log_error "创建 Jaeger Ingress 失败"
        return 1
    }

    # 步骤 14.1: 等待 Ingress LoadBalancer 就绪
    log_info "步骤 14.1: 等待 Jaeger Ingress 就绪"
    runme run install-tracing:wait-jaeger-ingress || {
        log_error "等待 Jaeger Ingress 就绪失败"
        return 1
    }

    # 步骤 15: 打印 Jaeger UI URL
    log_info "步骤 15: 打印 Jaeger UI URL"
    runme run install-tracing:print-jaeger-url || {
        log_error "打印 Jaeger UI URL 失败"
        return 1
    }

    # 步骤 16: 生成 otel-collector.yaml 到 /tmp
    log_info "步骤 16: 生成 /tmp/otel-collector.yaml"
    runme print install-tracing:otel-collector-yaml > /tmp/otel-collector.yaml || {
        log_error "生成 otel-collector.yaml 失败"
        return 1
    }

    # 步骤 16.1: envsubst 渲染并 apply（需在 /tmp 目录下执行）
    log_info "步骤 16.1: 渲染并应用 otel-collector.yaml"
    kubectl_apply_runme_block "install-tracing:apply-otel-collector" "/tmp/" || {
        log_error "应用 otel-collector.yaml 失败"
        return 1
    }

    # 步骤 16.2: 等待 otel OpenTelemetryCollector 状态副本数收敛
    log_info "步骤 16.2: 等待 otel OpenTelemetryCollector status.scale.statusReplicas=1/1"
    kubectl wait "opentelemetrycollector/otel" \
        -n "${JAEGER_NS}" \
        --for=jsonpath='{.status.scale.statusReplicas}'=1/1 \
        --timeout=180s || {
        log_error "等待 otel OpenTelemetryCollector status.scale.statusReplicas=1/1 失败"
        return 1
    }

    # 步骤 17: 等待 otel collector deployment 就绪
    log_info "步骤 17: 等待 OpenTelemetry Collector 就绪"
    runme run install-tracing:wait-otel-collector-rollout || {
        log_error "等待 OpenTelemetry Collector 就绪失败"
        return 1
    }

    # 步骤 18: 部署 telemetrygen 生成测试 trace（内含 wait/delete）
    log_info "步骤 18: 部署 telemetrygen 生成测试 trace"
    _deploy_telemetrygen "${TRACING_TELEMETRYGEN_TEST_DURATION_1:-30s}" || {
        log_error "telemetrygen 端到端验证失败"
        return 1
    }

    # 步骤 19-26:（可选）Service Performance Monitoring (SPM) 章节
    # SPM 需 ACP monitoring，默认跳过；设置 TRACING_TEST_SPM=true 启用。
    if [ "${TRACING_TEST_SPM:-true}" = "true" ]; then
        _test_spm || return 1
    else
        log_warn "跳过 SPM 章节测试（未设置 TRACING_TEST_SPM=true）"
    fi

    log_success "=========================================="
    log_success "Alauda Distributed Tracing 安装测试完成，所有验证通过！"
    log_success "=========================================="
    return 0
}
