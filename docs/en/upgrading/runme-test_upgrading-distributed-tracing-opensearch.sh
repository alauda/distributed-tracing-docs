#!/usr/bin/env bash
# Alauda Distributed Tracing v2.0 → v2.1 升级文档测试脚本（OpenSearch 后端）
# 对应文档: docs/en/upgrading/upgrading-distributed-tracing-opensearch.mdx
# 覆盖范围: 「Installing the Alauda Build of Jaeger v2 Cluster Plugin」（仅 CLI 方案）、
#           「Upgrading the Alauda Build of OpenTelemetry v2 Operator」（仅 CLI 方案）、
#           「Updating the OpenTelemetry Collector」「Migrating Index Management to ISM」
#           「Updating the Alauda Build of Jaeger v2」「Retiring the Index Cleaner」
#           「Verification」及两段 (Optional) SPM 章节；web console 方案为 UI 操作不可自动化。
# 前置条件: 环境上存在一套 **v2.0**（Jaeger 2.16.0 + Operator 0.147.0、按天日期索引）的
#           OpenSearch 部署。不满足时门槛检测以 SKIPPED 退出，不判红（见 _upgrade_precheck）。
# 公共逻辑: 与 Elasticsearch 篇共享的 16 个代码块集中在同目录 _upgrade-common.sh。

set -e

: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"

# 加载框架函数库
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
# tracing 项目钩子：提供 ISM 共享辅助函数 tracing_reset_ism_policy /
# tracing_verify_ism_attached（与 OpenSearch 安装测试共用），以及集群插件共享安装函数。
source "$FRAMEWORK_ROOT/projects/tracing/project.sh"
# 加载两篇升级文档的公共逻辑（与 elasticsearch 版共用）
source "$(dirname "${BASH_SOURCE[0]}")/_upgrade-common.sh"

RUNME_PREFIX="upgrade-tracing-opensearch"
RUNME_PREFIX_SPM="upgrade-tracing-opensearch-spm"

# 文档「Migrating Index Management to ISM」：建 ISM policy → 跑 jaeger-es-rollover init
# → 把历史日期索引挂进 read alias。
#
# 两处补充的辅助逻辑：
#   - policy 先删后建：文档写的是 policy 尚不存在的升级场景，对已存在的 policy 直接 PUT
#     会返回 409 version_conflict_engine_exception，重跑测试就过不去。
#   - init Job 先删残留：文档代码块最后会删掉 Job，但上一次异常中断会留下已完成的 Job，
#     此时 kubectl apply 会因 Job 的 spec 不可变而失败。
_upgrade_os_migrate_to_ism() {
    log_info "创建 ISM policy (${RUNME_PREFIX}:create-ism-policy)"
    tracing_reset_ism_policy
    runme run "${RUNME_PREFIX}:create-ism-policy" || {
        log_error "创建 ISM policy 失败"
        return 1
    }

    log_info "清理可能残留的 jaeger-es-rollover-init Job"
    kubectl delete job jaeger-es-rollover-init -n "${JAEGER_NS}" --ignore-not-found >/dev/null 2>&1 || true

    log_info "运行 jaeger-es-rollover init (${RUNME_PREFIX}:run-rollover-init)"
    runme run "${RUNME_PREFIX}:run-rollover-init" || {
        log_error "运行 jaeger-es-rollover init 失败"
        return 1
    }

    # 代码块内是四类索引各发一次 _aliases 请求，curl 不带 -f，
    # 因此 dependencies / sampling 常见的 404 index_not_found_exception 不会让返回码非 0
    # （纯采集场景下这两类从未产生过日期索引，文档已注明这是预期结果）。
    log_info "把历史日期索引挂进 read alias (${RUNME_PREFIX}:attach-existing-indices)"
    local output
    output=$(runme run "${RUNME_PREFIX}:attach-existing-indices" 2>&1) || {
        log_error "挂载历史日期索引失败"
        log_error "输出: $output"
        return 1
    }
    echo "$output"

    log_success "索引管理迁移到 ISM 通过"
    return 0
}

