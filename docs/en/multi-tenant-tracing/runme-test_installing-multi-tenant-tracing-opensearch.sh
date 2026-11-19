#!/usr/bin/env bash
# 多租户调用链安装文档测试脚本（OpenSearch 后端）
# 对应文档: docs/en/multi-tenant-tracing/installing-multi-tenant-tracing-opensearch.mdx
# 覆盖范围: 集群插件（CLI）、OTel Operator RBAC 授权、带网关的 Jaeger、平台 Collector、
#           租户隔离验证（文档注释块：ServiceAccount token 替代测试用户）、(Optional) SPM、
#           Uninstalling 的第 2、3 步（第 1 步委托卸载文档，由编排脚本调用）。
#
# 可选环境变量:
#   TRACING_JAEGER_ES_INDEX_PREFIX  覆盖文档默认索引前缀 acp-${CLUSTER_NAME}
#   TRACING_JAEGER_ISM_POLICY       覆盖文档默认 ISM 策略名 jaeger-ism-policy
#                                   （多个集群共用一个 OpenSearch 时必须区分，否则互相覆盖）
#   TRACING_MT_TEST_NS_A / _B       租户隔离验证的两个命名空间，默认 mt-tracing-a / mt-tracing-b。
#                                   须为不存在的命名空间：脚本只复用带本测试标签的残留，
#                                   cleanup 只删除这两个且带标签的命名空间
#   TRACING_TEST_SPM                是否测试 SPM 章节，默认 true

set -e

: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"

source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
# tracing 项目钩子：tracing_install_jaeger_plugin、tracing_telemetrygen_image、
# tracing_reset_ism_policy、tracing_verify_ism_attached 等
source "$FRAMEWORK_ROOT/projects/tracing/project.sh"

MT_PREFIX="install-mt-tracing-opensearch"
MT_SPM_PREFIX="install-mt-tracing-opensearch-spm"
# envsubst 渲染的文件放在独立目录，不与其他测试的 /tmp/jaeger.yaml 混用
MT_WORK_DIR="${TMPDIR:-/tmp}/mt-tracing-opensearch"
# 脚本自建的测试命名空间带此标签，cleanup 按标签删除
MT_TEST_NS_LABEL="docs-runme-tests/mt-tracing=true"
OTEL_OPERATOR_NS="opentelemetry-operator2"

_in_otel_repo() {
    pushd "$OTEL_REPO_ROOT" >/dev/null
    "$@"
    local rc=$?
    popd >/dev/null
    return $rc
}

# 严格执行多命令代码块：首条失败即中断（runme run 只回传最后一条命令的返回码）
# 用法: _mt_run_strict <block> [目录]
_mt_run_strict() {
    local block="$1" dir="${2:-.}" content
    content=$(runme print "$block") || {
        log_error "无法获取代码块内容: $block"
        return 1
    }
    (cd "$dir" && bash -ec "$content")
}

# 执行代码块并按 __cmp_lines 规则校验输出
# 用法: _mt_run_and_check <block> <期望规则>
_mt_run_and_check() {
    local block="$1" rules="$2" output
    output=$(_mt_run_strict "$block" 2>&1) || {
        log_error "执行 ${block} 失败"
        log_error "输出: $output"
        return 1
    }
    echo "$output"
    if ! __cmp_lines "$output" "$rules"; then
        log_error "${block} 输出校验失败"
        log_error "期望: $rules"
        return 1
    fi
    log_success "${block} 输出校验通过"
}

# 等待 OpenTelemetryCollector 的 Deployment 生成并完成滚动
# 用法: _mt_wait_collector <CR 名> <rollout 代码块>
_mt_wait_collector() {
    local name="$1" block="$2"
    kubectl wait "opentelemetrycollector/${name}" -n "${JAEGER_NS}" \
        --for=jsonpath='{.status.scale.statusReplicas}'=1/1 --timeout=300s || {
        log_error "等待 OpenTelemetryCollector ${name} 就绪失败"
        return 1
    }
    # 文档 note：Deployment 尚未创建时 rollout status 报 not found，再执行一次即可
    retry_command "runme run ${block}" 6 10 || {
        log_error "等待 ${name} Deployment 滚动完成失败"
        return 1
    }
}

