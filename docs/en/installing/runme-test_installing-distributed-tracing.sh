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

# 测试函数：分布式调用链安装
test_installing_distributed_tracing() {
    log_info "=========================================="
    log_info "开始 Alauda Distributed Tracing 安装测试"
    log_info "=========================================="

    # 步骤 0: 检查 Elasticsearch 依赖（外部强依赖，缺失则 SKIPPED）
    if [ -z "${TRACING_ES_ENDPOINT:-}" ] || [ -z "${TRACING_ES_USER:-}" ] || [ -z "${TRACING_ES_PASS:-}" ]; then
        log_warn "SKIPPED: 未设置 TRACING_ES_ENDPOINT / TRACING_ES_USER / TRACING_ES_PASS，跳过分布式调用链安装测试"
        return 0
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

    # 步骤 16: 创建 otel OpenTelemetryCollector
    log_info "步骤 16: 创建 OpenTelemetry Collector"
    runme run install-tracing:create-otel-collector || {
        log_error "创建 OpenTelemetry Collector 失败"
        return 1
    }

    # 步骤 17: 等待 otel collector deployment 就绪
    log_info "步骤 17: 等待 OpenTelemetry Collector 就绪"
    runme run install-tracing:wait-otel-rollout || {
        log_error "等待 OpenTelemetry Collector 就绪失败"
        return 1
    }

    # 步骤 18: 部署 telemetrygen 生成测试 trace（内含 wait/delete，约 150s）
    log_info "步骤 18: 部署 telemetrygen 生成测试 trace"
    runme run install-tracing:deploy-telemetrygen || {
        log_error "telemetrygen 端到端验证失败"
        return 1
    }

    log_success "=========================================="
    log_success "Alauda Distributed Tracing 安装测试完成，所有验证通过！"
    log_success "=========================================="
    return 0
}