# 文档「Updating the Alauda Build of Jaeger v2」：
#   1. 先把镜像与配置一次性 patch 下去（含 create_mappings: false、
#      date_layout / rollover_frequency 置 null）。
#   2. 再单独换 oauth2-proxy sidecar 镜像。
#
# NOTE: 这个先后顺序与 Elasticsearch 篇**相反**，不要对齐。oauth2 patch 会触发一次重启，
#       若排在配置 patch 之前，那次重启时 create_mappings 仍是默认的 true，v2.16 启动时
#       会用同名模板覆盖掉上一步 init 写好的模板，把 read alias 与 ISM rollover_alias
#       一起抹掉；而且写入照常成功，只有第一次轮转时才暴露。
_upgrade_os_jaeger() {
    _upgrade_apply_patch "${RUNME_PREFIX}:jaeger-upgrade-patch-yaml" \
        "${RUNME_PREFIX}:apply-jaeger-patch" "jaeger-upgrade-patch.yaml" || return 1

    log_info "更新 OAuth2 Proxy sidecar 镜像 (${RUNME_PREFIX}:patch-oauth2-proxy-image)"
    if ! retry_command "runme run ${RUNME_PREFIX}:patch-oauth2-proxy-image" \
            "$UPGRADE_PATCH_RETRIES" "$UPGRADE_PATCH_INTERVAL"; then
        log_error "更新 OAuth2 Proxy sidecar 镜像失败"
        return 1
    fi

    log_success "Alauda Build of Jaeger v2 升级通过"
    return 0
}

# 文档「Retiring the Index Cleaner」：先看还剩哪些日期索引，再删掉 index-cleaner CronJob。
#
# NOTE: 文档的语义是「等日期索引清空后再删」，而刚升级完日期索引必然还在。测试环境按
#       文档的最终态执行，以覆盖 delete-index-cleaner 代码块；生产环境请按文档所述，
#       等历史日期索引过期后再删。
_upgrade_os_retire_index_cleaner() {
    log_info "查看剩余的日期索引 (${RUNME_PREFIX}:list-date-indices)"
    local output
    output=$(runme run "${RUNME_PREFIX}:list-date-indices" 2>&1) || {
        log_error "查询日期索引失败"
        log_error "输出: $output"
        return 1
    }
    echo "$output"

    log_info "删除 index-cleaner CronJob (${RUNME_PREFIX}:delete-index-cleaner)"
    local rc=0
    output=$(runme run "${RUNME_PREFIX}:delete-index-cleaner" 2>&1) || rc=$?
    echo "$output"
    if [ "$rc" != "0" ]; then
        # 重跑场景下 CronJob 已被上一次执行删掉，NotFound 不算失败
        case "$output" in
            *NotFound*) log_warn "index-cleaner CronJob 已不存在，跳过" ;;
            *)
                log_error "删除 index-cleaner CronJob 失败"
                return 1
                ;;
        esac
    fi

    log_success "index-cleaner 退役步骤通过"
    return 0
}