# 部署 telemetrygen：镜像按 tracing_telemetrygen_image 改写
# （USE_MESH_V2_TEST_SUITE_PLUGIN=true 时取 mesh-v2-test-suite 插件内的镜像）
_mt_deploy_telemetrygen() {
    local content image
    content=$(runme print "${MT_PREFIX}:deploy-telemetrygen") || return 1
    image=$(tracing_telemetrygen_image) || return 1
    content="${content//$TRACING_TELEMETRYGEN_DEFAULT_IMAGE/$image}"
    bash -ec "$content"
}

# 加载平台配置与 Jaeger 默认变量（测试与 cleanup 共用）
_mt_load_env() {
    eval "$(runme print "${MT_PREFIX}:get-platform-config")" || {
        log_error "拉取平台配置失败"
        return 1
    }
    eval "$(runme print "${MT_PREFIX}:set-jaeger-defaults")" || {
        log_error "设置 Jaeger 默认环境变量失败"
        return 1
    }
    if [ -n "${TRACING_JAEGER_ES_INDEX_PREFIX:-}" ]; then
        export JAEGER_ES_INDEX_PREFIX="$TRACING_JAEGER_ES_INDEX_PREFIX"
        log_info "索引前缀改用 TRACING_JAEGER_ES_INDEX_PREFIX: ${JAEGER_ES_INDEX_PREFIX}"
    fi
    if [ -n "${TRACING_JAEGER_ISM_POLICY:-}" ]; then
        export JAEGER_ISM_POLICY="$TRACING_JAEGER_ISM_POLICY"
        log_info "ISM 策略名改用 TRACING_JAEGER_ISM_POLICY: ${JAEGER_ISM_POLICY}"
    fi
    export TEST_NS_A="${TRACING_MT_TEST_NS_A:-mt-tracing-a}"
    export TEST_NS_B="${TRACING_MT_TEST_NS_B:-mt-tracing-b}"
}

# 命名空间是否带本测试的标签（即由本测试创建）。kubectl 不允许名字与 -l 同用，故按标签列出再匹配名字
_mt_ns_owned() {
    kubectl get namespace -l "$MT_TEST_NS_LABEL" -o name 2>/dev/null | grep -qx "namespace/$1"
}

# 创建测试命名空间；已存在且不是本测试创建的则报错，避免 cleanup 误删
_mt_create_test_ns() {
    local ns="$1"
    if kubectl get namespace "$ns" >/dev/null 2>&1; then
        if _mt_ns_owned "$ns"; then
            log_info "复用上次测试残留的命名空间 ${ns}"
            return 0
        fi
        log_error "命名空间 ${ns} 已存在且不是本测试创建的，请用 TRACING_MT_TEST_NS_A / TRACING_MT_TEST_NS_B 指定不存在的命名空间"
        return 1
    fi
    kubectl create namespace "$ns" || return 1
    kubectl label namespace "$ns" "$MT_TEST_NS_LABEL" >/dev/null || return 1
}

