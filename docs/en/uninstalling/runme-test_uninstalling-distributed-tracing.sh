#!/usr/bin/env bash
# Alauda Distributed Tracing 卸载文档测试脚本
# 对应文档: docs/en/uninstalling/uninstalling-distributed-tracing.mdx
# 覆盖范围: 「Uninstalling via the CLI」章节；「via the web console」为 UI 操作不可自动化。

set -e

: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"

# 加载框架函数库
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"

# 执行删除类 runme 块并校验输出（模式 B）
# 用法: _delete_and_verify <步骤描述> <runme-block>
# 期望输出取自配对的 <runme-block>-output 代码块。
_delete_and_verify() {
    local desc="$1" block="$2"
    local output expected
    output=$(runme run "$block" 2>&1) || {
        log_error "${desc}失败"
        log_error "输出: $output"
        return 1
    }
    expected=$(runme print "${block}-output")
    if ! __cmp_contains "$output" "$expected"; then
        log_error "${desc}输出校验失败"
        log_error "期待包含: $expected"
        log_error "实际输出: $output"
        return 1
    fi
    log_success "${desc}通过"
    return 0
}

# 测试函数：分布式调用链卸载
test_uninstalling_distributed_tracing() {
    log_info "=========================================="
    log_info "开始 Alauda Distributed Tracing 卸载测试"
    log_info "=========================================="

    # 步骤 0: 检查 ES 依赖（与安装测试保持一致；未设置则 SKIPPED）
    if [ -z "${TRACING_ES_ENDPOINT:-}" ]; then
        log_warn "SKIPPED: 未设置 TRACING_ES_ENDPOINT，跳过分布式调用链卸载测试"
        return 0
    fi

    # 步骤 1: 设置环境变量（JAEGER_NS / JAEGER_INSTANCE_NAME）
    log_info "步骤 1: 设置卸载环境变量"
    eval "$(runme print uninstall-tracing:set-env)" || {
        log_error "设置卸载环境变量失败"
        return 1
    }

    # 步骤 2: 删除 otel OpenTelemetryCollector 实例
    log_info "步骤 2: 删除 OpenTelemetry Collector 实例"
    _delete_and_verify "删除 OpenTelemetry Collector 实例" uninstall-tracing:delete-otel-collector || return 1

    # 步骤 3: 删除 jaeger OpenTelemetryCollector 实例
    log_info "步骤 3: 删除 Jaeger v2 实例"
    _delete_and_verify "删除 Jaeger v2 实例" uninstall-tracing:delete-jaeger-collector || return 1

    # 步骤 4: 删除 Jaeger 命名空间
    log_info "步骤 4: 删除 Jaeger 命名空间"
    _delete_and_verify "删除 Jaeger 命名空间" uninstall-tracing:delete-jaeger-ns || return 1

    # 步骤 5: (可选) 删除 OTel Operator subscription
    # 受 --skip-operator-and-crds 控制：传入时保留 Operator 以便后续测试复用。
    if [ "${SKIP_OPERATOR_AND_CRDS:-false}" = "true" ]; then
        log_info "步骤 5: 跳过删除 OTel Operator subscription (--skip-operator-and-crds)"
    else
        log_info "步骤 5: 删除 OTel Operator subscription"
        _delete_and_verify "删除 OTel Operator subscription" uninstall-tracing:delete-otel-subscription || return 1
    fi

    log_success "=========================================="
    log_success "Alauda Distributed Tracing 卸载测试完成，所有验证通过！"
    log_success "=========================================="
    return 0
}
