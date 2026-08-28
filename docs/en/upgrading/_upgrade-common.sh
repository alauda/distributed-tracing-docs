#!/usr/bin/env bash
# Alauda Distributed Tracing v2.0 → v2.1 升级文档测试的公共逻辑。
#
# 被 runme-test_upgrading-distributed-tracing-elasticsearch.sh 与
#    runme-test_upgrading-distributed-tracing-opensearch.sh 复用。
#
# 两篇升级文档的 23 / 29 个代码块中有 16 个逐字节相同——集群插件安装、Operator 升级、
# otel Collector 配置迁移、两段 SPM patch、收尾验证；只有存储后端相关的中段
# （ES 重跑 rollover init / OpenSearch 迁移到 ISM）与 jaeger、oauth2 两次 patch 的
# 先后顺序不同。故共同部分按 runme 前缀参数化集中于此，两个测试脚本只保留差异步骤。
#
# 落点与同仓 docs/en/installing/_spm-ha-common.sh 一致：与被测 .mdx 同仓同目录，
# 文档改动与测试改动进同一个 PR。

# 复用框架侧的 Jaeger v2 集群插件共享安装逻辑（tracing_install_jaeger_plugin）。
# 经 docs-runme-tests/run.sh 运行时引擎已对 --project tracing 自动 source 该文件；
# 这里补一次加载，兼容直接 source 本文件的场景。
[ -n "${FRAMEWORK_ROOT:-}" ] && [ -f "$FRAMEWORK_ROOT/projects/tracing/project.sh" ] \
    && source "$FRAMEWORK_ROOT/projects/tracing/project.sh"

# ── 可调参数 ──────────────────────────────────────────────────────────────────
# Operator 升级后等待新 CSV 进入 Succeeded 的轮询次数与间隔（实测约 45s）
UPGRADE_CSV_RETRIES="${UPGRADE_CSV_RETRIES:-24}"
UPGRADE_CSV_INTERVAL="${UPGRADE_CSV_INTERVAL:-10}"
# CR patch 的重试次数与间隔。Operator 升级会重签 admission webhook 证书，紧接着
# patch CR 会报 `x509: certificate signed by unknown authority`（两篇文档均有 note）
UPGRADE_PATCH_RETRIES="${UPGRADE_PATCH_RETRIES:-10}"
UPGRADE_PATCH_INTERVAL="${UPGRADE_PATCH_INTERVAL:-15}"

# ── 门槛检测 ──────────────────────────────────────────────────────────────────

# 升级测试要求环境上存在一套 **v2.0** 部署，判据三条：
#   1. Jaeger 命名空间与实例存在      —— 否则根本没装过调用链
#   2. 存储后端与本篇文档匹配          —— ES 篇不能跑在 OpenSearch 部署上，反之亦然
#   3. 配置里带 v2.0 特征字段          —— 已是 v2.1 形态就没有可升的内容
#        ES : elasticsearch.use_aliases / use_ilm（这两个字段被 v2.20.0 拒绝）
#        OS : opensearch.indices.spans.date_layout / rollover_frequency（v2.1 改用
#             rotation.auto_rollover，且这两个扁平字段与 rotation 并存会校验失败）
#
# 用法: _upgrade_precheck <elasticsearch|opensearch>
# 返回: 0=可继续；2=已调用 skip_test_env，调用方应立即 return 0；1=出错
#
# NOTE: 本函数早于 set-vars 执行（set-vars 要从 CR 上反查端点，CR 不在时读到的是空值），
#       故这里用文档 set-vars 里的同名默认值 jaeger-system / jaeger。
_upgrade_precheck() {
    local backend="$1"
    local ns="${JAEGER_NS:-jaeger-system}"
    local instance="${JAEGER_INSTANCE_NAME:-jaeger}"
    local storage_key legacy_fields legacy_desc

    case "$backend" in
        elasticsearch)
            storage_key="es_storage"
            legacy_fields="{.spec.config.extensions.jaeger_storage.backends.es_storage.elasticsearch.use_aliases}{.spec.config.extensions.jaeger_storage.backends.es_storage.elasticsearch.use_ilm}"
            legacy_desc="use_aliases / use_ilm"
            ;;
        opensearch)
            storage_key="opensearch_storage"
            legacy_fields="{.spec.config.extensions.jaeger_storage.backends.opensearch_storage.opensearch.indices.spans.date_layout}{.spec.config.extensions.jaeger_storage.backends.opensearch_storage.opensearch.indices.spans.rollover_frequency}"
            legacy_desc="indices.spans.date_layout / rollover_frequency"
            ;;
        *)
            log_error "_upgrade_precheck: 未知存储后端 ${backend}"
            return 1
            ;;
    esac

    if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
        skip_test_env "命名空间 ${ns} 不存在，未检测到分布式调用链部署，跳过升级测试"
        return 2
    fi

    local backends
    backends=$(kubectl -n "$ns" get opentelemetrycollector "$instance" \
        -o jsonpath='{.spec.config.extensions.jaeger_storage.backends}' 2>/dev/null || echo "")
    if [ -z "$backends" ]; then
        skip_test_env "命名空间 ${ns} 中不存在 Jaeger 实例 ${instance}，跳过升级测试"
        return 2
    fi
    case "$backends" in
        *"$storage_key"*) : ;;
        *)
            skip_test_env "Jaeger 实例 ${instance} 未使用 ${storage_key} 存储后端，与本篇升级文档不匹配，跳过升级测试"
            return 2
            ;;
    esac

    local legacy
    legacy=$(kubectl -n "$ns" get opentelemetrycollector "$instance" \
        -o jsonpath="$legacy_fields" 2>/dev/null || echo "")
    if [ -z "$legacy" ]; then
        skip_test_env "Jaeger 实例 ${instance} 的配置中未发现 v2.0 特征字段（${legacy_desc}），当前已是 v2.1 形态，跳过升级测试"
        return 2
    fi

    log_success "门槛检查通过：${ns}/${instance} 为 ${storage_key} 的 v2.0 部署（含 ${legacy_desc}）"
    return 0
}