# 租户隔离验证（文档 Verifying Tenant Isolation 及其注释块）
_mt_verify_isolation() {
    log_header "租户隔离验证"

    log_info "步骤 17: 创建测试命名空间 ${TEST_NS_A} / ${TEST_NS_B}"
    local ns
    if [ "$TEST_NS_A" = "$TEST_NS_B" ]; then
        log_error "TEST_NS_A 与 TEST_NS_B 不能相同: ${TEST_NS_A}"
        return 1
    fi
    for ns in "$TEST_NS_A" "$TEST_NS_B"; do
        _mt_create_test_ns "$ns" || return 1
    done

    log_info "步骤 17.1: 在两个命名空间部署 telemetrygen"
    _mt_deploy_telemetrygen || {
        log_error "telemetrygen 部署或运行失败"
        return 1
    }

    # 注释块：用 ServiceAccount token 代替测试用户
    log_info "步骤 18: 创建只能查看 ${TEST_NS_A} 调用链的 ServiceAccount 并签发 token"
    eval "$(runme print "${MT_PREFIX}:create-test-serviceaccount")" || {
        log_error "创建测试 ServiceAccount 失败"
        return 1
    }
    if [ -z "${TOKEN:-}" ]; then
        log_error "未签发到 ServiceAccount token"
        return 1
    fi
    # 文档块里 TOKEN 未 export，后续代码块在子进程执行
    export TOKEN

    # 服务列表不过滤：两个服务都应可见。span 写入与服务缓存有延迟，重试
    log_info "步骤 19: 验证服务列表包含两个命名空间的 telemetrygen"
    local rules
    rules="$(printf '+ telemetrygen.%s"\n+ telemetrygen.%s"' "$TEST_NS_A" "$TEST_NS_B")"
    retry_command "_mt_run_and_check '${MT_PREFIX}:verify-services' '${rules}'" 20 15 || {
        log_error "服务列表验证失败"
        return 1
    }

    # A：完整保留；B：mask 后 process 只剩命名空间属性，span 不再有业务 tag
    log_info "步骤 20: 验证两个命名空间调用链的可见范围"
    retry_command "_mt_check_isolation_output" 10 15 || {
        log_error "租户隔离验证失败"
        return 1
    }

    log_info "步骤 21: 删除测试 ServiceAccount 与 RoleBinding"
    _mt_run_strict "${MT_PREFIX}:delete-test-serviceaccount" || {
        log_error "删除测试 ServiceAccount 失败"
        return 1
    }
    log_success "租户隔离验证通过"
}

# 执行 verify-isolation 并逐个命名空间断言（retry_command 调用）
_mt_check_isolation_output() {
    local output line_a line_b
    output=$(_mt_run_strict "${MT_PREFIX}:verify-isolation" 2>&1) || {
        log_warn "verify-isolation 执行失败（可能尚未查到调用链）: $output"
        return 1
    }
    echo "$output"
    line_a=$(echo "$output" | awk -v h="== telemetrygen.${TEST_NS_A}" '$0==h {getline; print; exit}')
    line_b=$(echo "$output" | awk -v h="== telemetrygen.${TEST_NS_B}" '$0==h {getline; print; exit}')
    if ! __cmp_lines "$line_a" "$(cat <<'EOF'
+ "k8s.namespace.name"
+ "k8s.pod.name"
+ "network.peer.address"
EOF
)"; then
        log_warn "telemetrygen.${TEST_NS_A} 的 span 未完整保留: $line_a"
        return 1
    fi
    if ! __cmp_regex "$line_b" '^\{"process":\["k8s\.namespace\.name"\],"span":\[[^]]*\]\}$' \
        || ! __cmp_lines "$line_b" "$(cat <<'EOF'
- "network.peer.address"
- "k8s.pod.name"
EOF
)"; then
        log_warn "telemetrygen.${TEST_NS_B} 的 span 未被 mask: $line_b"
        return 1
    fi
    log_success "可见范围符合 mask 策略"
}

# (Optional) SPM 章节
_mt_test_spm() {
    log_header "Service Performance Monitoring (SPM) 测试"

    log_info "步骤 22: 拉取 monitoring 配置"
    eval "$(runme print "${MT_SPM_PREFIX}:get-monitoring-config")" || {
        log_error "拉取 monitoring 配置失败"
        return 1
    }

    log_info "步骤 23: 创建 monitoring 凭据 Secret"
    runme run "${MT_SPM_PREFIX}:create-monitoring-secret" || {
        log_error "创建 monitoring 凭据 Secret 失败"
        return 1
    }

    log_info "步骤 24: 生成 jaeger-spm-patch.yaml"
    runme print "${MT_SPM_PREFIX}:jaeger-spm-patch-yaml" > "${MT_WORK_DIR}/jaeger-spm-patch.yaml" || {
        log_error "生成 jaeger-spm-patch.yaml 失败"
        return 1
    }

    log_info "步骤 25: 应用 SPM patch"
    kubectl_apply_runme_block "${MT_SPM_PREFIX}:apply-jaeger-patch" "${MT_WORK_DIR}/" || {
        log_error "应用 SPM patch 失败"
        return 1
    }

    # Operator 分两步更新 Deployment：先等 Pod 模板带上新卷，再等滚动完成
    log_info "步骤 26: 等待 Jaeger 以 SPM 配置重启"
    retry_command "kubectl get deployment/${JAEGER_INSTANCE_NAME}-collector -n ${JAEGER_NS} \
        -o jsonpath='{.spec.template.spec.volumes[*].name}' | grep -qw monitoring-credentials" 18 10 || {
        log_error "Jaeger Deployment 未出现 monitoring-credentials 卷"
        return 1
    }
    runme run "${MT_SPM_PREFIX}:wait-jaeger-rollout" || {
        log_error "等待 Jaeger 重启失败"
        return 1
    }
    log_success "SPM 测试完成"
}

