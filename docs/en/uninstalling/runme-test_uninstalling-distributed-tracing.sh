#!/usr/bin/env bash
# Alauda Distributed Tracing 卸载文档测试脚本
# 对应文档: docs/en/uninstalling/uninstalling-distributed-tracing.mdx
# 覆盖范围: 「Uninstalling via the CLI」章节（含「(Optional) Uninstall the Alauda Build of
#           Jaeger v2 Cluster Plugin」）；「via the web console」为 UI 操作不可自动化。

set -e

: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"

# 加载框架函数库
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"

# 在 opentelemetry-docs 仓库内执行命令的小封装（删除 CRDs 为跨仓库操作，
# uninstall-otel:* 代码块位于 opentelemetry-docs）。$OTEL_REPO_ROOT 由 run.sh 引擎注入。
_in_otel_repo() {
    pushd "$OTEL_REPO_ROOT" >/dev/null
    "$@"
    local rc=$?
    popd >/dev/null
    return $rc
}

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

# 卸载 Jaeger v2 集群插件的 Global 集群侧步骤（文档代码块 1-2）。
# 集群插件的 ModuleInfo 只存在于 Global 集群，故函数内 local export KUBECONFIG 指向
# Global，返回后自动还原调用方 KUBECONFIG（指向被测业务集群）。
# 用法: _uninstall_jaeger_plugin_via_global <target_cluster> <global_kubeconfig>
_uninstall_jaeger_plugin_via_global() {
    local target_cluster="$1" global_kc="$2"

    local KUBECONFIG="$global_kc"
    export KUBECONFIG

    # 文档代码块 1: 列出集群插件的 ModuleInfo（CLUSTER 列标明各条目的目标集群）
    log_info "列出 Jaeger v2 集群插件 (uninstall-tracing:list-jaeger-plugin-moduleinfo)"
    local list_output
    list_output=$(runme run uninstall-tracing:list-jaeger-plugin-moduleinfo 2>&1) || {
        log_error "列出集群插件 ModuleInfo 失败"
        log_error "输出: $list_output"
        return 1
    }
    echo "$list_output"

    # 从输出中取目标集群那一行的 ModuleInfo 名字（列序: NAME CLUSTER MODULE ...）。
    # 平台会把 ModuleInfo 重命名为 <cluster>-<hash>，名字只能从这里解析，不能拼。
    local moduleinfo_name
    moduleinfo_name=$(echo "$list_output" | awk -v c="$target_cluster" 'NR>1 && $2==c {print $1; exit}')
    if [ -z "$moduleinfo_name" ]; then
        log_error "未在 Global 集群找到目标集群 ${target_cluster} 的 jaeger-cluster-plugin ModuleInfo"
        return 1
    fi
    log_info "目标 ModuleInfo: ${moduleinfo_name}"

    # 文档代码块 2: 替换 <target-cluster> 占位符后按 label 删除（模式 H）
    log_info "删除集群插件 ModuleInfo (uninstall-tracing:delete-jaeger-plugin-moduleinfo)"
    local delete_cmd delete_output expected
    delete_cmd=$(runme print uninstall-tracing:delete-jaeger-plugin-moduleinfo) || {
        log_error "获取 ModuleInfo 删除代码块失败"
        return 1
    }
    delete_cmd="${delete_cmd//<target-cluster>/$target_cluster}"
    delete_output=$(eval "$delete_cmd" 2>&1) || {
        log_error "删除集群插件 ModuleInfo 失败"
        log_error "输出: $delete_output"
        return 1
    }
    # 期望输出中的 <moduleinfo-name> 同步替换为实际名字
    expected=$(runme print uninstall-tracing:delete-jaeger-plugin-moduleinfo-output)
    expected="${expected//<moduleinfo-name>/$moduleinfo_name}"
    if ! __cmp_contains "$delete_output" "$expected"; then
        log_error "删除集群插件 ModuleInfo 输出校验失败"
        log_error "期待包含: $expected"
        log_error "实际输出: $delete_output"
        return 1
    fi
    log_success "集群插件 ModuleInfo 删除通过"
    return 0
}