# 文档「Verification」的第 3-5 步（OpenSearch 篇独有）：
#   - verify-index-template：代码块内是 `curl ... | grep -o "rollover_alias\|<prefix>-read"`，
#     模板被覆盖时 grep 无匹配返回 1，返回码本身即断言。这是唯一能提前发现「模板被静默
#     覆盖」的守卫，写入与查询在第一次轮转前都表现正常。
#   - verify-write-target：只打印写索引 _count 与别名分布（模式 A）。
#   - verify-ism-attached：代码块只打印 explain 结果，断言由 tracing_verify_ism_attached
#     承担；ISM 靠后台 sweep 发现新索引，超时只告警不判红。
_upgrade_os_verify_storage() {
    log_info "确认索引模板仍带 read alias 与 rollover_alias (${RUNME_PREFIX}:verify-index-template)"
    local output
    output=$(runme run "${RUNME_PREFIX}:verify-index-template" 2>&1) || {
        log_error "span 索引模板中未找到 rollover_alias / read alias——模板已被 Jaeger 覆盖"
        log_error "输出: $output"
        return 1
    }
    echo "$output"
    log_success "索引模板守卫通过"

    log_info "确认写入落到编号索引 (${RUNME_PREFIX}:verify-write-target)"
    output=$(runme run "${RUNME_PREFIX}:verify-write-target" 2>&1) || {
        log_error "查询写索引与别名失败"
        log_error "输出: $output"
        return 1
    }
    echo "$output"

    log_info "确认 ISM 已接管编号索引 (${RUNME_PREFIX}:verify-ism-attached)"
    output=$(runme run "${RUNME_PREFIX}:verify-ism-attached" 2>&1) || {
        log_error "查询 ISM explain 失败"
        log_error "输出: $output"
        return 1
    }
    echo "$output"
    tracing_verify_ism_attached || return 1

    return 0
}

# 测试函数：分布式调用链 v2.0 → v2.1 升级（OpenSearch）
test_upgrading_distributed_tracing_opensearch() {
    log_info "=========================================="
    log_info "开始 Alauda Distributed Tracing 升级测试 (OpenSearch)"
    log_info "=========================================="

    # 步骤 0: 门槛——必须是一套 OpenSearch 后端的 v2.0 部署
    # rc=2 表示门槛未过、_upgrade_precheck 已记 SKIPPED，这里正常返回不判红。
    # 不写成 `[ ... ] && return 0`——条件为假时整条语句返回 1，会被 set -e 直接中断。
    local rc=0
    _upgrade_precheck opensearch || rc=$?
    if [ "$rc" = "2" ]; then
        return 0
    fi
    if [ "$rc" != "0" ]; then
        return 1
    fi

    # 步骤 1: 设置升级环境变量（端点、索引前缀与凭据均从运行中的部署反查）
    log_info "步骤 1: 设置升级环境变量"
    _upgrade_set_vars "$RUNME_PREFIX" \
        OPENSEARCH_ENDPOINT JAEGER_ES_INDEX_PREFIX OPENSEARCH_USER OPENSEARCH_PASS || return 1

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

    # 步骤 7: 迁移索引管理到 ISM（本篇独有）
    log_info "步骤 7: 迁移索引管理到 ISM"
    _upgrade_os_migrate_to_ism || return 1

    # 步骤 8: 更新 Alauda Build of Jaeger v2（镜像+配置一次性 patch → oauth2 镜像）
    log_info "步骤 8: 更新 Alauda Build of Jaeger v2"
    _upgrade_os_jaeger || return 1

    # 步骤 9: (可选) SPM —— Jaeger 的 spanmetrics connector 改名为 span_metrics
    if _upgrade_spm_enabled; then
        log_info "步骤 9: 更新 Jaeger 的 SPM 配置"
        _upgrade_jaeger_spm "$RUNME_PREFIX_SPM" || return 1
    fi

    # 步骤 10: index-cleaner 退役
    log_info "步骤 10: index-cleaner 退役"
    _upgrade_os_retire_index_cleaner || return 1

    # 步骤 11: 验证（组件版本 / Pod 状态 / Jaeger 启动无告警）
    log_info "步骤 11: 升级后验证（组件状态）"
    _upgrade_verify "$RUNME_PREFIX" || return 1

    # 步骤 12: 验证（索引模板守卫 / 写入目标 / ISM 接管）
    log_info "步骤 12: 升级后验证（存储侧）"
    _upgrade_os_verify_storage || return 1

    log_success "=========================================="
    log_success "Alauda Distributed Tracing 升级测试 (OpenSearch) 完成，所有验证通过！"
    log_success "=========================================="
    return 0
}