test_installing_multi_tenant_tracing_opensearch() {
    log_info "=========================================="
    log_info "开始多租户调用链安装测试 (OpenSearch)"
    log_info "=========================================="

    # 步骤 0: OpenSearch 存储后端（规则同 installing-distributed-tracing-opensearch）
    if tracing_opensearch_auto_install_enabled; then
        log_info "步骤 0: 自动安装 OpenSearch 存储后端"
        tracing_ensure_opensearch || {
            log_error "OpenSearch 存储后端自动安装失败"
            return 1
        }
    elif [ -n "${TRACING_OPENSEARCH_ENDPOINT:-}" ] && [ -n "${TRACING_OPENSEARCH_USER:-}" ] && [ -n "${TRACING_OPENSEARCH_PASS:-}" ]; then
        log_info "步骤 0: 使用手动 OpenSearch 配置: endpoint=${TRACING_OPENSEARCH_ENDPOINT}"
    else
        skip_test_env "OpenSearch 存储后端不可用：自动安装未启用，且未设置 TRACING_OPENSEARCH_ENDPOINT / USER / PASS，跳过多租户调用链安装测试"
        return 0
    fi
    mkdir -p "$MT_WORK_DIR"

    # 步骤 1: 集群插件（CLI 章节代码块 1-3）；第 3 参传空：本文档的目标集群侧校验在步骤 2
    log_info "步骤 1: 安装 Jaeger v2 集群插件（CLI 方式）"
    tracing_install_jaeger_plugin "$MT_PREFIX" "" "" || {
        log_error "Jaeger v2 集群插件安装失败"
        return 1
    }

    log_info "步骤 2: 验证插件在目标集群创建的资源"
    _mt_run_and_check "${MT_PREFIX}:verify-jaeger-plugin-resources" "$(cat <<'EOF'
+ observability-gateway
+ tracing.alauda.io:traces-viewer
EOF
)" || return 1

    # 步骤 3-4: Operator 创建 RBAC 的授权；Operator 已在运行时按文档重启
    local operator_running=false
    if kubectl get pod -n "$OTEL_OPERATOR_NS" -l app.kubernetes.io/name=opentelemetry-operator \
        -o name 2>/dev/null | grep -q .; then
        operator_running=true
    fi

    log_info "步骤 3: 授权 OTel Operator 创建 RBAC 资源"
    runme run "${MT_PREFIX}:create-operator-rbac-clusterrole" || {
        log_error "创建 ClusterRole generate-processors-rbac 失败"
        return 1
    }
    runme run "${MT_PREFIX}:create-operator-rbac-clusterrolebinding" || {
        log_error "创建 ClusterRoleBinding generate-processors-rbac 失败"
        return 1
    }

    if [ "$operator_running" = true ]; then
        log_info "步骤 4: Operator 已在运行，重启以加载新权限"
        runme run "${MT_PREFIX}:restart-operator" || {
            log_error "重启 OTel Operator 失败"
            return 1
        }
        kubectl rollout status deployment -n "$OTEL_OPERATOR_NS" \
            -l app.kubernetes.io/name=opentelemetry-operator --timeout=180s || {
            log_error "等待 OTel Operator 重启就绪失败"
            return 1
        }
        retry_command "kubectl wait pod -n ${OTEL_OPERATOR_NS} -l app.kubernetes.io/name=opentelemetry-operator --for=condition=Ready --timeout=60s" 6 10 || {
            log_error "等待 OTel Operator Pod 就绪失败"
            return 1
        }
    else
        log_info "步骤 4: Operator 尚未安装，按文档跳过重启"
    fi

    log_info "步骤 5: 安装 OpenTelemetry v2 Operator"
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

    log_info "步骤 6: 设置 OpenSearch 连接变量、拉取平台配置与默认变量"
    export OPENSEARCH_ENDPOINT="$TRACING_OPENSEARCH_ENDPOINT"
    export OPENSEARCH_USER="$TRACING_OPENSEARCH_USER"
    export OPENSEARCH_PASS="$TRACING_OPENSEARCH_PASS"
    _mt_load_env || return 1
    # 文档 note：所有变量都不能为空
    local v
    for v in PLATFORM_URL CLUSTER_NAME ALB_CLASS_NAME OIDC_CLIENT_ID OIDC_CLIENT_SECRET \
        JAEGER_IMAGE JAEGER_ES_ROLLOVER_IMAGE GATEWAY_IMAGE; do
        if [ -z "${!v}" ]; then
            log_error "平台配置变量 ${v} 为空"
            return 1
        fi
    done
    log_success "平台配置完整: cluster=${CLUSTER_NAME} gateway=${GATEWAY_IMAGE}"

    log_info "步骤 7: 创建命名空间与 OpenSearch 凭据 Secret"
    _mt_run_strict "${MT_PREFIX}:create-jaeger-ns-and-opensearch-secret" || {
        log_error "创建命名空间与 OpenSearch Secret 失败"
        return 1
    }
    _mt_run_and_check "${MT_PREFIX}:verify-opensearch-secret" "+ opensearch-credentials" || return 1

    log_info "步骤 8: 创建并验证 ISM 策略 ${JAEGER_ISM_POLICY}"
    tracing_reset_ism_policy
    runme run "${MT_PREFIX}:create-ism-policy" || {
        log_error "创建 ISM 策略失败"
        return 1
    }
    _mt_run_and_check "${MT_PREFIX}:verify-ism-policy" "$(cat <<EOF
