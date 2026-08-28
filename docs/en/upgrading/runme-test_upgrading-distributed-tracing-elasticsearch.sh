#!/usr/bin/env bash
# Alauda Distributed Tracing v2.0 → v2.1 升级文档测试脚本（Elasticsearch 后端）
# 对应文档: docs/en/upgrading/upgrading-distributed-tracing-elasticsearch.mdx
# 覆盖范围: 「Installing the Alauda Build of Jaeger v2 Cluster Plugin」（仅 CLI 方案）、
#           「Upgrading the Alauda Build of OpenTelemetry v2 Operator」（仅 CLI 方案）、
#           「Updating the OpenTelemetry Collector」「Updating the Elasticsearch Index
#           Templates」「Updating the Alauda Build of Jaeger v2」「Verification」
#           及两段 (Optional) SPM 章节；各章节的 web console 方案为 UI 操作不可自动化。
# 前置条件: 环境上存在一套 **v2.0**（Jaeger 2.16.0 + Operator 0.147.0）的 Elasticsearch
#           部署。不满足时门槛检测以 SKIPPED 退出，不判红（见 _upgrade_precheck）。
# 公共逻辑: 与 OpenSearch 篇共享的 16 个代码块集中在同目录 _upgrade-common.sh。

set -e

: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"

# 加载框架函数库
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
# 加载两篇升级文档的公共逻辑（与 opensearch 版共用）
source "$(dirname "${BASH_SOURCE[0]}")/_upgrade-common.sh"

RUNME_PREFIX="upgrade-tracing-elasticsearch"
RUNME_PREFIX_SPM="upgrade-tracing-elasticsearch-spm"

# 文档「Updating the Elasticsearch Index Templates」：用新版 jaeger-es-rollover 镜像
# 重跑 init（幂等：模板 PUT 覆盖、索引与别名存在即跳过），再确认 span 索引模板已带
# v2.20.0 新增的 scopeTags 字段。
#
# 前置清理是测试脚本补充的辅助逻辑：文档代码块最后会删掉 Job，但上一次异常中断会留下
# 已完成的 Job，此时 kubectl apply 会因 Job 的 spec 不可变而失败。
_upgrade_es_index_templates() {
    log_info "清理可能残留的 jaeger-es-rollover-init Job"
    kubectl delete job jaeger-es-rollover-init -n "${JAEGER_NS}" --ignore-not-found >/dev/null 2>&1 || true

    log_info "用新镜像重跑 rollover init (${RUNME_PREFIX}:rerun-rollover-init)"
    runme run "${RUNME_PREFIX}:rerun-rollover-init" || {
        log_error "重跑 jaeger-es-rollover init 失败"
        return 1
    }

    # 代码块内是 `curl ... | grep -o scopeTags`：模板未更新时 grep 无匹配返回 1，
    # 故这里的返回码本身就是断言，不需要额外比对（模式 A）。
    log_info "确认 span 索引模板已含 scopeTags (${RUNME_PREFIX}:verify-index-template)"
    local output
    output=$(runme run "${RUNME_PREFIX}:verify-index-template" 2>&1) || {
        log_error "span 索引模板中未找到 scopeTags，模板未按新版本更新"
        log_error "输出: $output"
        return 1
    }
    echo "$output"
    log_success "Elasticsearch 索引模板更新通过"
    return 0
}

# 文档「Updating the Alauda Build of Jaeger v2」：
#   1. 先单独换 oauth2-proxy sidecar 镜像（additionalContainers 是数组，merge patch
#      会整体替换，只能用 json patch 定点改）。此刻 Jaeger 仍是 2.16.0 + 旧配置，重启安全。
#   2. 再把镜像与配置**一次性** patch 下去——v2.20.0 拒绝 use_aliases / use_ilm，
#      分两步改会让新 Pod 起不来（文档开头的 warning）。
#
# NOTE: 这个先后顺序与 OpenSearch 篇**相反**，不要对齐。OpenSearch 篇的 oauth2 patch
#       必须排在配置 patch 之后，否则那次重启会让 v2.16 用默认的 create_mappings=true
#       覆盖掉 init 刚写好的索引模板。
_upgrade_es_jaeger() {
    log_info "更新 OAuth2 Proxy sidecar 镜像 (${RUNME_PREFIX}:patch-oauth2-proxy-image)"
    if ! retry_command "runme run ${RUNME_PREFIX}:patch-oauth2-proxy-image" \
            "$UPGRADE_PATCH_RETRIES" "$UPGRADE_PATCH_INTERVAL"; then
        log_error "更新 OAuth2 Proxy sidecar 镜像失败"
        return 1
    fi

    _upgrade_apply_patch "${RUNME_PREFIX}:jaeger-upgrade-patch-yaml" \
        "${RUNME_PREFIX}:apply-jaeger-patch" "jaeger-upgrade-patch.yaml" || return 1

    log_success "Alauda Build of Jaeger v2 升级通过"
    return 0
}

