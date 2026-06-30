#!/usr/bin/env bash
# SPM 多副本（高可用）验证测试 —— Elasticsearch 场景。
#
# 不修改、不依赖任何 mdx runme 代码块；在已按安装文档启用 SPM 的环境上，
# 将 otel 与 jaeger 扩容到多副本，并校验「单写入者」：每个 service 只被一个
# Jaeger 副本聚合 spanmetrics，指标不碎片、不重复。
#
# 验证逻辑见同目录 _spm-ha-common.sh；手动操作手册见
# distributed-tracing-docs/.helper/ops/spanmetrics-ha-verification.md。

set -e

: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"

# 加载框架函数库
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
# 加载 SPM HA 公共验证逻辑（与 opensearch 版共用）
source "$(dirname "${BASH_SOURCE[0]}")/_spm-ha-common.sh"

# 测试函数：Elasticsearch 场景下的 SPM 多副本验证
test_spm_ha_elasticsearch() {
    _spm_ha_run "elasticsearch"
}

# 清理函数：删除 telemetrygen 并缩容回单副本
cleanup_spm_ha_elasticsearch() {
    _spm_ha_cleanup
}