+ "policy_id" : "${JAEGER_ISM_POLICY}"
+ "name" : "hot"
+ "name" : "delete"
EOF
)" || return 1

    log_info "步骤 9: 初始化索引别名与模板"
    runme run "${MT_PREFIX}:create-rollover-init-job" || {
        log_error "创建 rollover-init Job 失败"
        return 1
    }
    _mt_run_and_check "${MT_PREFIX}:verify-rollover-init" "$(cat <<EOF
+ ${JAEGER_ES_INDEX_PREFIX}-jaeger-span
+ ${JAEGER_ES_INDEX_PREFIX}-jaeger-sampling
+ ${JAEGER_ES_INDEX_PREFIX}-jaeger-span-read
+ ${JAEGER_ES_INDEX_PREFIX}-jaeger-span-write
+ ${JAEGER_ES_INDEX_PREFIX}-jaeger-service-write
EOF
)" || return 1
    runme run "${MT_PREFIX}:verify-ism-attached" || {
        log_error "查询 ISM explain 失败"
        return 1
    }
    tracing_verify_ism_attached || return 1
    runme run "${MT_PREFIX}:delete-rollover-init-job" || {
        log_error "清理 rollover-init Job 失败"
        return 1
    }

    log_info "步骤 10: 创建网关登录 Secret 与网关 RBAC"
    _mt_run_strict "${MT_PREFIX}:create-gateway-oidc-secret" || {
        log_error "创建网关登录 Secret 失败"
        return 1
    }
    runme run "${MT_PREFIX}:create-gateway-rbac" || {
        log_error "创建网关 RBAC 失败"
        return 1
    }

    log_info "步骤 11: 生成并应用网关配置"
    runme print "${MT_PREFIX}:gateway-config-yaml" > "${MT_WORK_DIR}/gateway-config.yaml" || {
        log_error "生成 gateway-config.yaml 失败"
        return 1
    }
    kubectl_apply_runme_block "${MT_PREFIX}:apply-gateway-config" "${MT_WORK_DIR}/" || return 1

    log_info "步骤 12: 部署 Jaeger 与网关"
    runme print "${MT_PREFIX}:jaeger-yaml" > "${MT_WORK_DIR}/jaeger.yaml" || {
        log_error "生成 jaeger.yaml 失败"
        return 1
    }
    kubectl_apply_runme_block "${MT_PREFIX}:apply-jaeger" "${MT_WORK_DIR}/" || return 1
    _mt_wait_collector "$JAEGER_INSTANCE_NAME" "${MT_PREFIX}:wait-jaeger-rollout" || return 1

    log_info "步骤 13: 暴露 Jaeger UI 并创建网关 ServiceMonitor"
    runme run "${MT_PREFIX}:label-jaeger-ns" || return 1
    runme run "${MT_PREFIX}:create-jaeger-ingress" || {
        log_error "创建 Ingress 失败"
        return 1
    }
    runme run "${MT_PREFIX}:wait-jaeger-ingress" || {
        log_error "等待 Ingress 就绪失败"
        return 1
    }
    runme run "${MT_PREFIX}:create-gateway-servicemonitor" || {
        log_error "创建网关 ServiceMonitor 失败"
        return 1
    }

    # 注释块：未登录浏览器跳转平台登录页。ALB 规则生效有延迟，重试
    # 不锚定行首：runme 启动的交互 shell 可能先输出终端转义序列（如 iTerm2 集成的 OSC 1337）
    log_info "步骤 14: 验证网关把未登录浏览器重定向到平台登录页"
    retry_command "runme run ${MT_PREFIX}:verify-gateway-login-redirect 2>&1 \
        | tee /dev/stderr | grep -qE '302 https?://[^ ]+/auth[?]client_id='" 18 10 || {
        log_error "网关登录重定向验证失败"
        return 1
    }

    log_info "步骤 15: 打印 Jaeger UI 地址"
    local url_output
    url_output=$(runme run "${MT_PREFIX}:print-jaeger-url" 2>&1)
    echo "$url_output"
    __cmp_contains "$url_output" "Jaeger UI: ${PLATFORM_URL}${JAEGER_BASEPATH}" || {
        log_error "Jaeger UI 地址不符"
        return 1
    }

    log_info "步骤 16: 部署平台 OpenTelemetry Collector"
    runme print "${MT_PREFIX}:otel-collector-yaml" > "${MT_WORK_DIR}/otel-collector.yaml" || {
        log_error "生成 otel-collector.yaml 失败"
        return 1
    }
    kubectl_apply_runme_block "${MT_PREFIX}:apply-otel-collector" "${MT_WORK_DIR}/" || return 1
    _mt_wait_collector otel "${MT_PREFIX}:wait-otel-collector-rollout" || return 1
    _mt_run_and_check "${MT_PREFIX}:verify-otel-collector-rbac" "$(cat <<EOF
