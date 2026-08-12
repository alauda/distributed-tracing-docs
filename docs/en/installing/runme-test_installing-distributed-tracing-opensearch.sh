#!/usr/bin/env bash
# Alauda Distributed Tracing 安装文档测试脚本（OpenSearch 后端）
# 对应文档: docs/en/installing/installing-distributed-tracing-opensearch.mdx
# 覆盖范围: 「Installing the Alauda Build of Jaeger v2 Cluster Plugin」（仅 CLI 安装方案）、
#           「Deploying the Alauda Build of Jaeger v2」（含 jaeger-es-index-cleaner）、
#           「Deploying the OpenTelemetry Collector」「Verification」「(Optional) SPM」章节。
#
# 与 Elasticsearch 版的差异：
#   - OpenSearch 无 ACP 自动获取（不引入 _tracing_load_acp_es_config）。默认自动安装：
#     TRACING_INSTALL_OPENSEARCH=true（默认）且 PKG_ACP_STORAGE_OPERATOR_URL /
#     PKG_TOPOLVM_OPERATOR_URL 齐全时，步骤 0 自动安装 TopoLVM + OpenSearch 并用实际
#     安装结果覆盖 TRACING_OPENSEARCH_*（见 projects/tracing/opensearch.sh）；
#     不满足时降级用手动 TRACING_OPENSEARCH_ENDPOINT/USER/PASS，两者皆缺则 SKIPPED。
#   - 无 ILM Policy / rollover-init 步骤；改用 jaeger-es-index-cleaner 按日索引清理。

set -e

: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"

# 加载框架函数库
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
# tracing 项目钩子：提供 telemetrygen 镜像解析公共函数 tracing_telemetrygen_image，
# 以及 Jaeger v2 集群插件共享安装函数 tracing_install_jaeger_plugin（均与 ES 版共用）。
# run.sh 引擎对 --project tracing 已自动 source 本文件，这里显式声明依赖、便于独立运行与阅读。
source "$FRAMEWORK_ROOT/projects/tracing/project.sh"

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
#     第二次由 TRACING_TELEMETRYGEN_TEST_DURATION_2 控制（默认 130s），覆盖文档默认的 150s
#   - 镜像：由 tracing_telemetrygen_image（projects/tracing/project.sh）解析有效镜像，
#     USE_MESH_V2_TEST_SUITE_PLUGIN=true 时改写到 mesh-v2-test-suite 集群插件镜像仓库
_deploy_telemetrygen() {
    local duration="$1"
    local content
    content=$(runme print install-tracing-opensearch:deploy-telemetrygen 2>/dev/null)
    if [ -z "$content" ]; then
        log_error "无法获取代码块内容: install-tracing-opensearch:deploy-telemetrygen"
        return 1
    fi

    # 改写测试时长（文档默认 150s）
    log_info "telemetrygen 测试时长: $duration"
    content="${content//--duration=150s/--duration=$duration}"

    # 改写镜像：启用 mesh-v2-test-suite 集群插件时改用其内网镜像仓库
    # （镜像解析见 projects/tracing/project.sh:tracing_telemetrygen_image，三脚本共用）
    local image
    image=$(tracing_telemetrygen_image) || return 1
    content="${content//$TRACING_TELEMETRYGEN_DEFAULT_IMAGE/$image}"

    eval "$content"
}