# ── 共同步骤 ──────────────────────────────────────────────────────────────────

# 文档「Setting environment variables」：eval set-vars 代码块（模式 F），
# 并校验必须导出的变量非空——空值意味着从 CR / Secret 反查失败，后续步骤会用空端点。
# 用法: _upgrade_set_vars <prefix> <必须非空的变量名>...
_upgrade_set_vars() {
    local prefix="$1"
    shift

    log_info "设置升级环境变量 (${prefix}:set-vars)"
    eval "$(runme print "${prefix}:set-vars")" || {
        log_error "设置升级环境变量失败"
        return 1
    }

    local name
    for name in "$@"; do
        if [ -z "${!name:-}" ]; then
            log_error "环境变量 ${name} 为空——未能从运行中的部署反查到该配置"
            return 1
        fi
        log_info "  ${name}=${!name}"
    done
    return 0
}

# 文档「Installing the Alauda Build of Jaeger v2 Cluster Plugin > Installing via the CLI」：
# 3 个代码块与两篇安装文档逐字节相同，直接复用框架侧共享函数。
# 第三参数传空——升级文档没有 verify-jaeger-plugin-configmap 代码块，
# 镜像清单改由随后的 get-plugin-images 直接读取。
_upgrade_install_plugin() {
    local prefix="$1"
    tracing_install_jaeger_plugin "$prefix" "" ""
}

# 文档「Reading the image addresses」：eval get-plugin-images（模式 F），
# 导出 JAEGER_IMAGE / JAEGER_ES_ROLLOVER_IMAGE / JOAUTH2_PROXY_IMAGE 供后续步骤使用。
_upgrade_get_plugin_images() {
    local prefix="$1"

    log_info "读取集群插件下发的镜像地址 (${prefix}:get-plugin-images)"
    eval "$(runme print "${prefix}:get-plugin-images")" || {
        log_error "读取镜像地址失败"
        return 1
    }

    local name
    for name in JAEGER_IMAGE JAEGER_ES_ROLLOVER_IMAGE JOAUTH2_PROXY_IMAGE; do
        if [ -z "${!name:-}" ]; then
            log_error "${name} 为空——cpaas-system/jaeger-cluster-plugin-manifest 未就绪"
            return 1
        fi
        log_info "  ${name}=${!name}"
    done
    return 0
}