+ otel-${JAEGER_NS}-cluster-role
+ otel-${JAEGER_NS}-collector
EOF
)" || return 1

    _mt_verify_isolation || return 1

    if [ "${TRACING_TEST_SPM:-true}" = "true" ]; then
        _mt_test_spm || return 1
    else
        log_warn "跳过 SPM 章节测试（TRACING_TEST_SPM=false）"
    fi

    log_success "=========================================="
    log_success "多租户调用链安装测试 (OpenSearch) 完成，所有验证通过！"
    log_success "=========================================="
    return 0
}

# 文档 Uninstalling 第 2、3 步，以及脚本自建的测试命名空间。
# 第 1 步（删除 Collector 与 Jaeger 命名空间）由编排脚本调用卸载文档测试完成，须先于本函数执行。
cleanup_installing_multi_tenant_tracing_opensearch() {
    log_info "=========================================="
    log_info "清理多租户调用链测试资源"
    log_info "=========================================="

    _mt_load_env || return 1

    log_info "删除网关的集群级 RBAC"
    _mt_run_strict "${MT_PREFIX}:delete-gateway-rbac" || {
        log_error "删除网关 RBAC 失败"
        return 1
    }

    # 只删本测试创建的两个命名空间：按名字删，且须带本测试标签
    local ns
    for ns in "$TEST_NS_A" "$TEST_NS_B"; do
        if ! _mt_ns_owned "$ns"; then
            log_info "命名空间 ${ns} 不存在或不是本测试创建的，跳过删除"
            continue
        fi
        log_info "删除测试命名空间 ${ns}"
        kubectl delete namespace "$ns" --wait=true --timeout=180s || {
            log_error "删除测试命名空间 ${ns} 失败"
            return 1
        }
    done

    log_success "测试资源清理完成"
    return 0
}