# 测试函数：分布式调用链卸载
test_uninstalling_distributed_tracing() {
    log_info "=========================================="
    log_info "开始 Alauda Distributed Tracing 卸载测试"
    log_info "=========================================="

    # 步骤 1: 设置环境变量（JAEGER_NS / JAEGER_INSTANCE_NAME）
    log_info "步骤 1: 设置卸载环境变量"
    eval "$(runme print uninstall-tracing:set-env)" || {
        log_error "设置卸载环境变量失败"
        return 1
    }

    # 门槛: 卸载存储无关，按集群状态判定是否装过——Jaeger 命名空间不存在则 SKIPPED。
    # ES 配置加载已下沉到 Elasticsearch 安装测试，卸载子进程不再自动注入 TRACING_ES_ENDPOINT，
    # 故改用命名空间存在性作为门槛，对 Elasticsearch / OpenSearch 两条链通用。
    if ! kubectl get namespace "${JAEGER_NS}" &>/dev/null; then
        skip_test_env "命名空间 ${JAEGER_NS} 不存在，未检测到分布式调用链部署，跳过卸载测试"
        return 0
    fi

    # 步骤 2: 删除 otel OpenTelemetryCollector 实例
    log_info "步骤 2: 删除 OpenTelemetry Collector 实例"
    _delete_and_verify "删除 OpenTelemetry Collector 实例" uninstall-tracing:delete-otel-collector || return 1

    # 步骤 3: 删除 jaeger OpenTelemetryCollector 实例
    log_info "步骤 3: 删除 Jaeger v2 实例"
    _delete_and_verify "删除 Jaeger v2 实例" uninstall-tracing:delete-jaeger-collector || return 1

    # 步骤 4: 删除 Jaeger 命名空间
    log_info "步骤 4: 删除 Jaeger 命名空间"
    _delete_and_verify "删除 Jaeger 命名空间" uninstall-tracing:delete-jaeger-ns || return 1

    # 步骤 5-6: (可选) 删除 OTel Operator subscription 与 OpenTelemetry CRDs
    # 受 --skip-operator-and-crds 控制：传入时保留 Operator 与 CRDs 以便后续测试复用。
    if [ "${SKIP_OPERATOR_AND_CRDS:-false}" = "true" ]; then
        log_info "步骤 5-6: 跳过删除 OTel Operator subscription 与 CRDs (--skip-operator-and-crds)"
    else
        log_info "步骤 5: 删除 OTel Operator subscription"
        _delete_and_verify "删除 OTel Operator subscription" uninstall-tracing:delete-otel-subscription || return 1

        # 步骤 6: 删除 OpenTelemetry CRDs（跨仓库：opentelemetry-docs 的 uninstall-otel:delete-crds）
        log_info "步骤 6: 删除 OpenTelemetry CRDs"
        if [ -z "${OTEL_REPO_ROOT:-}" ]; then
            log_error "OTEL_REPO_ROOT 未注入，无法定位 opentelemetry-docs 删除 CRDs"
            return 1
        fi
        _in_otel_repo runme run uninstall-otel:delete-crds || {
            log_error "删除 OpenTelemetry CRDs 失败"
            return 1
        }
    fi

    # 步骤 7: (可选) 卸载 Alauda Build of Jaeger v2 集群插件
    # 受 --skip-cluster-plugin 控制：传入时保留插件与镜像清单 ConfigMap 供后续测试复用。
    if [ "${SKIP_CLUSTER_PLUGIN:-false}" = "true" ]; then
        log_info "步骤 7: 跳过卸载 Jaeger v2 集群插件 (--skip-cluster-plugin)"
    else
        log_info "步骤 7: 卸载 Jaeger v2 集群插件"
        local target_cluster="${SINGLE_CLUSTER_NAME:-}"
        if [ -z "$target_cluster" ]; then
            log_error "SINGLE_CLUSTER_NAME 未设置，无法确定集群插件的目标集群"
            return 1
        fi
        local global_cluster="${GLOBAL_CLUSTER_NAME:-global}"
        local global_kc="$KUBECONFIG_DIR/${global_cluster}.yaml"
        if [ ! -f "$global_kc" ]; then
            log_error "未找到 Global kubeconfig: $global_kc"
            log_error "请先执行 './run.sh --project tracing --init-only' 让框架拉取 ${global_cluster} 集群 kubeconfig"
            return 1
        fi

        # Global 集群侧：文档代码块 1-2（查 ModuleInfo、按 label 删除）
        _uninstall_jaeger_plugin_via_global "$target_cluster" "$global_kc" || return 1

        # 目标集群侧：文档代码块 3 —— 确认插件创建的镜像清单 ConfigMap 已回收。
        # 插件卸载由平台异步收敛（实测 ModuleInfo 删除返回时 ConfigMap 已消失），
        # 这里仍留重试余量。ConfigMap 已删时该命令返回码为 1，故用 || true 承接。
        # 注：不用 retry_command —— 期望输出自带双引号，拼进 eval 字符串会被截断。
        log_info "验证镜像清单 ConfigMap 已删除 (uninstall-tracing:verify-jaeger-plugin-configmap-deleted)"
        local cm_expected cm_output cm_ok=false i
        cm_expected=$(runme print uninstall-tracing:verify-jaeger-plugin-configmap-deleted-output)
        for i in 1 2 3 4 5 6; do
            cm_output=$(runme run uninstall-tracing:verify-jaeger-plugin-configmap-deleted 2>&1 || true)
            if __cmp_contains "$cm_output" "$cm_expected"; then
                cm_ok=true
                break
            fi
            log_warn "ConfigMap 仍存在，等待插件卸载收敛 (${i}/6)"
            sleep 10
        done
        if [ "$cm_ok" != "true" ]; then
            log_error "镜像清单 ConfigMap 未在预期时间内删除"
            log_error "期待包含: $cm_expected"
            log_error "实际输出: $cm_output"
            return 1
        fi
        log_success "镜像清单 ConfigMap 已删除，集群插件卸载通过"
    fi

    log_success "=========================================="
    log_success "Alauda Distributed Tracing 卸载测试完成，所有验证通过！"
    log_success "=========================================="
    return 0
}