# SPM (Service Performance Monitoring) 章节测试，覆盖 install-tracing-opensearch-spm:* 代码块。
# 由 test_installing_distributed_tracing_opensearch 在 TRACING_TEST_SPM=true 时调用。
_test_spm() {
    log_header "Service Performance Monitoring (SPM) 测试"

    # 步骤 20: 拉取 monitoring 端点与凭据
    log_info "步骤 20: 拉取 monitoring 配置"
    eval "$(runme print install-tracing-opensearch-spm:get-monitoring-config)" || {
        log_error "拉取 monitoring 配置失败"
        return 1
    }

    # 步骤 21: 创建 monitoring 凭据 Secret
    log_info "步骤 21: 创建 monitoring 凭据 Secret"
    runme run install-tracing-opensearch-spm:create-monitoring-secret || {
        log_error "创建 monitoring 凭据 Secret 失败"
        return 1
    }

    # 步骤 22: Patch OpenTelemetry Collector 改用 load_balancing 按 service 路由到 Jaeger（spanmetrics 已移至 Jaeger）
    log_info "步骤 22: Patch OpenTelemetry Collector 配置 load_balancing 按 service 路由"
    runme run install-tracing-opensearch-spm:patch-otel-collector || {
        log_error "Patch OpenTelemetry Collector 失败"
        return 1
    }

    # 步骤 23: 等待 OpenTelemetry Collector 重启就绪
    log_info "步骤 23: 等待 OpenTelemetry Collector 重启就绪"
    runme run install-tracing-opensearch-spm:wait-otel-collector-rollout || {
        log_error "等待 OpenTelemetry Collector 重启失败"
        return 1
    }

    # 步骤 24: 生成 jaeger-spm-patch.yaml 到 /tmp
    log_info "步骤 24: 生成 /tmp/jaeger-spm-patch.yaml"
    runme print install-tracing-opensearch-spm:jaeger-spm-patch-yaml > /tmp/jaeger-spm-patch.yaml || {
        log_error "生成 jaeger-spm-patch.yaml 失败"
        return 1
    }

    # 步骤 25: 应用 SPM patch（需在 /tmp 目录下执行）
    log_info "步骤 25: 应用 jaeger-spm-patch.yaml"
    kubectl_apply_runme_block "install-tracing-opensearch-spm:apply-jaeger-patch" "/tmp/" || {
        log_error "应用 jaeger-spm-patch.yaml 失败"
        return 1
    }

    # 步骤 26: 等待 Jaeger 重启就绪
    log_info "步骤 26: 等待 Jaeger 重启就绪"
    runme run install-tracing-opensearch-spm:wait-jaeger-rollout || {
        log_error "等待 Jaeger 重启失败"
        return 1
    }

    # 步骤 27: 重新部署 telemetrygen 验证 SPM 指标（文档 Verification 要求）
    # --skip-telemetrygen 时跳过：SPM 配置路径已由步骤 20-26 覆盖。
    if [ "${SKIP_TELEMETRYGEN:-false}" = "true" ]; then
        log_warn "SKIP_TELEMETRYGEN=true，跳过步骤 27 SPM telemetrygen 验证"
    else
        log_info "步骤 27: 重新部署 telemetrygen 验证 SPM"
        _deploy_telemetrygen "${TRACING_TELEMETRYGEN_TEST_DURATION_2:-130s}" || {
            log_error "SPM telemetrygen 验证失败"
            return 1
        }
    fi

    # 输出 Jaeger UI 访问地址
    log_info "Jaeger UI 访问地址: ${PLATFORM_URL}${JAEGER_BASEPATH}"

    log_success "SPM 测试完成"
    return 0
}