# 测试函数：分布式调用链 v2.0 → v2.1 升级（Elasticsearch）
test_upgrading_distributed_tracing_elasticsearch() {
    log_info "=========================================="
    log_info "开始 Alauda Distributed Tracing 升级测试 (Elasticsearch)"
    log_info "=========================================="

    # 步骤 0: 门槛——必须是一套 Elasticsearch 后端的 v2.0 部署
    # rc=2 表示门槛未过、_upgrade_precheck 已记 SKIPPED，这里正常返回不判红。
    # 不写成 `[ ... ] && return 0`——条件为假时整条语句返回 1，会被 set -e 直接中断。
    local rc=0
    _upgrade_precheck elasticsearch || rc=$?
    if [ "$rc" = "2" ]; then
        return 0
    fi
    if [ "$rc" != "0" ]; then
        return 1
    fi

    # 步骤 1: 设置升级环境变量（ES 端点与索引前缀从运行中的实例反查）
    log_info "步骤 1: 设置升级环境变量"
    _upgrade_set_vars "$RUNME_PREFIX" ES_ENDPOINT JAEGER_ES_INDEX_PREFIX || return 1

    # 步骤 2: 安装 Alauda Build of Jaeger v2 集群插件（CLI 方式，经 Global 集群）
    log_info "步骤 2: 安装 Alauda Build of Jaeger v2 集群插件"
    _upgrade_install_plugin "$RUNME_PREFIX" || return 1

    # 步骤 3: 读取插件下发的镜像地址
    log_info "步骤 3: 读取插件下发的镜像地址"
    _upgrade_get_plugin_images "$RUNME_PREFIX" || return 1

    # 步骤 4: 升级 Alauda Build of OpenTelemetry v2 Operator
    log_info "步骤 4: 升级 OpenTelemetry v2 Operator"
    _upgrade_operator "$RUNME_PREFIX" || return 1

    # 步骤 5: 更新 OpenTelemetry Collector 配置（otlp → otlp_grpc 等）
    log_info "步骤 5: 更新 OpenTelemetry Collector 配置"
    _upgrade_otel_collector "$RUNME_PREFIX" || return 1

    # 步骤 6: (可选) SPM —— 前置 otel 的 loadbalancing 改名为 load_balancing
    if _upgrade_spm_enabled; then
        log_info "步骤 6: 更新 OpenTelemetry Collector 的 SPM 配置"
        _upgrade_otel_spm "$RUNME_PREFIX_SPM" || return 1
    fi

    # 步骤 7: 更新 Elasticsearch 索引模板
    log_info "步骤 7: 更新 Elasticsearch 索引模板"
    _upgrade_es_index_templates || return 1

    # 步骤 8: 更新 Alauda Build of Jaeger v2（oauth2 镜像 → 镜像+配置一次性 patch）
    log_info "步骤 8: 更新 Alauda Build of Jaeger v2"
    _upgrade_es_jaeger || return 1

    # 步骤 9: (可选) SPM —— Jaeger 的 spanmetrics connector 改名为 span_metrics
    if _upgrade_spm_enabled; then
        log_info "步骤 9: 更新 Jaeger 的 SPM 配置"
        _upgrade_jaeger_spm "$RUNME_PREFIX_SPM" || return 1
    fi

    # 步骤 10: 验证（组件版本 / Pod 状态 / Jaeger 启动无告警）
    log_info "步骤 10: 升级后验证"
    _upgrade_verify "$RUNME_PREFIX" || return 1

    log_success "=========================================="
    log_success "Alauda Distributed Tracing 升级测试 (Elasticsearch) 完成，所有验证通过！"
    log_success "=========================================="
    return 0
}