# 文档「Upgrading the Alauda Build of OpenTelemetry v2 Operator > Upgrading via the CLI」：
# check-operator-versions（模式 A）→ approve-installplan（模式 A）→
# verify-operator-csv + 其 -output（模式 I，带等待）。
#
# 两处补充的辅助逻辑：
#   - approve-installplan 在「已经升过」的环境上是幂等的：subscription 指向的
#     InstallPlan 已 approved，replace 成同一个值不会报错。
#   - 文档只给了一次性的 kubectl get csv，没有等待；实测新 CSV 约 45s 才 Succeeded，
#     故这里轮询。断言取期望输出里的 NAME 与 PHASE 两列——DISPLAY / REPLACES 随环境
#     浮动，用 __cmp_lines 关键字断言而非整块 __cmp_contains。
_upgrade_operator() {
    local prefix="$1"

    log_info "确认订阅 channel 中的目标版本 (${prefix}:check-operator-versions)"
    runme run "${prefix}:check-operator-versions" || {
        log_error "查询 Operator 可用版本失败"
        return 1
    }

    log_info "批准待处理的 InstallPlan (${prefix}:approve-installplan)"
    runme run "${prefix}:approve-installplan" || {
        log_error "批准 InstallPlan 失败"
        return 1
    }

    local expected expected_csv expected_phase csv_output i
    expected=$(runme print "${prefix}:verify-operator-csv-output")
    expected_csv=$(echo "$expected" | awk '$1 ~ /^opentelemetry-operator2\./ {print $1; exit}')
    expected_phase=$(echo "$expected" | awk '$1 ~ /^opentelemetry-operator2\./ {print $NF; exit}')
    if [ -z "$expected_csv" ] || [ -z "$expected_phase" ]; then
        log_error "未能从 ${prefix}:verify-operator-csv-output 解析出目标 CSV 与 PHASE"
        log_error "期望输出: $expected"
        return 1
    fi

    # 断言必须落在**同一行**：升级过程中存在「旧 CSV 还是 Succeeded、新 CSV 还在 Installing」
    # 的窗口，用 __cmp_lines 的两个独立关键字会在这个窗口里误判为已完成。
    # runme run 的输出是 pty 的 CRLF，awk 比对前先去掉 \r。
    log_info "等待 ${expected_csv} 进入 ${expected_phase} (${prefix}:verify-operator-csv)"
    i=0
    while [ "$i" -lt "$UPGRADE_CSV_RETRIES" ]; do
        csv_output=$(runme run "${prefix}:verify-operator-csv" 2>&1 || true)
        if echo "$csv_output" | awk -v csv="$expected_csv" -v phase="$expected_phase" \
                '{gsub(/\r/, "")} $1 == csv && $NF == phase {found = 1} END {exit !found}'; then
            echo "$csv_output"
            log_success "Operator 升级完成 (${expected_csv} ${expected_phase})"
            return 0
        fi
        i=$((i + 1))
        log_warn "CSV 尚未就绪，等待 Operator 升级收敛 (${i}/${UPGRADE_CSV_RETRIES})"
        sleep "$UPGRADE_CSV_INTERVAL"
    done

    log_error "Operator 升级未在预期时间内完成"
    log_error "期待同一行同时出现: ${expected_csv} 与 ${expected_phase}"
    log_error "实际输出: $csv_output"
    return 1
}

# 生成 patch 文件并在 /tmp 下渲染应用（模式 C + 模式 E）。
# apply 带重试：Operator 升级后 admission webhook 证书有一段轮换窗口，
# 此时 patch CR 会被拒绝（两篇文档的 note 都写了「等几秒再试」）。
# 用法: _upgrade_apply_patch <yaml 代码块> <apply 代码块> <文件名>
_upgrade_apply_patch() {
    local yaml_block="$1" apply_block="$2" filename="$3"

    log_info "生成 /tmp/${filename} (${yaml_block})"
    runme print "$yaml_block" > "/tmp/${filename}" || {
        log_error "生成 ${filename} 失败"
        return 1
    }

    log_info "渲染并应用 ${filename} (${apply_block})"
    if ! retry_command "kubectl_apply_runme_block '${apply_block}' '/tmp/'" \
            "$UPGRADE_PATCH_RETRIES" "$UPGRADE_PATCH_INTERVAL"; then
        log_error "应用 ${filename} 失败"
        return 1
    fi
    return 0
}

# 文档「Updating the OpenTelemetry Collector」：otel-upgrade-patch-yaml（模式 C）→
# apply-otel-patch（模式 E）→ verify-otel-collector（模式 A，块内自带 rollout status，
# 且用 `|| echo "No deprecation warnings"` 兜住 grep 无匹配时的返回码 1）。
_upgrade_otel_collector() {
    local prefix="$1"

    _upgrade_apply_patch "${prefix}:otel-upgrade-patch-yaml" \
        "${prefix}:apply-otel-patch" "otel-upgrade-patch.yaml" || return 1

    log_info "等待 Collector 重启并确认无弃用告警 (${prefix}:verify-otel-collector)"
    local output
    output=$(runme run "${prefix}:verify-otel-collector" 2>&1) || {
        log_error "验证 OpenTelemetry Collector 失败"
        log_error "输出: $output"
        return 1
    }
    echo "$output"
    log_success "OpenTelemetry Collector 配置迁移通过"
    return 0
}