# 测试函数：分布式调用链安装（OpenSearch）
test_installing_distributed_tracing_opensearch() {
    log_info "=========================================="
    log_info "开始 Alauda Distributed Tracing 安装测试 (OpenSearch)"
    log_info "=========================================="

    # 步骤 0: OpenSearch 存储后端准备
    # 优先自动安装（前置步骤）：TRACING_INSTALL_OPENSEARCH=true（默认）且 TopoLVM 插件包
    # 地址齐全时，自动安装 TopoLVM + OpenSearch，并用实际安装结果覆盖 TRACING_OPENSEARCH_*；
    # 否则降级用手动 TRACING_OPENSEARCH_*；两者皆不可用则跳过（与旧行为一致）。
    if tracing_opensearch_auto_install_enabled; then
        log_info "步骤 0: 自动安装 OpenSearch 存储后端（TRACING_INSTALL_OPENSEARCH=${TRACING_INSTALL_OPENSEARCH}）"
        tracing_ensure_opensearch || {
            log_error "OpenSearch 存储后端自动安装失败"
            return 1
        }
    elif [ -n "${TRACING_OPENSEARCH_ENDPOINT:-}" ] && [ -n "${TRACING_OPENSEARCH_USER:-}" ] && [ -n "${TRACING_OPENSEARCH_PASS:-}" ]; then
        if [ "${TRACING_INSTALL_OPENSEARCH:-true}" = "true" ]; then
            log_warn "TRACING_INSTALL_OPENSEARCH=true 但未设置 PKG_ACP_STORAGE_OPERATOR_URL / PKG_TOPOLVM_OPERATOR_URL，降级使用手动 OpenSearch 配置"
        fi
        log_info "步骤 0: 使用手动 OpenSearch 配置: endpoint=${TRACING_OPENSEARCH_ENDPOINT}"
    else
        skip_test "OpenSearch 存储后端不可用：自动安装未启用（TRACING_INSTALL_OPENSEARCH=true 且 PKG_ACP_STORAGE_OPERATOR_URL / PKG_TOPOLVM_OPERATOR_URL 齐全才生效），且未设置手动 TRACING_OPENSEARCH_ENDPOINT / USER / PASS，跳过 OpenSearch 调用链安装测试"
        return 0
    fi

    # 步骤 1: 安装 Alauda Build of Jaeger v2 集群插件（文档「Installing the Alauda Build
    # of Jaeger v2 Cluster Plugin > Installing via the CLI」章节。两篇安装文档的该章节
    # 内容一致，安装逻辑抽象为共享函数、按 runme 前缀参数化，见
    # docs-runme-tests/projects/tracing/jaeger-plugin.sh；后续 get-platform-config
    # 从插件创建的 ConfigMap 读取 Jaeger 相关镜像地址）
    log_info "步骤 1: 安装 Alauda Build of Jaeger v2 集群插件（CLI 方式）"
    tracing_install_jaeger_plugin "install-tracing-opensearch" || {
        log_error "Jaeger v2 集群插件安装失败"
        return 1
    }

    # 步骤 2: 安装 Alauda Build of OpenTelemetry v2 Operator（跨仓库前置依赖）
    log_info "步骤 2: 安装 OpenTelemetry v2 Operator"
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

    # 步骤 3: 注入 OpenSearch 连接环境变量（替代文档步骤 1 的占位符）
    log_info "步骤 3: 设置 OpenSearch 连接环境变量"
    export OPENSEARCH_ENDPOINT="$TRACING_OPENSEARCH_ENDPOINT"
    export OPENSEARCH_USER="$TRACING_OPENSEARCH_USER"
    export OPENSEARCH_PASS="$TRACING_OPENSEARCH_PASS"

    # 步骤 4: 拉取平台配置与 Jaeger 镜像
    log_info "步骤 4: 拉取平台配置"
    eval "$(runme print install-tracing-opensearch:get-platform-config)" || {
        log_error "拉取平台配置失败"
        return 1
    }

    # 步骤 5: 设置 Jaeger 默认环境变量
    log_info "步骤 5: 设置 Jaeger 默认环境变量"
    eval "$(runme print install-tracing-opensearch:set-jaeger-defaults)" || {
        log_error "设置 Jaeger 默认环境变量失败"
        return 1
    }

    # 步骤 6: 创建 Jaeger 命名空间与 OpenSearch 凭据 Secret
    log_info "步骤 6: 创建命名空间与 OpenSearch 凭据 Secret"
    runme run install-tracing-opensearch:create-jaeger-ns-and-opensearch-secret || {
        log_error "创建命名空间与 OpenSearch Secret 失败"
        return 1
    }

    # 步骤 6.1: 验证 OpenSearch Secret
    log_info "步骤 6.1: 验证 OpenSearch Secret"
    runme run install-tracing-opensearch:verify-opensearch-secret || {
        log_error "验证 OpenSearch Secret 失败"
        return 1
    }

    # 步骤 7: 创建 OAuth2 Proxy Secret
    log_info "步骤 7: 创建 OAuth2 Proxy Secret"
    runme run install-tracing-opensearch:create-oauth2-proxy-secret || {
        log_error "创建 OAuth2 Proxy Secret 失败"
        return 1
    }

    # 步骤 8: 生成 jaeger.yaml 到 /tmp（envsubst apply 依赖 cwd 中存在该文件）
    log_info "步骤 8: 生成 /tmp/jaeger.yaml"
    runme print install-tracing-opensearch:jaeger-yaml > /tmp/jaeger.yaml || {
        log_error "生成 jaeger.yaml 失败"
        return 1
    }

    # 步骤 9: envsubst 渲染并 apply（需在 /tmp 目录下执行）
    log_info "步骤 9: 渲染并应用 jaeger.yaml"
    kubectl_apply_runme_block "install-tracing-opensearch:apply-jaeger" "/tmp/" || {
        log_error "应用 jaeger.yaml 失败"
        return 1
    }

    # 步骤 9.1: 等待 OpenTelemetryCollector 状态副本数收敛
    log_info "步骤 9.1: 等待 OpenTelemetryCollector status.scale.statusReplicas=1/1"
    kubectl wait "opentelemetrycollector/${JAEGER_INSTANCE_NAME}" \
        -n "${JAEGER_NS}" \
        --for=jsonpath='{.status.scale.statusReplicas}'=1/1 \
        --timeout=180s || {
        log_error "等待 OpenTelemetryCollector status.scale.statusReplicas=1/1 失败"
        return 1
    }

    # 步骤 10: 等待 Jaeger collector deployment 就绪
    log_info "步骤 10: 等待 Jaeger collector 就绪"
    runme run install-tracing-opensearch:wait-jaeger-rollout || {
        log_error "等待 Jaeger collector 就绪失败"
        return 1
    }

    # 步骤 11: 设置 jaeger-es-index-cleaner 环境变量
    log_info "步骤 11: 设置 index-cleaner 环境变量"
    eval "$(runme print install-tracing-opensearch:set-index-cleaner-defaults)" || {
        log_error "设置 index-cleaner 环境变量失败"
        return 1
    }

    # 步骤 12: 生成 jaeger-index-cleaner.yaml 到 /tmp
    log_info "步骤 12: 生成 /tmp/jaeger-index-cleaner.yaml"
    runme print install-tracing-opensearch:index-cleaner-yaml > /tmp/jaeger-index-cleaner.yaml || {
        log_error "生成 jaeger-index-cleaner.yaml 失败"
        return 1
    }

    # 步骤 13: 渲染并部署 index-cleaner CronJob（需在 /tmp 目录下执行）
    log_info "步骤 13: 部署 jaeger-es-index-cleaner CronJob"
    kubectl_apply_runme_block "install-tracing-opensearch:apply-index-cleaner" "/tmp/" || {
        log_error "部署 jaeger-es-index-cleaner CronJob 失败"
        return 1
    }

    # 步骤 14: 给命名空间打 cpaas.io/project 标签
    log_info "步骤 14: 标记 Jaeger 命名空间"
    runme run install-tracing-opensearch:label-jaeger-ns || {
        log_error "标记命名空间失败"
        return 1
    }

    # 步骤 15: 创建 Jaeger Ingress
    log_info "步骤 15: 创建 Jaeger Ingress"
    runme run install-tracing-opensearch:create-jaeger-ingress || {
        log_error "创建 Jaeger Ingress 失败"
        return 1
    }

    # 步骤 15.1: 等待 Ingress LoadBalancer 就绪
    log_info "步骤 15.1: 等待 Jaeger Ingress 就绪"
    runme run install-tracing-opensearch:wait-jaeger-ingress || {
        log_error "等待 Jaeger Ingress 就绪失败"
        return 1
    }

    # 步骤 16: 打印 Jaeger UI URL
    log_info "步骤 16: 打印 Jaeger UI URL"
    runme run install-tracing-opensearch:print-jaeger-url || {
        log_error "打印 Jaeger UI URL 失败"
        return 1
    }

    # 步骤 17: 生成 otel-collector.yaml 到 /tmp
    log_info "步骤 17: 生成 /tmp/otel-collector.yaml"
    runme print install-tracing-opensearch:otel-collector-yaml > /tmp/otel-collector.yaml || {
        log_error "生成 otel-collector.yaml 失败"
        return 1
    }

    # 步骤 17.1: envsubst 渲染并 apply（需在 /tmp 目录下执行）
    log_info "步骤 17.1: 渲染并应用 otel-collector.yaml"
    kubectl_apply_runme_block "install-tracing-opensearch:apply-otel-collector" "/tmp/" || {
        log_error "应用 otel-collector.yaml 失败"
        return 1
    }

    # 步骤 17.2: 等待 otel OpenTelemetryCollector 状态副本数收敛
    log_info "步骤 17.2: 等待 otel OpenTelemetryCollector status.scale.statusReplicas=1/1"
    kubectl wait "opentelemetrycollector/otel" \
        -n "${JAEGER_NS}" \
        --for=jsonpath='{.status.scale.statusReplicas}'=1/1 \
        --timeout=180s || {
        log_error "等待 otel OpenTelemetryCollector status.scale.statusReplicas=1/1 失败"
        return 1
    }

    # 步骤 18: 等待 otel collector deployment 就绪
    log_info "步骤 18: 等待 OpenTelemetry Collector 就绪"
    runme run install-tracing-opensearch:wait-otel-collector-rollout || {
        log_error "等待 OpenTelemetry Collector 就绪失败"
        return 1
    }

    # 步骤 19: 部署 telemetrygen 生成测试 trace（内含 wait/delete）
    # --skip-telemetrygen 时跳过：用于 mesh 等仅需安装调用链组件、由
    # 业务流量产生 trace 而不依赖 telemetrygen 验证的编排场景。
    if [ "${SKIP_TELEMETRYGEN:-false}" = "true" ]; then
        log_warn "SKIP_TELEMETRYGEN=true，跳过步骤 19 telemetrygen 端到端验证"
    else
        log_info "步骤 19: 部署 telemetrygen 生成测试 trace"
        _deploy_telemetrygen "${TRACING_TELEMETRYGEN_TEST_DURATION_1:-30s}" || {
            log_error "telemetrygen 端到端验证失败"
            return 1
        }
    fi

    # 步骤 20-27:（可选）Service Performance Monitoring (SPM) 章节
    # SPM 需 ACP monitoring，默认跳过；设置 TRACING_TEST_SPM=true 启用。
    if [ "${TRACING_TEST_SPM:-true}" = "true" ]; then
        _test_spm || return 1
    else
        log_warn "跳过 SPM 章节测试（未设置 TRACING_TEST_SPM=true）"
    fi

    log_success "=========================================="
    log_success "Alauda Distributed Tracing 安装测试 (OpenSearch) 完成，所有验证通过！"
    log_success "=========================================="
    return 0
}