# 判断当前部署是否启用了 SPM。文档两段 SPM 步骤标注为 (Optional)，只对启用了 SPM 的
# 部署适用：没配 spanmetrics connector 的实例硬打 SPM patch 会造出半条 metrics 流水线，
# Jaeger 直接起不来。判据用 glob 同时兼容 v2.0 的旧别名 spanmetrics 与改名后的
# span_metrics（后者用于重跑场景）。TRACING_TEST_SPM=false 可强制跳过。
# 返回: 0=已启用；1=未启用
_upgrade_spm_enabled() {
    if [ "${TRACING_TEST_SPM:-true}" != "true" ]; then
        log_warn "TRACING_TEST_SPM=false，跳过两段 SPM 章节"
        return 1
    fi
    local connectors
    connectors=$(kubectl -n "${JAEGER_NS}" get opentelemetrycollector "${JAEGER_INSTANCE_NAME}" \
        -o jsonpath='{.spec.config.connectors}' 2>/dev/null || echo "")
    case "$connectors" in
        *span*metrics*)
            log_info "检测到 SPM 已启用（Jaeger 实例配置了 spanmetrics connector）"
            return 0
            ;;
        *)
            log_warn "当前部署未启用 SPM，跳过两段 (Optional) SPM 章节"
            return 1
            ;;
    esac
}

# 文档「(Optional) Updating the Collector for Service Performance Monitoring」：
# 把 loadbalancing exporter 改名为 load_balancing。前缀为 <文档前缀>-spm。
_upgrade_otel_spm() {
    local spm_prefix="$1"

    _upgrade_apply_patch "${spm_prefix}:otel-spm-upgrade-patch-yaml" \
        "${spm_prefix}:apply-otel-patch" "otel-spm-upgrade-patch.yaml" || return 1

    log_success "OpenTelemetry Collector SPM 配置迁移通过"
    return 0
}

# 文档「(Optional) Updating Jaeger for Service Performance Monitoring」：
# 把 spanmetrics connector 改名为 span_metrics。前缀为 <文档前缀>-spm。
_upgrade_jaeger_spm() {
    local spm_prefix="$1"

    _upgrade_apply_patch "${spm_prefix}:jaeger-spm-upgrade-patch-yaml" \
        "${spm_prefix}:apply-jaeger-patch" "jaeger-spm-upgrade-patch.yaml" || return 1

    log_success "Jaeger SPM 配置迁移通过"
    return 0
}

# 文档「Verification」前两步：verify-versions（模式 I——VERSION / AGE / Pod 名后缀均为
# 动态值，只断言两个实例与 Running）、verify-jaeger-logs（模式 A，块内已用
# `|| echo "No warnings"` 兜住 grep 返回码）。
# 第三步是「按安装文档生成 trace 验证」的文字引用，无代码块，不在测试范围内。
_upgrade_verify() {
    local prefix="$1"

    log_info "确认组件版本与 Pod 状态 (${prefix}:verify-versions)"
    local output
    output=$(runme run "${prefix}:verify-versions" 2>&1) || {
        log_error "查询组件版本与 Pod 状态失败"
        log_error "输出: $output"
        return 1
    }
    echo "$output"
    # 代码块输出两段：get opentelemetrycollector 与 get pods。这里逐 Pod 校验状态而不是
    # 用 `+ Running` 这类关键字——后者只要任意一行含 Running 就算过，Jaeger 崩了而 otel
    # 正常时会误判。Pod 行按 `<实例>-collector-<hash>` 前缀识别（CR 那段的 NAME 无此后缀），
    # STATUS 是第 3 列；runme run 输出是 CRLF，比对前先去掉 \r。
    if ! echo "$output" | awk -v jc="${JAEGER_INSTANCE_NAME}-collector-" '
            {gsub(/\r/, "")}
            index($1, jc) == 1        { jaeger++; if ($3 != "Running") bad = 1 }
            index($1, "otel-collector-") == 1 { otel++;   if ($3 != "Running") bad = 1 }
            END { exit !(jaeger > 0 && otel > 0 && !bad) }'; then
        log_error "组件状态验证失败（期待 ${JAEGER_INSTANCE_NAME}-collector 与 otel-collector 的 Pod 均为 Running）"
        log_error "实际输出: $output"
        return 1
    fi
    log_success "组件版本与 Pod 状态验证通过"

    log_info "确认 Jaeger 启动无告警 (${prefix}:verify-jaeger-logs)"
    output=$(runme run "${prefix}:verify-jaeger-logs" 2>&1) || {
        log_error "查询 Jaeger 日志失败"
        log_error "输出: $output"
        return 1
    }
    echo "$output"
    log_success "Jaeger 日志检查完成"
    return 0
}
